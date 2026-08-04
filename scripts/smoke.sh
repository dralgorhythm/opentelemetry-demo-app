#!/usr/bin/env bash
# The deploy gate, executable — behavior checks through the ALB, not a
# liveness ping. The one non-obvious assert is COUNTER MONOTONICITY: two
# greetings in a row must show a growing visitor number, which proves the
# whole ElastiCache round trip (rediss:// TLS + AUTH token via the CSI-
# mounted config) end to end — a pod serving 200s with a dead Redis would
# 500 on /, and a stale deploy would still increment, which is why the
# counter check complements (not replaces) the content asserts.
#
#   scripts/smoke.sh cloud    # the live stack through the ALB (CI's deploy gate)
#
# The mode arg is kept for future postures (local/preview — the template
# this derives from has them; this app runs cloud-only for now). No
# EXPECT_SHA: the app has no version stamp yet (deferred with
# service.version) — "deploy green but old version serving" is currently
# only caught by helm's own rollout tracking.
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-}"

# Counters, not set -e aborts: run EVERY check and fail at the end — a smoke
# run's value is the full picture, not the first red.
pass=0 fail=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); }
bad() { echo "  ✗ $1"; fail=$((fail + 1)); }

expect_status() { # <desc> <want> <url/curl args...>
  local desc=$1 want=$2 got; shift 2
  got=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@") || got="curl-error"
  if [[ "$got" == "$want" ]]; then ok "$desc ($got)"; else bad "$desc: want $want, got $got"; fi
}
expect_contains() { # <desc> <needle> <url/curl args...>
  local desc=$1 needle=$2 body; shift 2
  body=$(curl -s --max-time 10 "$@") || body="(curl error)"
  if [[ "$body" == *"$needle"* ]]; then ok "$desc"; else bad "$desc: no '$needle' in: $body"; fi
}

visitor_count() { # counter of the greeting ("…visitor number N"), or ""
  # Anchored to the greeting phrase on purpose: a bare last-integer grab
  # would let digits in an error page (ALB "503 Service Temporarily
  # Unavailable" HTML) masquerade as a counter — empty output now means
  # "no greeting at all", distinct from a real non-increment.
  curl -s --max-time 10 "http://$HOST/" | grep -oE 'visitor number [0-9]+' | grep -oE '[0-9]+' | tail -1 || true
}

case "$mode" in
  cloud)
    # Target selection (multi-env): CLUSTER/AWS_REGION env vars with dev
    # defaults. CI's deploy job exports both; a bare laptop run means the
    # dev stack. Per-env clusters are identical inside (cluster-per-env, not
    # namespace-per-env), so nothing below this line knows which environment
    # it is smoking.
    CLUSTER="${CLUSTER:-otel-demo-app-dev}"
    AWS_REGION="${AWS_REGION:-us-east-1}"
    # Trace-gate window opens HERE, before any request is made — every span
    # this run generates falls inside [smoke_start, now].
    smoke_start=$(date +%s)
    # Region-drift witness: say where the regional reads below actually
    # point before trusting any of them.
    echo "smoke[cloud]: target $CLUSTER/$AWS_REGION — aws-cli $(aws configure list 2>/dev/null | awk '/region/ {$1=$1; print; exit}')"
    aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION" >/dev/null
    # Ingress name = release name (roster convention): derive (svc, ns) from
    # the roster's first entry instead of hardcoding the pair — the roster
    # has ONE parser (scripts/roster.sh) and this is just another consumer.
    IFS=$'\t' read -r svc _f ns < <(scripts/roster.sh | head -n 1)
    # Bounded wait: on a fresh bring-up the ALB takes 2-4 min to provision;
    # on an up stack the first probe succeeds and this costs nothing.
    HOST=""
    for _ in $(seq 1 30); do
      HOST=$(kubectl -n "$ns" get ingress "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
      [[ -n "$HOST" ]] && curl -sf --max-time 5 "http://$HOST/healthz" >/dev/null 2>&1 && break
      HOST=""; sleep 10
    done
    [[ -n "$HOST" ]] || { echo "ALB never became reachable — is the stack up?"; exit 1; }
    # In CI, hand the host to the deploy summary step machine-readably —
    # the workflow must not re-derive the ingress lookup this script owns.
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "host=$HOST" >> "$GITHUB_OUTPUT"; fi
    echo "$svc through the ALB ($HOST):"
    # healthz has NO dependencies by design (readiness on / would evict all
    # pods on a Redis blip) — so a healthy healthz plus a healthy greeting
    # below are two different claims, and both get asserted.
    expect_status   "healthz"                200 "http://$HOST/healthz"
    expect_contains "healthz body"           "ok" "http://$HOST/healthz"
    expect_status   "greeting serves"        200 "http://$HOST/"
    expect_contains "greeting text"          "Hello, World! You are visitor number" "http://$HOST/"
    # The Redis round trip: INCRBY on every / hit, so two reads must be
    # strictly increasing. (Two replicas share one ElastiCache primary —
    # monotonic across pods; concurrent visitors only push n2 higher.)
    n1=$(visitor_count); n2=$(visitor_count)
    if [[ "$n1" =~ ^[0-9]+$ && "$n2" =~ ^[0-9]+$ && "$n2" -gt "$n1" ]]; then
      ok "visitor counter increments ($n1 -> $n2 — ElastiCache TLS+AUTH round trip)"
    else
      bad "visitor counter not monotonic (got '$n1' then '$n2')"
    fi
    # Trace gate — the pipeline the whole demo exists to prove
    # (app -> ADOT -> X-Ray) gets an enforced assert, not an info line. The
    # greeting hits above generated spans; X-Ray ingestion lags ~10-30s, so
    # poll every 15s for up to 90s for >=1 trace from service "app"
    # (OTEL_SERVICE_NAME, deploy/services/app.yaml) inside this run's window.
    traces=0
    for attempt in $(seq 1 7); do
      traces=$(aws xray get-trace-summaries --region "$AWS_REGION" \
            --start-time "$smoke_start" --end-time "$(date +%s)" \
            --filter-expression 'service("app")' \
            --query 'length(TraceSummaries)' --output text 2>/dev/null || echo 0)
      [[ "$traces" =~ ^[0-9]+$ && "$traces" -ge 1 ]] && break
      [[ "$attempt" -lt 7 ]] && sleep 15
    done
    if [[ "$traces" =~ ^[0-9]+$ && "$traces" -ge 1 ]]; then
      ok "X-Ray has traces from service 'app' in the smoke window ($traces — app -> ADOT -> X-Ray)"
    else
      bad "no X-Ray trace from service 'app' within 90s — the app -> ADOT -> X-Ray pipeline is not delivering"
    fi
    ;;
  *)
    echo "usage: $0 cloud   (local/preview postures deferred — cloud is the only mode)"
    exit 2
    ;;
esac

echo
echo "passed $pass, failed $fail"
[[ $fail -eq 0 ]]

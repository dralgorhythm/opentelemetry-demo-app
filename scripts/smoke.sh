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

visitor_count() { # trailing integer of the greeting ("…visitor number N"), or ""
  curl -s --max-time 10 "http://$HOST/" | grep -oE '[0-9]+' | tail -1 || true
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
    # Region-drift witness: say where the regional reads below actually
    # point before trusting any of them.
    echo "smoke[cloud]: target $CLUSTER/$AWS_REGION — aws-cli $(aws configure list 2>/dev/null | awk '/region/ {$1=$1; print; exit}')"
    aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION" >/dev/null
    # Bounded wait: on a fresh bring-up the ALB takes 2-4 min to provision;
    # on an up stack the first probe succeeds and this costs nothing.
    # Ingress name = release name (roster convention): `app` in otel-demo.
    HOST=""
    for _ in $(seq 1 30); do
      HOST=$(kubectl -n otel-demo get ingress app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
      [[ -n "$HOST" ]] && curl -sf --max-time 5 "http://$HOST/healthz" >/dev/null 2>&1 && break
      HOST=""; sleep 10
    done
    [[ -n "$HOST" ]] || { echo "ALB never became reachable — is the stack up?"; exit 1; }
    echo "app through the ALB ($HOST):"
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
    # Traces lag ingestion by ~10-30s — report, never fail on this.
    n=$(aws xray get-trace-summaries --region "$AWS_REGION" \
          --start-time "$(date -v-5M +%s 2>/dev/null || date -d '5 minutes ago' +%s)" \
          --end-time "$(date +%s)" --query 'length(TraceSummaries)' --output text 2>/dev/null || echo "?")
    echo "  i X-Ray traces in the last 5m: $n (info only — ADOT -> X-Ray)"
    ;;
  *)
    echo "usage: $0 cloud   (local/preview postures deferred — cloud is the only mode)"
    exit 2
    ;;
esac

echo
echo "passed $pass, failed $fail"
[[ $fail -eq 0 ]]

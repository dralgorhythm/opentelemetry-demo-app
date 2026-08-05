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
#   EXPECT_SHA=<sha> scripts/smoke.sh cloud   # also assert WHICH build serves
#
# EXPECT_SHA is what makes "deploy green but the old version is serving"
# fail instead of pass: /healthz answers "ok <build-sha>", baked into the
# binary at image build time (Dockerfile BUILD_SHA -> option_env! in
# src/main.rs). Optional on purpose — a laptop run against an unstamped or
# hand-built image should still be able to smoke the stack.
#
# The mode arg is kept for future postures (local/preview — the template
# this derives from has them; this app runs cloud-only for now).
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-}"

# Counters, not set -e aborts: run EVERY check and fail at the end — a smoke
# run's value is the full picture, not the first red.
pass=0 fail=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); }
bad() { echo "  ✗ $1"; fail=$((fail + 1)); }

# Retry ONLY transient curl failures — timeout, connection refused, reset —
# and NEVER a real HTTP response. The distinction is the whole point: a 500 is
# a real answer from a real server and must fail on the first try, while a
# connection that never completed is a race, not a verdict.
#
# Why this exists: during a rollout the ALB briefly routes to a draining
# target. Exactly one such blip failed an entire deploy gate for a stack that
# was otherwise healthy (run 30958213453 — the first /healthz timed out at
# 10s, and the very next curl to the same URL returned 200 with the right
# body). Every other assert in that run passed, including the X-Ray trace
# gate. A deploy gate that fails on a 10-second network hiccup teaches people
# to re-run it, which is how gates stop being believed.
curl_retry() { # <curl args...>; echoes stdout, non-zero only if ALL attempts fail
  local attempt out
  for attempt in 1 2 3; do
    if out=$(curl -s --max-time 10 "$@"); then printf '%s' "$out"; return 0; fi
    if [[ $attempt -lt 3 ]]; then
      echo "  … transient curl failure (attempt $attempt/3), retrying in 5s" >&2
      sleep 5
    fi
  done
  return 1
}

expect_status() { # <desc> <want> <url/curl args...>
  local desc=$1 want=$2 got; shift 2
  got=$(curl_retry -o /dev/null -w '%{http_code}' "$@") || got="curl-error"
  if [[ "$got" == "$want" ]]; then ok "$desc ($got)"; else bad "$desc: want $want, got $got"; fi
}
expect_contains() { # <desc> <needle> <url/curl args...>
  local desc=$1 needle=$2 body; shift 2
  # Same retry, same reason — this assert raced the rollout too, it just
  # happened to win its coin flip in the run that exposed the problem.
  body=$(curl_retry "$@") || body="(curl error)"
  if [[ "$body" == *"$needle"* ]]; then ok "$desc"; else bad "$desc: no '$needle' in: $body"; fi
}

visitor_count() { # "<N>" | "" (answered, no greeting) | "curl-error" (never answered)
  # Anchored to the greeting phrase on purpose: a bare last-integer grab
  # would let digits in an error page (ALB "503 Service Temporarily
  # Unavailable" HTML) masquerade as a counter — empty output now means
  # "no greeting at all", distinct from a real non-increment.
  #
  # Retried like every other assert (run 30959094319: n1 read fine, n2 spent
  # its full 10s max-time and came back empty, and the gate reported the
  # rollout blip as "counter not monotonic" — a Redis verdict for a network
  # event). Two reasons this needs its own body capture rather than piping
  # curl into grep: the pipeline's exit status is grep's, so curl's failure
  # was invisible, and "" then had to mean both "no greeting" and "no
  # answer". A retry re-hits / and so re-increments, which is safe here —
  # extra increments only push the later read higher.
  local body
  body=$(curl_retry "http://$HOST/") || { printf 'curl-error'; return 0; }
  printf '%s' "$body" | grep -oE 'visitor number [0-9]+' | grep -oE '[0-9]+' | tail -1 || true
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
    # The served-build assert. Skipped (not failed) without EXPECT_SHA so a
    # laptop run stays useful; when CI sets it, a stale ReplicaSet still
    # answering behind the ALB turns this red.
    if [[ -n "${EXPECT_SHA:-}" ]]; then
      expect_contains "healthz reports the expected build" "$EXPECT_SHA" "http://$HOST/healthz"
    else
      echo "  i EXPECT_SHA unset — not asserting which build is serving"
    fi
    expect_status   "greeting serves"        200 "http://$HOST/"
    expect_contains "greeting text"          "Hello, World! You are visitor number" "http://$HOST/"
    # The Redis round trip: INCRBY on every / hit, so two reads must be
    # strictly increasing. (Two replicas share one ElastiCache primary —
    # monotonic across pods; concurrent visitors only push n2 higher.)
    n1=$(visitor_count); n2=$(visitor_count)
    if [[ "$n1" == "curl-error" || "$n2" == "curl-error" ]]; then
      # Still red — three attempts failing is a real problem — but named for
      # what happened. Blaming Redis for a request that never arrived sends
      # whoever reads this log to the wrong dashboard.
      bad "visitor counter unreadable: the ALB never answered / after 3 attempts (got '$n1' then '$n2') — edge/rollout, not the ElastiCache round trip"
    elif [[ "$n1" =~ ^[0-9]+$ && "$n2" =~ ^[0-9]+$ && "$n2" -gt "$n1" ]]; then
      ok "visitor counter increments ($n1 -> $n2 — ElastiCache TLS+AUTH round trip)"
    else
      bad "visitor counter not monotonic (got '$n1' then '$n2')"
    fi
    # Trace gate — the pipeline the whole demo exists to prove
    # (app -> ADOT -> X-Ray) gets an enforced assert, not an info line.
    # LEARNED LIVE (first run of this gate): the awsxray exporter names X-Ray
    # service nodes from the local-root SPAN name ("GET /"), not the OTel
    # resource service.name — service("app") matched zero traces while ~500
    # were flowing. So instead of filtering by service, this asserts OUR OWN
    # request: hit a unique marker path (a traced 404 — the middleware traces
    # every request) and poll for a trace whose http.url contains the marker.
    # Stronger than service-presence: proves THIS run's request traversed
    # app -> ADOT -> X-Ray. Ingestion lags ~10-30s; poll 15s x7 (~90s+).
    marker="smoke-${GITHUB_RUN_ID:-local}-$smoke_start"
    curl -sf -m 10 -o /dev/null "http://$HOST/$marker" || true # 404 expected; span still emitted
    traces=0
    for attempt in $(seq 1 7); do
      traces=$(aws xray get-trace-summaries --region "$AWS_REGION" \
            --start-time "$smoke_start" --end-time "$(date +%s)" \
            --filter-expression "http.url CONTAINS \"$marker\"" \
            --query 'length(TraceSummaries)' --output text 2>/dev/null || echo 0)
      [[ "$traces" =~ ^[0-9]+$ && "$traces" -ge 1 ]] && break
      [[ "$attempt" -lt 7 ]] && sleep 15
    done
    if [[ "$traces" =~ ^[0-9]+$ && "$traces" -ge 1 ]]; then
      ok "X-Ray indexed this run's marker trace /$marker (app -> ADOT -> X-Ray delivering)"
    else
      bad "no X-Ray trace for marker /$marker within ~90s — the app -> ADOT -> X-Ray pipeline is not delivering"
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

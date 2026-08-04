#!/usr/bin/env bash
# The roster, parsed exactly once: one "service<TAB>values-file<TAB>namespace"
# line per deploy/services/*.yaml. Every CI loop (matrix, preview, deploy,
# destroy) consumes THIS output — the roster convention has one parser.
#
#   while IFS=$'\t' read -r svc f ns; do ... done < <(scripts/roster.sh)
#
# Conventions encoded here and nowhere else: filename = service = release
# name = ServiceAccount name; the `namespace:` key is LOOP metadata (not a
# chart value), defaulting to "default"; previews deliberately ignore ns.
set -euo pipefail
cd "$(dirname "$0")/.."
for f in deploy/services/*.yaml; do
  svc=$(basename "$f" .yaml)
  # Top-level `namespace:` key via plain sed — no yq dependency on runners.
  ns=$(sed -n 's/^namespace:[[:space:]]*["'\'']\{0,1\}\([^"'\'' #]*\).*/\1/p' "$f" | head -1)
  printf '%s\t%s\t%s\n' "$svc" "$f" "${ns:-default}"
done

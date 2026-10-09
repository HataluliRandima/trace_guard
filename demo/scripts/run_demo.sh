#!/usr/bin/env bash
# Drives the running demo server and saves the diagnostic report of a
# deliberately failing request.
#
#   cd demo && mix phx.server            # in one terminal
#   ./scripts/run_demo.sh [output.json] [task_output.json]  # in another
#
# Requires curl. Uses python3 (if present) only to pretty-print JSON.
set -euo pipefail

BASE="${BASE:-http://localhost:4000}"
OUT="${1:-trace_guard_report.json}"
TASK_OUT="${2:-trace_guard_task_report.json}"

pretty() { if command -v python3 >/dev/null; then python3 -m json.tool; else cat; fi; }
header() { grep -i "^$1:" | head -1 | cut -d' ' -f2 | tr -d '\r'; }

echo "== 1. Healthy request (no report expected)"
curl -sS -D - -o /dev/null "$BASE/api/health" | grep -iE '^(HTTP|x-traceguard-id)'

echo
echo "== 2. Real Ecto query (no report expected)"
curl -sS "$BASE/api/products"; echo

echo
echo "== 3. Deliberately failing checkout, sent with sensitive data"
RESPONSE_HEADERS="$(mktemp)"
trap 'rm -f "$RESPONSE_HEADERS"' EXIT

curl -sS -D "$RESPONSE_HEADERS" -X POST "$BASE/api/checkout" \
  -H 'content-type: application/json' \
  -H 'authorization: Bearer demo-user-session-token' \
  -H 'x-api-key: demo-client-key-123' \
  -d '{"sku":"TG-001","quantity":2,"password":"hunter2","card":{"card_number":"4242424242424242","cvc":"123"}}'
echo
grep -iE '^(HTTP|x-traceguard-id)' "$RESPONSE_HEADERS"
TRACE_ID="$(header x-traceguard-id < "$RESPONSE_HEADERS")"

echo
echo "== 4. Stored reports"
curl -sS "$BASE/dev/traces" | pretty

echo
echo "== 5. Exporting report $TRACE_ID to $OUT"
curl -sS --fail "$BASE/dev/traces/$TRACE_ID" | pretty > "$OUT"

echo
echo "== 6. Failure inside a wrapped child task (TraceGuard.wrap/1)"
curl -sS -X POST "$BASE/api/inventory/reconcile" -H 'content-type: application/json' -d '{}'; echo
# The request process exits (Task.await), so Phoenix renders without the
# trace header; find the report by route instead.
sleep 0.2
TASK_TRACE_ID="$(curl -sS "$BASE/dev/traces" | grep -o '"route":"/api/inventory/reconcile","status":500,"trace_id":"[0-9a-f]*"' | head -1 | grep -o '[0-9a-f]\{32\}')"
echo "Exporting report $TASK_TRACE_ID to $TASK_OUT"
curl -sS --fail "$BASE/dev/traces/$TASK_TRACE_ID" | pretty > "$TASK_OUT"

LEAKS=0
for secret in hunter2 4242424242424242 demo_merchant_key_123 demo-user-session-token demo-client-key-123 wf_demo_42; do
  if grep -q "$secret" "$OUT" "$TASK_OUT"; then echo "LEAK: $secret"; LEAKS=1; fi
done
[ "$LEAKS" -eq 0 ] && echo "OK: none of the 6 sensitive test values appear in $OUT or $TASK_OUT"
exit "$LEAKS"

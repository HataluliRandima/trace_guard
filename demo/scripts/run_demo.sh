#!/usr/bin/env bash
# Drives the running demo server and saves the diagnostic report of a
# deliberately failing request.
#
#   cd demo && mix phx.server            # in one terminal
#   ./scripts/run_demo.sh [output.json] [task_output.json] [server_output.json]
#
# Requires curl. Uses python3 (if present) only to pretty-print JSON.
set -euo pipefail

BASE="${BASE:-http://localhost:4000}"
OUT="${1:-trace_guard_report.json}"
TASK_OUT="${2:-trace_guard_task_report.json}"
SERVER_OUT="${3:-trace_guard_server_report.json}"

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
# The request process exits (Task.await), so Phoenix renders without the
# trace header. The client's correlation ID finds the report instead.
CORRELATION_ID="demo-reconcile-$$-$(date +%s)"
curl -sS -X POST "$BASE/api/inventory/reconcile" -H 'content-type: application/json' \
  -H "x-correlation-id: $CORRELATION_ID" -d '{}'; echo
TASK_TRACE_ID=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  TASK_TRACE_ID="$(curl -sS "$BASE/dev/traces?incoming_id=$CORRELATION_ID" | grep -o '[0-9a-f]\{32\}' | head -1)"
  [ -n "$TASK_TRACE_ID" ] && break
  sleep 0.1 # reports are stored asynchronously, just after the response
done
echo "Correlation ID $CORRELATION_ID -> trace $TASK_TRACE_ID"
echo "Exporting report $TASK_TRACE_ID to $TASK_OUT"
curl -sS --fail "$BASE/dev/traces/$TASK_TRACE_ID" | pretty > "$TASK_OUT"

echo
echo "== 7. Failure inside an explicitly traced GenServer call (TraceGuard.call/3)"
QUOTE_ID="demo-quote-$$-$(date +%s)"
curl -sS -X POST "$BASE/api/quote" -H 'content-type: application/json' \
  -H "x-correlation-id: $QUOTE_ID" -d '{"sku":"TG-002","qty":1}'; echo
SERVER_TRACE_ID=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  SERVER_TRACE_ID="$(curl -sS "$BASE/dev/traces?incoming_id=$QUOTE_ID" | grep -o '[0-9a-f]\{32\}' | head -1)"
  [ -n "$SERVER_TRACE_ID" ] && break
  sleep 0.1
done
echo "Correlation ID $QUOTE_ID -> trace $SERVER_TRACE_ID"
curl -sS --fail "$BASE/dev/traces/$SERVER_TRACE_ID" | pretty > "$SERVER_OUT"

LEAKS=0
for secret in hunter2 4242424242424242 demo_merchant_key_123 demo-user-session-token demo-client-key-123 wf_demo_42 rt_demo_secret_77; do
  if grep -q "$secret" "$OUT" "$TASK_OUT" "$SERVER_OUT"; then echo "LEAK: $secret"; LEAKS=1; fi
done
[ "$LEAKS" -eq 0 ] && echo "OK: none of the 7 sensitive test values appear in $OUT, $TASK_OUT or $SERVER_OUT"
exit "$LEAKS"

# TraceGuard request-overhead benchmark

Generated 2026-10-09T23:15:30Z by
`MIX_ENV=bench mix bench.requests` at commit `8d9e490` (with uncommitted changes).

## Environment and settings

* Elixir 1.17.0, Erlang/OTP 26.1.2, JIT true
* Linux, 12 cores, 12th Gen Intel(R) Core(TM) i5-1245U, 7.60 GB
* Demo app in `MIX_ENV=bench` (no code reloader, Logger level `:error`, SQLite file DB, pool size 5)
* Dispatch: in-process `TraceGuardDemoWeb.Endpoint.call/2` via `Plug.Test`, no sockets
* 3 paired rounds per scenario; per measurement: warm-up 1s,
  timing 3s, memory 1s; the off/on order alternates per
  round and scenario
* TraceGuard config (both modes, except `enabled` and, for 3b, `storage`):
  `[capture_sql: true, redact_keys: ["card_number", "cvc"], incoming_header: "x-correlation-id", capture_request_headers: ["accept", "content-type", "user-agent", "authorization", "x-api-key"], ecto_telemetry_prefixes: [[:trace_guard_demo, :repo]]]`

## One-time costs (not included below)

* `Application.ensure_all_started(:trace_guard)` incl. its deps: 56128 µs
* Re-running config validation + telemetry attach: 308 µs
* `Application.ensure_all_started(:trace_guard_demo)`: 206056 µs
* First request per scenario after boot (TraceGuard enabled; includes lazy module loading):
  * 1. GET /api/health (success, no DB): 80802 µs (status 200)
  * 2. GET /api/catalog (success, 4 Ecto queries): 37152 µs (status 200)
  * 3a. POST /api/checkout (exception; report built and stored): 88611 µs (status 500)
  * 3b. POST /api/checkout (exception; report built, discarded): 6247 µs (status 500)
  * 4. GET /api/inventory/audit (success, 151 queries > max_events): 24734 µs (status 200)
  * 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks): 10478 µs (status 200)
  * 6. POST /api/quote (success, 1 traced GenServer call with 1 query): 5919 µs (status 200)

## Steady state, sequential

"Off range (drift)" is the spread of the disabled medians across rounds, i.e.
how much the machine itself moved. Δ values are enabled − disabled within the
same round; the table shows their median and range across rounds. Memory is
allocated **by the request process** (Benchee `memory_time`); a report sent
to the store is copied into the store's heap and is not included.

| Scenario | Off median | Off range (drift) | On median | Δ median | Δ range | Δ p99 | Δ throughput | Δ memory |
| --- | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 13.6 µs | 11.9 µs – 16.6 µs | 21.0 µs | +7.1 µs | +4.5 µs – +9.1 µs | +100.4 µs | −38.5% | +5.6 KB |
| 2. GET /api/catalog (success, 4 Ecto queries) | 399.1 µs | 383.2 µs – 847.0 µs | 462.9 µs | +63.8 µs | −394.2 µs – +166.4 µs | −119.0 µs | −4.7% | +11.2 KB |
| 3a. POST /api/checkout (exception; report built and stored) | 568.6 µs | 549.5 µs – 599.6 µs | 2084.8 µs | +1516.2 µs | +1425.5 µs – +4134.1 µs | +3730.6 µs | −70.7% | +218.2 KB … +218.4 KB |
| 3b. POST /api/checkout (exception; report built, discarded) | 1536.6 µs | 541.5 µs – 2088.9 µs | 2126.2 µs | +1390.7 µs | +37.3 µs – +3019.4 µs | +3477.1 µs | −62.2% | +218.6 KB |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 18756.2 µs | 16885.7 µs – 47918.9 µs | 22151.5 µs | +5265.8 µs | −28818.7 µs – +33091.2 µs | +49319.5 µs | −36.3% | +117.2 KB |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 679.6 µs | 651.7 µs – 686.5 µs | 984.3 µs | +304.7 µs | +228.9 µs – +540.9 µs | +695.0 µs | −27.9% | +6.4 KB |
| 6. POST /api/quote (success, 1 traced GenServer call with 1 query) | 184.0 µs | 177.8 µs – 185.2 µs | 292.0 µs | +106.8 µs | +102.4 µs – +115.5 µs | +448.3 µs | −35.3% | +6.1 KB |


Report submission cost in the request process (3a − 3b, enabled medians):
−41.4 µs.

## Report retention (store process), measured separately

* Submit one checkout report and wait for its `[:trace_guard, :report, :stored]` event:
  median 12.5 µs, p99 234.3 µs
  (91814 samples).
* Size of that report: 15296 bytes as an Erlang term (flat size), 5649 bytes
  as JSON. At that size, the default bounds (`max_reports: 50` retained plus
  `max_pending_reports: 50` queued) hold at most about
  1.5 MB of reports.

Concurrent pass not run (set `BENCH_CONCURRENT=4` to add it).

## Raw per-round measurements (sequential)

| Scenario | Round | Off median | On median | Off p99 | On p99 | Off memory | On memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 1 | 16.6 µs | 21.0 µs | 162.9 µs | 269.5 µs | 10.5 KB | 16.2 KB | 107144 / 66429 |
| 1. GET /api/health (success, no DB) | 2 | 13.6 µs | 20.7 µs | 185.8 µs | 271.1 µs | 10.5 KB | 16.2 KB | 100556 / 64501 |
| 1. GET /api/health (success, no DB) | 3 | 11.9 µs | 21.0 µs | 158.4 µs | 258.8 µs | 10.5 KB | 16.2 KB | 121159 / 65403 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 1 | 847.0 µs | 452.7 µs | 3648.3 µs | 2291.7 µs | 55.8 KB | 67.0 KB | 2834 / 4620 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 2 | 399.1 µs | 462.9 µs | 2453.4 µs | 2334.3 µs | 55.8 KB | 67.0 KB | 4760 / 4537 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 3 | 383.2 µs | 549.6 µs | 1758.9 µs | 3791.6 µs | 55.8 KB | 67.0 KB | 4149 / 3532 |
| 3a. POST /api/checkout (exception; report built and stored) | 1 | 599.6 µs | 2025.2 µs | 2737.8 µs | 5996.8 µs | 64.4 KB | 282.6 KB | 3638 / 1162 |
| 3a. POST /api/checkout (exception; report built and stored) | 2 | 549.5 µs | 4683.5 µs | 2499.2 µs | 8082.8 µs | 64.0 KB | 282.4 KB | 3896 / 644 |
| 3a. POST /api/checkout (exception; report built and stored) | 3 | 568.6 µs | 2084.8 µs | 2301.1 µs | 6031.8 µs | 64.0 KB | 282.4 KB | 3922 / 1154 |
| 3b. POST /api/checkout (exception; report built, discarded) | 1 | 541.5 µs | 1932.2 µs | 2258.8 µs | 5735.9 µs | 64.0 KB | 282.6 KB | 4126 / 1195 |
| 3b. POST /api/checkout (exception; report built, discarded) | 2 | 1536.6 µs | 4555.9 µs | 4009.9 µs | 7584.1 µs | 64.0 KB | 282.6 KB | 1730 / 655 |
| 3b. POST /api/checkout (exception; report built, discarded) | 3 | 2088.9 µs | 2126.2 µs | 6643.7 µs | 6113.0 µs | 64.0 KB | 282.6 KB | 717 / 1127 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 1 | 16885.7 µs | 22151.5 µs | 34082.5 µs | 83402.1 µs | 2250.4 KB | 2367.6 KB | 166 / 106 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 2 | 47918.9 µs | 19100.3 µs | 86408.9 µs | 45156.2 µs | 2250.4 KB | 2367.6 KB | 61 / 150 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 3 | 18756.2 µs | 51847.3 µs | 34046.8 µs | 89205.1 µs | 2250.4 KB | 2367.6 KB | 158 / 54 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 1 | 679.6 µs | 984.3 µs | 3415.6 µs | 3136.9 µs | 16.3 KB | 22.7 KB | 3062 / 2529 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 2 | 651.7 µs | 1192.6 µs | 2608.7 µs | 3508.4 µs | 16.3 KB | 22.7 KB | 3625 / 2158 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 3 | 686.5 µs | 915.4 µs | 2469.1 µs | 3164.1 µs | 16.3 KB | 22.7 KB | 1859 / 2574 |
| 6. POST /api/quote (success, 1 traced GenServer call with 1 query) | 1 | 185.2 µs | 292.0 µs | 1124.0 µs | 1598.9 µs | 13.4 KB | 19.5 KB | 10143 / 6582 |
| 6. POST /api/quote (success, 1 traced GenServer call with 1 query) | 2 | 177.8 µs | 293.3 µs | 1061.8 µs | 1510.1 µs | 13.4 KB | 19.5 KB | 10951 / 6783 |
| 6. POST /api/quote (success, 1 traced GenServer call with 1 query) | 3 | 184.0 µs | 286.4 µs | 1086.9 µs | 1513.4 µs | 13.4 KB | 19.5 KB | 10462 / 6921 |


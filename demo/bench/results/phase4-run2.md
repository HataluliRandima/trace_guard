# TraceGuard request-overhead benchmark

Generated 2026-10-09T23:19:14Z by
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

* `Application.ensure_all_started(:trace_guard)` incl. its deps: 52042 µs
* Re-running config validation + telemetry attach: 95 µs
* `Application.ensure_all_started(:trace_guard_demo)`: 209177 µs
* First request per scenario after boot (TraceGuard enabled; includes lazy module loading):
  * 1. GET /api/health (success, no DB): 87046 µs (status 200)
  * 2. GET /api/catalog (success, 4 Ecto queries): 35217 µs (status 200)
  * 3a. POST /api/checkout (exception; report built and stored): 79598 µs (status 500)
  * 3b. POST /api/checkout (exception; report built, discarded): 3037 µs (status 500)
  * 4. GET /api/inventory/audit (success, 151 queries > max_events): 20032 µs (status 200)
  * 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks): 7162 µs (status 200)
  * 6. POST /api/quote (success, 1 traced GenServer call with 1 query): 8326 µs (status 200)

## Steady state, sequential

"Off range (drift)" is the spread of the disabled medians across rounds, i.e.
how much the machine itself moved. Δ values are enabled − disabled within the
same round; the table shows their median and range across rounds. Memory is
allocated **by the request process** (Benchee `memory_time`); a report sent
to the store is copied into the store's heap and is not included.

| Scenario | Off median | Off range (drift) | On median | Δ median | Δ range | Δ p99 | Δ throughput | Δ memory |
| --- | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 11.8 µs | 11.5 µs – 12.8 µs | 20.7 µs | +9.1 µs | +8.5 µs – +10.0 µs | +97.9 µs | −44.4% | +5.6 KB |
| 2. GET /api/catalog (success, 4 Ecto queries) | 688.7 µs | 353.9 µs – 851.9 µs | 423.2 µs | +48.2 µs | −428.6 µs – +1136.3 µs | +799.6 µs | −11.4% | +11.6 KB |
| 3a. POST /api/checkout (exception; report built and stored) | 315.3 µs | 282.9 µs – 322.6 µs | 1299.7 µs | +984.4 µs | +865.6 µs – +1078.4 µs | +3654.2 µs | −71.8% | +218.0 KB … +218.2 KB |
| 3b. POST /api/checkout (exception; report built, discarded) | 349.8 µs | 270.9 µs – 429.2 µs | 1396.4 µs | +1125.5 µs | +988.0 µs – +1558.2 µs | +6467.8 µs | −74.9% | +218.3 KB |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 16387.0 µs | 15886.9 µs – 18039.0 µs | 16359.7 µs | −27.3 µs | −213.9 µs – +2849.8 µs | +5180.5 µs | −3.1% | +117.2 KB |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 463.2 µs | 444.7 µs – 631.0 µs | 791.3 µs | +301.9 µs | +160.3 µs – +439.1 µs | +795.8 µs | −34.3% | +6.4 KB |
| 6. POST /api/quote (success, 1 traced GenServer call with 1 query) | 215.4 µs | 106.4 µs – 510.8 µs | 218.9 µs | +3.6 µs | −235.4 µs – +99.8 µs | +244.8 µs | +24.9% | +6.1 KB |


Report submission cost in the request process (3a − 3b, enabled medians):
−96.7 µs.

## Report retention (store process), measured separately

* Submit one checkout report and wait for its `[:trace_guard, :report, :stored]` event:
  median 13.4 µs, p99 241.2 µs
  (75497 samples).
* Size of that report: 15296 bytes as an Erlang term (flat size), 5665 bytes
  as JSON. At that size, the default bounds (`max_reports: 50` retained plus
  `max_pending_reports: 50` queued) hold at most about
  1.5 MB of reports.

Concurrent pass not run (set `BENCH_CONCURRENT=4` to add it).

## Raw per-round measurements (sequential)

| Scenario | Round | Off median | On median | Off p99 | On p99 | Off memory | On memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 1 | 11.8 µs | 20.3 µs | 158.2 µs | 270.9 µs | 10.5 KB | 16.2 KB | 114007 / 64068 |
| 1. GET /api/health (success, no DB) | 2 | 11.5 µs | 20.7 µs | 160.8 µs | 258.7 µs | 10.5 KB | 16.2 KB | 115845 / 66276 |
| 1. GET /api/health (success, no DB) | 3 | 12.8 µs | 22.8 µs | 165.9 µs | 259.4 µs | 10.5 KB | 16.2 KB | 117451 / 61406 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 1 | 851.9 µs | 423.2 µs | 4155.2 µs | 2817.3 µs | 55.3 KB | 67.0 KB | 2654 / 4633 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 2 | 688.7 µs | 1825.1 µs | 5263.0 µs | 6062.7 µs | 55.3 KB | 67.0 KB | 2826 / 1438 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 3 | 353.9 µs | 402.1 µs | 4779.2 µs | 5905.9 µs | 55.3 KB | 67.0 KB | 2382 / 4177 |
| 3a. POST /api/checkout (exception; report built and stored) | 1 | 322.6 µs | 1188.2 µs | 2680.3 µs | 4734.7 µs | 64.4 KB | 282.4 KB | 5523 / 2102 |
| 3a. POST /api/checkout (exception; report built and stored) | 2 | 315.3 µs | 1299.7 µs | 2439.1 µs | 6093.3 µs | 64.4 KB | 282.6 KB | 6345 / 1801 |
| 3a. POST /api/checkout (exception; report built and stored) | 3 | 282.9 µs | 1361.3 µs | 1932.2 µs | 6212.5 µs | 64.4 KB | 282.6 KB | 7194 / 1719 |
| 3b. POST /api/checkout (exception; report built, discarded) | 1 | 429.2 µs | 1987.4 µs | 3327.8 µs | 13080.6 µs | 64.4 KB | 282.6 KB | 4384 / 1101 |
| 3b. POST /api/checkout (exception; report built, discarded) | 2 | 349.8 µs | 1337.9 µs | 2308.3 µs | 5354.6 µs | 64.4 KB | 282.6 KB | 6093 / 1852 |
| 3b. POST /api/checkout (exception; report built, discarded) | 3 | 270.9 µs | 1396.4 µs | 1818.8 µs | 8286.6 µs | 64.4 KB | 282.6 KB | 5180 / 1575 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 1 | 18039.0 µs | 20888.9 µs | 46985.1 µs | 86383.5 µs | 2250.4 KB | 2367.6 KB | 162 / 99 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 2 | 16387.0 µs | 16359.7 µs | 50008.8 µs | 32533.0 µs | 2250.4 KB | 2367.6 KB | 170 / 179 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 3 | 15886.9 µs | 15673.0 µs | 31074.6 µs | 36255.0 µs | 2250.4 KB | 2367.6 KB | 192 / 186 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 1 | 444.7 µs | 883.9 µs | 2624.0 µs | 5056.9 µs | 16.3 KB | 22.7 KB | 4709 / 2600 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 2 | 631.0 µs | 791.3 µs | 3248.4 µs | 3632.1 µs | 16.3 KB | 22.7 KB | 3620 / 2980 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 3 | 463.2 µs | 765.1 µs | 2686.2 µs | 3482.0 µs | 16.3 KB | 22.7 KB | 3430 / 2986 |
| 6. POST /api/quote (success, 1 traced GenServer call with 1 query) | 1 | 510.8 µs | 275.4 µs | 2530.1 µs | 2774.9 µs | 13.4 KB | 19.5 KB | 4624 / 5795 |
| 6. POST /api/quote (success, 1 traced GenServer call with 1 query) | 2 | 215.4 µs | 218.9 µs | 1901.8 µs | 1771.3 µs | 13.4 KB | 19.5 KB | 7691 / 9600 |
| 6. POST /api/quote (success, 1 traced GenServer call with 1 query) | 3 | 106.4 µs | 206.2 µs | 964.5 µs | 1517.7 µs | 13.4 KB | 19.5 KB | 19246 / 10519 |


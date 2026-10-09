# TraceGuard request-overhead benchmark

Generated 2026-10-09T22:35:53Z by
`MIX_ENV=bench mix bench.requests` at commit `16b35e8` (with uncommitted changes).

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

* `Application.ensure_all_started(:trace_guard)` incl. its deps: 109728 µs
* Re-running config validation + telemetry attach: 180 µs
* `Application.ensure_all_started(:trace_guard_demo)`: 165467 µs
* First request per scenario after boot (TraceGuard enabled; includes lazy module loading):
  * 1. GET /api/health (success, no DB): 81903 µs (status 200)
  * 2. GET /api/catalog (success, 4 Ecto queries): 44350 µs (status 200)
  * 3a. POST /api/checkout (exception; report built and stored): 86694 µs (status 500)
  * 3b. POST /api/checkout (exception; report built, discarded): 4230 µs (status 500)
  * 4. GET /api/inventory/audit (success, 151 queries > max_events): 27502 µs (status 200)
  * 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks): 12139 µs (status 200)

## Steady state, sequential

"Off range (drift)" is the spread of the disabled medians across rounds, i.e.
how much the machine itself moved. Δ values are enabled − disabled within the
same round; the table shows their median and range across rounds. Memory is
allocated **by the request process** (Benchee `memory_time`); a report sent
to the store is copied into the store's heap and is not included.

| Scenario | Off median | Off range (drift) | On median | Δ median | Δ range | Δ p99 | Δ throughput | Δ memory |
| --- | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 16.5 µs | 11.0 µs – 17.8 µs | 27.5 µs | +11.8 µs | +11.0 µs – +14.1 µs | +98.6 µs | −44.6% | +5.6 KB |
| 2. GET /api/catalog (success, 4 Ecto queries) | 305.1 µs | 287.5 µs – 342.7 µs | 437.7 µs | +118.1 µs | +83.6 µs – +150.2 µs | +1590.3 µs | −39.8% | +11.2 KB |
| 3a. POST /api/checkout (exception; report built and stored) | 966.2 µs | 461.3 µs – 1732.4 µs | 2038.3 µs | +1072.2 µs | −106.5 µs – +2961.8 µs | +5624.7 µs | −53.7% | +217.9 KB … +218.4 KB |
| 3b. POST /api/checkout (exception; report built, discarded) | 451.7 µs | 371.3 µs – 488.2 µs | 2197.3 µs | +1709.1 µs | +1152.3 µs – +3030.6 µs | +5548.8 µs | −73.7% | +218.5 KB |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 20319.3 µs | 19408.8 µs – 20387.1 µs | 20776.3 µs | +457.0 µs | −1363.8 µs – +20466.1 µs | −804.0 µs | −1.4% | +117.2 KB |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 583.4 µs | 546.2 µs – 789.0 µs | 776.9 µs | +230.7 µs | −89.5 µs – +250.0 µs | +364.6 µs | −18.9% | +6.4 KB |


Report submission cost in the request process (3a − 3b, enabled medians):
−159.0 µs.

## Report retention (store process), measured separately

* Submit one checkout report and wait for its `[:trace_guard, :report, :stored]` event:
  median 14.2 µs, p99 202.3 µs
  (91634 samples).
* Size of that report: 15296 bytes as an Erlang term (flat size), 5661 bytes
  as JSON. At that size, the default bounds (`max_reports: 50` retained plus
  `max_pending_reports: 50` queued) hold at most about
  1.5 MB of reports.

Concurrent pass not run (set `BENCH_CONCURRENT=4` to add it).

## Raw per-round measurements (sequential)

| Scenario | Round | Off median | On median | Off p99 | On p99 | Off memory | On memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 1 | 17.8 µs | 29.6 µs | 161.0 µs | 259.5 µs | 10.5 KB | 16.2 KB | 114145 / 63950 |
| 1. GET /api/health (success, no DB) | 2 | 16.5 µs | 27.5 µs | 157.0 µs | 251.4 µs | 10.5 KB | 16.2 KB | 108453 / 65474 |
| 1. GET /api/health (success, no DB) | 3 | 11.0 µs | 25.2 µs | 116.8 µs | 277.4 µs | 10.5 KB | 16.2 KB | 164168 / 66059 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 1 | 305.1 µs | 388.7 µs | 1693.3 µs | 2245.2 µs | 55.8 KB | 67.0 KB | 7001 / 5151 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 2 | 287.5 µs | 437.7 µs | 1656.9 µs | 3516.8 µs | 55.8 KB | 67.0 KB | 7129 / 3540 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 3 | 342.7 µs | 460.8 µs | 1876.2 µs | 3466.6 µs | 55.8 KB | 67.0 KB | 5007 / 3591 |
| 3a. POST /api/checkout (exception; report built and stored) | 1 | 966.2 µs | 2038.3 µs | 3938.0 µs | 9750.4 µs | 64.4 KB | 282.3 KB | 2436 / 1130 |
| 3a. POST /api/checkout (exception; report built and stored) | 2 | 1732.4 µs | 1625.9 µs | 4337.1 µs | 5659.2 µs | 64.4 KB | 282.3 KB | 1556 / 1471 |
| 3a. POST /api/checkout (exception; report built and stored) | 3 | 461.3 µs | 3423.1 µs | 2175.4 µs | 7800.1 µs | 63.9 KB | 282.3 KB | 4836 / 791 |
| 3b. POST /api/checkout (exception; report built, discarded) | 1 | 451.7 µs | 1604.0 µs | 2485.3 µs | 5619.3 µs | 63.9 KB | 282.4 KB | 4414 / 1330 |
| 3b. POST /api/checkout (exception; report built, discarded) | 2 | 371.3 µs | 3401.9 µs | 1923.3 µs | 7472.1 µs | 63.9 KB | 282.4 KB | 6049 / 776 |
| 3b. POST /api/checkout (exception; report built, discarded) | 3 | 488.2 µs | 2197.3 µs | 2921.1 µs | 9838.7 µs | 63.9 KB | 282.4 KB | 4114 / 1085 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 1 | 20387.1 µs | 19023.3 µs | 40322.6 µs | 39518.6 µs | 2250.4 KB | 2367.6 KB | 144 / 155 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 2 | 20319.3 µs | 20776.3 µs | 44660.0 µs | 37636.8 µs | 2250.4 KB | 2367.6 KB | 143 / 141 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 3 | 19408.8 µs | 39874.9 µs | 35333.7 µs | 88233.8 µs | 2250.4 KB | 2367.6 KB | 154 / 66 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 1 | 789.0 µs | 699.5 µs | 5674.1 µs | 3323.2 µs | 16.3 KB | 22.7 KB | 2955 / 2983 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 2 | 546.2 µs | 776.9 µs | 2958.9 µs | 3323.4 µs | 16.3 KB | 22.7 KB | 3351 / 2718 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 3 | 583.4 µs | 833.3 µs | 2720.1 µs | 3700.5 µs | 16.3 KB | 22.7 KB | 3711 / 2586 |


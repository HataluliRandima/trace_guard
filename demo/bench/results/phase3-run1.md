# TraceGuard request-overhead benchmark

Generated 2026-10-09T22:32:42Z by
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

* `Application.ensure_all_started(:trace_guard)` incl. its deps: 76545 µs
* Re-running config validation + telemetry attach: 146 µs
* `Application.ensure_all_started(:trace_guard_demo)`: 106927 µs
* First request per scenario after boot (TraceGuard enabled; includes lazy module loading):
  * 1. GET /api/health (success, no DB): 40509 µs (status 200)
  * 2. GET /api/catalog (success, 4 Ecto queries): 17282 µs (status 200)
  * 3a. POST /api/checkout (exception; report built and stored): 42681 µs (status 500)
  * 3b. POST /api/checkout (exception; report built, discarded): 2177 µs (status 500)
  * 4. GET /api/inventory/audit (success, 151 queries > max_events): 21897 µs (status 200)
  * 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks): 9532 µs (status 200)

## Steady state, sequential

"Off range (drift)" is the spread of the disabled medians across rounds, i.e.
how much the machine itself moved. Δ values are enabled − disabled within the
same round; the table shows their median and range across rounds. Memory is
allocated **by the request process** (Benchee `memory_time`); a report sent
to the store is copied into the store's heap and is not included.

| Scenario | Off median | Off range (drift) | On median | Δ median | Δ range | Δ p99 | Δ throughput | Δ memory |
| --- | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 10.5 µs | 9.7 µs – 11.4 µs | 16.6 µs | +5.2 µs | +5.1 µs – +7.7 µs | +73.2 µs | −35.4% | +5.6 KB |
| 2. GET /api/catalog (success, 4 Ecto queries) | 333.2 µs | 275.0 µs – 348.1 µs | 446.8 µs | +113.5 µs | +83.2 µs – +1459.6 µs | +1654.2 µs | −28.2% | +11.2 KB |
| 3a. POST /api/checkout (exception; report built and stored) | 550.1 µs | 279.0 µs – 869.9 µs | 1441.2 µs | +1162.2 µs | +393.1 µs – +1368.8 µs | +3608.4 µs | −69.6% | +218.1 KB … +218.4 KB |
| 3b. POST /api/checkout (exception; report built, discarded) | 601.5 µs | 480.7 µs – 1411.9 µs | 2212.8 µs | +1732.1 µs | +643.5 µs – +3354.0 µs | +6654.4 µs | −73.4% | +218.5 KB |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 17384.6 µs | 16817.6 µs – 17488.0 µs | 18705.9 µs | +1321.4 µs | +1246.9 µs – +32975.1 µs | +13841.5 µs | −7.2% | +117.2 KB |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 825.9 µs | 693.8 µs – 846.1 µs | 1068.8 µs | +321.9 µs | +242.9 µs – +453.3 µs | +230.7 µs | −23.2% | +6.4 KB |


Report submission cost in the request process (3a − 3b, enabled medians):
−771.6 µs.

## Report retention (store process), measured separately

* Submit one checkout report and wait for its `[:trace_guard, :report, :stored]` event:
  median 7.8 µs, p99 162.0 µs
  (179259 samples).
* Size of that report: 15296 bytes as an Erlang term (flat size), 5649 bytes
  as JSON. At that size, the default bounds (`max_reports: 50` retained plus
  `max_pending_reports: 50` queued) hold at most about
  1.5 MB of reports.

Concurrent pass not run (set `BENCH_CONCURRENT=4` to add it).

## Raw per-round measurements (sequential)

| Scenario | Round | Off median | On median | Off p99 | On p99 | Off memory | On memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 1 | 10.5 µs | 15.6 µs | 92.5 µs | 135.8 µs | 10.5 KB | 16.2 KB | 174511 / 127974 |
| 1. GET /api/health (success, no DB) | 2 | 11.4 µs | 16.6 µs | 91.2 µs | 164.5 µs | 10.5 KB | 16.2 KB | 167128 / 109250 |
| 1. GET /api/health (success, no DB) | 3 | 9.7 µs | 17.3 µs | 101.3 µs | 192.7 µs | 10.5 KB | 16.2 KB | 175445 / 104611 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 1 | 348.1 µs | 431.3 µs | 3116.3 µs | 3537.0 µs | 55.8 KB | 67.0 KB | 4628 / 4427 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 2 | 333.2 µs | 446.8 µs | 2109.0 µs | 3763.2 µs | 55.8 KB | 67.0 KB | 5971 / 4290 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 3 | 275.0 µs | 1734.7 µs | 1879.3 µs | 4828.5 µs | 55.8 KB | 67.0 KB | 7393 / 1562 |
| 3a. POST /api/checkout (exception; report built and stored) | 1 | 279.0 µs | 1441.2 µs | 2046.2 µs | 5654.6 µs | 64.0 KB | 282.3 KB | 7096 / 1593 |
| 3a. POST /api/checkout (exception; report built and stored) | 2 | 869.9 µs | 1263.0 µs | 3517.9 µs | 4541.7 µs | 64.0 KB | 282.3 KB | 2801 / 1993 |
| 3a. POST /api/checkout (exception; report built and stored) | 3 | 550.1 µs | 1918.9 µs | 2316.0 µs | 6253.5 µs | 64.4 KB | 282.5 KB | 4324 / 1321 |
| 3b. POST /api/checkout (exception; report built, discarded) | 1 | 480.7 µs | 2212.8 µs | 2303.2 µs | 8957.7 µs | 64.0 KB | 282.5 KB | 4324 / 1151 |
| 3b. POST /api/checkout (exception; report built, discarded) | 2 | 601.5 µs | 3955.5 µs | 2725.3 µs | 11373.8 µs | 64.0 KB | 282.5 KB | 4006 / 692 |
| 3b. POST /api/checkout (exception; report built, discarded) | 3 | 1411.9 µs | 2055.4 µs | 4494.6 µs | 5942.9 µs | 64.0 KB | 282.5 KB | 1803 / 1225 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 1 | 16817.6 µs | 18064.6 µs | 32686.3 µs | 46527.8 µs | 2250.4 KB | 2367.6 KB | 171 / 159 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 2 | 17384.6 µs | 18705.9 µs | 56036.2 µs | 34043.7 µs | 2250.4 KB | 2367.6 KB | 164 / 156 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 3 | 17488.0 µs | 50463.1 µs | 65953.9 µs | 82581.9 µs | 2250.4 KB | 2367.6 KB | 157 / 58 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 1 | 693.8 µs | 1015.7 µs | 2890.6 µs | 3392.4 µs | 16.3 KB | 22.7 KB | 3524 / 2495 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 2 | 846.1 µs | 1299.5 µs | 10867.4 µs | 5961.4 µs | 16.3 KB | 22.7 KB | 2495 / 1960 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 3 | 825.9 µs | 1068.8 µs | 3230.8 µs | 3461.6 µs | 16.3 KB | 22.7 KB | 3085 / 2372 |


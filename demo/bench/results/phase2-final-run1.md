# TraceGuard request-overhead benchmark

Generated 2026-10-09T21:42:11Z by `MIX_ENV=bench mix bench.requests`.

## Environment

* Elixir 1.17.0, Erlang/OTP 26.1.2, JIT true
* Linux, 12 cores, 12th Gen Intel(R) Core(TM) i5-1245U, 7.60 GB
* Demo app in `MIX_ENV=bench` (no code reloader, Logger level `:error`, SQLite file DB, pool size 5)
* Dispatch: in-process `TraceGuardDemoWeb.Endpoint.call/2` via `Plug.Test`, no sockets
* Warm-up 2s, measurement 5s, memory measurement 1s per scenario and mode
* TraceGuard config (both modes, except `enabled`): `%{ecto_telemetry_prefixes: [[:trace_guard_demo, :repo]], capture_sql: true, capture_request_headers: ["accept", "content-type", "user-agent", "authorization", "x-api-key"], redact_keys: ["password", "authorization", "token", "access_token", "refresh_token", "secret", "api_key", "cookie", "private_key", "card_number", "cvc"], failure_status: 500, max_events: 100, max_reports: 50, capture_path: false, capture_path_params: false, capture_exception_message: true, max_string_length: 500, max_stacktrace_frames: 20, response_header: "x-traceguard-id", incoming_header: nil, max_task_collectors: 1000, task_drain_timeout: 100, task_collector_lifetime: 300000}`

## One-time costs (not included below)

* `Application.ensure_all_started(:trace_guard)` incl. its deps: 33123 µs
* Re-running config validation + telemetry attach: 95 µs
* `Application.ensure_all_started(:trace_guard_demo)`: 98680 µs
* First request per scenario after boot (TraceGuard enabled; includes lazy module loading):
  * 1. GET /api/health (success, no DB): 54136 µs (status 200)
  * 2. GET /api/catalog (success, 4 Ecto queries): 26663 µs (status 200)
  * 3. POST /api/checkout (exception, 5 queries, report built): 70359 µs (status 500)
  * 4. GET /api/inventory/audit (success, 151 queries > max_events): 17733 µs (status 200)
  * 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks): 6812 µs (status 200)

## Steady state

Latency columns are per request. "Throughput" is `parallel / average latency`
for the measuring process(es). Memory is the median allocated **by the
request process** per request (Benchee `memory_time`); allocations in other
processes (e.g. TraceGuard's report store) are not included.

### Sequential (1 process)

| Scenario | Median off | Median on | Δ median | p99 off | p99 on | Throughput off | Throughput on | Δ throughput | Memory off | Memory on | Δ memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 9.7 µs | 18.9 µs | 9.2 µs (+94.6%) | 95.5 µs | 267.0 µs | 66234/s | 24470/s | -63.1% | 10.7 KB | 16.1 KB | 5.4 KB (+50.1%) | 320794 / 119621 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 187.4 µs | 419.6 µs | 232.2 µs (+123.9%) | 1278.4 µs | 2377.9 µs | 3896/s | 1552/s | -60.2% | 57.5 KB | 66.9 KB | 9.4 KB (+16.3%) | 19350 / 7718 |
| 3. POST /api/checkout (exception, 5 queries, report built) | 263.4 µs | 1722.2 µs | 1458.8 µs (+553.8%) | 1796.0 µs | 6029.4 µs | 2675/s | 444/s | -83.4% | 63.9 KB | 282.2 KB | 218.3 KB (+341.4%) | 13290 / 1812 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 10900.9 µs | 58012.1 µs | 47111.3 µs (+432.2%) | 35290.2 µs | 79717.3 µs | 79/s | 21/s | -73.9% | 2251.1 KB | 2383.9 KB | 132.8 KB (+5.9%) | 396 / 103 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 445.3 µs | 668.4 µs | 223.2 µs (+50.1%) | 2130.3 µs | 3459.0 µs | 1748/s | 1010/s | -42.2% | 16.3 KB | 22.6 KB | 6.3 KB (+38.7%) | 8684 / 5028 |

### Concurrent (4 processes, read-only scenarios, no memory measurement)

| Scenario | Median off | Median on | Δ median | p99 off | p99 on | Throughput off | Throughput on | Δ throughput | Memory off | Memory on | Δ memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 22.8 µs | 52.9 µs | 30.1 µs (+131.8%) | 158.7 µs | 309.0 µs | 124786/s | 59286/s | -52.5% | n/a | n/a | n/a | 602549 / 289488 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 1088.4 µs | 1386.6 µs | 298.2 µs (+27.4%) | 4287.0 µs | 5241.5 µs | 3074/s | 2426/s | -21.1% | n/a | n/a | n/a | 15319 / 12099 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 38532.2 µs | 45503.0 µs | 6970.8 µs (+18.1%) | 75178.6 µs | 78097.0 µs | 99/s | 86/s | -12.9% | n/a | n/a | n/a | 496 / 432 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 765.1 µs | 1041.4 µs | 276.3 µs (+36.1%) | 2571.8 µs | 3531.2 µs | 4558/s | 3317/s | -27.2% | n/a | n/a | n/a | 22692 / 16518 |


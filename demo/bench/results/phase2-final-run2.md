# TraceGuard request-overhead benchmark

Generated 2026-10-09T21:44:33Z by `MIX_ENV=bench mix bench.requests`.

## Environment

* Elixir 1.17.0, Erlang/OTP 26.1.2, JIT true
* Linux, 12 cores, 12th Gen Intel(R) Core(TM) i5-1245U, 7.60 GB
* Demo app in `MIX_ENV=bench` (no code reloader, Logger level `:error`, SQLite file DB, pool size 5)
* Dispatch: in-process `TraceGuardDemoWeb.Endpoint.call/2` via `Plug.Test`, no sockets
* Warm-up 2s, measurement 5s, memory measurement 1s per scenario and mode
* TraceGuard config (both modes, except `enabled`): `%{ecto_telemetry_prefixes: [[:trace_guard_demo, :repo]], capture_sql: true, capture_request_headers: ["accept", "content-type", "user-agent", "authorization", "x-api-key"], redact_keys: ["password", "authorization", "token", "access_token", "refresh_token", "secret", "api_key", "cookie", "private_key", "card_number", "cvc"], failure_status: 500, max_events: 100, max_reports: 50, capture_path: false, capture_path_params: false, capture_exception_message: true, max_string_length: 500, max_stacktrace_frames: 20, response_header: "x-traceguard-id", incoming_header: nil, max_task_collectors: 1000, task_drain_timeout: 100, task_collector_lifetime: 300000}`

## One-time costs (not included below)

* `Application.ensure_all_started(:trace_guard)` incl. its deps: 44526 µs
* Re-running config validation + telemetry attach: 97 µs
* `Application.ensure_all_started(:trace_guard_demo)`: 172979 µs
* First request per scenario after boot (TraceGuard enabled; includes lazy module loading):
  * 1. GET /api/health (success, no DB): 66697 µs (status 200)
  * 2. GET /api/catalog (success, 4 Ecto queries): 32170 µs (status 200)
  * 3. POST /api/checkout (exception, 5 queries, report built): 78530 µs (status 500)
  * 4. GET /api/inventory/audit (success, 151 queries > max_events): 30286 µs (status 200)
  * 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks): 4231 µs (status 200)

## Steady state

Latency columns are per request. "Throughput" is `parallel / average latency`
for the measuring process(es). Memory is the median allocated **by the
request process** per request (Benchee `memory_time`); allocations in other
processes (e.g. TraceGuard's report store) are not included.

### Sequential (1 process)

| Scenario | Median off | Median on | Δ median | p99 off | p99 on | Throughput off | Throughput on | Δ throughput | Memory off | Memory on | Δ memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 11.2 µs | 18.2 µs | 7.0 µs (+62.9%) | 170.8 µs | 255.8 µs | 46745/s | 24792/s | -47.0% | 10.7 KB | 16.1 KB | 5.4 KB (+50.1%) | 225761 / 121057 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 349.8 µs | 396.7 µs | 46.9 µs (+13.4%) | 2502.6 µs | 2252.2 µs | 1827/s | 1594/s | -12.7% | 57.5 KB | 66.9 KB | 9.4 KB (+16.3%) | 9072 / 7925 |
| 3. POST /api/checkout (exception, 5 queries, report built) | 440.2 µs | 1593.4 µs | 1153.3 µs (+262.0%) | 2182.9 µs | 5551.7 µs | 1560/s | 447/s | -71.4% | 63.9 KB | 282.2 KB | 218.3 KB (+341.4%) | 7755 / 1830 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 18124.4 µs | 17198.9 µs | -925.5 µs (-5.1%) | 72939.5 µs | 33469.0 µs | 50/s | 56/s | +11.8% | 2251.1 KB | 2383.9 KB | 132.8 KB (+5.9%) | 252 / 282 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 598.1 µs | 648.2 µs | 50.0 µs (+8.4%) | 2708.8 µs | 3339.5 µs | 1240/s | 1061/s | -14.4% | 16.3 KB | 22.6 KB | 6.3 KB (+38.7%) | 6157 / 5279 |

### Concurrent (4 processes, read-only scenarios, no memory measurement)

| Scenario | Median off | Median on | Δ median | p99 off | p99 on | Throughput off | Throughput on | Δ throughput | Memory off | Memory on | Δ memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 19.4 µs | 33.6 µs | 14.2 µs (+73.5%) | 149.7 µs | 254.7 µs | 132169/s | 70192/s | -46.9% | n/a | n/a | n/a | 637661 / 342662 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 891.5 µs | 1174.9 µs | 283.4 µs (+31.8%) | 3153.0 µs | 3815.2 µs | 3828/s | 2988/s | -21.9% | n/a | n/a | n/a | 19084 / 12023 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 44211.9 µs | 42404.9 µs | -1807.0 µs (-4.1%) | 66436.4 µs | 67889.7 µs | 89/s | 93/s | +4.0% | n/a | n/a | n/a | 447 / 464 |
| 5. GET /api/catalog/parallel (success, 4 queries in 4 wrapped Tasks) | 808.1 µs | 993.3 µs | 185.2 µs (+22.9%) | 2727.2 µs | 3339.8 µs | 4342/s | 3512/s | -19.1% | n/a | n/a | n/a | 21616 / 17491 |


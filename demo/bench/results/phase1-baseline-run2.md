# TraceGuard request-overhead benchmark

Generated 2026-10-09T21:13:01Z by `MIX_ENV=bench mix bench.requests`.

## Environment

* Elixir 1.17.0, Erlang/OTP 26.1.2, JIT true
* Linux, 12 cores, 12th Gen Intel(R) Core(TM) i5-1245U, 7.60 GB
* Demo app in `MIX_ENV=bench` (no code reloader, Logger level `:error`, SQLite file DB, pool size 5)
* Dispatch: in-process `TraceGuardDemoWeb.Endpoint.call/2` via `Plug.Test`, no sockets
* Warm-up 2s, measurement 5s, memory measurement 1s per scenario and mode
* TraceGuard config (both modes, except `enabled`): `%{ecto_telemetry_prefixes: [[:trace_guard_demo, :repo]], capture_sql: true, capture_request_headers: ["accept", "content-type", "user-agent", "authorization", "x-api-key"], redact_keys: ["password", "authorization", "token", "access_token", "refresh_token", "secret", "api_key", "cookie", "private_key", "card_number", "cvc"], max_stacktrace_frames: 20, failure_status: 500, max_events: 100, max_reports: 50, capture_path: false, capture_path_params: false, capture_exception_message: true, max_string_length: 500, response_header: "x-traceguard-id", incoming_header: nil}`

## One-time costs (not included below)

* `Application.ensure_all_started(:trace_guard)` incl. its deps: 62844 µs
* Re-running config validation + telemetry attach: 447 µs
* `Application.ensure_all_started(:trace_guard_demo)`: 63077 µs
* First request per scenario after boot (TraceGuard enabled; includes lazy module loading):
  * 1. GET /api/health (success, no DB): 25865 µs (status 200)
  * 2. GET /api/catalog (success, 4 Ecto queries): 10207 µs (status 200)
  * 3. POST /api/checkout (exception, 5 queries, report built): 27997 µs (status 500)
  * 4. GET /api/inventory/audit (success, 151 queries > max_events): 11168 µs (status 200)

## Steady state

Latency columns are per request. "Throughput" is `parallel / average latency`
for the measuring process(es). Memory is the median allocated **by the
request process** per request (Benchee `memory_time`); allocations in other
processes (e.g. TraceGuard's report store) are not included.

### Sequential (1 process)

| Scenario | Median off | Median on | Δ median | p99 off | p99 on | Throughput off | Throughput on | Δ throughput | Memory off | Memory on | Δ memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 8.9 µs | 15.7 µs | 6.7 µs (+75.0%) | 48.5 µs | 74.1 µs | 82692/s | 48465/s | -41.4% | 10.7 KB | 16.8 KB | 6.0 KB (+56.0%) | 401005 / 237730 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 136.2 µs | 173.8 µs | 37.6 µs (+27.6%) | 764.5 µs | 747.6 µs | 5796/s | 4762/s | -17.8% | 57.5 KB | 72.0 KB | 14.4 KB (+25.1%) | 28812 / 23695 |
| 3. POST /api/checkout (exception, 5 queries, report built) | 176.6 µs | 2243.4 µs | 2066.8 µs (+1170.3%) | 826.1 µs | 4533.1 µs | 4823/s | 416/s | -91.4% | 64.0 KB | 906.8 KB | 842.8 KB (+1317.5%) | 23984 / 2075 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 6079.5 µs | 6625.8 µs | 546.3 µs (+9.0%) | 12703.1 µs | 16088.5 µs | 154/s | 140/s | -9.0% | 2251.1 KB | 2533.6 KB | 282.5 KB (+12.5%) | 770 / 534 |

### Concurrent (4 processes, read-only scenarios, no memory measurement)

| Scenario | Median off | Median on | Δ median | p99 off | p99 on | Throughput off | Throughput on | Δ throughput | Memory off | Memory on | Δ memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 9.5 µs | 17.1 µs | 7.6 µs (+79.3%) | 113.5 µs | 194.8 µs | 214471/s | 122351/s | -43.0% | n/a | n/a | n/a | 1034982 / 598957 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 1405.6 µs | 1391.4 µs | -14.2 µs (-1.0%) | 3957.8 µs | 4108.7 µs | 2554/s | 2522/s | -1.3% | n/a | n/a | n/a | 12749 / 12590 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 63208.6 µs | 62400.7 µs | -807.9 µs (-1.3%) | 102959.6 µs | 76478.0 µs | 62/s | 65/s | +5.0% | n/a | n/a | n/a | 312 / 327 |


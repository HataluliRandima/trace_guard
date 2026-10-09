# TraceGuard request-overhead benchmark

Generated 2026-10-09T21:17:20Z by `MIX_ENV=bench mix bench.requests`.

## Environment

* Elixir 1.17.0, Erlang/OTP 26.1.2, JIT true
* Linux, 12 cores, 12th Gen Intel(R) Core(TM) i5-1245U, 7.60 GB
* Demo app in `MIX_ENV=bench` (no code reloader, Logger level `:error`, SQLite file DB, pool size 5)
* Dispatch: in-process `TraceGuardDemoWeb.Endpoint.call/2` via `Plug.Test`, no sockets
* Warm-up 2s, measurement 5s, memory measurement 1s per scenario and mode
* TraceGuard config (both modes, except `enabled`): `%{ecto_telemetry_prefixes: [[:trace_guard_demo, :repo]], capture_sql: true, capture_request_headers: ["accept", "content-type", "user-agent", "authorization", "x-api-key"], redact_keys: ["password", "authorization", "token", "access_token", "refresh_token", "secret", "api_key", "cookie", "private_key", "card_number", "cvc"], max_events: 100, failure_status: 500, capture_exception_message: true, max_stacktrace_frames: 20, capture_path_params: false, max_string_length: 500, max_reports: 50, capture_path: false, response_header: "x-traceguard-id", incoming_header: nil}`

## One-time costs (not included below)

* `Application.ensure_all_started(:trace_guard)` incl. its deps: 23147 µs
* Re-running config validation + telemetry attach: 82 µs
* `Application.ensure_all_started(:trace_guard_demo)`: 74948 µs
* First request per scenario after boot (TraceGuard enabled; includes lazy module loading):
  * 1. GET /api/health (success, no DB): 15675 µs (status 200)
  * 2. GET /api/catalog (success, 4 Ecto queries): 10293 µs (status 200)
  * 3. POST /api/checkout (exception, 5 queries, report built): 29689 µs (status 500)
  * 4. GET /api/inventory/audit (success, 151 queries > max_events): 8999 µs (status 200)

## Steady state

Latency columns are per request. "Throughput" is `parallel / average latency`
for the measuring process(es). Memory is the median allocated **by the
request process** per request (Benchee `memory_time`); allocations in other
processes (e.g. TraceGuard's report store) are not included.

### Sequential (1 process)

| Scenario | Median off | Median on | Δ median | p99 off | p99 on | Throughput off | Throughput on | Δ throughput | Memory off | Memory on | Δ memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 8.5 µs | 14.3 µs | 5.8 µs (+68.3%) | 80.6 µs | 74.8 µs | 84065/s | 52640/s | -37.4% | 10.7 KB | 15.9 KB | 5.2 KB (+48.2%) | 406174 / 257324 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 139.2 µs | 180.8 µs | 41.6 µs (+29.8%) | 1217.9 µs | 1421.9 µs | 4731/s | 3723/s | -21.3% | 57.5 KB | 67.3 KB | 9.7 KB (+16.9%) | 23525 / 18519 |
| 3. POST /api/checkout (exception, 5 queries, report built) | 197.3 µs | 1060.6 µs | 863.3 µs (+437.5%) | 1769.2 µs | 4692.3 µs | 3233/s | 771/s | -76.1% | 63.9 KB | 275.9 KB | 212.0 KB (+331.5%) | 16084 / 3844 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 6641.4 µs | 7189.1 µs | 547.7 µs (+8.2%) | 15546.9 µs | 25139.5 µs | 138/s | 116/s | -16.1% | 2251.1 KB | 2350.0 KB | 98.9 KB (+4.4%) | 690 / 445 |

### Concurrent (4 processes, read-only scenarios, no memory measurement)

| Scenario | Median off | Median on | Δ median | p99 off | p99 on | Throughput off | Throughput on | Δ throughput | Memory off | Memory on | Δ memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 9.6 µs | 16.6 µs | 7.1 µs (+73.9%) | 132.0 µs | 204.2 µs | 201732/s | 118889/s | -41.1% | n/a | n/a | n/a | 972699 / 580531 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 1428.1 µs | 1192.1 µs | -236.0 µs (-16.5%) | 4643.7 µs | 4273.7 µs | 2417/s | 2809/s | +16.2% | n/a | n/a | n/a | 12062 / 14012 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 79602.0 µs | 33803.1 µs | -45798.9 µs (-57.5%) | 110277.0 µs | 83123.3 µs | 52/s | 100/s | +91.5% | n/a | n/a | n/a | 262 / 499 |


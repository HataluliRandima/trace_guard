# TraceGuard request-overhead benchmark

Generated 2026-10-09T21:19:10Z by `MIX_ENV=bench mix bench.requests`.

## Environment

* Elixir 1.17.0, Erlang/OTP 26.1.2, JIT true
* Linux, 12 cores, 12th Gen Intel(R) Core(TM) i5-1245U, 7.60 GB
* Demo app in `MIX_ENV=bench` (no code reloader, Logger level `:error`, SQLite file DB, pool size 5)
* Dispatch: in-process `TraceGuardDemoWeb.Endpoint.call/2` via `Plug.Test`, no sockets
* Warm-up 2s, measurement 5s, memory measurement 1s per scenario and mode
* TraceGuard config (both modes, except `enabled`): `%{ecto_telemetry_prefixes: [[:trace_guard_demo, :repo]], capture_sql: true, capture_request_headers: ["accept", "content-type", "user-agent", "authorization", "x-api-key"], redact_keys: ["password", "authorization", "token", "access_token", "refresh_token", "secret", "api_key", "cookie", "private_key", "card_number", "cvc"], max_stacktrace_frames: 20, failure_status: 500, max_events: 100, max_reports: 50, capture_path: false, capture_path_params: false, capture_exception_message: true, max_string_length: 500, response_header: "x-traceguard-id", incoming_header: nil}`

## One-time costs (not included below)

* `Application.ensure_all_started(:trace_guard)` incl. its deps: 61389 µs
* Re-running config validation + telemetry attach: 82 µs
* `Application.ensure_all_started(:trace_guard_demo)`: 91548 µs
* First request per scenario after boot (TraceGuard enabled; includes lazy module loading):
  * 1. GET /api/health (success, no DB): 37213 µs (status 200)
  * 2. GET /api/catalog (success, 4 Ecto queries): 13526 µs (status 200)
  * 3. POST /api/checkout (exception, 5 queries, report built): 43449 µs (status 500)
  * 4. GET /api/inventory/audit (success, 151 queries > max_events): 10575 µs (status 200)

## Steady state

Latency columns are per request. "Throughput" is `parallel / average latency`
for the measuring process(es). Memory is the median allocated **by the
request process** per request (Benchee `memory_time`); allocations in other
processes (e.g. TraceGuard's report store) are not included.

### Sequential (1 process)

| Scenario | Median off | Median on | Δ median | p99 off | p99 on | Throughput off | Throughput on | Δ throughput | Memory off | Memory on | Δ memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 9.1 µs | 15.2 µs | 6.0 µs (+65.9%) | 65.4 µs | 65.3 µs | 83801/s | 50344/s | -39.9% | 10.7 KB | 15.9 KB | 5.2 KB (+48.2%) | 405448 / 246369 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 141.2 µs | 172.6 µs | 31.4 µs (+22.2%) | 1096.9 µs | 824.9 µs | 4967/s | 4710/s | -5.2% | 57.5 KB | 67.3 KB | 9.7 KB (+16.9%) | 24684 / 23423 |
| 3. POST /api/checkout (exception, 5 queries, report built) | 199.2 µs | 923.5 µs | 724.3 µs (+363.6%) | 1392.3 µs | 3835.2 µs | 3738/s | 888/s | -76.2% | 63.9 KB | 275.9 KB | 212.0 KB (+331.5%) | 18580 / 4426 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 6649.8 µs | 6437.6 µs | -212.1 µs (-3.2%) | 20305.2 µs | 13924.1 µs | 134/s | 144/s | +7.6% | 2251.1 KB | 2350.0 KB | 98.9 KB (+4.4%) | 669 / 636 |

### Concurrent (4 processes, read-only scenarios, no memory measurement)

| Scenario | Median off | Median on | Δ median | p99 off | p99 on | Throughput off | Throughput on | Δ throughput | Memory off | Memory on | Δ memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 10.0 µs | 17.5 µs | 7.4 µs (+74.0%) | 119.6 µs | 196.3 µs | 204826/s | 117360/s | -42.7% | n/a | n/a | n/a | 988153 / 573719 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 1259.6 µs | 1249.5 µs | -10.0 µs (-0.8%) | 4443.9 µs | 4328.2 µs | 2671/s | 2678/s | +0.3% | n/a | n/a | n/a | 13328 / 13368 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 67954.2 µs | 59643.0 µs | -8311.1 µs (-12.2%) | 94466.9 µs | 89115.1 µs | 61/s | 67/s | +9.7% | n/a | n/a | n/a | 307 / 338 |


# TraceGuard request-overhead benchmark

Generated 2026-10-09T21:11:11Z by `MIX_ENV=bench mix bench.requests`.

## Environment

* Elixir 1.17.0, Erlang/OTP 26.1.2, JIT true
* Linux, 12 cores, 12th Gen Intel(R) Core(TM) i5-1245U, 7.60 GB
* Demo app in `MIX_ENV=bench` (no code reloader, Logger level `:error`, SQLite file DB, pool size 5)
* Dispatch: in-process `TraceGuardDemoWeb.Endpoint.call/2` via `Plug.Test`, no sockets
* Warm-up 2s, measurement 5s, memory measurement 1s per scenario and mode
* TraceGuard config (both modes, except `enabled`): `%{ecto_telemetry_prefixes: [[:trace_guard_demo, :repo]], capture_sql: true, capture_request_headers: ["accept", "content-type", "user-agent", "authorization", "x-api-key"], redact_keys: ["password", "authorization", "token", "access_token", "refresh_token", "secret", "api_key", "cookie", "private_key", "card_number", "cvc"], max_stacktrace_frames: 20, failure_status: 500, max_events: 100, max_reports: 50, capture_path: false, capture_path_params: false, capture_exception_message: true, max_string_length: 500, response_header: "x-traceguard-id", incoming_header: nil}`

## One-time costs (not included below)

* `Application.ensure_all_started(:trace_guard)` incl. its deps: 54327 µs
* Re-running config validation + telemetry attach: 69 µs
* `Application.ensure_all_started(:trace_guard_demo)`: 89041 µs
* First request per scenario after boot (TraceGuard enabled; includes lazy module loading):
  * 1. GET /api/health (success, no DB): 24880 µs (status 200)
  * 2. GET /api/catalog (success, 4 Ecto queries): 10949 µs (status 200)
  * 3. POST /api/checkout (exception, 5 queries, report built): 34607 µs (status 500)
  * 4. GET /api/inventory/audit (success, 151 queries > max_events): 9487 µs (status 200)

## Steady state

Latency columns are per request. "Throughput" is `parallel / average latency`
for the measuring process(es). Memory is the median allocated **by the
request process** per request (Benchee `memory_time`); allocations in other
processes (e.g. TraceGuard's report store) are not included.

### Sequential (1 process)

| Scenario | Median off | Median on | Δ median | p99 off | p99 on | Throughput off | Throughput on | Δ throughput | Memory off | Memory on | Δ memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 8.5 µs | 15.1 µs | 6.6 µs (+78.6%) | 33.0 µs | 60.7 µs | 97055/s | 54426/s | -43.9% | 10.7 KB | 16.8 KB | 6.0 KB (+56.0%) | 469511 / 266536 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 133.3 µs | 172.5 µs | 39.2 µs (+29.4%) | 694.8 µs | 930.0 µs | 6035/s | 4537/s | -24.8% | 57.5 KB | 72.0 KB | 14.4 KB (+25.1%) | 29999 / 22561 |
| 3. POST /api/checkout (exception, 5 queries, report built) | 267.4 µs | 2095.8 µs | 1828.4 µs (+683.7%) | 1702.3 µs | 5028.7 µs | 2441/s | 432/s | -82.3% | 64.4 KB | 906.7 KB | 842.3 KB (+1308.9%) | 12146 / 2158 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 7901.8 µs | 7336.8 µs | -565.0 µs (-7.2%) | 25241.8 µs | 19888.3 µs | 107/s | 117/s | +9.6% | 2251.1 KB | 2533.6 KB | 282.5 KB (+12.5%) | 535 / 530 |

### Concurrent (4 processes, read-only scenarios, no memory measurement)

| Scenario | Median off | Median on | Δ median | p99 off | p99 on | Throughput off | Throughput on | Δ throughput | Memory off | Memory on | Δ memory | Samples off / on |
| --- | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | --: |
| 1. GET /api/health (success, no DB) | 10.9 µs | 17.2 µs | 6.3 µs (+57.4%) | 118.8 µs | 217.1 µs | 197661/s | 115495/s | -41.6% | n/a | n/a | n/a | 953770 / 564934 |
| 2. GET /api/catalog (success, 4 Ecto queries) | 761.2 µs | 1127.4 µs | 366.2 µs (+48.1%) | 3590.1 µs | 3832.4 µs | 3950/s | 2974/s | -24.7% | n/a | n/a | n/a | 19707 / 14837 |
| 4. GET /api/inventory/audit (success, 151 queries > max_events) | 63406.0 µs | 32418.0 µs | -30987.9 µs (-48.9%) | 100765.7 µs | 74642.0 µs | 62/s | 93/s | +49.3% | n/a | n/a | n/a | 311 / 468 |


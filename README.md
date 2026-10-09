# TraceGuard

> When an API request fails, TraceGuard reconstructs the relevant execution
> timeline, correlates available telemetry events, safely redacts sensitive
> information, and produces a useful diagnostic report.

**Status: Phase 3 (v0.1.0, unreleased).** It works end to end against
Phoenix 1.8 / Plug 1.20 / Ecto SQL 3.14, and its overhead has been measured
(see [docs/performance.md](docs/performance.md)), but it is not yet
production-hardened. See [Limitations](#limitations).

## The problem

A Phoenix API returns `500 Internal Server Error`. The log has a stack trace,
but you still need to know what that particular request did before it failed:
which route ran, which queries it issued and in what order, how long each
step took, and whether a transaction was rolled back. Reconstructing this
from interleaved logs of concurrent requests is slow, and the logs often
contain secrets that you cannot paste into a ticket.

TraceGuard records the telemetry events that Phoenix and Ecto already emit,
attributes each one to the request that caused it, and on failure turns them
into a redacted JSON report that is safe to share. You don't change any
business logic: you add one plug and one config line.

## What it does

| Capability | Status |
| --- | --- |
| Generates a unique 128-bit trace ID for each request (`x-traceguard-id` response header, `trace_guard_id` Logger metadata) | ✅ |
| Records method, route template, start time, status and duration | ✅ |
| Records Phoenix endpoint and router events and Ecto queries (timing, table, row count, outcome, calling function) | ✅ |
| Attributes events to the correct request, including under concurrency | ✅ |
| Includes events from selected `Task`s via explicit `TraceGuard.wrap/1` (Phase 2) | ✅ opt-in |
| Reproducible enabled-vs-disabled overhead benchmark (Phase 2) | ✅ |
| Captures exceptions through supported Phoenix telemetry, without rescuing them | ✅ |
| Reports error responses that had no exception (e.g. a `503`) | ✅ |
| Redacts sensitive keys recursively in maps, lists and header tuples, and scrubs labelled secrets from exception messages | ✅ |
| Bounded in-memory report store with bounded admission: retained reports **and** queued submissions are capped, and refusals are counted and emitted as events (Phase 3) | ✅ |
| `TraceGuard.Storage` behaviour (in-memory default, test adapter, contract suite) and JSON export (Phase 3) | ✅ |
| Finding reports whose response has no trace header: correlation ID, request ID and route filters, plus `await_report/2` (Phase 3) | ✅ |
| Validated incoming correlation ID (opt-in) | ✅ |
| Phoenix demo app with real SQLite queries and a deliberate failure | ✅ |

Not implemented: cloud service, dashboard, distributed tracing, implicit
or cross-node propagation, LiveView/Oban, log capture, automatic function
tracing, AI analysis. See [Roadmap](#roadmap).

## Example

`POST /api/checkout` in the demo app fails inside a database transaction.
The client receives Phoenix's usual `{"errors":{"detail":"Internal Server Error"}}`
plus an `x-traceguard-id` header. The stored report for that ID looks like
this (abridged; the full real output is in
[docs/sample_report.json](docs/sample_report.json)):

```json
{
  "schema": "traceguard.report/v1",
  "trace_id": "9a172de8c3a49cac179676daf5950dca",
  "outcome": "exception",
  "request": {
    "method": "POST", "route": "/api/checkout",
    "headers": {"authorization": "[REDACTED]", "x-api-key": "[REDACTED]", "user-agent": "curl/8.5.0", "...": "..."}
  },
  "response": {"status": 500},
  "duration_us": 144384,
  "events": [
    {"seq": 1,  "process": "request", "offset_us": 25,     "name": "request.start"},
    {"seq": 3,  "process": "request", "offset_us": 10684,  "name": "phoenix.router_dispatch.start", "metadata": {"plug": "TraceGuardDemoWeb.CheckoutController", "action": "create"}},
    {"seq": 4,  "process": "request", "offset_us": 26715,  "name": "ecto.query", "metadata": {"sql": "begin"}},
    {"seq": 5,  "process": "request", "offset_us": 40727,  "name": "ecto.query", "metadata": {"source": "products", "num_rows": 1, "origin": "TraceGuardDemo.Shop.-checkout/1-fun-0-/3 (lib/trace_guard_demo/shop.ex:117)"}},
    {"seq": 7,  "process": "request", "offset_us": 99276,  "name": "ecto.query", "metadata": {"source": "orders", "sql": "INSERT INTO \"orders\" ..."}},
    {"seq": 8,  "process": "request", "offset_us": 107705,  "name": "ecto.query", "metadata": {"sql": "rollback"}},
    {"seq": 9,  "process": "request", "offset_us": 127893, "name": "phoenix.router_dispatch.exception", "outcome": "error"},
    {"seq": 11, "process": "request", "offset_us": 144378, "name": "request.stop", "metadata": {"status": 500}}
  ],
  "failure": {
    "kind": "error",
    "exception": "TraceGuardDemo.Payments.GatewayError",
    "message": "card processor returned HTTP 502 for a 9800 cent charge (merchant api_key=[REDACTED])",
    "captured_by": "phoenix.router_dispatch.exception",
    "stacktrace": [{"module": "TraceGuardDemo.Payments", "function": "charge/2", "file": "lib/trace_guard_demo/payments.ex", "line": 19}]
  },
  "tasks": null,
  "redaction": {"applied": true, "redacted_values": 2, "scrubbed_message_values": 1},
  "limitations": ["Only telemetry events emitted by the request-handling process, or by functions wrapped with TraceGuard.wrap/1, are included; ..."]
}
```

(Timings are from the first checkout after the dev server started, so they
include one-time code loading. Steady-state costs are in
[docs/performance.md](docs/performance.md).)

The request body (password, card number) was never captured. The
`authorization` and `x-api-key` headers were captured only because the demo
allow-lists them, and they are redacted. The merchant API key embedded in the
exception message is scrubbed.

## Installation

TraceGuard is not published to Hex yet. Use a path or git dependency:

```elixir
# mix.exs
{:trace_guard, path: "../trace_guard"}
```

Runtime dependencies: `telemetry`, `plug` and `jason`. Tested with Elixir
1.17 / OTP 26, Phoenix 1.8.15, Plug 1.20.3, Ecto SQL 3.14 and Bandit 1.12.
The `mix.exs` constraints allow Elixir ≥ 1.15 and Phoenix 1.7, which emit the
same events, but those versions are untested.

## Quick start

```elixir
# lib/my_app_web/endpoint.ex
plug Plug.RequestId
plug TraceGuard.Plug        # after RequestId, before Plug.Telemetry and the router
plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

# config/config.exs
config :trace_guard, ecto_telemetry_prefixes: [[:my_app, :repo]]
```

```elixir
TraceGuard.list_reports()                       # newest first
{:ok, report} = TraceGuard.get_report(trace_id) # trace_id from the x-traceguard-id header
{:ok, json} = TraceGuard.export_json(trace_id, pretty: true)
```

Work moved into a `Task` is invisible unless you opt it in:

```elixir
Task.async(TraceGuard.wrap(fn -> Repo.all(Product) end))
```

See [docs/getting_started.md](docs/getting_started.md) for the full guide,
[docs/task_propagation.md](docs/task_propagation.md) for the propagation
contract and [docs/configuration.md](docs/configuration.md) for every option.

## Running the demo

The demo is a small Phoenix API in [`demo/`](demo/) that depends on
TraceGuard through a path dependency. It uses SQLite, so it doesn't need a
database server.

```bash
cd demo
mix setup                    # deps, create + migrate SQLite DB, seed products
mix phx.server               # http://localhost:4000

# in another terminal
cd demo
./scripts/run_demo.sh report.json task_report.json
```

The script calls the healthy endpoints and triggers the failing checkout
with sensitive headers and body. It then triggers a failure inside a wrapped
child task, exports both reports, and checks that none of the six sensitive
test values appear in them. Details are in [demo/README.md](demo/README.md).

## Running the benchmark

```bash
cd demo
MIX_ENV=bench mix bench.requests                       # enabled vs disabled, paired alternating rounds
MIX_ENV=bench mix run --no-start bench/event_cost.exs  # allocation per event
```

Method, results and the proposed overhead budget are in
[docs/performance.md](docs/performance.md). In short, on the reference
laptop:

* A successful request costs about 5–9 µs and 5.6 KB, plus about 1.1 KB per
  recorded query event.
* Building the report for a failed request costs about 0.7–0.9 ms and
  218 KB on a quiet machine. That's down from about 2 ms and 842 KB in
  Phase 1.
* Handing a report to the store adds no measurable request-side cost.
  Retaining it costs the store about 8–14 µs. At the defaults, the store
  holds at most about 1.5 MB (typical reports) to 12 MB (near-worst case).
* The benchmark reports machine drift next to every delta. Latency on this
  laptop is noisy; memory figures repeat exactly.

## Running the tests

```bash
mix test                      # library: 105 tests + 1 doctest (unit, real Phoenix endpoint, real Task processes, storage contract)
(cd demo && mix test)         # demo: 13 tests, end-to-end with real Ecto/SQLite and real Bandit HTTP
mix format --check-formatted
mix compile --warnings-as-errors
```

## Documentation

* [Getting started](docs/getting_started.md)
* [Configuration reference](docs/configuration.md)
* [Architecture: event correlation and exception capture](docs/architecture.md)
* [Task propagation](docs/task_propagation.md)
* [Performance: benchmark method, results, overhead budget](docs/performance.md)
* [Storage, overload and finding reports](docs/storage.md)
* [Phase 2 review: lifecycle, bounds, security, interface changes](docs/phase2_review.md)
* [Phase 3 review: storage inspection, overload guarantees, security, interface changes](docs/phase3_review.md)
* Sample reports generated by `demo/scripts/run_demo.sh`:
  [request failure](docs/sample_report.json), [failure in a child task](docs/sample_task_report.json)

## Limitations

These are deliberate and documented:

* **Request process plus explicitly wrapped work only.** Events are
  attributed to a request only if they are emitted by the process that
  handles it, or by a function wrapped with `TraceGuard.wrap/1`. Plain
  `Task`s, `GenServer`s and other nodes are not included, and task events
  that arrive after the request completes are dropped. (Transactions are
  fine: `Repo.transaction/2` runs its function in the calling process.)
  Nothing is inferred from timing. See
  [docs/task_propagation.md](docs/task_propagation.md#unsupported-cross-process-cases).
* **Only observable events.** TraceGuard records Phoenix endpoint and router
  events, `[:phoenix, :error_rendered]` and Ecto queries. It does not trace
  function calls.
* **Exceptions after the response is sent** (for example a controller that
  calls `send_resp/3` and then raises) are not reported: the trace is already
  complete when the exception happens.
* **No response header for some failures.** For exceptions raised outside the
  router (in an endpoint plug), and for `throw`/`exit` (including
  `Task.await/2` on a crashed task), Phoenix renders the
  error with the conn that entered the endpoint, so the `x-traceguard-id`
  response header is missing. TraceGuard cannot add it there. The report is
  still stored: find it by the client's correlation ID, the request ID or
  trace ID from the log line, or by filters. See
  [docs/storage.md](docs/storage.md#finding-a-report-without-a-response-header).
* **With `debug_errors: true`**, failures outside the router are not reported,
  because `Plug.Debugger` renders them and Phoenix then emits no
  `error_rendered` event. Router failures (the common case) are reported.
* **Exception messages** are the riskiest field. Labelled secrets
  (`api_key=…`, `"password": "…"`, `Bearer …`) are scrubbed, but an unlabelled
  secret cannot be recognized. Set `capture_exception_message: false` if your
  exceptions may carry personal data.
* **Your own logs are not sanitized.** TraceGuard's redaction applies only
  to its own reports. Phoenix, Bandit, Ecto and your `Logger` calls still log
  raw exception messages, secrets included. TraceGuard does not protect
  secrets in any logging system.
* **Linked tasks.** If a `Task.async` task crashes, the link kills the request
  process before Phoenix can render an error, so no report is produced. Use
  `Task.Supervisor.async_nolink/3` for work that may fail.
* **In-memory storage only.** Reports are local to one node and lost on
  restart, including submissions still queued when the store crashes (those
  are counted as `:lost`, without trace IDs). Under a burst, reports beyond
  `max_pending_reports` are refused, not queued. Reports are stored
  asynchronously, so use `await_report/2` rather than reading immediately.
  No persistent adapter exists yet.
* **Measured on one machine.** Overhead figures come from one laptop with
  SQLite, in-process. Latency deltas are noisy (the benchmark shows the
  drift); allocation figures are reliable. Nothing has been measured under
  PostgreSQL, Cowboy, real network I/O, multiple nodes or long-running load.

## Roadmap

* **Phase 1 (done):** the proof of concept.
* **Phase 2 (done):** the benchmark and overhead budget, measured
  optimizations, explicit `Task` propagation, and a lifecycle, bounds and
  security review.
* **Phase 3 (done):**
  * bounded admission for the report store, with observable overload;
  * honest storage outcomes, and reads that never exit;
  * report discovery without a response header;
  * the `TraceGuard.Storage` behaviour with a contract suite;
  * paired, alternating benchmark rounds that show drift.
* **Phase 4 (proposed, not implemented):**
  * explicit propagation for `GenServer` calls;
  * a benchmark run against PostgreSQL and Cowboy on a quiet, dedicated
    machine;
  * an optional persistent storage adapter, built on the Phase 3 contract;
  * a bounded record of recently dropped trace IDs, so `await_report/2` can
    report drops that happened before it was called.
* **Later:** LiveView and Oban events, optional log capture, ExDoc and Hex
  release, a local developer UI, OpenTelemetry interoperability.

## License

TraceGuard is licensed under the [Apache License 2.0](LICENSE).

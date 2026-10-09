# TraceGuard

> When an API request fails, TraceGuard reconstructs the relevant execution
> timeline, correlates available telemetry events, safely redacts sensitive
> information, and produces a useful diagnostic report.

**Status: Phase 1 proof of concept (v0.1.0).** It works end to end against
Phoenix 1.8 / Plug 1.20 / Ecto SQL 3.14, but it is not yet
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

## What Phase 1 does

| Capability | Status |
| --- | --- |
| Generates a unique 128-bit trace ID for each request (`x-traceguard-id` response header, `trace_guard_id` Logger metadata) | ✅ |
| Records method, route template, start time, status and duration | ✅ |
| Records Phoenix endpoint and router events and Ecto queries (timing, table, row count, outcome, calling function) | ✅ |
| Attributes events to the correct request, including under concurrency | ✅ (same-process events only) |
| Captures exceptions through supported Phoenix telemetry, without rescuing them | ✅ |
| Reports error responses that had no exception (e.g. a `503`) | ✅ |
| Redacts sensitive keys recursively in maps, lists and header tuples, and scrubs labelled secrets from exception messages | ✅ |
| Bounded in-memory report store and JSON export | ✅ |
| Validated incoming correlation ID (opt-in) | ✅ |
| Phoenix demo app with real SQLite queries and a deliberate failure | ✅ |

Not in Phase 1: cloud service, dashboard, distributed tracing,
cross-process propagation, automatic function tracing, AI analysis. See
[Roadmap](#roadmap).

## Example

`POST /api/checkout` in the demo app fails inside a database transaction.
The client receives Phoenix's usual `{"errors":{"detail":"Internal Server Error"}}`
plus an `x-traceguard-id` header. The stored report for that ID looks like
this (abridged; the full real output is in
[docs/sample_report.json](docs/sample_report.json)):

```json
{
  "schema": "traceguard.report/v1",
  "trace_id": "7c9c36dba4c0860f2735f0fb71cf6289",
  "outcome": "exception",
  "request": {
    "method": "POST", "route": "/api/checkout",
    "headers": {"authorization": "[REDACTED]", "x-api-key": "[REDACTED]", "user-agent": "curl/8.5.0", "...": "..."}
  },
  "response": {"status": 500},
  "duration_us": 54370,
  "events": [
    {"seq": 1,  "offset_us": 21,    "name": "request.start"},
    {"seq": 3,  "offset_us": 5443,  "name": "phoenix.router_dispatch.start", "metadata": {"plug": "TraceGuardDemoWeb.CheckoutController", "action": "create"}},
    {"seq": 4,  "offset_us": 8219,  "name": "ecto.query", "metadata": {"sql": "begin"}},
    {"seq": 5,  "offset_us": 11578, "name": "ecto.query", "metadata": {"source": "products", "num_rows": 1, "origin": "TraceGuardDemo.Shop.-checkout/1-fun-0-/3 (lib/trace_guard_demo/shop.ex:23)"}},
    {"seq": 7,  "offset_us": 35528, "name": "ecto.query", "metadata": {"source": "orders", "sql": "INSERT INTO \"orders\" ..."}},
    {"seq": 8,  "offset_us": 40358, "name": "ecto.query", "metadata": {"sql": "rollback"}},
    {"seq": 9,  "offset_us": 48684, "name": "phoenix.router_dispatch.exception", "outcome": "error"},
    {"seq": 11, "offset_us": 54367, "name": "request.stop", "metadata": {"status": 500}}
  ],
  "failure": {
    "kind": "error",
    "exception": "TraceGuardDemo.Payments.GatewayError",
    "message": "card processor returned HTTP 502 for a 9800 cent charge (merchant api_key=[REDACTED])",
    "captured_by": "phoenix.router_dispatch.exception",
    "stacktrace": [{"module": "TraceGuardDemo.Payments", "function": "charge/2", "file": "lib/trace_guard_demo/payments.ex", "line": 19}]
  },
  "redaction": {"applied": true, "redacted_values": 2, "scrubbed_message_values": 1},
  "limitations": ["Only telemetry events emitted by the request-handling process are included; ..."]
}
```

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

See [docs/getting_started.md](docs/getting_started.md) for the full guide and
[docs/configuration.md](docs/configuration.md) for every option.

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
./scripts/run_demo.sh report.json
```

The script calls the healthy endpoints, triggers the failing checkout with
sensitive headers and body, prints the stored-report list, exports the report
to `report.json`, and checks that none of the five sensitive test values
appear in it. Details are in [demo/README.md](demo/README.md).

## Running the tests

```bash
mix test                      # library: unit + real Phoenix endpoint integration
(cd demo && mix test)         # demo: end-to-end with real Ecto/SQLite and real Bandit HTTP
mix format --check-formatted
mix compile --warnings-as-errors
```

## Documentation

* [Getting started](docs/getting_started.md)
* [Configuration reference](docs/configuration.md)
* [Architecture: event correlation and exception capture](docs/architecture.md)
* [Sample report](docs/sample_report.json), generated by `demo/scripts/run_demo.sh`

## Limitations

These come from the design of Phase 1 and are documented on purpose:

* **Single process only.** Events are attributed to a request only if they
  are emitted by the process that handles it. Queries run inside a `Task` or a
  `GenServer` are not included. (Transactions are fine: `Repo.transaction/2`
  runs its function in the calling process.) Nothing is inferred from timing.
* **Only observable events.** TraceGuard records Phoenix endpoint and router
  events, `[:phoenix, :error_rendered]` and Ecto queries. It does not trace
  function calls.
* **Exceptions after the response is sent** (for example a controller that
  calls `send_resp/3` and then raises) are not reported: the trace is already
  complete when the exception happens.
* **No response header for some failures.** For exceptions raised outside the
  router (in an endpoint plug), and for `throw`/`exit`, Phoenix renders the
  error with the conn that entered the endpoint, so the `x-traceguard-id`
  response header is missing. The report is still stored; find it with
  `TraceGuard.list_reports/0` or via the `trace_guard_id` Logger metadata.
* **With `debug_errors: true`**, failures outside the router are not reported,
  because `Plug.Debugger` renders them and Phoenix then emits no
  `error_rendered` event. Router failures (the common case) are reported.
* **Exception messages** are the riskiest field. Labelled secrets
  (`api_key=…`, `"password": "…"`, `Bearer …`) are scrubbed, but an unlabelled
  secret cannot be recognized. Set `capture_exception_message: false` if your
  exceptions may carry personal data.
* **Your own logs are unaffected.** Phoenix and Bandit still log the raw
  exception message, secrets included. TraceGuard only controls its own
  reports.
* **In-memory storage.** Reports are lost on restart, are local to one node,
  and are written asynchronously, so a report is readable shortly after
  (not exactly when) its response is sent.
* **Overhead has not been benchmarked.** Each observed event costs a process
  dictionary read and write plus one small map. Reports are built only for
  failed requests. No numbers are claimed until Phase 2 measures them.

## Roadmap

Proposed next steps (none of these are implemented):

* **Phase 2: hardening and measurement.** Benchmarks and an overhead budget;
  explicit context propagation to `Task`s; LiveView and Oban events; optional
  log-line capture; a pluggable storage behaviour; ExDoc and Hex release.
* **Later:** a local developer UI, OpenTelemetry interoperability, and only
  then hosted collection and analysis.

## License

TraceGuard is licensed under the [Apache License 2.0](LICENSE).

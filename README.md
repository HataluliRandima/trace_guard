# TraceGuard

When a Phoenix request fails, TraceGuard gives you a **redacted diagnostic
report for that one request**: the route, the Ecto queries it ran (in
order, with timings), the work it did in Tasks and GenServer calls you opted
in, the exception, and what TraceGuard could *not* see. It never changes the
response or swallows the exception.

**Status: 0.1.0-rc.1, release candidate, not on Hex.** Tested on four
verified combinations from Elixir 1.15.8 / OTP 26 to Elixir 1.20.1 / OTP 29,
with Phoenix 1.7.24 and 1.8.15, under Bandit and Cowboy. See
[Limitations](#limitations) and [docs/compatibility.md](docs/compatibility.md).

## Why not just logs or telemetry?

* **Logs** interleave every concurrent request, and they include raw secrets.
  Finding "what did *this* failing request do" means correlating lines by
  hand.
* **Telemetry** emits events, but nothing ties them back into one failed
  request's story, and nothing redacts them.
* **TraceGuard** attaches to the telemetry Phoenix and Ecto already emit. It
  attributes each event to the request that caused it (by process, never by
  timing) and keeps only failures. It produces one JSON document per failure
  with sensitive keys redacted before the report leaves the request process.
  It is a library in your app: no agent, no service, no network calls.

It is not a distributed tracer or an APM, and it doesn't trace function
calls. It records the events listed in the report, nothing more.

## Install

Not yet on Hex. Use a path or git dependency:

```elixir
# mix.exs
{:trace_guard, path: "../trace_guard"}
# or {:trace_guard, git: "https://github.com/HataluliRandima/trace_guard.git", ref: "<commit>"}
```

## Configure (three lines)

```elixir
# lib/my_app_web/endpoint.ex: after Plug.RequestId, before Plug.Telemetry
plug Plug.RequestId
plug TraceGuard.Plug
plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

# config/config.exs
config :trace_guard, ecto_telemetry_prefixes: [[:my_app, :repo]]   # for MyApp.Repo
```

Everything else has conservative defaults: no request bodies, query strings,
cookies, SQL text or SQL parameters. See
[docs/configuration.md](docs/configuration.md).

## End-to-end example

```elixir
# A controller action that fails after a query
def show(conn, %{"id" => id}) do
  order = Repo.get!(Order, id)
  Payments.charge!(order)          # raises "payment provider rejected charge (api_key=demo_key_123)"
  json(conn, order)
end
```

```text
$ curl -i localhost:4000/api/orders/7
HTTP/1.1 500 Internal Server Error
x-traceguard-id: 9a172de8c3a49cac179676daf5950dca
{"errors":{"detail":"Internal Server Error"}}
```

```elixir
iex> {:ok, report} = TraceGuard.await_report("9a172de8c3a49cac179676daf5950dca")
iex> report["failure"]["message"]
"payment provider rejected charge (api_key=[REDACTED])"
iex> for e <- report["events"], do: {e["offset_us"], e["process"], e["name"]}
[{25, "request", "request.start"}, {10684, "request", "phoenix.router_dispatch.start"},
 {26715, "request", "ecto.query"}, ..., {127893, "request", "phoenix.router_dispatch.exception"}, ...]
iex> TraceGuard.export_json("9a172de8c3a49cac179676daf5950dca", pretty: true)
{:ok, "{\n  \"schema\": \"traceguard.report/v1\", ..."}
```

(Abridged and illustrative.) Real, complete reports from the demo:
[request failure](docs/sample_report.json),
[failure in a Task](docs/sample_task_report.json),
[failure in a traced GenServer call](docs/sample_server_report.json).

## Retrieving reports

| You have | Use |
| --- | --- |
| the `x-traceguard-id` response header | `TraceGuard.get_report(id)` or `TraceGuard.await_report(id, timeout)` |
| no header (throws, exits, endpoint-plug failures) | the client's correlation ID (`incoming_header: "x-correlation-id"`), then `TraceGuard.list_reports(incoming_id: "...")`; or the request ID from your logs, `list_reports(request_id: ...)` |
| a trace ID, and want to know what happened to its report | `TraceGuard.report_status(id)`: `:stored`, `{:dropped, reason}`, `:pending` or `:unknown` |
| a report to share | `TraceGuard.export_json(id, pretty: true)` |

Reports live in a bounded in-memory store by default, or in a SQLite file
with the optional adapter ([docs/storage.md](docs/storage.md)). All lookups
are node-local functions; TraceGuard serves nothing over HTTP.

## Work outside the request process (opt-in)

```elixir
Task.async(TraceGuard.wrap(fn -> Repo.all(Product) end))      # Task
TraceGuard.call(MyApp.Pricing, {:quote, sku, qty})            # GenServer with `use TraceGuard.Server`
```

Unwrapped Tasks, ordinary `GenServer.call/3`s, casts and a server's
background work are never attributed to a request. See
[task propagation](docs/task_propagation.md) and
[GenServer propagation](docs/genserver_propagation.md) (experimental).

## What is captured and what is redacted

* **Captured:** method, route template, status, timings; Phoenix endpoint and
  router events; Ecto query timing, table, row count, outcome and calling
  function; allow-listed request headers; exception module, message and
  stack frames (without arguments); opted-in Task and GenServer lifecycle
  events.
* **Never captured:** request bodies, query strings, cookies, SQL parameters,
  result rows, Task or GenServer arguments, inspected throw values or exit
  reasons.
* **Redacted before storage or export:** values under sensitive keys
  (`password`, `authorization`, `token`, `api_key`, `secret`, `cookie`, ...
  and your `redact_keys`), recursively. Also labelled secrets in exception
  messages (`api_key=…`, `Bearer …`).
* **Not protected:** unlabelled secrets inside exception messages
  (`capture_exception_message: false` turns messages off), and **your
  application's own logs.**

> ⚠️ **TraceGuard does not sanitize Phoenix, Plug, Bandit, Cowboy, Ecto or
> OTP log output.** Those log raw exception messages, secrets included,
> exactly as they would without TraceGuard. Verified: in the external
> integration test, both Bandit's and Cowboy's crash logs contained the API
> key that the TraceGuard report had redacted.

Details: [docs/security.md](docs/security.md).

## Reproduce the demo

```bash
cd demo
mix setup && mix phx.server                  # http://localhost:4000
./scripts/run_demo.sh a.json b.json c.json   # in another terminal
```

The script triggers three deliberate failures: in the request, in a Task,
and in a GenServer call. It exports their reports and checks that none of
seven planted secrets appear in them. See [demo/README.md](https://github.com/HataluliRandima/trace_guard/blob/main/demo/README.md).

## Limitations

* **Only observable, attributable events.** Events must come from the
  request process, a `wrap/1`ped function, or a `TraceGuard.Server`
  callback during `TraceGuard.call/3`. No function tracing, no implicit
  propagation, single node only.
* **Some failures have no response header:** throws, exits and exceptions in
  endpoint plugs. Use correlation IDs (above).
* **Cowboy:** an exception raised in an *endpoint plug* (outside the router)
  can go unreported, because Cowboy terminates the request process right
  after the response, before TraceGuard can finish. This is reproduced by a
  test that kills the request process at that point, but wasn't observed
  under real Cowboy. Router failures,
  including throws and exits, are reported. Cowboy's crash log doesn't carry
  `trace_guard_id`. Current Cowboy needs OTP 27 or later.
* **`debug_errors: true`:** failures outside the router are not reported.
* **Exceptions after the response was sent** are not reported.
* **Storage is local:** in memory (lost on restart), or SQLite for
  development and testing. Under a burst, reports beyond
  `max_pending_reports` are refused (and recorded as dropped), not queued.
* **Untested:** PostgreSQL, Ecto SQL other than 3.14, macOS, Windows,
  releases, multiple nodes, long-running load. See
  [docs/compatibility.md](docs/compatibility.md).
* **Performance** has been measured on one laptop only. Observations, not
  guarantees, are in [docs/performance.md](docs/performance.md).

## Development

```bash
mix test                          # library (148 tests + 1 doctest)
(cd demo && mix test)             # demo application (16 tests)
scripts/compat_matrix.sh          # library on several Elixir/OTP/dependency versions
scripts/external_smoke.sh         # a fresh Phoenix app integrating TraceGuard (Bandit/Cowboy x memory/SQLite)
MIX_ENV=dev mix docs              # HexDocs-style documentation in doc/
```

The release procedure is in [docs/release_checklist.md](docs/release_checklist.md),
the history in [CHANGELOG.md](CHANGELOG.md), and design notes in
[docs/architecture.md](docs/architecture.md) and the phase reviews.

## License

Apache License 2.0. See [LICENSE](https://github.com/HataluliRandima/trace_guard/blob/main/LICENSE).

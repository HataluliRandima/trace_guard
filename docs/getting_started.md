# Getting started

This guide adds TraceGuard to an existing Phoenix application and walks
through investigating a failed request.

## 1. Add the dependency

TraceGuard is not on Hex yet:

```elixir
# mix.exs
defp deps do
  [
    {:trace_guard, path: "../trace_guard"}
    # or: {:trace_guard, git: "<repository url>"}
  ]
end
```

```bash
mix deps.get
```

TraceGuard starts its own supervision tree (a bounded report store) and
attaches its telemetry handlers when your application boots. You don't need
to add anything to your supervision tree.

## 2. Add the plug to your endpoint

Order matters:

```elixir
# lib/my_app_web/endpoint.ex
plug Plug.RequestId
plug TraceGuard.Plug
plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

plug Plug.Parsers, ...
plug MyAppWeb.Router
```

* **After `Plug.RequestId`**, so the report records the `x-request-id` and you
  can find matching log lines.
* **Before `Plug.Telemetry` and the router**, so endpoint, router and query
  events happen while the request's trace is active.
* `Plug.Static` and `Phoenix.CodeReloader` normally sit above it, so static
  assets are not traced.

## 3. Tell TraceGuard about your Ecto repos

Ecto emits query events under the repo's telemetry prefix. By default that is
the repo module name in snake case: `MyApp.Repo` uses `[:my_app, :repo]`.

```elixir
# config/config.exs
config :trace_guard,
  ecto_telemetry_prefixes: [[:my_app, :repo]]
```

Optional: set `stacktrace: true` on the repo so that each query event can
name the function that issued it (the `origin` field):

```elixir
config :my_app, MyApp.Repo, stacktrace: true
```

## 4. Trigger a failure and look at the report

Every traced response carries an `x-traceguard-id` header, and every log
line for that request carries `trace_guard_id` metadata. To print it, add it
to your logger format:

```elixir
config :logger, :default_formatter, metadata: [:request_id, :trace_guard_id]
```

Reports are stored only for failed requests: by default, responses with a
status of 500 or above. Use the trace ID from a failed request:

```elixir
iex> TraceGuard.list_reports()
[%{"trace_id" => "7c9c36dba4c0860f2735f0fb71cf6289", "route" => "/api/checkout",
   "status" => 500, "exception" => "MyApp.Payments.GatewayError", ...}]

iex> {:ok, report} = TraceGuard.get_report("7c9c36dba4c0860f2735f0fb71cf6289")
iex> {:ok, json} = TraceGuard.export_json("7c9c36dba4c0860f2735f0fb71cf6289", pretty: true)
iex> TraceGuard.Exporter.JSON.write(report, "failure.json")
```

To check a report programmatically from inside the failing process (for
example in a test), call `TraceGuard.current_trace_id/0` while the request
is being handled.

## 5. Read the report

1. `failure` tells you what was raised (`exception`, `message`), where
   (`stacktrace`, with argument values removed) and which integration
   observed it (`captured_by`).
2. `events` is the ordered timeline. `offset_us` is the time since the
   request started, and `duration_us` is how long the step took, when the
   source reports it. Look at what happened just before the exception: which
   queries ran, which returned zero rows or an error, and whether a
   transaction was rolled back.
3. `request.route` and `ecto.query` → `origin` point to the code to open.
4. `limitations` lists what this report **cannot** show, such as events in
   other processes or SQL text that was not captured.

The full report structure is described in
[architecture.md](architecture.md#report-structure).

## 6. Optional: include work done in Tasks

Events from processes other than the request process are not part of the
trace unless you opt them in. Wrap the function in the request process:

```elixir
def dashboard(conn, _params) do
  [orders, stats] =
    [fn -> Orders.recent() end, fn -> Stats.compute() end]
    |> Enum.map(&Task.async(TraceGuard.wrap(&1)))
    |> Task.await_many()

  json(conn, %{orders: orders, stats: stats})
end
```

If a task may crash, prefer `Task.Supervisor.async_nolink/3`. A linked task
crash kills the request process before any error can be rendered or
reported. See [task_propagation.md](task_propagation.md) for the full
contract, limits and unsupported cases.

## 6b. Optional: include work done in a GenServer

For a long-lived server that does work on behalf of requests (pricing,
caching, an API client), opt in on both sides:

```elixir
defmodule MyApp.Pricing do
  use GenServer
  use TraceGuard.Server          # after use GenServer
  # handle_call/3 clauses unchanged
end

TraceGuard.call(MyApp.Pricing, {:quote, sku, qty})   # instead of GenServer.call/3
```

Only that call's `handle_call/3` is traced; the server's background work
never is. See [genserver_propagation.md](genserver_propagation.md).

## 7. Finding a report when the response has no trace header

Throws, exits (including `Task.await/2` on a crashed task) and exceptions in
endpoint plugs are rendered by Phoenix without TraceGuard's header. To still
find their reports, let clients send a correlation ID:

```elixir
config :trace_guard, incoming_header: "x-correlation-id"
```

```elixir
TraceGuard.list_reports(incoming_id: "checkout-7f3a")   # exact match
TraceGuard.list_reports(request_id: "F5zX...")         # from the crash log line
```

With `metadata: [:request_id, :trace_guard_id]` in your logger format,
Bandit's crash log line also carries the trace ID. All the options are in
[storage.md](storage.md#finding-a-report-without-a-response-header).

## 7b. Was my report kept?

```elixir
TraceGuard.report_status(trace_id)
#=> :stored | {:dropped, :overloaded} | {:dropped, :lost} | :pending | :unknown
```

`:unknown` means TraceGuard has no record, for example because it expired
after `:drop_record_ttl`. It never means "not dropped". See
[storage.md](storage.md#drop-records-phase-4).

## 7c. Optional: keep reports across restarts in development

```elixir
# mix.exs
{:exqlite, "~> 0.42"}

# config/dev.exs
config :trace_guard,
  storage: {TraceGuard.Storage.SQLite, database: "priv/trace_guard_reports.db"}
```

No migration is needed: the adapter creates its table. Writes happen in a
background writer behind the same bounded queue as the in-memory store. See
[storage.md](storage.md#the-sqlite-adapter-persistent-phase-4).

## 8. Optional: expose reports in development

The demo app adds a development-only controller (see
`demo/lib/trace_guard_demo_web/controllers/trace_report_controller.ex`) that
is routed only when a compile-time flag is set. If you copy it, never route it
in production: reports describe your application's internals.

## Testing your integration

Phoenix's `assert_error_sent/2` works unchanged, because TraceGuard never
rescues exceptions:

```elixir
{500, headers, _body} = assert_error_sent(500, fn -> get(conn, "/boom") end)
{_, trace_id} = List.keyfind(headers, "x-traceguard-id", 0)
{:ok, report} = TraceGuard.await_report(trace_id, 1_000)
```

Reports are stored asynchronously, just after the response.
`await_report/2` waits for the store's `[:trace_guard, :report, :stored]`
event, without polling, and returns `{:error, {:dropped, reason}}` if the
report is refused (for example when the store is overloaded).

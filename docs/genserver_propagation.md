# GenServer propagation

`TraceGuard.wrap/1` covers work you move into a `Task`. A **GenServer** is
different: it is a long-lived process that serves many callers, one message
at a time, and it often runs the queries that matter (caches, pricing,
rate limiting, external API clients). Phase 4 adds an explicit way to bring
a request's trace into **selected** calls to such a server.

## What can, and cannot, be correlated reliably

* **Can:** the work a server does *while it handles one specific call*. A
  GenServer processes one message at a time, so if the message itself carries
  the caller's trace token, everything emitted during that callback belongs
  to that caller, with no guessing.
* **Cannot, without changing the server:** a plain `GenServer.call/3`
  carries no context. The `from` tag is opaque, and the server's process
  dictionary can't be reached from outside. Correlating by "the call that
  arrived most recently" or by timing would attach other callers' work to
  the wrong request. TraceGuard doesn't do that.
* **Never:** the server's own background activity (`handle_info`, timers,
  casts) and work done after replying later with `GenServer.reply/2`. Those
  don't belong to any one request.

So the integration needs both sides to opt in, and it instruments
**individual calls**, not servers.

## API

```elixir
# Server: opt in once. Your handle_call/3 clauses stay exactly as they are.
defmodule MyApp.Pricing do
  use GenServer
  use TraceGuard.Server

  @impl true
  def handle_call({:quote, sku, qty}, _from, state) do
    product = MyApp.Repo.get_by!(MyApp.Product, sku: sku)   # traced for the caller
    {:reply, product.price_cents * qty, state}
  end
end

# Caller (a controller, a context function, ...): opt in per call.
TraceGuard.call(MyApp.Pricing, {:quote, "TG-001", 2})          # default timeout 5000
TraceGuard.call(MyApp.Pricing, {:quote, "TG-001", 2}, 1_000)
```

* `TraceGuard.call(server, request, timeout \\ 5000)` sends
  `{TraceGuard.Server, token, request}` with `GenServer.call/3`. The token is
  the same one `wrap/1` uses (trace ID, collector pid, shared `:atomics`
  budget), or `nil` when the caller has no active trace.
* `use TraceGuard.Server` (after `use GenServer`) overrides `handle_call/3`
  so that messages of that shape are unwrapped and **your**
  `handle_call(request, from, state)` runs with the caller's trace active,
  for the duration of that callback only. Every other message reaches your
  callbacks unchanged.
* Using `use TraceGuard.Server` in a module that defines no `handle_call/3`
  is a compile-time error. It works with or without `@impl` (both styles are
  compiled with warnings as errors in the test suite).

## What appears in the report

```json
{"seq": 4, "process": "server-1", "name": "genserver.call.start",
 "metadata": {"server": "MyApp.Pricing", "operation": "quote"}},
{"seq": 5, "process": "server-1", "name": "ecto.query", "metadata": {"source": "products", ...}},
{"seq": 6, "process": "server-1", "name": "genserver.call.exception", "outcome": "error",
 "metadata": {"server": "MyApp.Pricing", "operation": "quote", "kind": "error",
              "exception": "MyApp.Pricing.CurrencyError"}}
```

* Server-side events are labelled `server-N` (tasks: `task-N`), numbered per
  kind in order of first appearance, in the same merged timeline.
* `operation` is the request's leading atom (`:quote` for
  `{:quote, sku, qty}`, or the atom itself). The request's data is never
  recorded.
* A real example: [sample_server_report.json](sample_server_report.json),
  from the demo's `POST /api/quote`.

## Semantics

| Situation | Behaviour |
| --- | --- |
| Return values | Unchanged: `{:reply, ...}`, `{:noreply, ...}`, `{:stop, ...}` and `throw`-returns (`throw({:reply, v, state})`, which `gen_server` treats as a return) pass through. A throw-return is recorded as `genserver.call.stop`. |
| Callback raises or exits | Recorded as `genserver.call.exception` (kind and exception module), then re-raised with the original stacktrace. The server crashes and the caller exits, exactly as with `GenServer.call/3`. In the request's report the failure reads, for example, `GenServer.call/3 exited: process crashed: <message>` (scrubbed), with the server's exception module. |
| Concurrent callers | Serialized by the server, each message with its own token. The context is set from the message and removed or restored in an `after` block. Tested with 20 concurrent requests to one server. |
| Background work | Casts, infos, timers and other callers' ordinary calls run with no trace context (tested by interleaving them with a traced call, and by checking the server's process dictionary afterwards). |
| Deferred replies | Only the `handle_call/3` callback is traced. Work done before a later `GenServer.reply/2` (for example in `handle_info`) is not. |
| Timeouts | As with `GenServer.call/3`: the caller exits after `timeout`. If the server still processes the message, its events join the trace only if the trace is still live; otherwise they are dropped like late task events. The server keeps serving. |
| Server restarts | The token doesn't reference the server. A restarted server serves traced calls normally (tested). A call to a server that is down exits with `:noproc`, as `GenServer.call/3` does. |
| Nested calls | Inside a traced callback, `TraceGuard.call/3` and `TraceGuard.wrap/1` propagate the same token. Each server gets its own label. |
| No trace / TraceGuard disabled | The message keeps the wrapped shape with `token: nil`, and the server just runs the callback. Because the shape never depends on tracing, a server that forgot `use TraceGuard.Server` fails the same way (`FunctionClauseError`) in every environment. |
| Limits | The token's shared budget (`:max_events` per trace across all tasks and servers), `:max_task_collectors`, and the drain timeout all apply as for `wrap/1`. TraceGuard adds no waiting and no queue. |
| Exit reasons | When a traced call exits, the exit reason's `{GenServer, :call, [server, message, timeout]}` contains the *wrapped* message, including the token (a trace ID, a pid and an atomics reference; no request data). TraceGuard's report never includes it (it records only `GenServer.call/3`). Code that pattern-matches on that exact exit reason sees the wrapped message. |

## Instrumenting a call vs tracing a server

`TraceGuard.call/3` answers "what did the pricing server do **for this
request**?" It doesn't answer "what is the pricing server doing?" If a server
does expensive background work that makes requests slow (holding a lock,
refreshing a cache), that work appears in no request's report. It isn't
caused by one request, and attaching it to whichever request was waiting
would be wrong. Use your server's own telemetry or logs for that.

## Cost

Measured on the reference laptop (see [performance.md](performance.md)):

* about 0.1 µs per call for the wrapper when the caller has no trace;
* about 5 µs per traced call inside an active trace (lifecycle events plus
  messages to the collector);
* a once-per-request fixed cost when the first `wrap/1` or `TraceGuard.call/3`
  starts the trace's collector process. In the demo's quote request, the
  total enabled-vs-disabled delta was about +107 µs in the low-drift run.

## Not supported in Phase 4

* `GenServer.cast/2`, `send/2`, and `:gen_statem` / `:gen_event` calls.
* Implicit propagation (`$callers`, process-dictionary inheritance).
* Remote servers on other nodes. The token's `:atomics` budget is
  node-local, so a server receiving a token from another node runs the
  callback **untraced** (the call itself works normally). Multi-node
  behaviour beyond that guard is untested.

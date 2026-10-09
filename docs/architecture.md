# Architecture

This document explains how TraceGuard decides that an event belongs to a
request, how it captures failures without changing Phoenix's error
handling, and what a report contains. Everything here was verified against
Phoenix 1.8.15, Plug 1.20.3, Ecto SQL 3.14.0 and Bandit 1.12.5.

## Modules

| Module | Responsibility |
| --- | --- |
| `TraceGuard` | Public API: `get_report/1`, `export_json/2`, `list_reports/0`, `current_trace_id/0`. |
| `TraceGuard.Config` | Validates options at boot and caches them in `:persistent_term`. |
| `TraceGuard.Plug` | Starts a trace, records request metadata, and completes the trace in `before_send`. |
| `TraceGuard.Context` | Request-local trace state in the request process's dictionary; generates trace IDs. |
| `TraceGuard.EventCollector` | Appends bounded events to the context, records the failure, and completes the trace. |
| `TraceGuard.Telemetry` | Attaches handlers and turns telemetry metadata into allow-listed event fields. |
| `TraceGuard.TraceBuilder` | Orders events, converts times, makes values JSON-safe, then redacts. |
| `TraceGuard.Redactor` | Key normalization, recursive redaction, message scrubbing. |
| `TraceGuard.ReportStore` | Bounded in-memory GenServer of finished, redacted reports. |
| `TraceGuard.Exporter.JSON` | Jason encoding and file export. |
| `TraceGuard.Propagation` | `wrap/1`: opt-in propagation of a trace into selected processes (Phase 2). |
| `TraceGuard.TaskCollector` | Per-trace process that receives the events of wrapped work; bounded and always terminating (Phase 2). |

## Event correlation

TraceGuard relies on two facts and does not use time-based heuristics:

1. **One request is handled by one process.** Cowboy runs each request in
   its own stream process. Bandit runs HTTP/1 requests in the connection
   process, one after another for keep-alive, and each HTTP/2 stream in its
   own process. Endpoint plugs, the router, the controller and anything they
   call synchronously all run in that process.
2. **Telemetry handlers run synchronously in the emitting process.**
   `:telemetry.execute/3` calls each handler inline. Phoenix router events
   and Ecto query events (`Ecto.Adapters.SQL` emits them from the caller's
   log callback) are emitted in the process that did the work.

Therefore:

```
request process
───────────────────────────────────────────────────────────────────────────
TraceGuard.Plug.call/2          Process.put({Context, :ctx}, %Context{trace_id: ...})
Plug.Telemetry                  [:phoenix, :endpoint, :start] ─┐
Router                          [:phoenix, :router_dispatch, :start] ─┤ handler: Process.get(ctx)?
Controller → Repo.one!          [:my_app, :repo, :query] ─────────────┤   yes → append event
                                                                      │   no  → ignore
before_send                     record status, build + redact report, Process.delete(ctx)
```

A handler appends an event only if **the emitting process** has an active
context. Consequences:

* **Isolation is structural.** Another request's events are emitted in
  another process, so they cannot reach this context, and in-flight state
  cannot be read from outside its process. The test suites check this with
  40 interleaved concurrent requests (library) and 10 concurrent real
  database checkouts (demo).
* **No implicit cross-process attribution.** A query inside a plain
  `Task.async/1` or a `GenServer` finds no context and is dropped, never
  guessed. Each report lists this in `limitations`.
* **Explicit propagation (Phase 2).** `TraceGuard.wrap/1` gives a function a
  token (trace ID, collector pid, shared `:atomics` budget). Whichever process
  runs the function gets a temporary *task context* (`role: :task`) whose
  events are sent to the trace's `TaskCollector`. The request process merges
  them when it completes. The correlation is still structural, never
  time-based. The full contract is in [task_propagation.md](task_propagation.md).
* **Process reuse is handled.** Bandit reuses the connection process for
  keep-alive requests. Each `TraceGuard.Plug.call/2` replaces any stale
  context, and completing a trace deletes it. Tests run consecutive
  failing and succeeding requests in one process and check that each report
  contains only its own events.

Events carry a per-trace sequence number and a `System.monotonic_time/0`
reading. Reports sort by `{monotonic_time, seq}` and express time as
`offset_us` from the request's start. Durations come from the source's own
measurements (`duration`, `total_time`), which are also monotonic. The only
wall-clock values are `request.started_at` and `generated_at` (UTC,
ISO 8601).

## Exception capture

### Why a plug alone is not enough

A Plug's `call/2` returns its conn before the downstream plugs run, so an
ordinary plug placed before the router never sees a downstream exception.
Wrapping the rest of the pipeline in `try/rescue` would require
TraceGuard to sit around the router and to re-raise exactly as Phoenix
expects. Monkey-patching `Phoenix.Endpoint.call/2` is out of the question.
TraceGuard uses Phoenix's own, documented telemetry instead.

### What Phoenix 1.8 actually does

From `Phoenix.Router.__call__/5` and `Phoenix.Endpoint.RenderErrors`:

1. A controller raises. The router catches it, emits
   **`[:phoenix, :router_dispatch, :exception]`** (with `kind`, `reason`,
   `stacktrace`), and re-raises. `:error` exceptions are wrapped in
   `Plug.Conn.WrapperError` with the conn as it was inside the router.
   `throw`/`exit` are re-raised unwrapped.
2. The endpoint's `call/2` (generated by `use Phoenix.Endpoint`) catches
   everything and calls `RenderErrors.__catch__/5`, which:
   * uses the conn from the `WrapperError`, if there is one, or else the conn
     that **entered the endpoint**;
   * renders the error view and **sends the response**, which runs that
     conn's `before_send` callbacks;
   * **then** emits **`[:phoenix, :error_rendered]`**;
   * **re-raises** the original exception (except `NoRouteError`), so the
     adapter (Bandit/Cowboy) logs it.
3. If the response was already sent, `RenderErrors` renders nothing and emits
   nothing, and only re-raises.

### How TraceGuard uses it

| Failure | What happens | Report |
| --- | --- | --- |
| `:error` raised in a controller/router pipeline | `router_dispatch.exception` records the failure → `RenderErrors` sends with the wrapped conn → TraceGuard's `before_send` completes the trace | ✅ with route, events, failure and `x-traceguard-id` header |
| `throw`/`exit` in a controller | `router_dispatch.exception` records the failure → rendered with the endpoint's original conn (no `before_send`) → `error_rendered` handler completes the trace | ✅, but no response header |
| Exception in an endpoint plug after `TraceGuard.Plug` | No router event → rendered with the original conn → `error_rendered` handler records the failure and completes the trace | ✅ (`captured_by: "phoenix.error_rendered"`), no header, no route |
| Error status without an exception (e.g. `send_resp(conn, 503, ...)`) | `before_send` sees a status ≥ `:failure_status` | ✅ (`outcome: "error_status"`) |
| `debug_errors: true`, failure in the router | `Plug.Debugger` renders with the wrapped conn → `before_send` | ✅ |
| `debug_errors: true`, failure outside the router | `Plug.Debugger` renders with the original conn, and `RenderErrors` emits nothing because the response is already sent | ❌ (documented limitation, covered by a test) |
| Exception after the response was sent | The trace was completed at send time with the success status | ❌ (documented limitation, covered by a test) |

The first failure recorded wins. A later, less specific signal never
overwrites it.

TraceGuard never rescues anything in the request path except its own
internal errors. The tests use `Phoenix.ConnTest.assert_error_sent/2`, which
only passes if Phoenix both rendered the error **and** re-raised it, and the
demo checks that a failed checkout's transaction is still rolled back. Every
telemetry handler rescues its own errors, because `:telemetry` permanently
detaches a handler that raises.

## Metadata filtering

Telemetry metadata routinely includes the full `Plug.Conn`, Ecto `params`,
`cast_params`, result `rows` and `options`. Handlers never store metadata
wholesale. Each one copies an explicit allow-list:

| Event | Fields kept |
| --- | --- |
| `phoenix.router_dispatch.*` | `route`, `plug` (module name), `action`, `pipe_through`, `status`; for exceptions: `kind`, `exception` (module name) |
| `phoenix.endpoint.stop`, `phoenix.error_rendered` | `status` (and `kind`, `exception`) |
| `ecto.query` | `repo`, `source`, `query_time_us`, `queue_time_us`, `decode_time_us`, `num_rows` or `error` (module name), `origin` (first non-Ecto frame, no arguments), `sql` only if `capture_sql: true` |

A test sends query events whose metadata contains a fake parameter, result
rows, options and SQL text, and asserts that none of it appears in the
report.

## Report pipeline

When a request completes, still in the request process:

1. **Order** events by `{monotonic time, seq}`.
2. **Convert** times to microseconds relative to the request start.
3. **Sanitize** the data so it is JSON-safe: atoms become strings; structs,
   PIDs, references, functions, ports and tuples become placeholders such as
   `"(pid)"`; invalid UTF-8 becomes `"(binary, N bytes)"`; long strings and
   lists are truncated; nesting depth is capped.
4. **Redact** sensitive keys everywhere and scrub the exception message.
5. **Store** the result with an asynchronous cast to `ReportStore`.

Only the output of step 4 leaves the request process.

## Report structure

`schema: "traceguard.report/v1"`. All keys are strings.

| Field | Type | Notes |
| --- | --- | --- |
| `schema` | string | Bumped on breaking changes. |
| `trace_id` | string | 32 lowercase hex characters. |
| `generated_at` | string | ISO 8601 UTC. |
| `outcome` | `"exception"` \| `"error_status"` | |
| `request.method` | string | |
| `request.route` | string \| null | Route template, e.g. `/users/:id`. Null if no route was dispatched. |
| `request.path` | string \| null | Only with `capture_path: true`. |
| `request.path_params` | object | Only with `capture_path_params: true`. |
| `request.started_at` | string | ISO 8601 UTC. |
| `request.request_id` | string \| null | From `Plug.RequestId`. |
| `request.incoming_id` | object \| null | `{header, value}`, validated (see configuration). |
| `request.headers` | object | Allow-listed headers only, redacted. |
| `response.status` | integer \| null | |
| `duration_us` | integer | From trace start to report build. |
| `events[]` | array | `seq` (position in the merged timeline, 1..n), `process` (`"request"` or `"task-N"`), `name`, `type`, `offset_us`, `duration_us` (nullable), `outcome` (`"ok"`, `"error"` or null), `metadata` (object). |
| `events_dropped` | integer | Events discarded after `:max_events`. |
| `failure` | object \| null | `kind`, `exception` (module name; for an exit, the module of a crashed process's exception, otherwise null), `message` (nullable; for throw/exit a structural description, never the inspected value), `plug_status`, `stacktrace[]` (`module`, `function` as `name/arity`, `file`, `line`, `application`), `captured_by`. |
| `tasks` | object \| null | Only when `wrap/1` was used: `status` (`complete`, `timeout`, `unavailable`, `collector_limit_reached`), `processes`, `events`. |
| `redaction` | object | `applied`, `placeholder`, `sensitive_keys`, `redacted_values`, `scrubbed_message_values`. |
| `limitations` | array of strings | What this report cannot show. |

Event names: `request.start`, `request.stop`,
`phoenix.endpoint.start`, `phoenix.endpoint.stop`,
`phoenix.router_dispatch.start`, `phoenix.router_dispatch.stop`,
`phoenix.router_dispatch.exception`, `phoenix.error_rendered`, `ecto.query`,
and from Phase 2 `task.start`, `task.stop`, `task.exception`.

## Resource bounds

* Per request: at most `:max_events` ordinary events (request and task
  events together), plus a handful of lifecycle events. State is held only
  for the life of the request.
* Task propagation: at most `:max_task_collectors` collectors, each bounded
  to `:max_events` events and terminated at request completion, owner exit,
  or `:task_collector_lifetime`.
* Globally: at most `:max_reports` reports in one GenServer. There are no
  ETS tables.
* Handlers do no I/O and make no blocking calls. A report is written with a
  `GenServer.cast/2`. The only wait is draining task events for a failed
  request, bounded by `:task_drain_timeout`.
* Measured overhead and the proposed budget are in
  [performance.md](performance.md). The full bounds review is in
  [phase2_review.md](phase2_review.md).

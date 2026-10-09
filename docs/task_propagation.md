# Task propagation

By default, TraceGuard only sees events emitted by the process that handles
the request (see [architecture.md](architecture.md#event-correlation)). Work
you move into a `Task` is invisible: its queries are not attributed to any
request, by design.

`TraceGuard.wrap/1` lets you opt specific work back in.

## API

```elixir
TraceGuard.wrap(fun) :: fun     # fun has arity 0 or 1
```

`wrap/1` is called in the request process. It returns a function that, when
run in **any** process, attaches that process's telemetry events to the
request's trace for exactly the duration of the call.

```elixir
# One task
Task.async(TraceGuard.wrap(fn -> Repo.all(Product) end)) |> Task.await()

# Several tasks
[fn -> list_products() end, fn -> Repo.aggregate(Order, :count) end]
|> Enum.map(&Task.async(TraceGuard.wrap(&1)))
|> Task.await_many()

# Arity 1: async_stream
Task.async_stream(ids, TraceGuard.wrap(fn id -> Repo.get(Product, id) end))

# Unlinked tasks: recommended when a task may crash
Task.Supervisor.async_nolink(MyApp.TaskSupervisor, TraceGuard.wrap(fn -> call_api() end))
|> Task.await()
```

Outside a traced request (or when TraceGuard is disabled), `wrap/1` returns
`fun` unchanged, so library code can call it unconditionally.

## What you get in the report

```json
{"seq": 4, "process": "task-1", "name": "task.start", ...},
{"seq": 6, "process": "task-1", "name": "ecto.query", "metadata": {"source": "products", ...}},
{"seq": 9, "process": "task-2", "name": "task.exception", "outcome": "error",
 "metadata": {"kind": "error", "exception": "MyApp.WarehouseError"}},
...
"tasks": {"status": "complete", "processes": 2, "events": 6}
```

* Every event has a `process` field: `"request"`, `"task-N"`, or (for
  traced GenServer calls, Phase 4) `"server-N"`, numbered per kind in order of
  each process's first event.
* Each wrapped call adds `task.start`, then `task.stop` (with duration,
  outcome `"ok"`) or `task.exception` (with `kind` and exception module only).
* Events from all processes are merged into one timeline, ordered by
  monotonic time (one clock per node). `seq` is the position in that merged
  timeline.
* `tasks.status` is `complete`, `timeout`, `unavailable` or
  `collector_limit_reached`. Anything other than `complete` also adds a
  `limitations` entry saying that task events are missing.

[docs/sample_task_report.json](sample_task_report.json) is a real report from
the demo's `POST /api/inventory/reconcile`.

## Context propagation boundaries

* **What is copied:** an opaque token holding the trace ID, the pid of the
  trace's task collector, and an `:atomics` counter reference. Nothing else:
  no request metadata, headers, body, cookies, credentials, Logger metadata
  (apart from `trace_guard_id`), or other process-dictionary entries. A test
  checks this.
* **What is collected from tasks:** the same allow-listed fields as in the
  request process. Task events go through the same handlers, the same
  sanitization and the same redaction.
* **Same trace ID:** wrapped work never starts a new trace.
* **Opt-in only:** a plain `Task.async(fn -> ... end)` inherits nothing, even
  while a traced request is running. There is no implicit propagation through
  `$callers` or the process dictionary.

## Semantics

| Situation | Behaviour |
| --- | --- |
| Wrapped function returns | Its return value is returned unchanged. |
| Wrapped function raises, throws or exits | A `task.exception` event is recorded, then it is re-raised with the **original kind, reason and stacktrace** (`:erlang.raise/3`). TraceGuard never rescues. |
| Linked task (`Task.async`) crashes | Normal Elixir semantics: the link kills the request process, so Phoenix renders no error and no report is produced. Use `Task.Supervisor.async_nolink/3` if a task may fail. |
| Unlinked task crashes and you `Task.await/2` it | The request process exits. Phoenix renders a 500 and TraceGuard reports it with `kind: "exit"` and the child's exception module and (scrubbed) message, for example `"Task.await/2 exited: process crashed: ..."`. As with all exits, the response has no `x-traceguard-id` header (Plug only wraps `:error` exceptions); find the report with `TraceGuard.list_reports/0`. |
| Nested `wrap/1` inside wrapped work | Reuses the same token: grandchildren report into the same trace. |
| Repeated `wrap/1` in one request | One collector per trace; every wrapped process gets its own `task-N` label. |
| Wrapped function called in the process that owns the trace | It simply runs; its events are ordinary request events. |
| Wrapped function called in a process serving a *different* request | Its events go to the trace it was wrapped for. The other request's context is set aside for the call and then restored. |
| Task still running when the request completes | Events it sent **before** completion are included. Events sent afterwards are dropped: the collector has stopped and messages to a dead process are discarded. The task itself is unaffected. |
| Request succeeds | The collector is discarded without waiting. No report is produced. |
| Request fails | The request process asks the collector for its events and waits at most `:task_drain_timeout` (default 100 ms). On timeout the report says so, and the collector is told to stop. |

Ordering: if the request process waited for a task (for example
`Task.await/2`) before responding, all of that task's events are included.
Each event is sent before the task replies, and the request asks the
collector only after receiving that reply. Erlang formally guarantees
ordering only between pairs of processes. This chain relies on the BEAM
delivering a local message by the time `send/2` returns, which is how
single-node delivery works today and what the tests exercise. Across nodes
it would not hold, and propagation is single-node anyway.

## Limits and memory

| Resource | Bound |
| --- | --- |
| Task events per trace | At most `:max_events` sent in total by **all** task processes of a trace, enforced by a shared `:atomics` counter before sending. Further events are counted in `events_dropped`. After merging, the trace's ordinary events (request + tasks) are again capped at `:max_events`. |
| Collectors | At most `:max_task_collectors` (default 1,000) at once, one per trace that called `wrap/1`. Beyond that, `wrap/1` returns the plain function and the report says `collector_limit_reached`. |
| Collector lifetime | It ends when the request completes, when the request process exits (it is monitored), or after `:task_collector_lifetime` (default 5 minutes), whichever comes first. |
| Task process state | A task holds the token only while the wrapped function runs; it is removed afterwards, including when the function fails. |
| Waiting | Tasks never wait for TraceGuard. The request process waits at most `:task_drain_timeout`, and only when the request failed. |

## Unsupported cross-process cases

These are not propagated in Phase 2. Their events are not attributed to any
request:

* Processes you don't explicitly wrap: `spawn`, `Task` without `wrap/1`, and
  library-internal processes. GenServers are covered only for calls made with
  `TraceGuard.call/3` to a server that uses `TraceGuard.Server` (Phase 4,
  see [genserver_propagation.md](genserver_propagation.md)).
* Work that outlives the request, such as background jobs or `Task.start`
  that runs after the response. Its events are dropped (see above).
* Other nodes. The token holds a local pid and an `:atomics` reference, which
  are meaningful only on the node that created them.
* LiveView, channels and Oban jobs.

## Cost

`wrap/1` is free for requests that never call it. For requests that do, the
first call starts one collector process. Each task event costs one message
plus the normal per-event cost. In the benchmark, 4 wrapped tasks added
6.3 KB of allocation in the request process; see
[performance.md](performance.md).

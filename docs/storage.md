# Report storage, overload and discovery

Phase 3 made the path from a failed request to a stored report explicit:
bounded at every step, observable when something is not kept, and pluggable.

```
request process                                   ReportStore (GenServer)
──────────────────────────────────────────────    ─────────────────────────────
build + redact report
TraceGuard.Storage.put/1 ──► ReportStore.put/2
   admission: atomics +1 ≤ max_pending_reports?
     yes ─ send ───────────────────────────────►  mailbox (≤ max_pending_reports puts)
           {:ok, :queued}                         take: atomics −1; insert; evict
     no  ─ {:error, :overloaded}                  ≤ max_reports, oldest first
           + [:trace_guard, :report, :dropped]    + [:trace_guard, :report, :stored]
```

## Overload policy (default `TraceGuard.ReportStore`)

| Bound | Default | Mechanism |
| --- | --: | --- |
| Retained reports | `max_reports: 50` | Oldest evicted first; counted in `:evicted`. |
| Queued submissions (store mailbox) | `max_pending_reports: 50` | **Admission before sending.** Each store incarnation publishes `{pid, atomics counter}` once. A submitter increments the counter and only sends if the result is ≤ the limit. Otherwise it decrements, sends nothing and returns `{:error, :overloaded}`. The store decrements as it takes each submission. |
| Waiting in the request | none | `put` never waits: one atomic add, one `send/2`. No Task per report, no I/O, no call into the store. |
| Waiting in readers | `timeout` / `:call_timeout` (5 s) | `get_report/1`, `list_reports/1`, `report_stats/0` return `{:error, :unavailable}` / `[]` / `%{available: false}` instead of exiting. |

**What "bounded mailbox" means precisely.** The store's mailbox never holds
more than `max_pending_reports` report submissions. A test proves it: 200
concurrent submitters against a suspended store leave exactly
`max_pending_reports` messages queued, and 190 are refused. Reads are
synchronous calls, so they add at most one message per waiting caller.

**Policy under a burst: keep the earliest, refuse the rest.** While the queue
is full, new reports are refused rather than displacing queued ones. Once the
store catches up, retention keeps the newest `max_reports`.

**Memory.** The upper bound is (`max_reports` + `max_pending_reports`) ×
report size. Reports are bounded by `max_events`, `max_string_length` and
`max_stacktrace_frames`. Measured sizes, as Erlang terms:

* the demo's checkout report: about 15 KB, so about 1.5 MB at the defaults;
* a near-worst-case report (100 events with maximum-length SQL, 20 frames,
  maximum-length message): about 122 KB, so about 12 MB at the defaults.

## Knowing whether a report was kept

Every submission ends in exactly one observable outcome:

| Outcome | Request process sees | Event | Counter |
| --- | --- | --- | --- |
| Retained | `{:reported, id}` from `EventCollector.finish/1` | `[:trace_guard, :report, :stored]` (emitted by the store once inserted) | `:accepted`, then `:stored` |
| Refused: queue full | `{:dropped, id, :overloaded}` | `[:trace_guard, :report, :dropped]`, `reason: :overloaded` | `:dropped_overloaded` |
| Refused: no live store | `{:dropped, id, :unavailable}` | `:dropped`, `reason: :unavailable` | `:dropped_other` |
| Adapter raised, exited, or broke the contract | `{:dropped, id, {:adapter_failed, kind}}` / `{:invalid_adapter_result, term}` | `:dropped` | `:dropped_other` |
| Accepted, then lost in a store crash | `{:reported, id}` (it *was* accepted) | none (ID unknown after the crash) | `:lost` |
| Retained, later evicted | — | none | `:evicted` |

The accepted-then-lost case is the only one without a per-trace signal. It is
counted: after the crash, the new incarnation adds the old incarnation's
pending count to `:lost`. In other words, `{:reported, id}` means "accepted
for retention", never "durably stored".

From outside the request:

* `TraceGuard.await_report(trace_id, timeout)` subscribes to the two events
  *before* checking the store, then returns `{:ok, report}`,
  `{:error, {:dropped, reason}}` or `{:error, :timeout}`. It never polls,
  and never takes longer than `timeout`, even if the store is stalled.
* `TraceGuard.report_stats/0` returns `submitted`, `accepted`, `stored`,
  `dropped_overloaded`, `dropped_other` and `lost`, plus the adapter's
  `retained`, `pending`, `evicted`, `max_reports`, `max_pending_reports` and
  `available`.
* Attach to `[:trace_guard, :report, :stored | :dropped]` yourself. The
  metadata is `%{trace_id, summary}` or `%{trace_id, reason}`.

TraceGuard never logs per dropped report, so an overload doesn't flood your
logs. The counters and events are the signal.

## Finding a report without a response header

The `x-traceguard-id` header is missing when Phoenix renders the error with
the conn that entered the endpoint: throws, exits (including `Task.await/2`
on a crashed task), and exceptions raised in endpoint plugs. `x-request-id`
is missing from those responses too. In order of preference:

1. **The caller's correlation ID.** Configure
   `incoming_header: "x-correlation-id"` (validated: `[A-Za-z0-9._:-]`,
   1–128 characters), have clients send a unique value, then call
   `TraceGuard.list_reports(incoming_id: "...")`. This works for concurrent
   failures because the match is exact, and it never matches on time.
2. **The log line.** Bandit logs the re-raised failure from the request
   process *after* TraceGuard completed the trace, while TraceGuard's Logger
   metadata is still set. With `metadata: [:request_id, :trace_guard_id]` in
   your logger format, that line carries the trace ID (use `get_report/1` or
   `await_report/2`) and the request ID (use
   `list_reports(request_id: ...)`). This was verified with Bandit only.
   Cowboy logs crashes from a different process, where this metadata is not
   set; that is untested.
3. **Telemetry.** A handler on `[:trace_guard, :report, :stored]` receives
   each report's trace ID and summary as it is stored.
4. **Filters.** `list_reports(route: ..., kind: "exit", status: 500)`
   narrows the bounded recent list. Combine filters with an identifier;
   filters alone may match several concurrent failures.

`list_reports/1` filters are `trace_id`, `incoming_id`, `request_id`,
`route`, `method`, `status`, `outcome`, `kind` and `exception`. They are
exact matches, and unknown keys raise. Summaries contain only fields that are
already in the redacted report.

**Access boundary.** These are node-local Elixir functions. TraceGuard adds no
HTTP endpoint. The demo's `/dev/traces` route is compiled in only for dev and
test; don't route anything like it in production. Trace IDs are 128-bit
random values and carry no request data. Request IDs come from
`Plug.RequestId` (random). Correlation IDs are whatever your clients send:
treat them as untrusted labels, never as authorization.

## The `TraceGuard.Storage` behaviour

```elixir
config :trace_guard, storage: TraceGuard.ReportStore           # default
config :trace_guard, storage: {MyAdapter, max: 100}            # module or {module, opts}
```

| Callback | Contract |
| --- | --- |
| `child_spec(opts)` (optional) | If exported, TraceGuard supervises the adapter configured **at boot**. |
| `put(report, opts)` | Receives the final, **already redacted** report. Must not block for long and must not raise on overload. Returns `{:ok, :stored}` (retained now), `{:ok, :queued}` (accepted; the adapter then calls `TraceGuard.Storage.stored/1` or `dropped/2`), `{:error, :overloaded}` or `{:error, reason}`. Returning `{:ok, _}` for a refused report is a contract violation. |
| `get(trace_id, opts)` | `{:ok, report}`, `:error` or `{:error, :unavailable}`. Honors `opts[:timeout]`. Never exits. |
| `list(opts)` | Summaries (`TraceGuard.Storage.summary/1`), newest first, or `{:error, :unavailable}`. |
| `delete(trace_id, opts)`, `clear(opts)` | `:ok` or `{:error, :unavailable}`. |
| `stats(opts)` | A map that includes `:adapter`. |

Bounded retention, and a bounded queue if there is one, are part of the
contract. The facade (`TraceGuard.Storage`) wraps every call: an adapter that
raises or exits produces a `:dropped` outcome and never reaches the request.
It also keeps the counters and emits the events. Because the request's trace
context is removed before `put` runs, anything an adapter does, such as
running Ecto queries, cannot add events to any trace, and TraceGuard never
handles its own report events. So storage can't trigger recursive diagnostics.

Two adapters exist:

* `TraceGuard.ReportStore`, the default described above;
* `TraceGuard.TestStorage` (in `test/support`), a synchronous Agent-backed
  adapter that can also simulate overload, raising, exiting and contract
  violations. The shared contract suite (`test/support/storage_contract.ex`)
  runs against both.

Runtime changes to `:storage` (via `TraceGuard.Config.put!/1`) change where
reports go, but don't start or stop adapter processes.

## Restarts

`ReportStore` is supervised. A restart loses the retained reports and the
submissions queued in its mailbox; their number is added to `:lost`. While no
store is running, `put` returns `{:error, :unavailable}`. The new incarnation
publishes a fresh admission counter, so a crash can't leave stale counts
behind. Requests are never affected: their response and exception are the
same whatever happens to storage. Each restart rewrites one
`:persistent_term` entry, which triggers a global GC; restarts are expected
to be rare.

# Phase 4 review: GenServer propagation, persistence, drop records, compatibility

## Inspection (before any change)

The Phase 3 state was verified rather than assumed: commit `8d9e490`, a clean
working tree, 105 library tests + 1 doctest and 13 demo tests passing, and
formatting and warnings-as-errors compilation clean. The supervision tree
was `TraceGuard.Supervisor` → [storage adapter (`ReportStore`),
`TraceGuard.TaskCollectors` (DynamicSupervisor)].

Confirmed semantics:

* Admission: `max_pending_reports` via a per-incarnation `:atomics`
  counter, checked in the submitting process.
* Retention: `max_reports`, oldest evicted first.
* Lookup: `get_report/1`, filtered `list_reports/1`, and `await_report/2`
  subscribing to `:stored`/`:dropped` before checking.

Gaps relevant to Phase 4:

1. `await_report/2` timed out for a report dropped before the call, and
   `:lost` submissions were only a counter, without trace IDs.
2. Work done in GenServers was never correlated. Propagation existed only
   for wrapped functions.
3. Only an in-memory adapter existed.
4. Only one toolchain and dependency combination had ever been run.

## Plan (as executed)

1. Generalize the Task runner into one runner with a *kind* (`task` or
   `server`), so GenServer propagation reuses the token, collector and budget
   instead of adding a second mechanism.
2. Add `TraceGuard.call/3` (caller) and `use TraceGuard.Server` (server): an
   explicit integration. A plain `GenServer.call/3` carries no context that
   could be used without guessing.
3. Add `TraceGuard.DropLog`: bounded ETS records of drops and pending
   submissions, written directly by request and store processes (no
   mailbox).
4. Add `TraceGuard.Storage.SQLite` behind the existing contract: optional
   `exqlite` dependency, one writer behind the same bounded admission.
5. Add `scripts/compat_matrix.sh` and run it on every available toolchain.
6. Benchmarks for the new costs; then documentation.

## Decisions

* **Both sides opt in for GenServers.** Wrapping the message is the only way
  to give the server the caller's token without guessing.
  `TraceGuard.call/3` always sends the wrapped shape, even without a trace,
  so a server that forgot `use TraceGuard.Server` fails identically in every
  environment instead of only when tracing is on.
* **`use TraceGuard.Server` overrides `handle_call/3` via `defoverridable`
  and `super`.** Users' clauses are untouched. It is a compile-time error
  when the module has no `handle_call/3` of its own; detected from the
  clauses' `context: GenServer` metadata, because `Module.overridable?/2`
  stays true after a redefinition. It is compatible with and without `@impl`.
* **`throw` from a server callback counts as a return.** That's how
  `gen_server` treats it.
* **Drop records never infer.** Stale pending marks are deleted, not turned
  into drops. "Unknown" is a first-class answer.
* **Pending marks are written before calling the adapter**, so a fast store
  can't resolve a mark that doesn't exist yet.
* **SQLite through `exqlite` directly, not Ecto.** TraceGuard would otherwise
  need its own Ecto repo in the host application. `exqlite` is the driver
  `ecto_sqlite3` already uses (present in the demo). It is optional, so
  applications that don't use the adapter get no new dependency.
* **One SQLite writer, one transaction per report.** It is simple and
  correct; its throughput (about 0.4 ms per report here) is the limit, and
  admission makes the limit safe.

## Bounds after Phase 4

| State | Bound | Verified by |
| --- | --- | --- |
| GenServer-side events | shared per-trace budget (`max_events`) | `server_test` "respects the shared task budget" |
| Trace context in a server | only during one traced `handle_call/3`; removed or restored in `after` | `server_test` (process dictionary inspected) |
| Drop records | ≤ `max_drop_records`, TTL `drop_record_ttl` | `drop_log_test` (count bound; 2,000 concurrent writers; TTL; sweep) |
| Pending marks | ≤ `max_drop_records`, TTL; resolved on stored/dropped; `:lost` on restart | `drop_log_test`, `sqlite_storage_test` |
| SQLite writer mailbox | ≤ `max_pending_reports`, including during a locked-database outage | `sqlite_storage_test` (200 concurrent submitters, database locked); benchmark (max observed 50 of 50) |
| SQLite rows | ≤ `:max_reports` per insert transaction; `:max_age` by cleanup | `sqlite_storage_test` |
| Request-path I/O | none (SQLite I/O only in the writer) | code; outage test (requests unaffected) |

## Failure semantics added

| Case | Behaviour | Test |
| --- | --- | --- |
| Traced callback raises | `genserver.call.exception` recorded, re-raised; server crashes; caller exits as usual | `server_test` |
| Traced call times out | caller exits as usual; late server events dropped; server keeps serving | `server_test` |
| Server restarts | traced calls work against the new process | `server_test` |
| Server without `use TraceGuard.Server` | `FunctionClauseError` in its `handle_call/3`, the same with or without a trace | `server_test` |
| Token unusable here (another node, or an invalid budget) | callback runs untraced; never raises in the server | `server_test` |
| SQLite locked / unopenable / newer schema | admitted reports dropped with an explicit reason; reads return `:unavailable`; requests unaffected; file untouched for a newer schema | `sqlite_storage_test` |
| SQLite writer dies with queued reports | each becomes `{:dropped, :lost}` | `sqlite_storage_test`, `drop_log_test` (ReportStore) |
| Corrupt row | `{:error, :corrupt}`; skipped in lists; counted | `sqlite_storage_test` |

## Security review

* **What propagates into a server:** only the token (trace ID, collector pid,
  atomics reference). Requests' arguments aren't recorded; only the leading
  atom (`operation`) and the server module are. A test sends
  `"password=hunter2"` as a call argument and checks that the report doesn't
  contain it.
* **Isolation:** each message carries its own token, and the server handles
  one message at a time. Background work runs without context (tested by
  interleaving casts, infos and plain calls).
* **Persistence:** only redacted reports reach SQLite (the facade has no
  other path). A test scans the raw database, WAL and shared-memory files
  after a real failing request with a bearer token, an API key and a
  password; none is present. The demo does the same for seven secrets.
* **Queries:** every SQLite statement binds its parameters. The only
  interpolated SQL is the integer schema version in `PRAGMA user_version`.
* **Drop records** contain a trace ID, a normalized reason, and two integers.
  Arbitrary terms (maps, structs, long strings) are reduced to `:other` or
  truncated (tested with a map containing a password).
* **Exit reasons:** a traced call that exits has the wrapped message (with
  the token) in its exit reason, as any `GenServer.call/3` exit contains its
  message. The token holds no request data, and TraceGuard's own report
  doesn't include the exit reason's arguments.
* **No new endpoints.** The lookup APIs (`report_status/1`, `await_report/2`)
  are node-local functions.
* **Unchanged:** TraceGuard does not sanitize the host application's logs.
  Phoenix and Bandit still log raw exception messages, and the pricing
  server's crash is logged by OTP with its message.

## Public interface changes

All additive except where noted:

* New: `TraceGuard.call/3`, `TraceGuard.Server` (`use TraceGuard.Server`),
  `TraceGuard.report_status/1`, `TraceGuard.DropLog`,
  `TraceGuard.Storage.SQLite`, `TraceGuard.Storage.lost_pending/1`.
* New config: `:max_drop_records` (1000), `:drop_record_ttl` (600000 ms).
* New optional dependency: `exqlite ~> 0.42`.
* New event names: `genserver.call.start | stop | exception`. New process
  labels: `server-N`.
* **Behaviour change:** `await_report/2` now returns
  `{:error, {:dropped, reason}}` for a drop recorded *before* the call,
  where Phase 3 returned `{:error, :timeout}`.
* **Behaviour change:** `get_report/1` can return `{:error, :corrupt}`
  (only the SQLite adapter produces it).
* Internal: `Propagation.send_event/4` (was `/3`); the collector message
  carries the process kind.

## Remaining limitations

* GenServer propagation covers `call` only: not `cast`, `send`,
  `:gen_statem` or `:gen_event`, and not deferred replies. Nothing is
  implicit.
* The collector start (about 100 µs per propagating request here) is the
  largest propagation cost; it isn't optimized.
* SQLite is a local development and testing adapter: one writer, one file,
  one node, no encryption at rest. It is not a production storage
  recommendation.
* Drop records live in memory and are lost if `DropLog` restarts.
* Cowboy, PostgreSQL, other Ecto versions, other operating systems,
  releases and multi-node setups are untested (see
  [compatibility.md](compatibility.md)).

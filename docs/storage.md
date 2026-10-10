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

## Which storage?

| | In memory (default) | SQLite | Ecto / PostgreSQL |
| --- | --- | --- | --- |
| Module | `TraceGuard.ReportStore` | `TraceGuard.Storage.SQLite` | `TraceGuard.Storage.Ecto` |
| Survives restarts | no | yes | yes |
| Extra dependency | none | `exqlite ~> 0.42` | your app's `ecto_sql ~> 3.10` + `postgrex` |
| Database | none | its own file | **your app's existing database and Repo** |
| Intended for | development, production debugging with no persistence | local development and testing | apps that already use PostgreSQL through Ecto |
| Status | stable | experimental | experimental (Phase 6) |

All three sit behind the same bounded admission queue, the same explicit
drop outcomes and the same `report_status/1` semantics. Reports reach every
adapter already redacted.

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
| Accepted, then lost in a store crash | `{:reported, id}` (it *was* accepted) | none (the process that would emit it is gone) | `:lost`; and since Phase 4 a per-trace drop record with reason `:lost` |
| Retained, later evicted | — | none | `:evicted` |

In other words, `{:reported, id}` means "accepted for retention", never
"durably stored". Since Phase 4, the accepted-then-lost case also has a
per-trace record: every queued submission is marked pending in
`TraceGuard.DropLog`, and a restarted store turns its leftover pending marks
into `{:dropped, :lost}` records (see below).

From outside the request:

* `TraceGuard.report_status(trace_id)` (Phase 4) returns `:stored`,
  `{:dropped, reason}`, `:pending` or `:unknown`. See
  [Drop records](#drop-records-phase-4).
* `TraceGuard.await_report(trace_id, timeout)` subscribes to the two events
  *before* checking the store, then returns `{:ok, report}`,
  `{:error, {:dropped, reason}}` (including drops recorded **before** the
  call, since Phase 4) or `{:error, :timeout}`. It never polls, and never
  takes longer than `timeout`, even if the store is stalled.
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

## Drop records (Phase 4)

`TraceGuard.DropLog` keeps a bounded record of recent outcomes that are
*not* "stored", so a lookup can tell them apart:

| `report_status/1` | Meaning | Source |
| --- | --- | --- |
| `:stored` | The adapter has the report now. | the adapter |
| `{:dropped, reason}` | A retained record says it was not kept: `:overloaded`, `:unavailable`, `:lost` (died in a store restart), `{:adapter_failed, kind}`, `{:sqlite_error, message}`, ... | drop record |
| `:pending` | Accepted by a queueing adapter; no outcome observed yet. | pending mark |
| `:unknown` | None of the above: the request didn't fail or hasn't finished, the report was evicted, or its record expired or was evicted. | — |

Rules:

* **Explicit only.** A drop is reported only from a record written at the
  moment of the drop. It is never inferred from a missing report or from
  timing. Stale pending marks are deleted, never turned into drops.
* **Bounded.** At most `:max_drop_records` (default 1000) records, oldest
  evicted first. Each expires after `:drop_record_ttl` (default 10 minutes,
  monotonic clock). Pending marks share the count bound and the TTL.
* **Expired means unknown.** Once a record expires or is evicted, the trace
  reads as `:unknown`, which is never evidence that the report was or wasn't
  dropped.
* **No sensitive data.** A record is `{trace_id, reason, time, seq}`.
  Reasons are normalized to atoms, integers, strings up to 100 characters,
  and tuples of up to three of those; anything else becomes `:other`.
* **No mailbox.** Writers insert into public ETS tables owned by
  `TraceGuard.DropLog`. Concurrent writers can briefly leave the count
  slightly *below* the bound, never above it.
* **Restarts.** If `DropLog` itself restarts, its records are gone, and
  traces read as `:unknown`.

## The Ecto/PostgreSQL adapter (Phase 6, experimental)

`TraceGuard.Storage.Ecto` stores reports in a table in **your application's
PostgreSQL database, through your application's Ecto Repo**. TraceGuard
creates no Repo, no connection pool and no database of its own (the external
PostgreSQL test checks both: `Ecto.Repo.all_running()` is just the app's
Repo, and no database other than the app's exists).

### Install

Your application already has `ecto_sql` and `postgrex`. TraceGuard declares
`ecto_sql ~> 3.10` as an **optional** dependency, so applications without
Ecto pull in nothing. The adapter module is compiled only when Ecto SQL is
present. If you add Ecto to a project that already compiled TraceGuard, run
`mix deps.compile trace_guard --force`.

### Configure

```elixir
# config/config.exs
config :trace_guard,
  storage: {TraceGuard.Storage.Ecto, repo: MyApp.Repo, max_age: :timer.hours(24 * 7)}
```

| Option | Default | Meaning |
| --- | --- | --- |
| `:repo` | required | Your `Ecto.Repo`. It must use `Ecto.Adapters.Postgres`; anything else is refused at start. |
| `:prefix` | Repo default | PostgreSQL schema of the table (same as the migration's `:prefix`). |
| `:max_reports` | the `:max_reports` config | Rows kept; the oldest are deleted in each insert's transaction. |
| `:max_age` | none | Rows older than this (ms, database clock) are deleted by cleanup. |
| `:cleanup_interval` | 60000 | Periodic cleanup (ms). `TraceGuard.Storage.Ecto.cleanup/1` runs it on demand. |
| `:write_timeout` | 5000 | Per-statement timeout for the writer (ms). |
| `:call_timeout` | 5000 | Default read timeout (ms). |

Unknown or invalid options raise `ArgumentError` at start.

### Migrate (your migration, your workflow)

TraceGuard never creates or alters tables by itself, and never migrates at
startup.

```bash
mix trace_guard.gen.ecto_migration          # writes priv/repo/migrations/<ts>_add_trace_guard_reports.exs
mix ecto.migrate
```

The generator resolves things the way `mix ecto.gen.migration` does: the
Repo from `--repo` (or `-r`) or your `:ecto_repos` (it refuses to guess
when several are listed, and refuses non-PostgreSQL repos), the directory
from that Repo's `:priv` setting, and the module name
`<Repo>.Migrations.AddTraceGuardReports`. The file is already formatted,
identical on every run apart from its timestamp, and generated only once
(a second run refuses). The clean-install test
(`scripts/external_postgres_smoke.sh`) checks all of this in a fresh
Phoenix application.

The generated migration calls `TraceGuard.Storage.Ecto.Migration.up(version: 1)`
and `down(version: 1)`. The version is pinned, so a later TraceGuard release
can't change what an already-run migration does. A future schema change
would ship as `version: 2`, which you add in a new migration of your own.

* **Ordering:** run the migration before (or in the same deploy as) enabling
  the adapter. If the adapter runs before the table exists, writes are
  dropped with `{:ecto_error, :undefined_table}`, reads return
  `{:error, :unavailable}`, and requests are unaffected.
* **Rollback:** `down` drops the table and every stored report. Switch
  TraceGuard to another adapter first.
* **Ownership:** the table belongs to your database and your migration
  history. Its definition is in `TraceGuard.Storage.Ecto.Migration`:
  * the `jsonb` redacted report and summary;
  * plain columns for the `list_reports/1` filters (`trace_id` unique,
    `incoming_id`, `request_id`, `(route, status)` indexed);
  * `inserted_at`, indexed, for age retention.

### How it uses your Repo

* **Request path:** admission (one `:atomics` add against
  `:max_pending_reports`) and a `send/2` to the writer. No database work.
* **Writer:** one process, started by TraceGuard at boot. It never queries
  in `init`, so it starts fine before your Repo or while the database is
  down. It uses at most one pool connection at a time. Each report is one
  transaction: upsert by `trace_id`, then delete rows beyond `:max_reports`.
  It is announced as stored after the commit.
* **Reads** (`get_report/1`, `list_reports/1`, `report_status/1`, ...) run
  in the caller through your pool. `list_reports/1` filters are pushed into
  SQL (the optional `list_matching/2` callback) and use the indexes.
* **Quiet:** every statement passes `log: false` and `telemetry_event: nil`.
  TraceGuard's own queries don't appear in your Ecto logs or telemetry, and
  are never traced.
* **Tests with the SQL sandbox:** use shared mode (or allow the writer,
  `Process.whereis(TraceGuard.Storage.Ecto)`), as for any process that
  queries.

### Failures and recovery

| Situation | Outcome |
| --- | --- |
| Writer queue full | `{:error, :overloaded}` at admission; `report_status/1` → `{:dropped, :overloaded}` |
| Repo not started yet | dropped `{:ecto_error, :repo_not_started}`; succeeds once the Repo is up (tested) |
| Database unreachable, or connections refused | dropped `{:ecto_error, :connection}` (or the PostgreSQL code, for example `:admin_shutdown`); the writer keeps running; writes succeed again when the pool reconnects (tested with `ALLOW_CONNECTIONS false` and terminated backends) |
| Table missing (migration not run) | dropped `{:ecto_error, :undefined_table}` |
| Statement timeout | dropped `{:ecto_error, :timeout}`, or `:query_canceled` when PostgreSQL cancels it |
| Table locked (for example by a migration) | the writer waits up to `:write_timeout` per report; queued reports are stored once the lock is released (observed: 49 of 51 after a 12 s lock, 2 cancelled) |
| Corrupt or incompatible row | `get_report/1` → `{:error, :corrupt}`; `list_reports/1` skips it |
| Writer killed with queued reports | queued reports become `{:dropped, :lost}`; committed ones remain |

There are no automatic retries: a report that fails is dropped with its
reason, counted (`report_stats/0`: `write_errors`, `last_error`) and recorded
for `report_status/1`.

**During an outage, the writer is slow, not stuck.** Each failed write
waits for your Repo's pool to give up on a connection (about 4 s per write
with default pool settings, measured on PostgreSQL 18). So the writer
drains only a few reports per second, the queue fills, and most reports
in an outage are refused at admission as `:overloaded`. They would have
failed anyway, but the reason you see is the queue, not the database. See
"Overload or outage?" below. Writes succeed again within about a second
of the database coming back. The writer logs one warning when writes start failing
and one notice when they recover, with the error code only, never report
content. PostgreSQL error *messages* are never kept, because they can quote
row values.

### Overload or outage?

`report_stats/0` tells the two apart:

| Signal | Load beyond the writer | Database problem |
| --- | --- | --- |
| `dropped_overloaded` | rising | rising (the queue fills behind slow failures) |
| `write_errors` | flat | rising |
| `last_error` | `nil` (or old) | a code: `:connection`, `:admin_shutdown`, `:query_canceled`, ... |
| `available` | `true` | `false` while reads fail |
| `writer_busy` | usually `false` | often `true` (the writer is inside a slow statement) |
| Log | nothing | one warning, `TraceGuard Ecto storage: writes failing (<code>)`, and one notice on recovery |

`[:trace_guard, :report, :dropped]` events carry the same distinction per
report: `reason: :overloaded` or `reason: {:ecto_error, code}`.

`writer_running: true, writer_busy: true` means the writer is alive but
didn't answer within a second (it's waiting on the database). `pending` is
then read from the admission counter. `writer_running: false` means it
isn't running at all.

### Shutdown

The writer doesn't trap exits, so it stops immediately when your
application shuts down, even inside a statement. PostgreSQL rolls back an
interrupted transaction. Reports still queued (at most
`:max_pending_reports`) are lost. If only the writer restarts, they're
recorded as `{:dropped, :lost}`; when the whole application stops, there's
no record left. Shutdown time doesn't depend on the database (observed:
immediate, with the writer blocked on a locked table and 51 queued
reports).

### Troubleshooting

* **`report_stats()` shows `available: false`:** the Repo isn't running, the
  database is unreachable, or the table is missing. Check
  `report_stats().last_error`.
* **`last_error: :undefined_table`:** run the migration, or check that
  `:prefix` matches the migration's.
* **Reports missing in tests:** the SQL sandbox is in manual mode, and the
  writer has no connection. Use shared mode.
* **Pool pressure:** the writer holds one connection per write. A burst of
  failures is limited by `:max_pending_reports`, not by pool size.

### Deleted data in PostgreSQL

Retention, `delete_report/1` and `clear_reports/0` are ordinary `DELETE`s.
PostgreSQL keeps old row versions until `VACUUM` reclaims the space.
Deleted data can also persist in WAL segments, streaming replicas, base
backups and point-in-time-recovery archives, for as long as those are kept.
**TraceGuard can't erase it from any of those.** Use your database's own
retention and backup policies. The stored reports are redacted, but they
still describe your application's failures.

## The SQLite adapter (persistent, Phase 4)

`TraceGuard.Storage.SQLite` keeps reports in a SQLite file, so they survive
application restarts. It is meant for local development and testing, and
needs the optional dependency `{:exqlite, "~> 0.42"}`. That is the same
driver `ecto_sqlite3` uses, but no Ecto repo is needed.

```elixir
# mix.exs
{:exqlite, "~> 0.42"}

# config/dev.exs
config :trace_guard,
  storage: {TraceGuard.Storage.SQLite, database: "priv/trace_guard_reports.db", max_age: 86_400_000}
```

If `exqlite` is added to a project that already compiled TraceGuard, run
`mix deps.compile trace_guard --force`: the adapter module is compiled only
when exqlite is present.

**Setup and migrations.** None to run. On start, the adapter creates the
file and its single table if needed, and records schema version 1 in
`PRAGMA user_version`. A database with a newer version is left untouched,
and the adapter reports itself unavailable. The table definition is in the
`TraceGuard.Storage.SQLite` moduledoc.

| Option | Default | Meaning |
| --- | --- | --- |
| `:database` | required | File path. |
| `:max_reports` | the `:max_reports` config | Rows kept; the oldest are deleted in the same transaction as each insert. |
| `:max_age` | none | Rows older than this (ms, wall clock) are deleted by cleanup. |
| `:cleanup_interval` | 60000 | Periodic cleanup (ms). `TraceGuard.Storage.SQLite.cleanup/0` runs it on demand. |
| `:busy_timeout` | 1000 | How long a write waits for a SQLite lock (ms). |
| `:call_timeout` | 5000 | Default read timeout (ms). |
| `:file_mode` | `0o600` | Permissions of a database file the adapter creates (Phase 5). SQLite gives `-wal`/`-shm` the same mode. Existing files keep theirs. |

Unknown or invalid options raise `ArgumentError` when the adapter starts
(Phase 5).

**Deleted data (Phase 5).** `PRAGMA secure_delete = ON` zeroes deleted
content, and each delete, clear and cleanup ends with
`PRAGMA wal_checkpoint(TRUNCATE)`. A test reads the raw database and WAL
files after each operation and finds no trace of the removed reports. Before
Phase 5, deleted reports stayed readable in the files.

**Write path.** Admission happens in the request process, exactly as for
`ReportStore`: one `:atomics` add against `:max_pending_reports`, then
`send/2` to the single writer, or an immediate `{:error, :overloaded}`.
**No database I/O happens in the request.** The writer encodes the report
as JSON, then runs `BEGIN IMMEDIATE`, upsert by `trace_id`, retention delete
and `COMMIT`. It announces `:stored` only after the commit. All statements
use bound parameters.

**Failures.** Any write error rolls back and becomes a `:dropped` event and
record with `{:sqlite_error, message}` (or `:serialization_error`). If the
database can't be opened, the writer keeps running without a connection:
admitted reports are dropped with `{:sqlite, :unavailable}`, reads return
`{:error, :unavailable}`, and it retries opening every second. Requests are
never affected (tested with an unopenable path and with a database locked by
another connection). During a lock, the writer's mailbox stays at most
`:max_pending_reports`: 50 in the benchmark, with 433 of 500 reports refused
at admission.

**Recovery.** Committed reports are read back after a restart. A writer
restart is covered by automated tests, in the library and in the demo with a
real failing request. A full application restart (stopping and starting the
demo server with `TRACE_GUARD_STORAGE=sqlite`) was verified by hand. Reports admitted but not yet committed when the
writer dies become `{:dropped, :lost}`. A row that fails to decode makes
`get_report/1` return `{:error, :corrupt}`; `list_reports/1` skips it, and
`stats` counts it in `:corrupt_reads`. WAL mode with `synchronous = NORMAL`
means a power loss can lose the latest commits but doesn't corrupt the file.

**Throughput.** One writer and one transaction per report: about 0.4 ms per
report in the benchmark. A burst faster than that fills the queue, and
further reports are refused (193 of 500 in a burst from 8 concurrent
failing requests). Raise `:max_pending_reports` to absorb longer bursts, at
the cost of memory.

**Privacy.** The file contains only the redacted report and its summary. A
test reads every byte of the database, WAL and shared-memory files after a
real failing request carrying a bearer token, an API key and a password, and
finds none of them. Treat the file like any diagnostic artefact: it describes
your application's internals.

## The `TraceGuard.Storage` behaviour

```elixir
config :trace_guard, storage: TraceGuard.ReportStore           # default
config :trace_guard, storage: {MyAdapter, max: 100}            # module or {module, opts}
```

| Callback | Contract |
| --- | --- |
| `child_spec(opts)` (optional) | If exported, TraceGuard supervises the adapter configured **at boot**. |
| `put(report, opts)` | Receives the final, **already redacted** report. Must not block for long and must not raise on overload. Returns `{:ok, :stored}` (retained now), `{:ok, :queued}` (accepted; the adapter then calls `TraceGuard.Storage.stored/1` or `dropped/2`), `{:error, :overloaded}` or `{:error, reason}`. Returning `{:ok, _}` for a refused report is a contract violation. |
| `get(trace_id, opts)` | `{:ok, report}`, `:error`, `{:error, :unavailable}` or (Phase 4) `{:error, :corrupt}`. Honors `opts[:timeout]`. Never exits. |
| `list_matching(criteria, opts)` (optional, Phase 6) | Summaries matching every `{field, value}` exactly, newest first. |
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

Four adapters exist:

* `TraceGuard.ReportStore`, the default described above;
* `TraceGuard.Storage.SQLite`, persistent (Phase 4, optional dependency);
* `TraceGuard.Storage.Ecto`, your PostgreSQL through your Repo (Phase 6,
  optional dependency);
* `TraceGuard.TestStorage` (in `test/support`), a synchronous Agent-backed
  adapter that can also simulate overload, raising, exiting and contract
  violations. The shared contract suite (`test/support/storage_contract.ex`)
  runs against all four, the Ecto adapter against a real PostgreSQL.

**Optional callback (Phase 6):** `list_matching/2` lets an adapter apply
`list_reports/1` filters itself (in SQL, for example). The facade re-applies
the exact-match criteria to whatever it returns, so an adapter can only
narrow results, never widen them. Adapters without it keep the old behaviour
(`list/1`, then filter).

A queueing adapter should call `TraceGuard.Storage.lost_pending/1` with its
module when it (re)starts, so that submissions which died with its previous
incarnation become per-trace `:lost` records.

Runtime changes to `:storage` (via `TraceGuard.Config.put!/1`) change where
reports go, but don't start or stop adapter processes.

## Restarts

`ReportStore` is supervised. A restart loses the retained reports and the
submissions queued in its mailbox. Their number is added to `:lost`, and
(Phase 4) each becomes a `{:dropped, :lost}` record by trace ID. The SQLite
adapter keeps its committed reports across restarts (see above). While no
store is running, `put` returns `{:error, :unavailable}`. The new incarnation
publishes a fresh admission counter, so a crash can't leave stale counts
behind. Requests are never affected: their response and exception are the
same whatever happens to storage. Each restart rewrites one
`:persistent_term` entry, which triggers a global GC; restarts are expected
to be rare.

# Phase 6 review: Ecto/PostgreSQL storage adapter

## Starting point (verified)

* **Branch:** `phase4`, tracking `origin/phase4`. Phase 5 *was* committed
  (`b136d36`, "Add changelog, docs for storagem phase5 and release"), not
  uncommitted as the brief assumed.
* **Working tree:** clean, with no uncommitted work to protect.
* **`origin/main`:** still at the Phase 3 commit (`8d9e490`).
* **Baseline:** 148 tests + 1 doctest; demo 16 tests.
* **Nothing** was committed, tagged, pushed or published in this phase.

## Architecture and API decisions

* **`TraceGuard.Storage.Ecto`** is optional: it compiles only when
  `ecto_sql` is present, and `ecto_sql ~> 3.10` is declared
  `optional: true`. It takes the application's Repo
  (`storage: {TraceGuard.Storage.Ecto, repo: MyApp.Repo}`) and uses that
  Repo's pool. It never starts a Repo, a pool or a database, and it refuses
  non-PostgreSQL repos at start.
* **The same writer design as SQLite.** Admission happens in the request
  process (`:atomics`, `max_pending_reports`, then `send/2`). One writer
  process does the database work, one transaction per report (upsert by
  `trace_id`, then count retention), and announces `:stored` after the
  commit. Queued reports lost in a writer crash become `{:dropped, :lost}`.
* **The writer never queries in `init`.** TraceGuard boots before the host
  app's Repo, so the adapter must start without the database, and it does.
  Writes before the Repo is up are dropped with
  `{:ecto_error, :repo_not_started}` and succeed once it is up.
* **Reads run in the caller through the pool**, not through the writer, so
  lookups aren't queued behind writes.
* **Quiet by construction:** `log: false, telemetry_event: nil` on every
  statement. Report JSON never reaches the application's Ecto logs or
  telemetry, and TraceGuard never traces its own storage queries. There's a
  test for this.
* **Errors become codes:** PostgreSQL error codes (`:undefined_table`, ...)
  or `:connection`, `:repo_not_started`, `:timeout`, `:serialization`. Server
  messages can quote values, so they are never stored or logged.
* **Migrations are owned by the application:**
  * `TraceGuard.Storage.Ecto.Migration.up/down(version: 1, prefix: ...)` is
    called from the app's own migration;
  * `mix trace_guard.gen.ecto_migration` writes that migration, with the
    version pinned;
  * nothing is created or migrated automatically.
* **Minimal contract change:** an optional callback, `list_matching/2`,
  lets adapters filter `list_reports/1` in their store (SQL, using the
  indexes). The facade re-applies the exact-match criteria, so an adapter
  can narrow results but never widen them. Existing adapters are unchanged.
* **Stability:** **experimental**, labelled in the module docs and grouped as
  experimental in ExDoc. It passed the real PostgreSQL suite, but has one
  database version, one machine, and no production use.

## Defects found during this phase

1. **`await_report/2` raised `CaseClauseError` on a corrupt stored report**
   (`{:error, :corrupt}` wasn't handled after a `:stored` event). This has
   affected the SQLite adapter since Phase 4. Fixed: it returns
   `{:error, :corrupt}`, immediately when the report is already present.
   There is a regression test in the SQLite suite, and the Ecto contract
   suite exercises the path.
2. **(In the new code, before release)** Schemaless `insert_all` can't use
   `:replace_all_except`; the first PostgreSQL run caught it. It now uses an
   explicit replace list.

## PostgreSQL integration evidence

There was no system PostgreSQL, no Docker and no `sudo`.
`scripts/local_postgres.sh` downloads Ubuntu's own signed PostgreSQL 16
packages with `apt-get download` (no installation), extracts them under a
scratch directory, and runs the server as the current user on
`127.0.0.1:54329` with trust authentication. Nothing system-wide was
installed or changed.

**Library suite** (`TRACE_GUARD_POSTGRES_URL` set): 21 PostgreSQL tests
plus the shared contract suite, all against PostgreSQL 16.15. Each run
creates and drops a throwaway `trace_guard_test` database.

| Brief item | Covered by |
| --- | --- |
| 1. Save and retrieve a redacted report | `EctoTest` "a real failure is stored redacted", contract suite |
| 2. Persistence across a full application restart | `EctoTest` (TraceGuard's application stopped and restarted, adapter configured at boot); external two-VM check |
| 3. Lookup by trace ID and filters | `EctoTest` "lookup by trace ID and by every supported filter" (SQL path equals the generic path) |
| 4. `await_report/2` and `report_status/1` | `EctoTest`, contract suite |
| 5. Queue overflow and drop outcomes | `EctoTest` (100 submitters, suspended writer: mailbox exactly 10, 90 refusals recorded) |
| 6. Database unavailable at startup and during operation | `EctoTest` (Repo not started; `ALLOW_CONNECTIONS false` plus `pg_terminate_backend`) |
| 7. Recovery after temporary failure | same tests: writes succeed after the Repo starts or connections are allowed again |
| 8. Retention by count and age | `EctoTest` "retention by count and by age" |
| 9. Clearing without affecting unrelated tables | same test (`app_orders` row count unchanged) |
| 10. Corrupt or incompatible data | `EctoTest` (non-map report, foreign schema version, broken summary; missing table) |
| 11. Concurrent writes and reads | `EctoTest` (100 concurrent submit/await/get/list) |
| 12. Redaction before persistence, raw scan | `EctoTest` (every column of every row as text; 6 planted secrets absent) |
| 13. Writer restart and shutdown | `EctoTest` (killed with queued reports → `:lost`; committed reports survive) |
| 14. Storage contract suite | `EctoContractTest` (shared with memory, SQLite and the test adapter) |
| (extra) Migration up/down with a schema prefix | `EctoTest` |
| (extra) Invalid options and non-PostgreSQL repos | `EctoTest` |

**Compatibility matrix with PostgreSQL enabled:** all four rows pass, 171
tests + 1 doctest, including `ecto_sql` 3.10.2 / `postgrex` 0.17.5 on
Elixir 1.15.8 / OTP 26, `ecto_sql` 3.12.1 on OTP 27, and `ecto_sql` 3.14.0
on OTP 26 and 29. See [compatibility.md](compatibility.md).

**External application** (`scripts/external_postgres_smoke.sh`):
* a fresh Phoenix app on PostgreSQL with its own Repo;
* TraceGuard's migration generated and run through the app's `ecto.migrate`;
* the app's own suite: 5/5;
* two-VM restart: the report written in VM 1 was read in VM 2;
* `Ecto.Repo.all_running() == [AcmePg.Repo]`;
* no database other than the app's.

## Performance observations

From [performance.md](performance.md#phase-6-ecto-postgresql-adapter-costs):
* the request side costs about 3–4 µs;
* a commit takes about 5.5 ms median, so roughly 180 reports per second from
  the single writer on this WSL2 laptop; bursts beyond the queue are refused
  and recorded;
* indexed reads take about 0.5 ms.

No production claim is made.

## Security review

* Only the redacted report and its summary are written (plus filter columns
  copied from the summary). This is verified by a raw scan of every row
  after a request carrying a bearer token, an API key and a password, in the
  library suite and in the external app.
* All queries are built with `Ecto.Query`, with values bound as parameters.
  The schema prefix and table name are fixed or validated strings, and the
  column atoms come from a fixed map; no atoms are created from input.
* No raw reports, server error messages or credentials are logged. The
  writer logs only state transitions with an error code.
  `show_sensitive_data_on_connection_error` is untouched (the application's
  setting).
* Deletion is logical, and PostgreSQL's MVCC, WAL, replicas and backups can
  retain deleted data. This is documented, with no erasure claim.
* Retention and `clear_reports/0` touch only `trace_guard_reports` (tested
  against an unrelated table).
* Unchanged from before: TraceGuard doesn't sanitize application logs.

## Verification (final code)

| Check | Result |
| --- | --- |
| `mix format --check-formatted` (library, demo, demo bench, library bench) | ✅ |
| `mix compile --warnings-as-errors` (library dev and test; demo dev and bench) | ✅ |
| `mix test` without PostgreSQL | ✅ 171 tests (21 PostgreSQL tests excluded) + 1 doctest, 0 failures |
| `mix test` with PostgreSQL 16.15, run twice | ✅ 171 tests + 1 doctest, 0 failures |
| `mix test` (demo) | ✅ 16 tests, 0 failures |
| `scripts/compat_matrix.sh` with PostgreSQL (4 rows) | ✅ every row 171 tests + 1 doctest |
| `scripts/external_smoke.sh`: OTP 26 Bandit × {memory, SQLite}; OTP 27 {Bandit, Cowboy} × {memory, SQLite} | ✅ 6/6 each |
| `scripts/external_postgres_smoke.sh` | ✅ 5/5, two-VM restart, single Repo, no extra database |
| `MIX_ENV=dev mix docs --warnings-as-errors` | ✅ 0 warnings |
| `mix hex.build --unpack` (local) and secret scan | ✅ see the final report |

## Outstanding blockers and limitations

* **Single environment:** PostgreSQL 16 on one WSL2 laptop. Untested: other
  PostgreSQL versions, managed or TLS databases, PgBouncer in transaction
  mode, large tables, sustained load.
* **No CI** runs the PostgreSQL suite yet.
* **Writer throughput** of about 180 reports per second (here): bursts beyond
  the queue are dropped, by design.
* **`origin/main`** is still at Phase 3. The release tag `v0.1.0-rc.1`, which
  ExDoc's `source_ref` points to, doesn't exist yet.
* The adapter has had **no production use**; it stays experimental.

**Recommendation:** ready for an **external preview, marked experimental**,
for teams already on PostgreSQL who accept the limits above. It is not ready
to be called stable. Before that, it needs a CI run against at least one
other PostgreSQL major version and real-user feedback on the migration
workflow.

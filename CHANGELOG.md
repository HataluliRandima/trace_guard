# Changelog

All notable changes. TraceGuard follows [Semantic Versioning](https://semver.org/).
Before 1.0, minor versions may change the API; changes are listed here.

## 0.1.0-rc.2: experimental preview (GitHub pre-release)

Second release candidate, from the tag `v0.1.0-rc.2`. Still **not on
Hex**. Install it with
`{:trace_guard, github: "HataluliRandima/trace_guard", tag: "v0.1.0-rc.2"}`.
No API or configuration changes since rc.1.

* **Fixed:** timeline order when another telemetry handler runs before
  TraceGuard's. Error reporters such as ErrorTracker handle
  `[:phoenix, :router_dispatch, :exception]` too and query the database
  from it. Those queries were listed before the exception, and the
  exception's `offset_us` was late by the reporter's run time. The end of
  a span (endpoint and router dispatch stop and exception) is now
  timestamped at its start plus its `duration`. Found by trying the
  release candidate on an application that uses ErrorTracker.
* Announcement draft: `docs/announcements/v0.1.0-rc.2.md`.
* Development lock files: `decimal` 3.1.1 → 3.2.0 and `plug_crypto`
  2.2.0 → 2.2.1, for advisories EEF-CVE-2026-97853 and
  EEF-CVE-2026-105963 reported by `mix hex.audit`. Lock files aren't used by
  applications that depend on TraceGuard: check your own `mix.lock`.

## 0.1.0-rc.1: experimental preview (GitHub pre-release)

First release candidate, distributed as a GitHub pre-release from the tag
`v0.1.0-rc.1`. It is **not published to Hex**. Install it with
`{:trace_guard, github: "HataluliRandima/trace_guard", tag: "v0.1.0-rc.1"}`.

This is an early, experimental preview, not a stability guarantee.
`TraceGuard.Server`, `TraceGuard.Storage` and its adapters (SQLite and
Ecto/PostgreSQL), and the migration module and task are experimental and
may change before 1.0.

### Phase 8: release preparation

* Installation from the Git tag, documented and tested in fresh Phoenix
  apps (memory storage without Ecto, and the Ecto adapter with a generated
  migration). The clean-install scripts accept `TRACE_GUARD_DEP`.
* CI policy: required CI pins PostgreSQL to exact minor versions (16.15,
  18.6). The weekly Compatibility workflow keeps the floating major tags
  and now runs `mix hex.audit`, which was removed from required CI.
* README: a storage table (memory, SQLite, Ecto/PostgreSQL), dropped
  reports, and the status of this preview.
* A draft announcement: `docs/announcements/v0.1.0-rc.1.md`.
* **Fixed (test):** `DropLogTest` "concurrent writers never exceed the
  bound" asserted a lower bound (at least 45 of 50 records) that concurrent
  eviction doesn't guarantee. It failed about once in 200 bursts. It now
  asserts the upper bound and deterministic oldest-first recovery.
  DropLog's documentation states the possible dip precisely. This was the
  likely cause of the unexplained Phase 7 failure.

### Phase 7: CI and release readiness

* GitHub Actions: `ci.yml` runs on pull requests and on pushes to `main` and
  `phase*`. It covers formatting, warnings-as-errors builds, tests, ExDoc,
  the package check, the demo, real PostgreSQL 16 and 18, the minimum
  toolchain, and clean installs. `compat.yml` runs weekly and on demand,
  for the other toolchain rows and Bandit/Cowboy.
* **Fixed:** `report_stats/0` with the Ecto adapter reported a writer
  blocked in a slow statement as `writer_running: false`; it now reports
  `writer_running: true, writer_busy: true` and the queue length.
* `mix trace_guard.gen.ecto_migration` resolves the Repo and directory as
  `mix ecto.gen.migration` does (`--repo`/`-r` or `:ecto_repos`, the
  Repo's `:priv`). It refuses ambiguous or non-PostgreSQL repos, and is only
  compiled when Ecto is present.
* `scripts/compat_matrix.sh` now exits non-zero when a row fails, and checks
  that the running toolchain is the row's.
* New scripts: `scripts/package_check.sh` and `scripts/no_ecto_smoke.sh`.
  `scripts/external_postgres_smoke.sh` now follows the public install steps
  from the built package. It checks the generated migration (location,
  module, formatting, determinism, refusing a second copy), rollback, that
  nothing is created before migrating, and that unrelated tables are left
  untouched.
* `scripts/local_postgres.sh` supports other PostgreSQL majors
  (`PG_MAJOR=18`) from the PostgreSQL apt repository, with verified
  signatures.
* Documented: how to tell overload from a database outage, writer shutdown,
  and outage throughput (`bench/ecto_writer_operations.exs`).

### Phase 6: Ecto/PostgreSQL storage (experimental)

* `TraceGuard.Storage.Ecto`: stores reports in the application's own
  PostgreSQL database through its existing Ecto Repo (optional dependency
  `ecto_sql ~> 3.10`). One bounded writer, the same admission and drop
  semantics as the other adapters, no database work in the request.
* `TraceGuard.Storage.Ecto.Migration` (versioned `up`/`down`) and
  `mix trace_guard.gen.ecto_migration`. Nothing is migrated automatically.
* Optional storage callback `list_matching/2`: adapters may filter
  `list_reports/1` themselves; the facade re-checks the results.
* **Fixed:** `await_report/2` could raise `CaseClauseError` when a stored
  report was corrupt (SQLite since Phase 4); it now returns
  `{:error, :corrupt}`, immediately if the report is already present.
* Real PostgreSQL 16 test suite (`TRACE_GUARD_POSTGRES_URL`),
  `scripts/local_postgres.sh`, `scripts/external_postgres_smoke.sh`, and
  `ecto_sql` pins in the compatibility matrix.

### Phase 5: release preparation

* **Fixed (Cowboy):** reports for `throw` and `exit` failures (including a
  crashed `TraceGuard.call/3` or `Task.await/2`) could be lost under Cowboy.
  TraceGuard completed those traces at `[:phoenix, :error_rendered]`, which
  fires after the response is sent, and Cowboy terminates the request process
  once its response is complete. They are now completed at
  `[:phoenix, :router_dispatch, :exception]`, before rendering. Found by the
  external integration test (3 of 4 runs failed under Cowboy). Regression test
  added.
* **Fixed (SQLite adapter):** a newly created database file was world-readable
  (`0644`); it is now created `0600` (`:file_mode` option). Deleted, cleared
  and cleaned-up reports remained readable in the database and WAL files; the
  adapter now enables `secure_delete` and truncates the WAL after removals.
  Unknown or invalid adapter options are rejected at start instead of being
  ignored.
* Reports for throws and exits now end with `request.stop` instead of
  `phoenix.error_rendered`.
* Package metadata, ExDoc configuration, module stability labels (public,
  experimental, internal), `scripts/external_smoke.sh`, release checklist,
  security notes.

### Phase 4

* `TraceGuard.call/3` and `use TraceGuard.Server`: explicit trace propagation
  into selected `GenServer.call/3` operations.
* `TraceGuard.Storage.SQLite`: optional persistent adapter (`exqlite`).
* `TraceGuard.report_status/1` and a bounded drop record (`:max_drop_records`,
  `:drop_record_ttl`). Queued reports lost in a store restart are recorded as
  `{:dropped, :lost}` by trace ID.
* `await_report/2` returns `{:error, {:dropped, reason}}` for drops recorded
  before the call (previously `{:error, :timeout}`).
* `scripts/compat_matrix.sh`; verified on Elixir 1.15.8–1.20.1 / OTP 26–29
  (four combinations).

### Phase 3

* Bounded admission in front of the report store (`:max_pending_reports`);
  explicit storage outcomes; `[:trace_guard, :report, :stored | :dropped]`
  events; `report_stats/0`.
* `TraceGuard.Storage` behaviour; `list_reports/1` filters; `await_report/2`;
  `delete_report/1`. Reads return `{:error, :unavailable}` instead of exiting.

### Phase 2

* `TraceGuard.wrap/1`: explicit Task propagation.
* Measured optimizations of report building (about 75% less allocation).
* Exit and throw failures are described structurally instead of inspected.
* `TraceGuard.Telemetry.attach/0` is safe to call concurrently.

### Phase 1

* `TraceGuard.Plug`, Phoenix and Ecto telemetry capture, failure capture
  without rescuing, recursive redaction, in-memory report store, JSON export.

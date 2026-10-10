# Changelog

All notable changes. TraceGuard follows [Semantic Versioning](https://semver.org/).
Before 1.0, minor versions may change the API; changes are listed here.

## 0.1.0-rc.1 (unreleased release candidate)

First release candidate. Not published to Hex.

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

# TraceGuard.Storage.Ecto: writer under failure (Phase 7)

`bench/ecto_writer_operations.exs`, two runs, 2026-10-10. Elixir 1.17.0 /
OTP 26.1.2, PostgreSQL 18.6 (user-local, TCP on localhost), WSL2 laptop
with 12 logical CPUs. `max_pending_reports: 50`, default `write_timeout`
(5 s) and default Repo pool settings (`pool_size: 10`). Observations on one
machine, not guarantees.

| Scenario | Run 1 | Run 2 |
| --- | --- | --- |
| **Outage** (`ALLOW_CONNECTIONS false`, backends terminated), 200 reports in a burst | 61 admitted, 139 refused at admission (`:overloaded`) | same |
| Writer outcomes for the 61 admitted | 51 `{:ecto_error, :connection}`, 10 `{:ecto_error, :admin_shutdown}` | same |
| Time per failed write | median 4,000 ms, max 5,866 ms | median 4,000 ms, max 5,875 ms |
| Time to drain the 61 | 205.9 s | 205.9 s |
| `report_stats()` afterwards | `available: false`, `write_errors: 62`, `last_error: :connection`, `dropped_overloaded: 139` | same |
| **Recovery**: first committed write after connections were allowed again | 913 ms | 429 ms |
| **Table locked** for 12 s (`ACCESS EXCLUSIVE`), 200 reports in a burst | 51 admitted, 149 refused; 49 stored after the lock, 2 `{:ecto_error, :query_canceled}`; last outcome at 12.2 s | same |
| `report_stats()` while blocked | before the fix: `writer_running: false` (wrong); after: `writer_running: true, writer_busy: true` with `pending` | |
| **Shutdown** (supervisor) with the writer blocked on the lock and 51 queued | 0 ms; on restart, `lost: 51` | same |

Reading:

* The writer isn't stuck during an outage, but it is slow: each failed
  write waits for the pool's checkout (about 4 s), so it drains about 0.25
  reports per second. Most reports in an outage are therefore refused at
  admission as `:overloaded`. They couldn't have been stored anyway, but the
  drop reason points at the queue; `write_errors` and `last_error` point at
  the database (see "Overload or outage?" in docs/storage.md).
* The 4 s comes from DBConnection's queue handling and reconnect backoff in
  the application's Repo, not from TraceGuard. It will differ with other
  pool settings.
* Memory stays bounded: at most `max_pending_reports` queued reports.
* Shutdown never waits for the database.

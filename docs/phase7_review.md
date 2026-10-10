# Phase 7 review: CI, compatibility and release readiness

## Starting point (verified)

The brief's Git facts were out of date:

* **Phase 6 is committed:** `631227d` ("Add ecto") on `phase4`, pushed to
  `origin/phase4`. It contains all 28 Phase 6 files.
* **`main` already contains Phases 4–6:** `main` = `origin/main` =
  `77718c9`, the merge of pull request #1 (`phase4`) into the Phase 3 commit
  `8d9e490`. `phase4` is fully merged (0 commits ahead of `main`).
* Phases by commit: Phase 4 is `5205b4f`, Phase 5 is `b136d36`, Phase 6 is
  `631227d`. No other branch holds this work.
* **Working tree:** clean, nothing staged, `git diff --check` clean. No
  tags locally or on the remote. No CI configuration existed.

Phase 7 itself changed no Git state. The maintainer then committed it
directly on `main` as `882fc9a` ("add postgres") and pushed it, so
`origin/main` = `882fc9a` contains Phases 4–7. That push started the first
GitHub Actions run (see CI below). No tag exists. `phase4` is fully merged
and can be deleted when no longer needed.

**Remaining steps (maintainer):**

1. Run `Compatibility` once by hand (Actions → Compatibility → Run
   workflow), since it has never run on GitHub.
2. Optionally, protect `main` by requiring the `CI` jobs, and send future
   work through pull requests.
3. Only when the external-preview gate in
   [release_checklist.md](release_checklist.md) is complete, tag
   `v0.1.0-rc.1` on the commit to release.

No force-push or history rewrite is needed.

## CI

* **`.github/workflows/ci.yml`** (pull requests; pushes to `main` and
  `phase*`; manual), six jobs:
  * library checks with no database;
  * the demo;
  * PostgreSQL 16 and PostgreSQL 18 (service containers);
  * the minimum toolchain against PostgreSQL 16;
  * clean installs: a Phoenix app on PostgreSQL, and one without Ecto.
* **`.github/workflows/compat.yml`** (weekly and manual): the other three
  rows of the compatibility matrix, plus Bandit/Cowboy × memory/SQLite on
  OTP 27.
* **Design choices:**
  * exact toolchains and `ubuntu-24.04`;
  * actions pinned by SHA;
  * read-only permissions, no secrets;
  * trust-auth PostgreSQL containers with health checks;
  * caches keyed exactly on the lock file and toolchain, with no fallback
    keys, and the project recompiled with `--force`;
  * every job has a timeout;
  * failure logs uploaded as artifacts;
  * no `continue-on-error`.
* **Guards against false passes:**
  * PostgreSQL jobs fail if any test is excluded, or if the server isn't
    the expected major version (the suite now prints the server version);
  * `compat_matrix.sh` now exits non-zero when a row fails (it used to
    always exit 0), and checks that the running Elixir/OTP is the row's;
  * every check was shown to fail on a deliberately broken input:
    * a stray file in the package;
    * a wrong toolchain on `PATH`;
    * an unknown row;
    * the wrong PostgreSQL version;
    * no PostgreSQL server.
* **First GitHub run:** [run 38040243638](https://github.com/HataluliRandima/trace_guard/actions/runs/38040243638), on the
  push of `882fc9a` to `main`. **All six `ci.yml` jobs succeeded**
  (63–98 s each). The PostgreSQL steps can only succeed if the suite
  reported `PostgreSQL 16.` or `PostgreSQL 18.` and excluded nothing, so
  both service containers really ran the database suite. Job logs (exact
  test counts) need a GitHub sign-in to read. `compat.yml` hasn't run on
  GitHub yet.
* **Before that,** both workflows passed `actionlint` 1.7.12 with
  `shellcheck` 0.11.0, and every job's `run:` steps were executed locally,
  in order, with GitHub's `bash -eo pipefail` and the job's exact
  toolchain:

| Job | Result (local) |
| --- | --- |
| Library checks | ✅ 175 tests + 1 doctest (21 PostgreSQL tests excluded); ExDoc, package check, `hex.audit` ok |
| Demo | ✅ 16 tests |
| PostgreSQL 16 / 18 | ✅ 175 tests + 1 doctest on 16.15 and on 18.6, none excluded |
| Minimum (ecto_sql 3.10.2, postgrex 0.17.5) | ✅ |
| Clean install (PostgreSQL), clean install (no Ecto) | ✅ |
| Compatibility rows current, elixir117-otp27, latest | ✅ (latest failed once on a test assertion I had just added; fixed, see below) |
| External, Bandit and Cowboy × memory and SQLite | ✅ 6/6 per variant |

## PostgreSQL versions

**16** (as in Phase 6) and **18**, the newest major version. There's no
Docker here, and enabling its WSL integration would change system
configuration. So `scripts/local_postgres.sh` gained `PG_MAJOR=18`:

* it downloads PostgreSQL 18.6 from apt.postgresql.org, checking the key
  fingerprint, the `InRelease` signature and every package's SHA-256, plus
  two runtime libraries from Ubuntu;
* it runs the server as the current user on port 54331;
* nothing is installed system-wide.

CI uses the official `postgres:16` and `postgres:18` images.

**One unexplained failure (investigated in Phase 7.1).** The very first
suite run against PostgreSQL 18 (03:03:30, 2026-10-10) reported
`1 doctest, 171 tests, 1 failure`. I had kept only the last 6 lines of its
output, so **the failing test's name, seed, assertion and error are lost.**
They can't be recovered:

* ExUnit's failure manifest was overwritten (it is now empty).
* The session transcript holds only those 6 lines.
* No other log of that run exists.

What the surviving evidence does show:

* **No server-side anomaly.** PostgreSQL 18's own log shows the same kinds
  and counts of events in that run as in the 83 later runs against the same
  server:
  * the missing-table test's `undefined_table` errors;
  * the outage test's 10 terminated backends and cancel requests;
  * nothing else.

  No PostgreSQL-18-specific error was raised.
* **Not a timeout.** The run took 19.4 s (18.8 s synchronous), inside the
  range of the passing runs (19.4–19.7 s). Every long wait in the
  PostgreSQL tests is 5 s or more, so the failure was a fast assertion
  mismatch or exception, not one of those waits running out.
* **The visible stack trace is unrelated.** The tail ended in a
  `gen_server.erl:1142` stack. That is the expected `PricingServer` crash
  log that every run prints, passing ones included.
* **Not reproduced:** 72 further runs passed. These were 60 full-suite and
  12 PostgreSQL-only runs, half of them under full CPU load, plus one on a
  freshly initialised cluster and every local CI job since.

What remains uncertain:

* whether it was a PostgreSQL test at all (150 of the 171 tests don't
  touch PostgreSQL);
* whether PostgreSQL 18 played any part.

The outage-test race I suggested earlier is unlikely: the pool is idle and
fully connected when the test closes the database, so no connection is
being established in that window. Without knowing the test, a regression
test would be guesswork, so none was added.

Lesson applied: CI keeps the complete job log (and the PostgreSQL jobs
`tee` the full output), so a recurrence there will name the test and its
seed. Locally, keep full logs (`mix test 2>&1 | tee run.log`), never only a
`tail`.

## Clean installation and migration workflow

`scripts/external_postgres_smoke.sh` was rebuilt around the brief's nine
steps. It now:

* installs the **built package** (`mix hex.build --unpack`), not the
  repository;
* checks every step;
* exits non-zero on any failure;
* always drops its databases.

Results on PostgreSQL 16.15 and on 18.6 (15/15 checks each):

1. dependency added (package path; not on Hex yet);
2. the app's existing `AcmePg.Repo` configured as documented;
3. **started before migrating:** no `trace_guard_reports` table,
   `available: false`, only `AcmePg.Repo` running. TraceGuard creates
   nothing;
4. `mix trace_guard.gen.ecto_migration` with no flags:
   * written to `priv/repo/migrations/` as
     `AcmePg.Repo.Migrations.AddTraceGuardReports`;
   * accepted by the app's own `mix format --check-formatted`;
   * byte-identical when regenerated;
   * a second run refuses;
5. the app's ordinary `mix ecto.migrate`. `mix ecto.migrations` shows both
   the app's `create_orders` and TraceGuard's migration up, and rollback
   then migrate works;
6. a traced failure through real HTTP (Bandit);
7. the persisted report retrieved (`await_report`, `report_status`,
   `list_reports`), and read back by a second VM after a restart;
8. a raw scan of every column: the planted API key and bearer token are
   absent, and the header shows `[REDACTED]`;
9. the app's `orders` table is untouched by storing, cleanup and
   `clear_reports/0`. The only databases created were `acme_pg_dev` and
   `acme_pg_test`.

**Generator fix:** it inferred `<App>.Repo` from the app name and always
wrote to `priv/repo/migrations`. It now resolves the Repo and directory as
`mix ecto.gen.migration` does:

* the Repo from `--repo`/`-r` or `:ecto_repos`, refusing to guess when
  several are configured;
* the directory from the Repo's `:priv` setting;
* it refuses non-PostgreSQL repos.

It is compiled only when Ecto is present. There are 6 generator tests.

**Optional dependencies:** `scripts/no_ecto_smoke.sh` creates a fresh
`--no-ecto` Phoenix app using the built package. Its lock file has no
`ecto`, `ecto_sql`, `exqlite`, `postgrex` or `db_connection`. TraceGuard
compiles without warnings, the optional modules aren't compiled, and a real
failure is reported, redacted, in memory (4/4).

Only one Ecto version is used by the clean install (3.14.0, what
`phx.new` resolves). `ecto_sql` 3.10.2 and 3.12.1 are covered by the
library suite's compatibility rows.

## Operational reliability review

Evidence: `bench/ecto_writer_operations.exs`, two runs on PostgreSQL 18
([results](https://github.com/HataluliRandima/trace_guard/blob/main/bench/results/phase7-ecto-operations.md)).

| Question | Finding |
| --- | --- |
| Are saturation and drops observable? | Yes: `[:trace_guard, :report, :dropped]` with the reason, `report_status/1`, and `report_stats/0` (`dropped_overloaded`, `dropped_other`, `lost`, `pending`). |
| Can operators tell database unavailability from overload? | Yes, but not from the drop counts alone. During an outage each failed write takes about 4 s, so most reports are refused as `:overloaded` (139 of 200). `write_errors`, `last_error` and the one-time warning log show the cause. Now documented ("Overload or outage?" in storage.md). |
| Is recovery bounded? | Yes: the first commit came 0.4–0.9 s after the database returned. A 12 s table lock: 49 of 51 queued reports stored afterwards, 2 cancelled. |
| Is shutdown bounded? | Yes: the writer doesn't trap exits and stops immediately, even when blocked. Queued reports are lost, recorded as `:lost` if only the writer restarts. Now documented. |
| Does the README describe throughput and queue limits? | It didn't mention throughput. It now gives about 180 reports/s (environment-specific), the outage slowdown, and how to read the drops. |
| Are retention and deletion limits documented accurately? | Yes. Deletion is logical; WAL, replicas and backups can retain data. Nothing new claimed. |

**Defect fixed:** while the writer was inside a slow statement,
`report_stats/0` waited 5 s and then reported `writer_running: false`. It
now waits at most 1 s, and reports `writer_running: true, writer_busy: true`
with `pending` from the admission counter. There's a regression test in the
queue-overflow test.

**No performance change.** The single writer's throughput is a documented
limit. Outage behaviour is bounded in memory (`max_pending_reports`) and in
time. A fail-fast circuit breaker would only relabel drops that can't be
avoided anyway, so it doesn't justify changing the writer.

## Security and package review

* **Redaction before storage:** unchanged pipeline. It's re-verified by raw
  column scans in the library suite, the PostgreSQL clean install, and the
  no-Ecto app.
* **SQL:** `Ecto.Query` with bound parameters only; fixed table and column
  names; prefix validated as a string.
* **Errors:** codes only, never PostgreSQL messages. The writer logs state
  transitions only.
* **Queue and memory bounds:** confirmed under outage and lock: at most
  `max_pending_reports` queued.
* **Tests, logs and CI:**
  * only fake planted secrets;
  * no credentials in the repository or workflows;
  * failure artifacts kept for 7 days.
* **Package:** `scripts/package_check.sh` checks:
  * the file allowlist, and that every tracked lib file ships;
  * a secret and artefact scan;
  * the metadata: version, license and links;
  * `exqlite` and `ecto_sql` optional; `postgrex`, `phoenix` and `ex_doc`
    absent.
* **Migration permissions and ownership:** the migration runs as the
  application's migration user, in the application's history. TraceGuard
  needs `SELECT`, `INSERT`, `UPDATE` and `DELETE` on its table, and the
  sequence it uses. Nothing runs at startup.
* **PostgreSQL deletion:** logical only. No erasure claim.
* **Memory and SQLite adapters:** pass in every run (library suite, and the
  external smoke test with memory and SQLite variants).

## Outstanding blockers to an external preview

1. ~~`compat.yml` never run on GitHub~~: resolved. The manual
   [run 38042363035](https://github.com/HataluliRandima/trace_guard/actions/runs/38042363035) for `882fc9a` passed all four jobs: rows
   current, elixir117-otp27 and latest (PostgreSQL 16, 16 and 18), and the
   external Bandit/Cowboy × memory/SQLite test.
2. **No `v0.1.0-rc.1` tag**, which ExDoc's source links point to.
3. **No announcement or release notes** beyond the changelog.
4. **One unexplained failure** in 73 local runs against PostgreSQL 18
   (details unrecoverable; see above). CI passed on PostgreSQL 18 on its
   first run.
5. **Not tested:**
   * PostgreSQL other than 16 and 18;
   * managed or pooled PostgreSQL (TLS, PgBouncer);
   * macOS and Windows;
   * releases;
   * multiple nodes;
   * sustained load.
6. **No production use.** The Ecto adapter, `TraceGuard.Server` and the
   storage behaviour remain **experimental**.

## Recommendation

`ci.yml` is green on GitHub for `882fc9a`. `compat.yml` is green too
([run 38042363035](https://github.com/HataluliRandima/trace_guard/actions/runs/38042363035)). TraceGuard is **ready for an
experimental external preview** once the release text is updated, CI passes
on the commit to tag, and that commit is tagged. The Ecto adapter stays
experimental regardless of CI.

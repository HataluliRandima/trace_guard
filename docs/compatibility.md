# Compatibility

"Supported" here means **verified by running the checks**, not merely
allowed by the version constraints in `mix.exs`.

## Continuous integration

Two GitHub Actions workflows run the same scripts as the local procedure.
Every job must pass; none uses `continue-on-error`. Toolchains are exact
(`version-type: strict`), runners are `ubuntu-24.04`, and third-party
actions are pinned by commit SHA. PostgreSQL runs as a CI service container
with trust authentication, so no credential exists in the repository or in
CI secrets.

**Version policy (Phase 8).** Required CI is reproducible: it pins exact
toolchains, `mix.lock` and exact PostgreSQL minors (`postgres:16.15`,
`postgres:18.6`), so a pull request's result changes only with its code.
The weekly Compatibility workflow floats on purpose: PostgreSQL major
tags (`postgres:16`, `postgres:18`, so the latest minors), fresh
dependency resolution, and `mix hex.audit` for retired packages.

* **Red weekly, green required:** something changed upstream. Fix it or
  tighten a constraint, then bump the pins in `ci.yml` in their own pull
  request.
* **Minors** are bumped deliberately, roughly when PostgreSQL ships them
  (quarterly).
* **Digests** (`@sha256:`) aren't pinned: the official images rebuild the
  same minor tag for OS updates, and stale digests would miss them.
* **Exception:** the clean-install job resolves its generated app's
  dependencies fresh, as a new user's would. It prints the resolved
  versions so a break can be traced upstream.

**`ci.yml`: every pull request, and pushes to `main` and `phase*`:**

| Job | Toolchain | What it checks |
| --- | --- | --- |
| Library checks | Elixir 1.17.0 / OTP 26.1.2 | lock file current and minimal, formatting, warnings-as-errors compile (dev, test), tests and doctest without PostgreSQL, ExDoc with warnings as errors, `scripts/package_check.sh` |
| Demo application | same | formatting, warnings-as-errors compile (dev, bench), tests |
| PostgreSQL 16.15 and PostgreSQL 18.6 | same | the full suite including the real PostgreSQL tests; fails if any are excluded or if the server isn't exactly the pinned version |
| Minimum toolchain | Elixir 1.15.8 / OTP 26.1.2 | compatibility row "minimum" (fresh resolution: Phoenix 1.7, Plug 1.14, Telemetry 1.0, `ecto_sql` 3.10, `postgrex` 0.17) against PostgreSQL 16.15 |
| Clean install | Elixir 1.17.0 / OTP 26.1.2, `phx_new` 1.8.8 | `scripts/external_postgres_smoke.sh` (fresh Phoenix app on PostgreSQL 16.15) and `scripts/no_ecto_smoke.sh` (fresh Phoenix app without Ecto) |

**`compat.yml`: weekly (Mondays) and on demand:** rows "current"
(fresh resolution instead of the lock file, PostgreSQL 16),
"elixir117-otp27" (PostgreSQL 16) and "latest" (Elixir 1.20.1 / OTP 29.0,
PostgreSQL 18), on the floating major tags; `scripts/external_smoke.sh`
with Bandit and Cowboy × memory and SQLite on Elixir 1.17.1 / OTP 27.0; and
`mix hex.audit` on the locked dependencies.

**Status (remote runs; each tested only its own commit):** `ci.yml` first ran on GitHub for `882fc9a`
([run 38040243638](https://github.com/HataluliRandima/trace_guard/actions/runs/38040243638)), and all six jobs succeeded,
including PostgreSQL 16 and 18 with nothing excluded. `compat.yml` ran
manually for the same commit ([run 38042363035](https://github.com/HataluliRandima/trace_guard/actions/runs/38042363035)): all four jobs
succeeded. **The released commit, `67905b6` (v0.1.0-rc.1),** passed CI
[38055935412](https://github.com/HataluliRandima/trace_guard/actions/runs/38055935412) (six jobs, pinned PostgreSQL 16.15 and 18.6) and Compatibility [38057068064](https://github.com/HataluliRandima/trace_guard/actions/runs/38057068064)
(five jobs, including the retired-package audit). **The released commit,
`5060bfd` (v0.1.0-rc.2),** passed CI
[40206743041](https://github.com/HataluliRandima/trace_guard/actions/runs/40206743041) and Compatibility [40206940976](https://github.com/HataluliRandima/trace_guard/actions/runs/40206940976). Before the first runs,
both workflows were linted (`actionlint`
with `shellcheck`), and every job's `run:` steps were executed locally with
the job's exact toolchain (see the table below).

**Locally verified but not in CI:** the demo and the clean-install test on
other toolchains, PostgreSQL 18 for the clean-install test, and the
benchmarks.

## Verified (Phase 7)

The jobs of both workflows, run locally with the jobs' exact toolchains
(asdf) and a user-local PostgreSQL 16.15 or 18.6 (`scripts/local_postgres.sh`;
PostgreSQL 18 comes from the PostgreSQL project's apt repository, with its
signature and hashes verified):

| Job / row | Elixir / OTP | PostgreSQL | Resolved Phoenix / Plug / Telemetry / Exqlite / Ecto SQL / Postgrex | Result |
| --- | --- | --- | --- | --- |
| Library checks | 1.17.0 / 26.1.2 | none | lock file | ✅ 175 tests + 1 doctest, 0 failures (21 PostgreSQL tests excluded); docs, package, audit ok |
| PostgreSQL 16 | 1.17.0 / 26.1.2 | 16.15 | lock file | ✅ 175 tests + 1 doctest, none excluded |
| PostgreSQL 18 | 1.17.0 / 26.1.2 | 18.6 | lock file | ✅ 175 tests + 1 doctest, none excluded |
| minimum | 1.15.8 / 26.1.2 | 16.15 | 1.7.24 / 1.14.2 / 1.0.0 / 0.42.0 / **3.10.2 / 0.17.5** | ✅ |
| current (fresh) | 1.17.0 / 26.1.2 | 16.15 | 1.8.15 / 1.20.3 / 1.4.2 / 0.42.0 / 3.14.0 / 0.22.4 | ✅ |
| elixir117-otp27 | 1.17.1 / 27.0 | 16.15 | 1.8.15 / 1.20.3 / 1.4.2 / 0.42.0 / 3.12.1 / 0.22.4 | ✅ |
| latest | 1.20.1 / 29.0 | 18.6 | 1.8.15 / 1.20.3 / 1.4.2 / 0.42.0 / 3.14.0 / 0.22.4 | ✅ |
| Demo | 1.17.0 / 26.1.2 | none | lock file | ✅ 16 tests |
| Clean install (PostgreSQL) | 1.17.0 / 26.1.2 | 16.15 and 18.6 | `ecto_sql` 3.14.0 in the generated app | ✅ every check, app suite 6 tests |
| Clean install (no Ecto) | 1.17.0 / 26.1.2 | none | no Ecto in the app's lock file | ✅ 4 tests |
| External, Bandit and Cowboy × memory and SQLite | 1.17.1 / 27.0 | none | Bandit 1.12, Cowboy 2.20 | ✅ 6 tests per variant |

## Verified (Phase 6)

`scripts/compat_matrix.sh` copies the library into a scratch directory,
pins the dependency requirements there, resolves them from scratch (no lock
file), and runs `mix deps.get`, `mix compile --warnings-as-errors` and the
full test suite. With `TRACE_GUARD_POSTGRES_URL` set, that suite includes the
**real PostgreSQL suite** for `TraceGuard.Storage.Ecto`: 171 tests + 1
doctest in total, covering real Phoenix requests, Task and GenServer
propagation, and all four storage adapters.

| Row | Elixir | OTP | Phoenix (test) | Plug | Telemetry | Exqlite | Ecto SQL / Postgrex | Result (PostgreSQL 16.15) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| minimum | 1.15.8 | 26.1.2 | 1.7.24 | 1.14.2 | 1.0.0 | 0.42.0 | **3.10.2 / 0.17.5** | ✅ 171 tests + 1 doctest, 0 failures |
| current (lock file) | 1.17.0 | 26.1.2 | 1.8.15 | 1.20.3 | 1.4.2 | 0.42.0 | 3.14.0 / 0.22.4 | ✅ |
| Elixir 1.17 on OTP 27 | 1.17.1 | 27.0 | 1.8.15 | 1.20.3 | 1.4.2 | 0.42.0 | 3.12.1 / 0.22.4 | ✅ |
| latest | 1.20.1 | 29.0 | 1.8.15 | 1.20.3 | 1.4.2 | 0.42.0 | 3.14.0 / 0.22.4 | ✅ |

Jason resolved to 1.4.5 in every row.

**PostgreSQL:** 16.15 in Phase 6; 18.6 added in Phase 7 (see above).
Versions other than 16 and 18 are untested; the adapter uses `jsonb`,
`bigserial`, `ON CONFLICT` and `COMMENT ON`, all available since
PostgreSQL 9.5, but that isn't verified.

The demo application (Ecto SQL 3.14 on SQLite, Bandit 1.12) and its 16 tests
were run on the "current" row only.

Reproduce it with:

```bash
eval "$(scripts/local_postgres.sh start | tail -1)"  # or any PostgreSQL: TRACE_GUARD_POSTGRES_URL=...
scripts/compat_matrix.sh                            # all rows
ROWS="minimum latest" scripts/compat_matrix.sh      # selected rows
```

Without `TRACE_GUARD_POSTGRES_URL`, the PostgreSQL suite is excluded, and
the script says so in its summary. Such a run doesn't verify the Ecto
adapter. The script needs asdf with the listed versions and access to
hex.pm.

## External PostgreSQL application (Phase 6)

`scripts/external_postgres_smoke.sh` generates a fresh Phoenix app with
`--database postgres` (its own `AcmePg.Repo`, `acme_pg_dev` and
`acme_pg_test` databases). It configures
`storage: {TraceGuard.Storage.Ecto, repo: AcmePg.Repo}`, generates
TraceGuard's migration with `mix trace_guard.gen.ecto_migration`, and runs
it with the app's own `mix ecto.migrate`. Result (Elixir 1.17.0 / OTP 26,
PostgreSQL 16.15):

* the app's own test suite over real HTTP (Bandit): ✅ 5 tests, 0
  failures. This covers an ordinary request being unchanged, a failure's
  report stored redacted in the app's database (raw row scan for the planted
  secrets), and `Ecto.Repo.all_running() == [AcmePg.Repo]`;
* **two-VM restart:** VM 1 (`mix phx.server`) served a failing request; a
  separate VM (`mix run`) read the report back from PostgreSQL
  (`report_status/1` → `:stored`), with only `AcmePg.Repo` running;
* the server's databases afterwards: only `acme_pg_dev` and `acme_pg_test`.
  TraceGuard created none.

## External integration (Phase 5)

`scripts/external_smoke.sh` generates a brand-new Phoenix application with
`mix phx.new` (SQLite, no HTML or assets), outside this repository and not
derived from the demo. It then:

* adds TraceGuard as a path dependency;
* configures it with documented options only;
* installs `TraceGuard.Plug`;
* adds a controller that fails after an Ecto query and a wrapped Task, and a
  `use TraceGuard.Server` GenServer that crashes;
* runs the new app's own test suite over **real HTTP** against the running
  endpoint.

The tests use only `TraceGuard`'s public functions: `await_report/2`,
`report_status/1`, `export_json/2`, `list_reports/1`, `report_stats/0`,
`clear_reports/0`, `wrap/1` and `call/3`.

| Toolchain | HTTP adapter | Storage | Result |
| --- | --- | --- | --- |
| Elixir 1.17.0 / OTP 26.1.2 | Bandit 1.12 | in memory | ✅ 6 tests, 0 failures |
| Elixir 1.17.0 / OTP 26.1.2 | Bandit 1.12 | SQLite | ✅ 6 tests, 0 failures |
| Elixir 1.17.1 / OTP 27.0 | Bandit 1.12 | in memory | ✅ 6 tests, 0 failures |
| Elixir 1.17.1 / OTP 27.0 | Bandit 1.12 | SQLite | ✅ 6 tests, 0 failures |
| Elixir 1.17.1 / OTP 27.0 | Cowboy 2.20 (`plug_cowboy` 2.9) | in memory | ✅ 6 tests, 0 failures (5 further runs: 5 passed) |
| Elixir 1.17.1 / OTP 27.0 | Cowboy 2.20 (`plug_cowboy` 2.9) | SQLite | ✅ 6 tests, 0 failures (5 further runs: 5 passed) |

The generated app also started as a normal dev server (`mix phx.server`),
and a real failing request returned Phoenix's generic 500 with an
`x-traceguard-id` header.

What the external run found and changed:

* **Cowboy lost reports for throws and exits** (3 of 4 runs) until Phase 5
  completed those traces before rendering. See
  [architecture.md](architecture.md).
* **Cowboy 2.20 / cowlib 2.21 need OTP 27+**: cowlib uses `maybe`
  expressions, which don't compile on OTP 26. This is a constraint of
  Cowboy, not TraceGuard.
* **Log discovery differs by adapter.** Bandit's crash log carries
  `trace_guard_id`; Cowboy's doesn't. Both contain the raw secret that the
  report redacted.
* **SQLite file permissions** were `0644` and are now `0600`.

## Declared requirements

| Dependency | Requirement | Lowest verified | Notes |
| --- | --- | --- | --- |
| Elixir | `~> 1.15` | 1.15.8 | |
| OTP | (via Elixir) | 26.1.2 | 27.0 and 29.0 also verified. |
| `plug` | `~> 1.14` | 1.14.2 | |
| `telemetry` | `~> 1.0` | 1.0.0 | |
| `jason` | `~> 1.4` | 1.4.5 | Every row resolved 1.4.5; 1.4.0–1.4.4 are untested. |
| `phoenix` | `~> 1.7` (tests only) | 1.7.24 | TraceGuard has no runtime dependency on Phoenix; it relies on Phoenix's telemetry events and error rendering, verified on 1.7.24 and 1.8.15. |
| `exqlite` | `~> 0.42`, **optional** | 0.42.0 | Only for `TraceGuard.Storage.SQLite`. The `~>` requirement allows later 0.x releases, which are untested. |
| `ecto_sql` | `~> 3.10`, **optional** | 3.10.2 | Only for `TraceGuard.Storage.Ecto` (3.10.2, 3.12.1 and 3.14.0 verified with PostgreSQL 16). TraceGuard also consumes Ecto SQL's `[..., :query]` telemetry events (verified with SQLite and PostgreSQL). |
| `postgrex` | none (from your app) | 0.17.5 | Test-only dependency of TraceGuard; 0.17.5 and 0.22.4 verified. |

## Not tested (outstanding)

* **PostgreSQL versions other than 16 and 18**, managed or remote PostgreSQL
  (TLS, poolers such as PgBouncer in transaction mode), MySQL and other Ecto
  adapters. The Ecto adapter refuses non-PostgreSQL repos.
* **Cowboy on OTP 26** (current Cowboy doesn't compile there), and older
  Cowboy versions.
* **Elixir 1.16, 1.18, 1.19** and **OTP 25, 28.**
* **Operating systems other than Linux under WSL2.** macOS, Windows and
  native Linux are untested; the SQLite adapter's file handling is the most
  likely place for differences.
* **Releases** (`mix release`, embedded mode) and hot code upgrades.
* **Multiple nodes.** Propagation is node-local by design; calling a remote
  server with `TraceGuard.call/3` runs the callback untraced. Nothing else
  about distribution is tested.
* **Long-running load and memory growth over hours.**

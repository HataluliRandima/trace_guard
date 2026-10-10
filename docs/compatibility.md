# Compatibility

"Supported" here means **verified by running the checks**, not merely
allowed by the version constraints in `mix.exs`.

## Verified (Phase 4)

`scripts/compat_matrix.sh` copies the library into a scratch directory,
pins the dependency requirements there, resolves them from scratch (no lock
file), and runs `mix deps.get`, `mix compile --warnings-as-errors` and the
full test suite (148 tests + 1 doctest, including real Phoenix requests,
Task and GenServer propagation, and all three storage adapters, SQLite
included).

| Row | Elixir | OTP | Phoenix (test) | Plug | Telemetry | Jason | Exqlite | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| minimum | 1.15.8 | 26.1.2 | 1.7.24 | 1.14.2 | 1.0.0 | 1.4.5 | 0.42.0 | ✅ 148 tests + 1 doctest, 0 failures |
| current (lock file) | 1.17.0 | 26.1.2 | 1.8.15 | 1.20.3 | 1.4.2 | 1.4.5 | 0.42.0 | ✅ |
| Elixir 1.17 on OTP 27 | 1.17.1 | 27.0 | 1.8.15 | 1.20.3 | 1.4.2 | 1.4.5 | 0.42.0 | ✅ |
| latest | 1.20.1 | 29.0 | 1.8.15 | 1.20.3 | 1.4.2 | 1.4.5 | 0.42.0 | ✅ |

The demo application (Ecto SQL 3.14, `ecto_sqlite3` 0.25, Bandit 1.12) and
its 16 tests were run on the "current" row only.

Reproduce it with:

```bash
scripts/compat_matrix.sh                       # all rows
ROWS="minimum latest" scripts/compat_matrix.sh # selected rows
```

The script needs asdf with the listed Elixir and Erlang versions installed,
and access to hex.pm. Elixir 1.15.8 was installed for this phase
(`asdf install elixir 1.15.8-otp-26`, then `mix local.hex` for it).

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
| Ecto | none | — | TraceGuard consumes Ecto SQL's `[..., :query]` telemetry events. Their metadata shape was verified with `ecto_sql` 3.14 only. |

## Not tested (outstanding)

* **PostgreSQL / Postgrex**, MySQL, and `ecto_sql` versions other than 3.14.
  No PostgreSQL server is installed in the development environment, Docker
  isn't available, and installing one would need `sudo` (password
  required). The Ecto query event shape on PostgreSQL is therefore
  unverified. **Outstanding before a stable release.**
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

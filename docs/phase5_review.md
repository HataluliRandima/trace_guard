# Phase 5 review: release candidate and external validation

## Starting point (verified, not assumed)

Commit `5205b4f` with a clean working tree: 142 library tests + 1 doctest
and 16 demo tests passing; formatting and warnings-as-errors compilation
clean. The git remote is `github.com/HataluliRandima/trace_guard`, default
branch `main`.

## External validation

`scripts/external_smoke.sh` builds a new Phoenix 1.8 application with
`mix phx.new`, outside this repository, and integrates TraceGuard using
only the README's instructions and public functions. It then runs that app's
own tests over real HTTP. Results are in
[compatibility.md](compatibility.md#external-integration-phase-5): all
variants pass on the final code, covering Bandit on OTP 26 and 27 and
Cowboy on OTP 27, each with in-memory and SQLite storage.

The external run found two defects that the in-repo suites had not:

1. **Cowboy lost throw/exit reports (release blocker, fixed).** Cowboy
   terminates the request process once its response is complete. TraceGuard
   completed throw/exit traces only after the response, at
   `[:phoenix, :error_rendered]`. 3 of 4 runs lost the report, without even
   a drop record. These traces are now completed at
   `[:phoenix, :router_dispatch, :exception]`, before rendering. There is a
   regression test that kills the request process right after the response;
   it fails on the old code.
2. **SQLite reports file world-readable (fixed).** See below.

**Not testable here: PostgreSQL.** No server is installed, Docker is
unavailable, and installing one needs `sudo` (password required). Nothing was
installed, and no system configuration was changed. This is outstanding.

## Public API review

* **Stable surface for 0.1:**
  * `TraceGuard`: `current_trace_id/0`, `get_report/1`, `await_report/2`,
    `report_status/1`, `list_reports/1`, `export_json/2`, `report_stats/0`,
    `delete_report/1`, `clear_reports/0`, `wrap/1`;
  * `TraceGuard.Plug`;
  * `TraceGuard.Exporter.JSON`;
  * the `config :trace_guard` options.
* **Experimental (labelled in their docs):** `TraceGuard.Server` and
  `TraceGuard.call/3`, the `TraceGuard.Storage` behaviour, and
  `TraceGuard.Storage.SQLite`.
* **Internal (labelled, and grouped separately in ExDoc):** `Config`,
  `Context`, `DropLog`, `EventCollector`, `Propagation` (and `Token`),
  `Redactor`, `TaskCollector`, `Telemetry`, `TraceBuilder`. They stay public
  modules, so as not to break the links the guides make, but they are not
  API.
* **No breaking changes were made.** Points reviewed and kept:
  * `report_stats/0` and `report_status/1` have similar names, but each is
    descriptive.
  * `list_reports/1` returns `[]` when storage is unavailable (documented;
    `report_stats/0` shows `available: false`).
  * `report_status/1` reads the store with a fixed 1 s timeout; the other
    reads use the adapter's 5 s.
  * The response header (`x-traceguard-id`) and the Logger key
    (`trace_guard_id`) are spelled differently. Both are kept for
    compatibility.
* **Behaviour changes in this phase** (both bug fixes): throw/exit reports
  end with `request.stop` (formerly `phoenix.error_rendered`); the SQLite
  adapter rejects unknown options.
* **Disabled tracing and unavailable storage** behave as documented and are
  covered by tests: the plug is a no-op; `wrap/1` returns its function;
  `TraceGuard.call/3` still delivers the call; lookups return
  `{:error, :unavailable}` or `[]`; requests are never affected.

## Package and documentation

* **Name:** `trace_guard` is unclaimed on hex.pm. The API returned 404, the
  HexDocs URL returned 404, and a search found no packages, as of
  2026-10-10. The project name *TraceGuard* is used by unrelated GitHub
  projects (checked between Phases 1 and 2); that isn't a Hex conflict.
* **Version:** `0.1.0-rc.1`.
* **Description:** rewritten.
* **License:** Apache-2.0.
* **Links:** GitHub and Changelog, derived from the git remote.
* **Maintainers:** not set, because no maintainer name was provided (Hex
  makes the field optional).
* **Package files:** `lib`, `mix.exs`, `.formatter.exs`, `README.md`,
  `LICENSE`, `CHANGELOG.md`. Verified by `mix hex.build --unpack` (local, not
  published): exactly those files, no databases, no tests, no demo, and no
  secret-like strings.
* **Dependencies:**
  * runtime: `telemetry ~> 1.0`, `plug ~> 1.14`, `jason ~> 1.4`;
  * optional: `exqlite ~> 0.42`;
  * test only: `phoenix ~> 1.7`;
  * dev only: `ex_doc ~> 0.34`.
* **ExDoc:** `MIX_ENV=dev mix docs --warnings-as-errors` builds with zero
  warnings. Modules are grouped as Public / Experimental / Internals, and the
  guides as Guides / Reference / Development history.
* **New files:** `CHANGELOG.md`, `docs/release_checklist.md`,
  `docs/security.md` and this review. The README is rewritten around the
  questions a new user asks.

## Security and reliability audit

| Area | Finding | Action |
| --- | --- | --- |
| Trace IDs | 128-bit `strong_rand_bytes`; lookups validate `^[0-9a-f]{32}$` | none needed |
| Redaction before export and storage | Holds; adapters only ever receive the redacted report | none needed |
| Exception messages | Only *labelled* secrets are scrubbed | documented prominently (README, security.md) |
| Logs | Bandit's and Cowboy's crash logs contain raw secrets (observed) | documented; logging is out of scope |
| Throw/exit capture under Cowboy | **Reports lost** | **fixed + regression test** |
| Endpoint-plug failures under Cowboy | Can be lost (no earlier signal) | documented + test pinning the limitation |
| SQLite file mode | **`0644`** | **fixed: `0600` on creation (`:file_mode`) + test** |
| SQLite deleted data | **Deleted reports stayed readable in DB/WAL files** | **fixed: `secure_delete` + WAL truncate + test** |
| SQLite options | **Typos silently ignored** | **fixed: validated at start + test** |
| Bounded queues and state | Hold under outage and burst (Phase 3/4 tests and benchmark) | none needed |
| Storage restart | Committed SQLite reports survive; queued ones are recorded `:lost` | none needed |
| Lookup boundary | Node-local functions only; the response header is safe only for that reason | documented in security.md |
| Configuration validation | Unknown or ill-typed options raise at boot | none needed |
| Dependency failures | Adapter raise/exit/garbage → dropped with a reason; telemetry handler errors rescued; no recursive diagnostics | none needed |

Every "fixed" row's regression test fails on the previous code and passes
now.

## Performance review

See the summary at the top of [performance.md](performance.md):

* **Reliable:** allocation figures and the queue bounds.
* **Indicative:** single-machine latencies.
* **Noisy:** database-bound latency deltas and p99s.
* **Not measured:** PostgreSQL, Cowboy, production hardware, long runs.

No production overhead target is claimed. Cheaper first propagation (about
100 µs) remains future work: it is a cost, not a correctness or usability
problem.

## Verification (final code)

| Check | Result |
| --- | --- |
| `mix format --check-formatted` (library, demo, demo bench) | ✅ |
| `mix compile --warnings-as-errors` (library dev/test; demo dev/bench) | ✅ |
| `mix test` (library), run twice | ✅ 148 tests + 1 doctest, 0 failures |
| `mix test` (demo), run twice | ✅ 16 tests, 0 failures |
| `scripts/compat_matrix.sh` (4 rows) | ✅ every row 148 tests + 1 doctest |
| `scripts/external_smoke.sh`, OTP 26, Bandit × {memory, SQLite} | ✅ 6/6 each |
| `scripts/external_smoke.sh`, OTP 27, {Bandit, Cowboy} × {memory, SQLite} | ✅ 6/6 each |
| `MIX_ENV=dev mix docs --warnings-as-errors` | ✅ 0 warnings |
| `mix hex.build --unpack` (local) + secret scan | ✅ intended files only; clean |
| Published to Hex / release performed | **No** |

## Release readiness

**Ready for an internal release candidate. Not yet for an external preview.**

Release blockers for an external preview or stable release:

1. **PostgreSQL** is unverified, and so is the Ecto event shape on
   `ecto_sql` other than 3.14. Most Phoenix apps use PostgreSQL.
2. **No CI.** All checks ran on one developer laptop (WSL2). macOS, Windows
   and native Linux are untested, and so are `mix release` and embedded mode.
3. **Maintainer metadata and repository state:** the remote `main` branch is
   at Phase 3. The Phase 4 and 5 work must be pushed, tagged, and the
   `source_ref` (`v0.1.0-rc.1`) must exist before documentation links
   resolve.
4. **Experimental surfaces** (GenServer propagation, the storage behaviour,
   SQLite) need real-user feedback before their APIs are frozen.

Known limitations that don't block an internal RC are documented in the
README's Limitations section.

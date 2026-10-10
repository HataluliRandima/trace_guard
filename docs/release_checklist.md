# Release checklist

Steps for cutting a TraceGuard release. **Publishing is a manual, human
step.** Nothing in this repository publishes automatically, and no CI
workflow has publishing credentials.

## 0. External preview gate (0.1.0-rc.1)

Every box must be ticked, with evidence (a link or a log), before the
release candidate is announced as an external preview. Status as of the
Phase 7 review ([phase7_review.md](phase7_review.md)):

| # | Item | Evidence required | Status |
| --- | --- | --- | --- |
| 1 | **CI green** | a passing `CI` run on GitHub for the commit to release: library checks, demo, minimum toolchain | ☐ workflows written and their steps pass locally; **never run on GitHub** |
| 2 | **Real PostgreSQL CI green** | the `PostgreSQL 16` and `PostgreSQL 18` jobs of that run, with no excluded tests | ☐ passes locally against 16.15 and 18.6; **not yet on GitHub** |
| 3 | **Clean migration workflow verified** | the `Clean install` job of that run | ☐ passes locally (PostgreSQL 16 and 18); **not yet on GitHub** |
| 4 | **Compatibility workflow green** | one manual run of `Compatibility` (Actions → Compatibility → Run workflow) | ☐ passes locally; **not yet on GitHub** |
| 5 | **Supported toolchain documented** | [compatibility.md](compatibility.md) matches the CI matrix | ☑ |
| 6 | **Security limitations disclosed** | [security.md](security.md): logs aren't sanitized, PostgreSQL deletion is logical, SQLite caveats | ☑ |
| 7 | **Experimental API boundaries clear** | ExDoc groups; `TraceGuard.Server`, `TraceGuard.Storage` and its adapters, the migration and its task are labelled experimental | ☑ (CI passing doesn't make them stable) |
| 8 | **Git history and integration plan agreed** | the maintainer has decided how Phase 7 reaches `main` (see phase7_review.md) | ☐ maintainer decision |
| 9 | **Release notes ready** | `CHANGELOG.md` entry; an announcement that says "experimental preview" and lists the limits | ☐ changelog done; announcement not written |
| 10 | **Tag exists** | `v0.1.0-rc.1` points at the released commit (ExDoc's source links use it) | ☐ maintainer action, step 10 |

## 1. Clean state

```bash
git status --short                 # expect no output
git log --oneline -1               # the commit you intend to release
```

## 2. Library checks (current toolchain)

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=test mix compile --warnings-as-errors
mix test                           # expect 0 failures
```

## 2b. Real PostgreSQL suite (Ecto adapter)

In CI: the `PostgreSQL 16`, `PostgreSQL 18` and `Clean install` jobs.
Locally, for each major version:

```bash
eval "$(PG_MAJOR=16 scripts/local_postgres.sh start | tail -1)"   # or point TRACE_GUARD_POSTGRES_URL at any PostgreSQL
mix test                           # prints "PostgreSQL suite: enabled, PostgreSQL 16..."; 0 failures, **no** excluded tests
scripts/external_postgres_smoke.sh # fresh Phoenix app installs TraceGuard, migrates: every line "ok", exit 0
PG_MAJOR=16 scripts/local_postgres.sh stop
# repeat with PG_MAJOR=18
```

Without `TRACE_GUARD_POSTGRES_URL`, `mix test` excludes the PostgreSQL
suite and says so ("N excluded"). Such a run does **not** verify the Ecto
adapter.

## 3. Demo checks

```bash
cd demo
mix deps.get
mix format --check-formatted && mix format --check-formatted bench/*.exs
mix compile --warnings-as-errors
MIX_ENV=bench mix compile --warnings-as-errors
mix test                           # expect 0 failures
cd ..
```

## 4. Compatibility matrix

```bash
TRACE_GUARD_POSTGRES_URL=... scripts/compat_matrix.sh   # needs asdf with the listed toolchains
```

Every row must show `ok | ok` and 0 failures. Update
[compatibility.md](compatibility.md) if rows or versions change.

## 5. External integration (fresh Phoenix app, public API only)

```bash
scripts/external_smoke.sh                                      # Bandit variants on any OTP
ASDF_ELIXIR_VERSION=1.17.1 ASDF_ERLANG_VERSION=27.0 \
  scripts/external_smoke.sh                                    # + Cowboy (needs OTP 27+)
```

Every variant must `PASS`. The `OBSERVATION` lines show whether the adapter's
crash log carries the trace ID and the raw secret. Both secrets are expected
in the log: TraceGuard doesn't sanitize logs.

```bash
scripts/no_ecto_smoke.sh           # fresh Phoenix app without Ecto: no Ecto deps pulled in, exit 0
```

## 6. Documentation

```bash
MIX_ENV=dev mix docs --warnings-as-errors
open doc/index.html                # spot-check README, guides, module groups
```

## 7. Package contents (local build only)

`scripts/package_check.sh` does all of this section and exits non-zero on
any problem (it runs in CI). By hand:

```bash
mix hex.build                      # builds trace_guard-<version>.tar locally; does NOT publish
tar -tf trace_guard-*.tar          # outer tarball: VERSION, CHECKSUM, metadata.config, contents.tar.gz
tar -xOf trace_guard-*.tar contents.tar.gz | tar -tzf -   # the files that would ship
rm trace_guard-*.tar
```

The files that would ship must be exactly `lib/**`, `mix.exs`, `.formatter.exs`,
`README.md`, `LICENSE` and `CHANGELOG.md`. There must be no `*.db`, `demo/`,
`test/`, `bench/`, `_build/`, `deps/` or `.elixir_ls/`.

```bash
mix hex.build --unpack -o /tmp/tg_pkg && grep -rIl -E "sk_(live|test)_|BEGIN (RSA|OPENSSH) PRIVATE KEY" /tmp/tg_pkg ; rm -rf /tmp/tg_pkg
```

Expect no matches (the only "secrets" in the repository are fake test values,
and tests aren't packaged).

## 8. Version and changelog

* `@version` in `mix.exs` matches the release.
* `CHANGELOG.md` has an entry for it.
* `docs/compatibility.md` and the README's status line are current.

## 9. Package name

* `curl -s -o /dev/null -w "%{http_code}" https://hex.pm/api/packages/trace_guard`
  returns `404` while the name is unclaimed. (It returned 404 on 2026-10-10.)

## 10. Publish (manual, outside this checklist's automation)

Only after every step above passes, and only by a maintainer with Hex
credentials:

```bash
git tag v<version> && git push origin v<version>
mix hex.publish                    # interactive; asks for confirmation
```

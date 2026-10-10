# Release checklist

Steps for cutting a TraceGuard release. **Publishing is a manual, human
step.** Nothing in this repository publishes automatically, and no CI
workflow has publishing credentials.

## 0. Release gate for 0.1.0-rc.1 (experimental GitHub pre-release)

Distribution: a Git tag `v0.1.0-rc.1` and a GitHub pre-release. **Not
Hex.** Every box must be ticked, with evidence, **for the commit that will
be tagged**. A run on an earlier commit doesn't count for a later one.
Status at the end of Phase 8 (the release commit isn't made yet):

| # | Item | Evidence required | Status |
| --- | --- | --- | --- |
| 1 | **CI green on the release commit** | a passing `CI` run whose commit is the one to tag | ☐ the release commit doesn't exist yet. Earlier runs: [38040243638](https://github.com/HataluliRandima/trace_guard/actions/runs/38040243638) on `882fc9a` (passed) |
| 2 | **Real PostgreSQL CI green** | the `PostgreSQL 16.15` and `PostgreSQL 18.6` jobs of that run | ☐ with item 1 |
| 3 | **Clean install green** | the `Clean install` job of that run | ☐ with item 1 |
| 4 | **Compatibility green on the release commit** | a manual `Compatibility` run on that commit (the workflow itself changed in Phase 8) | ☐ earlier: [38042363035](https://github.com/HataluliRandima/trace_guard/actions/runs/38042363035) on `882fc9a` (passed) |
| 5 | **Git-tag installation verified** | a fresh Phoenix app installs `{:trace_guard, github: "HataluliRandima/trace_guard", tag: "v0.1.0-rc.1"}` | ☐ locally ✅: a scratch tag behind a Git URL redirect, so the documented line ran unchanged (memory without Ecto, and the Ecto adapter with migration). Against GitHub: needs the real tag (step 9) |
| 6 | **Supported toolchain documented** | [compatibility.md](compatibility.md) matches the CI matrix | ☑ |
| 7 | **Security limitations disclosed** | [security.md](security.md): logs aren't sanitized, unlabelled secrets, PostgreSQL deletion is logical, reports can be dropped | ☑ |
| 8 | **Experimental API boundaries clear** | ExDoc groups and module docs | ☑ (CI passing doesn't make them stable) |
| 9 | **Release notes ready** | the `CHANGELOG.md` entry and the announcement draft (`docs/announcements/v0.1.0-rc.1.md`) | ☐ drafted; maintainer review |
| 10 | **Tag exists** | `v0.1.0-rc.1` points at the release commit (ExDoc's source links use it) | ☐ maintainer action |
| 11 | **Pre-release published** | a GitHub release, marked pre-release, from that tag | ☐ maintainer action |

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

In CI: the `PostgreSQL 16.15`, `PostgreSQL 18.6` and `Clean install` jobs.
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

## 9. Release (GitHub pre-release; maintainer only)

Only after every step above passes, **and** CI and Compatibility are green
on GitHub for the commit to tag:

```bash
git switch main && git pull --ff-only
git status --short                          # expect no output
git log --oneline -1                        # the commit CI and Compatibility passed on
git tag -a v0.1.0-rc.1 -m "TraceGuard 0.1.0-rc.1 (experimental preview)"
git push origin v0.1.0-rc.1
```

Then verify the published tag from a clean machine or directory (this is
the one check that can't run before the tag exists):

```bash
TRACE_GUARD_DEP='github: "HataluliRandima/trace_guard", tag: "v0.1.0-rc.1"' scripts/no_ecto_smoke.sh
TRACE_GUARD_DEP='github: "HataluliRandima/trace_guard", tag: "v0.1.0-rc.1"' \
  TRACE_GUARD_POSTGRES_URL=... scripts/external_postgres_smoke.sh
```

Then, on GitHub: Releases → Draft a new release → choose tag
`v0.1.0-rc.1` → title "TraceGuard 0.1.0-rc.1 (experimental preview)" →
paste the announcement → tick **Set as a pre-release** → Publish.

A tag is easy to create and awkward to retract once people have fetched it.
If something is wrong after tagging, release `v0.1.0-rc.2` rather than
moving the tag.

## 10. Hex (not part of 0.1.0-rc.1)

Publishing to Hex is a separate, later decision. It permanently claims the
package name, and a version can only be reverted briefly. When it comes:

* `scripts/package_check.sh` passes (it already runs in CI).
* `curl -s -o /dev/null -w "%{http_code}" https://hex.pm/api/packages/trace_guard`
  returns `404` while the name is unclaimed. (It returned 404 on
  2026-10-10.)
* A maintainer with a Hex account and 2FA runs `mix hex.publish` from the
  tagged checkout.

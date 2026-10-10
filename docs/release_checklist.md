# Release checklist

Steps for cutting a TraceGuard release. **Publishing is a manual, human
step.** Nothing in this repository publishes automatically.

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
scripts/compat_matrix.sh           # needs asdf with the listed toolchains
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

## 6. Documentation

```bash
MIX_ENV=dev mix docs --warnings-as-errors
open doc/index.html                # spot-check README, guides, module groups
```

## 7. Package contents (local build only)

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

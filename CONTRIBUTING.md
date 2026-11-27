# Contributing

Bug reports, compatibility results and pull requests are welcome. For a
security issue, follow [SECURITY.md](SECURITY.md) instead of opening a
public issue.

## Before you start

For anything larger than a small fix, open an issue first, so we can agree
on the approach before you spend time on it.

TraceGuard deliberately stays small. Some things it **won't** do:

* trace function calls, or propagate traces implicitly (work outside the
  request process is traced only through `TraceGuard.wrap/1` and
  `TraceGuard.call/3`);
* attribute events by timing rather than by process;
* run an agent, call a service, or make network requests;
* serve reports over HTTP (lookups are node-local Elixir functions, see
  [docs/security.md](docs/security.md#identifiers-and-lookup)).

## Setup

You need Elixir 1.15 or later with OTP 26 or later. CI's main toolchain is
Elixir 1.17.0 / OTP 26.1.2 ([docs/compatibility.md](docs/compatibility.md)).

```bash
mix deps.get
mix test
```

Without a PostgreSQL server, `mix test` excludes the PostgreSQL suite and
says so ("21 excluded"). If you change anything under
`lib/trace_guard/storage/`, run it too:

```bash
eval "$(scripts/local_postgres.sh start | tail -1)"   # a user-local server, or set TRACE_GUARD_POSTGRES_URL
mix test                                             # now 0 excluded
```

The [README's Development section](README.md#development) lists every
check, including the demo application and the fresh-app smoke tests.

## Pull requests

Before opening one, run:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=test mix compile --warnings-as-errors
mix test
MIX_ENV=dev mix docs --warnings-as-errors   # if you changed docs or module docs
```

CI runs these and more (real PostgreSQL 16 and 18, the minimum toolchain,
clean installs) on every pull request. Every job must pass.

* **Tests:** a bug fix comes with a test that fails without it. Wait for
  outcomes (for example with `TraceGuard.await_report/2`) rather than
  sleeping: CI runners are shared and timing varies.
* **No real secrets or customer data**, anywhere: tests use fake values,
  and CI logs on a public repository can be read by anyone.
* **Changelog:** add a line for anything a user would notice to the top
  section of [CHANGELOG.md](CHANGELOG.md).
* **Docs:** keep them accurate about what is implemented. A new public
  function needs `@doc` and `@spec`. APIs marked experimental keep that
  label until a release says otherwise.

## License

By contributing, you agree that your contribution is licensed under the
[Apache License 2.0](LICENSE), like the rest of the project.

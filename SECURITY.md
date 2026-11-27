# Security policy

## Supported versions

| Version | Supported |
| --- | --- |
| 0.1.x (latest release) | yes |
| 0.1.0 release candidates (`v0.1.0-rc.*` Git tags) | no: upgrade to 0.1.x |

Fixes are released as a new patch version. Older versions aren't patched.

## Reporting a vulnerability

Please report it **privately**, not in a public issue or pull request:

1. Open the repository's
   [Security tab](https://github.com/HataluliRandima/trace_guard/security).
2. Choose **Report a vulnerability**.

Include the TraceGuard version, your Elixir/OTP and Phoenix versions, the
storage adapter, and the smallest configuration or request that shows the
problem. **Don't include real secrets or customer data**: fake values that
show where a secret leaks are enough.

TraceGuard has a single maintainer, so responses are best effort. You'll
get an acknowledgement once the report has been read, and the fix is
coordinated with you before an advisory is published.

## What counts

A vulnerability is anything where TraceGuard doesn't do what
[docs/security.md](docs/security.md) says it does, for example:

* a sensitive key, header or labelled secret that reaches a stored report
  unredacted;
* an event from one request attributed to another request's report;
* a way for a client to read reports, or to make TraceGuard change a
  response or swallow an exception;
* a stored report, database file or table readable more widely than
  documented.

The limitations [docs/security.md](docs/security.md) already lists aren't
vulnerabilities in TraceGuard. Examples: your application's logs aren't
sanitized, unlabelled secrets in exception messages aren't recognized, and
deletion from PostgreSQL is logical. Reports about them are still welcome
as ordinary issues.

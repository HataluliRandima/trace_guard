# Configuration reference

All options live under the `:trace_guard` application:

```elixir
config :trace_guard,
  ecto_telemetry_prefixes: [[:my_app, :repo]],
  redact_keys: ["card_number"]
```

Configuration is validated when the application starts. Invalid values and
unknown option names raise `ArgumentError`, so a typo stops the boot instead
of being silently ignored. Module-keyed entries (`config :trace_guard,
SomeModule, ...`) are ignored by the validator. The validated configuration
is cached in `:persistent_term`. Changing it at runtime with
`TraceGuard.Config.put!/1` is meant for tests: every change triggers a
global GC. After changing which events should be observed, call
`TraceGuard.Telemetry.attach/0`.

The defaults are conservative: nothing that commonly contains personal data
is captured unless you opt in.

| Option | Default | Description |
| --- | --- | --- |
| `:enabled` | `true` | When `false`, `TraceGuard.Plug` does nothing and no handlers are attached. |
| `:failure_status` | `500` | A request is reported when its final status is at least this. Exceptions that Plug maps to a lower status (for example `Ecto.NoResultsError` → 404) are not reported. Set it to `400` to include client errors. |
| `:max_events` | `100` | Maximum number of ordinary events kept per trace. Further events are counted in `events_dropped`. Lifecycle events (request start/stop, exceptions, error rendering) are always kept. |
| `:max_reports` | `50` | Maximum number of reports in the in-memory store. The oldest is evicted first. |
| `:redact_keys` | `[]` | Extra sensitive keys. They **extend** the built-in list and never replace it. Keys are normalized (see below). |
| `:capture_request_headers` | `["accept", "content-type"]` | Allow-list of request header names to record. Values are still redacted if the name is sensitive. |
| `:capture_path` | `false` | Record the raw `request_path`. Off by default because paths often contain identifiers or e-mail addresses. The route template (e.g. `/users/:id`) is always recorded. Query strings are never recorded. |
| `:capture_path_params` | `false` | Record the router's `path_params` (redacted). |
| `:capture_sql` | `false` | Record Ecto's SQL text. Parameter values are **never** recorded, but literals written directly into a query appear in the SQL text, which is why this is off by default. |
| `:capture_exception_message` | `true` | Record the exception message, truncated to `:max_string_length` and scrubbed for labelled secrets. Turn it off if your exceptions may contain personal data. |
| `:max_string_length` | `500` | Strings longer than this are truncated in reports. |
| `:max_stacktrace_frames` | `20` | Maximum number of stack frames kept. Frames never include argument values. |
| `:response_header` | `"x-traceguard-id"` | Response header that carries the trace ID, or `nil` to disable it. |
| `:incoming_header` | `nil` | Request header to read an upstream correlation ID from (for example `"x-correlation-id"` or `"traceparent"`). See below. |
| `:ecto_telemetry_prefixes` | `[]` | Telemetry prefixes of the Ecto repos to observe, such as `[[:my_app, :repo]]`. TraceGuard attaches to `prefix ++ [:query]`. |
| `:max_task_collectors` | `1_000` | Phase 2. Maximum number of traces that can propagate to tasks at the same time (one collector process each). Beyond that, `TraceGuard.wrap/1` returns the plain function and the report says task events are missing. **Read once at application start.** |
| `:task_drain_timeout` | `100` | Phase 2. Milliseconds a *failed* request waits for its task events when completing. Successful requests never wait. `0` makes draining effectively non-blocking (and usually empty). |
| `:task_collector_lifetime` | `300_000` | Phase 2. Maximum lifetime of a task collector in milliseconds, a safety net for requests that never complete. Task events of a request that runs longer are lost. |
| `:storage` | `TraceGuard.ReportStore` | Phase 3. The `TraceGuard.Storage` adapter that receives finished reports: a module, or `{module, opts}`. Phase 4 adds `{TraceGuard.Storage.SQLite, database: path, ...}` (optional `exqlite` dependency; options in [storage.md](storage.md#the-sqlite-adapter-persistent-phase-4)). Phase 6 adds `{TraceGuard.Storage.Ecto, repo: MyApp.Repo, ...}` (your app's PostgreSQL Repo; options in [storage.md](storage.md#the-ecto-postgresql-adapter-phase-6-experimental)). The adapter configured **at application start** is supervised by TraceGuard if it exports `child_spec/1`. See [storage.md](storage.md). |
| `:max_pending_reports` | `50` | Phase 3. Maximum report submissions queued for the default `ReportStore` (its mailbox bound). Beyond it, reports are refused with `{:error, :overloaded}` and a `[:trace_guard, :report, :dropped]` event. Read on every submission. |
| `:max_drop_records` | `1_000` | Phase 4. Maximum drop records (and, separately, pending marks) kept by `TraceGuard.DropLog` for `report_status/1` and `await_report/2`. Oldest evicted first. |
| `:drop_record_ttl` | `600_000` | Phase 4. Milliseconds (monotonic) after which a drop record or pending mark expires and the trace reads as `:unknown`. |

## Redaction

### Built-in sensitive keys

`password`, `authorization`, `token`, `access_token`, `refresh_token`,
`secret`, `api_key`, `cookie`, `private_key`.

### Key normalization

Keys are normalized before comparison: atom → string, camelCase →
snake_case, lower case, and any run of non-alphanumeric characters → `_`.

| Key as seen | Normalized |
| --- | --- |
| `:api_key` | `api_key` |
| `"X-Api-Key"` | `x_api_key` |
| `"apiKey"` | `api_key` |
| `"AUTHORIZATION"` | `authorization` |

A key is sensitive when a configured key's `_`-separated tokens appear
**contiguously** in its tokens. So `token` matches `csrf_token` and
`access_token` but not `tokenizer`, and `api_key` matches `x_api_key`. This
deliberately errs towards over-redaction. String keys are never converted to
atoms.

### What is redacted

The whole report is traversed: maps (atom or string keys), lists, and
`{key, value}` tuples such as header lists. Values of sensitive keys become
`"[REDACTED]"`. The exception message is also scrubbed for `key=value`,
`key: value`, `"key": "value"` and `key => value` patterns that use a
sensitive key, and for `Bearer …` / `Basic …` credentials.

Redaction runs inside the request process, before the report is stored, so
nothing unredacted is ever stored or exported. The report's `redaction`
section records the keys that were applied and how many values were
replaced.

## Incoming correlation IDs

Caller-supplied IDs are untrusted. When `:incoming_header` is set,
TraceGuard:

* accepts the value only if it matches `^[A-Za-z0-9._:-]{1,128}$` (a W3C
  `traceparent` value matches), and otherwise ignores it;
* records it as `request.incoming_id = %{"header" => ..., "value" => ...}`,
  separately from `trace_id`;
* never uses it as the trace ID or as a key into the report store.

The trace ID itself is always generated internally from 128 bits of
`:crypto.strong_rand_bytes/1`.

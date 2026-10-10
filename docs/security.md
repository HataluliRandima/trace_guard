# Security and privacy

What TraceGuard captures, what it protects, and what it does **not**.

## What is captured

| Data | Captured | Notes |
| --- | --- | --- |
| HTTP method, route template (`/users/:id`), status, timing | always | |
| Raw request path | only with `capture_path: true` | Paths often contain identifiers. |
| Path parameters | only with `capture_path_params: true` | Redacted by key. |
| Request headers | allow-list only (`capture_request_headers`, default `accept`, `content-type`) | Sensitive names are redacted even if allow-listed. |
| Query string, request body, cookies | **never** | |
| Ecto query timing, table, row count, outcome, calling function | when `ecto_telemetry_prefixes` is set | |
| SQL text | only with `capture_sql: true` | Literals written into a query appear in it. |
| SQL parameters, result rows | **never** | |
| Exception module, message, stack frames (module/function/arity/file/line) | yes; message can be disabled (`capture_exception_message: false`) | Frames never include argument values. The message is scrubbed (below). |
| Throw values, exit reasons | **never inspected** | Described structurally (for example `throw of a map value`). |
| Task and GenServer arguments | **never** | Only lifecycle events and the request's leading atom (`operation`). |
| Client correlation ID | only with `incoming_header` | Validated (`[A-Za-z0-9._:-]`, 1–128 characters), stored separately from the trace ID. |

## Redaction

* **Key-based, recursive**, over maps, lists and `{key, value}` tuples, on
  the finished report, *before* it leaves the request process. No adapter
  ever receives unredacted data. Keys are normalized (`X-Api-Key`, `apiKey`
  and `:api_key` are equivalent) and matched by token (`csrf_token` matches
  `token`; `tokenizer` doesn't).
* **Built-in keys:** `password authorization token access_token
  refresh_token secret api_key cookie private_key`. `redact_keys` adds more;
  it can't remove the built-ins.
* **Exception messages** are scrubbed for labelled secrets (`key=value`,
  `key: value`, `"key": "value"`, `key => value` with a sensitive key, and
  `Bearer …` / `Basic …`). An **unlabelled** secret in a message (`"card
  4242… declined"`) is not recognized. Set
  `capture_exception_message: false` if that matters to you.

## What TraceGuard does NOT protect

* **Your application's logs.** TraceGuard's redaction applies only to
  TraceGuard's reports. Phoenix, Plug, Bandit, Cowboy, Ecto, OTP (for example
  a GenServer's crash report) and your own `Logger` calls log whatever they
  log, including **raw exception messages containing secrets**. This was
  verified: in the external integration test, both Bandit's and Cowboy's
  crash logs contained the raw API key that the report had redacted.
  TraceGuard doesn't change, filter or sanitize any logging.
* Data you put into a report's allow-listed fields yourself, for example a
  secret in a route template or in an allow-listed header under a
  non-sensitive name.
* Copies outside TraceGuard: backups, filesystem snapshots, crash dumps,
  `:observer` or remote shells (which can read any process state).

## Identifiers and lookup

* **Trace IDs** are 128 random bits from `:crypto.strong_rand_bytes/1`,
  hex-encoded, and carry no request data. Lookups accept only well-formed
  IDs (`^[0-9a-f]{32}$`); anything else is rejected before the store is
  touched.
* **The `x-traceguard-id` response header** exposes the trace ID to the
  client. This is safe only because TraceGuard has **no HTTP lookup**: every
  lookup (`get_report/1`, `list_reports/1`, `report_status/1`,
  `await_report/2`) is a node-local Elixir function. If you build an
  endpoint that serves reports, as the demo's dev-only `/dev/traces` does,
  restrict it to development or authenticated operators; never expose it
  publicly. Disable the header with `response_header: nil`.
* **Correlation IDs** are client-controlled labels. They help find reports
  but grant nothing; filters match exactly.

## Retained state and storage

* **Bounds:**
  * in memory, at most `max_reports` retained and `max_pending_reports`
    queued;
  * at most `max_drop_records` drop records, each expiring after
    `drop_record_ttl`;
  * per trace, `max_events`.
* **The in-memory store** is lost on restart; nothing is written to disk.
* **The SQLite adapter** (development and testing):
  * new database files are created `0600` (owner only; `:file_mode`), and
    SQLite's `-wal`/`-shm` files inherit that mode;
  * existing files keep their permissions;
  * deleted, cleared and cleaned-up reports are zeroed (`secure_delete`), and
    the WAL is truncated afterwards;
  * there is no encryption at rest, so treat the file as sensitive
    diagnostic data, and keep it out of version control and backups you
    share.
* **Storage failures** (overload, adapter errors, a locked or missing
  database) never change the application's response or exception. They are
  counted, emitted as `[:trace_guard, :report, :dropped]`, and recorded for
  `report_status/1`. TraceGuard logs nothing per dropped report, so a
  failure storm can't become a log storm.

## Configuration validation

Unknown or ill-typed `:trace_guard` options raise at boot. `TraceGuard.Storage.SQLite` rejects unknown or invalid options when it starts.

## Reporting a vulnerability

Please report security issues privately to the maintainer through the
GitHub repository's security advisories, rather than in a public issue.

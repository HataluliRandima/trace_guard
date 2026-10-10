# Phase 3 review: storage, overload and discovery

## Inspection (before any change)

The Phase 2 code was re-read and re-run (80 tests + 1 doctest; demo 13; all
passing) rather than taken from the Phase 2 summary. What the storage path
actually did:

| # | Finding | Evidence |
| --- | --- | --- |
| 1 | `ReportStore.put/1` was a `GenServer.cast/2` to a registered name. Nothing bounded the store's mailbox. | Measured: with the store suspended, 10,000 submissions queued 10,000 messages (about 19 MB in the store process). |
| 2 | `put/1` returned `:ok` even when no store was running (a cast to a missing name is silently dropped), and `EventCollector.finish/1` always returned `{:reported, id}`. TraceGuard could claim success for reports it lost. | Code. |
| 3 | `get/1` and `list/0` were `GenServer.call/2` with the default 5 s timeout and no handling. A dead or stuck store made `TraceGuard.get_report/1` **exit in the caller**. | Code. |
| 4 | `list_reports/0` copied every retained report (up to `max_reports` full reports) out of the store to build summaries. | Code. |
| 5 | Failures without a response header (throw, exit, endpoint-level) could only be found by scanning `list_reports/0`, whose summaries had no correlation fields. Tests polled with sleeps. | Code, tests. |
| 6 | Storage was hard-wired: the engine called `ReportStore.put/1` directly. | Code. |

The resource bounds and failure semantics otherwise matched the Phase 2
review: per-trace event caps, task collector bounds, and no rescue of
application errors.

## Changes

* **Bounded admission** in front of `ReportStore` (`:max_pending_reports`,
  default 50) using an `:atomics` counter per store incarnation. See
  [storage.md](storage.md#overload-policy-default-traceguardreportstore).
* **Honest outcomes**: `finish/1` returns `{:reported, id}` only when
  accepted, otherwise `{:dropped, id, reason}`. There are new
  `[:trace_guard, :report, :stored | :dropped]` events and submission
  counters (`TraceGuard.report_stats/0`).
* **Reads never exit**: `{:error, :unavailable}`, `[]` or
  `%{available: false}`, with a bounded wait.
* **`TraceGuard.Storage` behaviour** plus facade. `ReportStore` is the
  default adapter. There is a synchronous test adapter and a shared contract
  suite.
* **Discovery**: summaries gain `kind`, `captured_by`, `request_id` and
  `incoming_id`, and are built inside the store (no full-report copies).
  `list_reports/1` takes exact-match filters. `await_report/2` replaces
  polling. The demo sends `x-correlation-id`, and its dev-only
  `/dev/traces` accepts the same filters.
* **Benchmark**: paired, alternating rounds with a visible drift column;
  report building and retention measured separately; commit and settings
  recorded. See [performance.md](performance.md).

### Why the missing header is not "fixed"

For throws, exits and endpoint-level exceptions, `Phoenix.Endpoint`'s
error handling renders the response with the conn that **entered the
endpoint**, before any endpoint plug ran (verified in Phoenix 1.8.15
`render_errors.ex`; see [architecture.md](architecture.md#exception-capture)).
Plug's `WrapperError`, which would carry TraceGuard's conn, is only used for
`:error` exceptions. A response header set by `TraceGuard.Plug` therefore
can't reach those responses without wrapping or patching the endpoint, and
TraceGuard does neither. The same is true of `Plug.RequestId`'s
`x-request-id`. Phase 3 instead makes those reports reliably findable by
identifiers that *do* survive: the client's own correlation ID, and the
request ID and trace ID in the Bandit crash log line.

### Why a behaviour, and why this small

The engine needs exactly one operation (`put`), and the public API needs
four more (`get`, `list`, `delete`, `clear`), plus stats. The facade holds
everything that must be identical for all adapters: exception safety,
counters, events and summaries. That keeps adapters small: the test adapter
is about 70 lines, including its failure simulation. Supervision is optional
(`child_spec/1`). Not abstracted, on
purpose: eviction policy, admission mechanism and serialization. Those are
adapter internals, constrained only by "bounded" and "report what you
refused".

## Bounds after Phase 3

| State | Bound | Test |
| --- | --- | --- |
| Store mailbox (report submissions) | ≤ `max_pending_reports` | `report_store_test`: 200 concurrent submitters, suspended store; queue length is exactly 10 with `max_pending_reports: 10`; 190 refusals, each with a `:dropped` event |
| Retained reports | ≤ `max_reports`, oldest evicted | `report_store_test`, contract suite (both adapters) |
| Report size | bounded by `max_events`, `max_string_length`, `max_stacktrace_frames` | measured: 15 KB (demo checkout), about 122 KB (near-worst case) |
| Request-path waiting on storage | none | `put` is one atomic add and one `send/2` |
| Reader waiting | `timeout` (`await_report/2`) or 5 s (`:call_timeout`) | `report_store_test` (suspended store; stopped store) |
| Admission counter after a crash | replaced; old pending count added to `:lost` | `report_store_test` "a store restart loses queued submissions, counts them, and recovers" |
| Per-trace events, task collectors, contexts | unchanged from Phase 2 | Phase 2 tests (all still pass) |

## Failure semantics

| Case | Behaviour | Test |
| --- | --- | --- |
| Store overloaded | Report refused (`:overloaded`); response and exception unchanged | `report_store_test` "an overloaded store drops the report but not the request's semantics" |
| Store stopped | `:unavailable`; reads return instead of exiting; requests unchanged | `report_store_test` "with the store stopped..." |
| Store killed with queued reports | Queued reports lost and counted; new incarnation accepts immediately | `report_store_test` restart test |
| Adapter raises, exits, overloads, or returns a non-contract value | `:dropped` with a reason; `assert_error_sent/2` proves the original exception was rendered and re-raised | `storage_test` |
| Adapter emits telemetry while storing | Not recorded in any trace; exactly one report | `storage_test` "events emitted while storing never enter any trace" |

## Security review (Step 7)

* **Identifiers carry no request data.** Trace IDs are 128 random bits.
  Summaries contain only fields of the redacted report. A test checks that a
  bearer token and a query-string password sent with a request appear in
  neither the summary nor the report.
* **Lookup boundary.** All lookups are node-local Elixir functions; nothing is
  served over HTTP by TraceGuard. Filters are exact matches over the bounded
  retained set, so a correlation ID can't match a different request's ID by
  prefix or time window (tested). Correlation IDs are client-controlled
  labels: they help find reports but grant nothing.
* **Overload doesn't cross requests.** Each submission is a whole, already
  redacted report keyed by its own trace ID. A refused report is discarded,
  never merged or substituted, and the refusal event names only that trace ID.
* **Redaction before export is unchanged.** Adapters receive only the final
  redacted report; the contract says so and the engine has no other path.
* **No indefinite retention.** `max_reports` retained, `max_pending_reports`
  queued, nothing on disk. A restart clears the store.
* **No recursive diagnostics.** The trace context is removed before
  `Storage.put/1`. TraceGuard never handles its own `[:trace_guard, ...]`
  events and doesn't log per dropped report (tested with an adapter that
  emits Ecto-shaped events while storing).
* **Logging is out of scope and unchanged.** TraceGuard's redaction applies
  only to its reports. Phoenix's and Bandit's own log output (for example
  Bandit's crash log containing a raw exception message with a secret) is not
  sanitized by TraceGuard. Phase 3 deliberately did not modify logging.

## Public interface changes

All are additive or bug fixes. No existing function was removed or renamed.

* New: `TraceGuard.await_report/2`, `TraceGuard.report_stats/0`,
  `TraceGuard.delete_report/1`, `TraceGuard.list_reports/1` (filters; the
  `/0` form still works), the `TraceGuard.Storage` behaviour and facade, and
  the telemetry events `[:trace_guard, :report, :stored | :dropped]`.
* New config: `:storage` (default `TraceGuard.ReportStore`) and
  `:max_pending_reports` (default 50).
* Changed return values (bug fixes): `get_report/1` and `export_json/2` can
  return `{:error, :unavailable}` instead of exiting; `clear_reports/0` can
  return `{:error, :unavailable}`; `EventCollector.finish/1` can return
  `{:dropped, id, reason}`; `list_reports` summaries gain four keys.
* `TraceGuard.ReportStore`'s old direct functions (`put/1`, `get/1`,
  `list/0`, `clear/0`) are replaced by the behaviour callbacks (`put/2` and
  so on). They were documented as internal storage; use the `TraceGuard`
  functions.

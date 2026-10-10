# Phase 2 review: lifecycle, bounds and security

This is the audit carried out at the start of Phase 2, with the issues it
found and how each was resolved. Phase 2 also re-checked memory bounds and
security after adding Task propagation.

## Request lifecycle (as audited, still valid)

1. **Create.** `TraceGuard.Plug`'s `call/2` generates a 128-bit trace ID and puts
   a `%TraceGuard.Context{role: :request}` in the request process's
   dictionary. It replaces any stale context left by an earlier request in
   the same process; Phase 2 also stops a stale context's task collector.
2. **Access.** Telemetry handlers run in the emitting process and append
   allow-listed events through `TraceGuard.EventCollector`, only if that
   process has a context. Phase 2 adds task contexts (`role: :task`) in
   processes running `TraceGuard.wrap/1` functions; their events are sent to
   the trace's collector.
3. **Complete.** `TraceGuard.Plug`'s `before_send` callback, or the
   `[:phoenix, :error_rendered]` handler for failures outside the router,
   calls `EventCollector.finish/1`. This removes the context. For a failure,
   it merges task events and builds, sanitizes and redacts the report in the
   request process, then casts it to `TraceGuard.ReportStore`.
4. **Remove.** The context is always deleted at completion. A request that
   is never completed (see the limitations) leaves its context until the
   process serves another request or exits.

## Audit findings

| # | Finding | Severity | Resolution |
| --- | --- | --- | --- |
| 1 | `TraceGuard.Telemetry.attach/0` crashed with `{:error, :already_exists}` when called concurrently, because detach + attach is not atomic. Found when Benchee called it from parallel processes. | Bug | Fixed: serialized with a node-local `:global.trans/3` lock. A regression test fails on the old code (verified) and passes now. |
| 2 | Report building was the dominant cost of a failed request: +1.8–2.1 ms and +842 KB per report. The causes were repeated key splitting, regexes recompiled per call, and `:application.get_application/1` per frame. | Performance | Fixed: allocation is now 212–218 KB, and latency +0.7–0.9 ms in quiet runs. See [performance.md](performance.md). |
| 3 | `inspect/1` on module names was the largest cost on simple requests. | Performance | Fixed (`Atom.to_string/1`). |
| 4 | Ecto events arriving after the buffer was full still built their metadata map. | Performance | Fixed: capacity is checked first. |
| 5 | For `throw` and `exit` failures, `failure.message` was `inspect(reason)`. With Tasks this embeds whole exception structs (all fields), stack traces, `Task` structs and PIDs. Only *labelled* secrets were scrubbed. | **Security** | Fixed: exits and throws are now described structurally. Crashed processes give the exception module plus its message (scrubbed); `Task.await`-style exits are unwrapped; other reasons and thrown values are reported only by type. Tests cover a struct with an unlabelled card number. |
| 6 | Handlers do no blocking I/O. The only side effect is `Logger.warning/1` when TraceGuard itself fails internally, which emits no telemetry events, so it can't recurse. | OK | Test added: an internal handler error is logged, records nothing, and leaves the handler attached. |
| 7 | `ReportStore.put/1` is a cast. Under a burst of failures, the store's **mailbox** is not bounded, only the number of stored reports is. | Known limitation | Documented. A proper fix (load shedding) is proposed for Phase 3. |
| 8 | `Logger.metadata(trace_guard_id: ...)` stays set in a Bandit keep-alive process after its request completes. | Deliberate | Kept on purpose: Bandit's error log for the re-raised exception is written *after* completion, and the ID is what links that log line to the report. The next request overwrites it. |

## Memory and failure handling (Step 5)

| State | Bound | Verified by |
| --- | --- | --- |
| Request event buffer | `:max_events` ordinary events plus a few lifecycle events | `event_collector_test`, `phoenix_integration_test` |
| Task events per trace | `:max_events` sends in total across all task processes (shared `:atomics` budget); merged total re-capped at `:max_events` | `propagation_test` "task events are bounded across all task processes" (4 tasks × 502 events, `max_events: 20`) |
| Active request contexts | One per request process; removed at completion; replaced by the next request in the same process | `event_collector_test`, `concurrency_test` |
| Task contexts | Exist only while a wrapped function runs; restored or removed in `after`, also on failure | `propagation_test` "the task context is removed when the wrapped function returns or fails" |
| Task collectors | ≤ `:max_task_collectors`; each stops at completion, owner exit, or `:task_collector_lifetime`; a stale request context stops its collector | `propagation_test` lifecycle tests (each uses monitors, no sleeps) |
| A failed or stuck child | Never blocks completion: the drain waits at most `:task_drain_timeout`; a crashed child simply stops sending | `propagation_test` "draining never waits longer than :task_drain_timeout" (suspended collector) |
| Report store | ≤ `:max_reports` reports (mailbox: see finding 7) | `report_store_test` |
| Module → application index | One `:persistent_term` map, built once | — |
| Cached scrub regexes | One `:persistent_term` entry per distinct sensitive-key list (changes only with config) | — |
| TraceGuard's own errors | Rescued in every handler and in `before_send`; never replace application errors; never emit telemetry | `telemetry_test` |
| Application errors | Never rescued by TraceGuard; `wrap/1` re-raises with the original kind, reason and stacktrace | `propagation_test` "preserves results, raises, throws and exits exactly", "linked task crashes keep their normal exit reason"; Phase 1 `assert_error_sent` tests |

## Security review (Step 6)

* **Propagation copies no process-local data.** The token is
  `{trace_id, collector pid, atomics ref}`. A test puts a secret in the
  parent's process dictionary and Logger metadata, and checks that neither
  is visible in the task.
* **Child metadata is allow-listed.** Task events go through the same
  handlers. The only task-specific events are `task.start`, `task.stop`
  (duration) and `task.exception` (`kind` and exception module only, no
  message).
* **Redaction before export is unchanged.** Merging happens before
  sanitization and redaction, so task events are redacted like all others.
  The demo's leak checks now cover six secrets across two reports (one with
  task events).
* **No raw SQL parameters or exception structures.** Parameters were never
  captured. Finding 5 closed the last path through which whole exception
  structs could reach a report.
* **Application semantics are preserved.** See the table above.
* **Your own logs are not sanitized.** TraceGuard's redaction applies only to
  TraceGuard's reports. Phoenix, Bandit, Ecto and your own `Logger` calls keep
  logging whatever they log, including raw exception messages that contain
  secrets. The demo's own test output shows Bandit logging the merchant key
  in plain text. TraceGuard does not protect secrets in any logging system.

## Public interface changes in Phase 2

All additive except the two marked as behaviour changes:

* **New:** `TraceGuard.wrap/1` (delegates to `TraceGuard.Propagation.wrap/1`).
* **New config:** `:max_task_collectors`, `:task_drain_timeout`,
  `:task_collector_lifetime` (see [configuration.md](configuration.md)).
  `:max_task_collectors` is read when the application starts.
* **New report fields:** `events[].process` and top-level `tasks`. The
  schema stays `traceguard.report/v1` because the changes are additive.
* **Behaviour change:** `events[].seq` is now the position in the merged,
  time-ordered timeline (1..n). Before, it was the observation counter, which
  could have gaps after dropped events.
* **Behaviour change (security):** `failure.message` for `throw`/`exit` no
  longer contains the inspected value; `failure.exception` can now name the
  exception inside an exit (e.g. a crashed task).
* **New internal fields** on `TraceGuard.Context` (`role`, `tasks`) and new
  functions `EventCollector.accepting?/0` and `record_dropped/0`, used by the
  handlers.
* **Fixed:** `TraceGuard.Telemetry.attach/0` is safe to call concurrently.

# Performance

TraceGuard's overhead, measured on the demo application. Every figure here
was produced by the commands below. Raw outputs are in
[`demo/bench/results/`](../demo/bench/results/).

> These are measurements of **one laptop running WSL2**, not production
> performance figures. Treat the latency columns as order-of-magnitude
> indications. Memory figures are deterministic and repeat exactly between
> runs.

## How to run

```bash
cd demo
MIX_ENV=bench mix bench.requests                       # ~4 minutes; writes bench/results/latest.md
MIX_ENV=bench mix run --no-start bench/event_cost.exs  # ~20 seconds; allocation per event
```

`bench.requests` creates and migrates a separate SQLite database
(`trace_guard_demo_bench.db`), reseeds the same two products, and runs
`bench/request_overhead.exs`. Environment variables:

* `BENCH_ROUNDS` (default 3)
* `BENCH_WARMUP`, `BENCH_TIME`, `BENCH_MEMORY_TIME` (seconds per
  measurement; defaults 1, 3 and 1)
* `BENCH_CONCURRENT=N` adds an N-process pass over the read-only scenarios
* `BENCH_OUTPUT`

For comparable numbers: run on AC power, keep the editor and language server
idle (it recompiles on file changes), and don't edit files during a run.

## Method (Phase 3)

* **Same application, same requests, two modes.** Only `enabled` differs
  between "off" and "on" (and, for scenario 3b, `storage`). Everything else is
  the demo's real configuration (`capture_sql: true`, five allow-listed
  headers, 100-event buffer). When disabled, `TraceGuard.Plug` returns the conn
  untouched, no handlers are attached, and `TraceGuard.wrap/1` returns its
  function unchanged.
* **Production-like environment.** `MIX_ENV=bench` (`config/bench.exs`): no
  code reloader, no SQL sandbox, Logger at `:error`, no dev routes.
* **In-process dispatch.** Requests go through
  `TraceGuardDemoWeb.Endpoint.call/2` with `Plug.Test`, the same code path
  as under Bandit but without sockets. The test adapter's messages are drained
  after every request.
* **Paired, alternating rounds.** Each scenario is measured in
  `BENCH_ROUNDS` rounds. In every round, off and on run back to back, and the
  order flips every round and every scenario, so a slowly drifting machine
  doesn't systematically favour one mode. Δ is computed **within each round**
  and reported as the median and range across rounds.
* **Drift is shown, not hidden.** "Off range (drift)" is the spread of the
  disabled medians across rounds. If it is wide, the machine moved during the
  run, and latency Δs from that run are unreliable.
* **Build vs retention, separated.** Scenario 3a stores the report in the
  real `ReportStore`. Scenario 3b builds the identical report and hands it to
  a discarding adapter. Separately, "submit + retain" times
  `TraceGuard.Storage.put/1` until the store's `:stored` event, and the
  report's retained size is recorded.
* **[Benchee](https://hex.pm/packages/benchee) 1.5.1** per measurement. It
  reports the median, the 99th percentile, throughput (`1 / average`) and
  memory (the median bytes allocated **by the request process**). A report
  sent to the store is copied into the store's heap, so it is not in this
  figure; that is why it appears separately.
* **Sanity checks** run before any timing. Both modes must return identical
  statuses, and only the enabled mode may store a report.
* **One-time costs** are measured separately and excluded: application
  start, and the first request of each scenario after boot.
* **Provenance.** Each output records its commit (and whether the working
  tree was dirty), versions and all settings.

### Scenarios

| # | Request | What it exercises |
| --- | --- | --- |
| 1 | `GET /api/health` | Fixed per-request cost; no database. |
| 2 | `GET /api/catalog` | 4 Ecto queries in the request process. |
| 3a | `POST /api/checkout` | Transaction with 5 queries, an exception, and a report **built, redacted and stored**. |
| 3b | same | Same, but the report is **discarded** by a no-op adapter. |
| 4 | `GET /api/inventory/audit` | 151 queries: fills the 100-event buffer and drops 51+ events. |
| 5 | `GET /api/catalog/parallel` | The same 4 queries in 4 Tasks wrapped with `TraceGuard.wrap/1`. |

### What SQLite-based measurements can and cannot show

* SQLite runs in-process through a NIF, with no network round trip. Query
  latency here is much lower than PostgreSQL's (no network, no server
  process), so TraceGuard's fixed cost is a *larger fraction* of a request
  here than it would be against a networked database. The absolute
  per-request and per-event costs are what transfer.
* SQLite serializes writers, so concurrent write scenarios measure lock
  contention. The concurrent pass is therefore opt-in and read-only.
* **Not tested:** PostgreSQL, Cowboy, real network I/O, multiple nodes,
  long-running load and memory growth over hours. No claims are made about
  them.

## Environment

Elixir 1.17.0, Erlang/OTP 26.1.2 (JIT), Linux (WSL2), 12 × Intel Core
i5-1245U, 7.6 GB RAM, SQLite via `ecto_sqlite3` 0.25 / `exqlite` 0.42,
Phoenix 1.8.15, Bandit 1.12.5 (not used for dispatch).

## Phase 3 results

Two full runs with the default settings (3 rounds; 1 s warm-up, 3 s timing,
1 s memory per measurement). The raw files are
[`phase3-run1.md`](../demo/bench/results/phase3-run1.md) and
[`phase3-run2.md`](../demo/bench/results/phase3-run2.md), which also hold
per-round data. Both were run from a working tree with the Phase 3 changes
uncommitted.

| Scenario | Δ median (run 1 / run 2) | Δ range across rounds (run 1 / run 2) | Off drift (run 1 / run 2) | Δ memory (both runs) |
| --- | --: | --: | --: | --: |
| 1. health | +5.2 / +11.8 µs | +5.1…+7.7 / +11.0…+14.1 µs | 9.7–11.4 / 11.0–17.8 µs | +5.6 KB |
| 2. catalog | +113.5 / +118.1 µs | +83…+1460 / +84…+150 µs | 275–348 / 288–343 µs | +11.2 KB |
| 3a. checkout, stored | +1162 / +1072 µs | +393…+1369 / −107…+2962 µs | **279–870** / **461–1732** µs | +218.1…+218.4 KB |
| 3b. checkout, discarded | +1732 / +1709 µs | +644…+3354 / +1152…+3031 µs | 481–1412 / 371–488 µs | +218.5 KB |
| 4. audit | +1321 / +457 µs | +1247…+32975 / −1364…+20466 µs | 16818–17488 / 19409–20387 µs | +117.2 KB |
| 5. parallel catalog (wrap) | +322 / +231 µs | +243…+453 / −90…+250 µs | 694–846 / 546–789 µs | +6.4 KB |

Report retention, measured separately:

| | Run 1 | Run 2 |
| --- | --: | --: |
| Submit + retain one checkout report (until `:stored`), median | 7.8 µs | 14.2 µs |
| Same, p99 | 162 µs | 202 µs |
| Retained size of that report (Erlang term / JSON) | 15,296 B / 5,661 B | 15,296 B / 5,649 B |

### Reading these results

* **The machine was noisy during both runs.** The drift column shows it: the
  *disabled* checkout median moved between 279 and 870 µs within run 1, and
  between 461 and 1732 µs within run 2. The disabled catalog median was
  275–348 µs, against 133–141 µs in the quiet Phase 2 runs. Latency Δs from
  these runs are therefore wide. Before Phase 3 the same noise would have
  been invisible; the drift column now makes it explicit.
* **Request-side submission cost is below the noise floor.** 3a and 3b
  allocate the same in the request process (218.1–218.5 KB). Their latency
  difference flips sign between runs (3a − 3b = −772 µs and −159 µs, which
  is not physically meaningful because 3a does strictly more work). The
  submission is one atomic add and one `send/2`.
* **Retention costs the store about 8–14 µs per report** (median), off the
  request path.
* **Memory figures are reliable** and repeat between runs and rounds.
  Compared with Phase 2, catalog shows +11.2 KB (Phase 2: 9.2–9.4 KB) and
  audit +117.2 KB (Phase 2: 132.8 KB). Phase 3 doesn't touch the per-event
  path, and the measurement procedure changed (separate shorter Benchee runs
  per measurement), so these differences are not attributed to code changes.
* **Fixed cost on a successful request:** +5.2 µs in run 1 (tight range
  +5.1…+7.7 µs). Run 2 measured +11.8 µs on a slower machine state (its
  disabled baseline was itself 11.0–17.8 µs), plus 5.6 KB.

### Memory bound of the report store

At the defaults (50 retained + 50 queued), the report store holds at most
100 reports. Measured sizes: the demo checkout report is about 15 KB, so
about 1.5 MB at the defaults. A near-worst-case report (100 events with
maximum-length SQL, 20 stack frames, a maximum-length message) is about
122 KB, so about 12 MB at the defaults. Lower `max_reports`,
`max_pending_reports` or `max_events` to shrink the bound.

## Phase 2 results (previous method, kept for history)

These runs used the Phase 2 method: one Benchee run per scenario and mode, in a
fixed off-then-on order, with 2 s warm-up, 5 s timing and 1 s memory. The
benchmark ran at three stages, twice each:

* **Phase 1 baseline:** Phase 1 code, plus the `Telemetry.attach/0`
  concurrency fix (without it the benchmark crashed; see below).
* **Optimized:** after the measured optimizations, before Task propagation.
* **Final:** the delivered Phase 2 code. The only change after these runs
  was the wording of one static `limitations` string in reports.

"Δ" is enabled minus disabled, within the same run.

### Sequential: Δ median latency (run 1 / run 2)

| Scenario | Phase 1 baseline | Optimized | Final |
| --- | --: | --: | --: |
| 1. health | +6.6 / +6.7 µs | +5.8 / +6.0 µs | +9.2 / +7.0 µs |
| 2. catalog (4 queries) | +39.2 / +37.6 µs | +41.6 / +31.4 µs | +232.2 / +46.9 µs ⚠ |
| 3. checkout (failure + report) | +1828 / +2067 µs | **+863 / +724 µs** | +1459 / +1153 µs ⚠ |
| 4. audit (151 queries) | −565 / +546 µs | +548 / −212 µs | +47111 / −926 µs ⚠ |
| 5. parallel catalog (wrapped tasks) | – | – | +223 / +50 µs ⚠ |

### Sequential: Δ memory allocated per request (identical in both runs)

| Scenario | Phase 1 baseline | Optimized | Final |
| --- | --: | --: | --: |
| 1. health | +6.0 KB | +5.2 KB | +5.4 KB |
| 2. catalog | +14.4 KB | +9.7 KB | +9.2–9.4 KB |
| 3. checkout (report built) | **+842 KB** | **+212 KB** | +218 KB |
| 4. audit | +282.5 KB | +98.9 KB | +132.8 KB |
| 5. parallel catalog | – | – | +6.3 KB (request process only) |

### Absolute medians, disabled → enabled (final, run 2)

| Scenario | Disabled | Enabled | p99 disabled | p99 enabled |
| --- | --: | --: | --: | --: |
| 1. health | 11.2 µs | 18.2 µs | 170.8 µs | 255.8 µs |
| 2. catalog | 349.8 µs | 396.7 µs | 2502.6 µs | 2252.2 µs |
| 3. checkout | 440.2 µs | 1593.4 µs | 2182.9 µs | 5551.7 µs |
| 4. audit | 18124.4 µs | 17198.9 µs | 72939.5 µs | 33469.0 µs |
| 5. parallel catalog | 598.1 µs | 648.2 µs | 2708.8 µs | 3339.5 µs |

The concurrent pass (4 processes) produced deltas for catalog and audit that
swing by ±50% between runs in both directions, because SQLite contention
dominates. Health stays consistent: +6.3 to +14.2 µs per request. See the
result files for the full tables.

### Per-event allocation (`bench/event_cost.exs`, final code)

| Measurement | Bytes |
| --- | --: |
| `:telemetry.execute/3` with a no-op handler (telemetry itself) | 200 |
| Query event emitted outside any trace | 320 |
| Empty trace (context start + take) | 720 |
| **Per retained query event** (includes telemetry dispatch) | **1,086** |
| **Per dropped query event** (buffer full) | **368** |

### One-time costs (final, run 1)

* `Application.ensure_all_started(:trace_guard)`, including its dependencies:
  about 20 ms. Re-validating config and re-attaching handlers: 132 µs.
* The first request per scenario after boot: 5–32 ms, mostly lazy module
  loading. A release in embedded mode preloads modules.

## Reading the results honestly

* **Noise.** ⚠ marks latency deltas from runs where the machine was
  measurably slower: the *disabled* medians were 1.3–2.6× those of earlier
  runs, for example catalog at 187–350 µs versus 133–141 µs. These runs
  happened after a long series of benchmarks and while the editor's Elixir
  language server was recompiling. A +47 ms audit delta in one run and −0.9 ms
  in the next shows noise, not TraceGuard. Before these two runs, I discarded
  two final-stage runs: one pair predated the last code change (the
  exit/throw description fix), and one pair was equally noisy.
* **Memory is the reliable signal.** It repeated byte for byte across runs.
* **What is solid:**
  * The fixed cost on a successful request is about 6–9 µs and 5.4 KB.
  * Each retained query event costs about 1.1 KB, and each dropped one
    0.37 KB.
  * Building and redacting a report costs about 0.7–0.9 ms (quiet runs)
    and 218 KB.
  * The optimizations cut report-building allocation by 75% (842 → 212 KB)
    and buffer-overflow allocation by 65% (282 → 99 KB).
* **Unexplained.** Audit allocation rose from 98.9 KB (optimized) to
  132.8 KB (final). The per-event code paths changed by a few bytes per event
  (one map key, two struct fields), which accounts for under 5 KB. The rest
  wasn't isolated. A plausible cause is heap-size quantization in Benchee's
  GC-based memory measurement, but it is not verified.
* **Not measured:** memory in other processes (the report store and task
  collectors), Cowboy, PostgreSQL, multi-node setups, and long-running
  memory growth.

## What the optimizations were (measured with `:eprof`)

Profiling Phase 1's failure path showed that almost all of TraceGuard's cost
was report building, not event collection:

1. `Redactor.sensitive?/2` re-split every configured key into tokens for
   every key it checked: about 2,400 `String.split` calls per report. Keys
   are now split once per redaction pass, and verdicts are memoized per
   distinct key within the pass.
2. `:application.get_application/1` scans the application controller table
   on each call: about 21 µs per stack frame, or about 340 µs per report. It
   was replaced by a module → application index, built once from the loaded
   applications.
3. The message-scrubbing regex was recompiled for every report. It is now
   compiled once per key set.
4. `inspect/1` on module names (route plug, Ecto repo) validates every alias
   segment, and was the largest TraceGuard cost on simple requests. It was
   replaced by `Atom.to_string/1` plus prefix stripping.
5. Ecto events arriving after the buffer is full no longer build their
   metadata before being dropped.
6. Sanitization skips grapheme counting for strings shorter than the limit.

## Proposed initial overhead budget

These figures are derived from the quiet measurements above, for the
reference machine and demo workload. They are guard rails for regressions,
not promises:

| Path | Budget | Measured | Trade-off |
| --- | --: | --: | --- |
| Fixed cost per successful request (median) | ≤ 10 µs, ≤ 8 KB | 6–9 µs, 5.4 KB | Trace ID from `:crypto.strong_rand_bytes/1` is kept: unguessable IDs matter more than ~2 µs. |
| Per retained event | ≤ 1.5 KB | 1.09 KB | Allow-listed metadata copies are the price of never storing raw telemetry maps. |
| Per dropped event | ≤ 0.5 KB | 0.37 KB | |
| Report build on failure | ≤ 1 ms, ≤ 256 KB | 0.72–0.86 ms*, 218 KB | Built synchronously in the failing request so that only redacted data leaves the process; this adds latency to responses that are already failing. |
| `wrap/1` per request (request process) | ≤ 8 KB | 6.3 KB | Latency not budgeted yet: collector start and message passing were within noise (+50 to +223 µs over 4 tasks). |
| Report submission in the request process (Phase 3) | no measurable cost | 3a vs 3b: same allocation; latency difference below noise | One atomic add and one `send/2`; the report copy is allocated in the store. |
| Report retention in the store (Phase 3) | ≤ 50 µs median per report | 7.8–14.2 µs | Off the request path. Bounds the drain rate after a burst. |
| Report store memory at defaults (Phase 3) | ≤ 16 MB | 1.5 MB typical, 12 MB near-worst case | (`max_reports` + `max_pending_reports`) × report size; tune both, or `max_events`. |

\* Measured in the optimized, quiet runs. The final runs on the slower
machine state measured 1.15–1.46 ms.

**Repeat the benchmark** on AC power, with the editor and language server
idle. Run it at least twice and compare memory first. Treat a latency change
as real only if it repeats and the *disabled* baseline is stable between the
runs being compared.

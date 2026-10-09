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
MIX_ENV=bench mix bench.requests                       # ~3 minutes; writes bench/results/latest.md
MIX_ENV=bench mix run --no-start bench/event_cost.exs  # ~20 seconds; allocation per event
```

`bench.requests` creates and migrates a separate SQLite database
(`trace_guard_demo_bench.db`), reseeds the same two products, and runs
`bench/request_overhead.exs`. You can tune it with environment variables:
`BENCH_WARMUP`, `BENCH_TIME`, `BENCH_MEMORY_TIME` (seconds, default 2/5/1),
`BENCH_PARALLEL` (default 4) and `BENCH_OUTPUT`.

## Method

* **Same application, same requests, two modes.** Only `enabled` differs
  between "TraceGuard disabled" and "TraceGuard enabled". Everything else is
  the demo's real configuration (`capture_sql: true`, five allow-listed
  headers, 100-event buffer). When disabled, `TraceGuard.Plug` returns the conn
  untouched, no handlers are attached, and `TraceGuard.wrap/1` returns its
  function unchanged.
* **Production-like environment.** `MIX_ENV=bench` (`config/bench.exs`): no
  code reloader, no SQL sandbox, Logger at `:error`, no dev routes.
* **In-process dispatch.** Requests go through
  `TraceGuardDemoWeb.Endpoint.call/2` with `Plug.Test`, the same code path
  as under Bandit but without sockets, so network noise doesn't swamp
  microsecond-level differences. The test adapter's messages are drained
  after every request.
* **[Benchee](https://hex.pm/packages/benchee) 1.5.1.** Each scenario and
  mode gets 2 s of warm-up, 5 s of timing and 1 s of memory measurement.
  It reports the median, the 99th percentile, throughput (`parallel /
  average`) and memory (the median bytes allocated **by the process handling
  the request**, which excludes TraceGuard's report store and task
  collectors).
* **A second, concurrent pass** runs the read-only scenarios in 4 parallel
  processes. Checkout is excluded because SQLite serializes writers, so it
  would mostly measure lock contention.
* **Sanity checks** run before any timing. Both modes must return identical
  statuses (200, 200, 500, 200, 200), and only the enabled mode may produce a
  report.
* **One-time costs** are measured separately and excluded: application
  start, and the first request of each scenario after boot (lazy module
  loading).

### Scenarios

| # | Request | What it exercises |
| --- | --- | --- |
| 1 | `GET /api/health` | Fixed per-request cost; no database. |
| 2 | `GET /api/catalog` | 4 Ecto queries in the request process. |
| 3 | `POST /api/checkout` | Transaction with 5 queries, an exception, and a **report built and redacted**. |
| 4 | `GET /api/inventory/audit` | 151 queries: fills the 100-event buffer and drops 51+ events. |
| 5 | `GET /api/catalog/parallel` | The same 4 queries in 4 Tasks wrapped with `TraceGuard.wrap/1` (Phase 2 only). |

## Environment

Elixir 1.17.0, Erlang/OTP 26.1.2 (JIT), Linux (WSL2), 12 × Intel Core
i5-1245U, 7.6 GB RAM, SQLite via `ecto_sqlite3` 0.25 / `exqlite` 0.42,
Phoenix 1.8.15, Bandit 1.12.5 (not used for dispatch).

## Results

The benchmark ran at three stages, twice each:

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

\* Measured in the optimized, quiet runs. The final runs on the slower
machine state measured 1.15–1.46 ms.

**Repeat the benchmark** on AC power, with the editor and language server
idle. Run it at least twice and compare memory first. Treat a latency change
as real only if it repeats and the *disabled* baseline is stable between the
runs being compared.

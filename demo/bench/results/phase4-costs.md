# TraceGuard Phase 4 isolated costs

Generated 2026-10-09T23:11:47Z by
`MIX_ENV=bench mix run --no-start bench/phase4_costs.exs` at commit `8d9e490` (with uncommitted changes).
Elixir 1.17.0, OTP 26, {:unix, :linux}, 12 schedulers. Benchee
warm-up 1s, time 2s, memory 1s per job. TraceGuard config: demo's
`config/config.exs` (max_events 100, max_reports 50, max_pending_reports 50 unless stated).

## 1. GenServer propagation (`TraceGuard.call/3` to a `use TraceGuard.Server` echo server)

| Measurement | Median | p99 | Memory (calling process) | Samples |
| --- | --: | --: | --: | --: |
| c. trace start + finish (success), no calls | 0.53 µs | 3.49 µs | 720 B | 1000000 |
| a. 10 × GenServer.call (no TraceGuard) | 12.44 µs | 97.09 µs | 2664 B | 107823 |
| b. 10 × TraceGuard.call, caller has no trace | 13.54 µs | 121.46 µs | 3120 B | 85903 |
| d. trace start + 10 × TraceGuard.call + finish (success) | 64.49 µs | 869.34 µs | 4376 B | 15656 |

Per traced call, inside an active trace: (d − c − a) / 10. Wrapper only, without a trace: (b − a) / 10.

## 2. Report submission and retention (sample checkout report, 15216 bytes as a term)

| Measurement | Median | p99 | Memory (calling process) | Samples |
| --- | --: | --: | --: | --: |
| put + await :stored, ReportStore (memory) | 11.14 µs | 250.55 µs | 536 B | 61215 |

| Measurement | Median | p99 | Memory (calling process) | Samples |
| --- | --: | --: | --: | --: |
| put + await :stored, SQLite (WAL, synchronous=NORMAL) | 380.51 µs | 5388.40 µs | 512 B | 3236 |

| Measurement | Median | p99 | Memory (calling process) | Samples |
| --- | --: | --: | --: | --: |
| put refused (queue full): Storage.put/1 → {:error, :overloaded} | 7.43 µs | 88.11 µs | 856 B | 145014 |

## 3. Retrieval (50 retained reports)

| Measurement | Median | p99 | Memory (calling process) | Samples |
| --- | --: | --: | --: | --: |
| memory: report_status/1 (stored) | 7.11 µs | 64.09 µs | 280 B | 164037 |
| memory: get_report/1 | 7.37 µs | 66.22 µs | 280 B | 156330 |
| memory: await_report/2 (already stored) | 15.84 µs | 182.13 µs | 1240 B | 70757 |
| memory: list_reports/0 (50 summaries) | 76.31 µs | 396.79 µs | 3416 B | 18649 |

| Measurement | Median | p99 | Memory (calling process) | Samples |
| --- | --: | --: | --: | --: |
| SQLite: get_report/1 | 143.29 µs | 718.54 µs | 256 B | 10268 |
| SQLite: report_status/1 (stored) | 163.32 µs | 917.48 µs | 344 B | 8785 |
| SQLite: list_reports/0 (50 summaries) | 438.69 µs | 1979.14 µs | 3392 B | 3280 |

## 4. Failure burst: 500 failing checkout requests, 8 concurrent

| Adapter | Accepted | Refused (overloaded) | Retained after | Store process memory (after GC) | VM memory delta (after GC, all processes) | Drop records (before → after, cap 1000) |
| --- | --: | --: | --: | --: | --: | --: |
| ReportStore (memory) | 500 | 0 | 50 | 1537.2 KB | 691.9 KB | 1000 → 1000 |
| SQLite | 307 | 193 | 50 | 2.8 KB | 104.4 KB | 1000 → 1000 |

SQLite file (database + WAL) after the burst: 4359.5 KB.

## 5. SQLite outage: database locked by another connection during 500 failing requests

* Largest writer mailbox observed (sampled every ~1 ms): **50** (limit `max_pending_reports` = 50)
* Refused at admission (overloaded): 433
* Admitted, then failed and dropped with `{:sqlite_error, _}`: 16
* Admitted and stored once the lock was released: 51
* Requests affected: none (every request completed with Phoenix's normal 500 for this endpoint)

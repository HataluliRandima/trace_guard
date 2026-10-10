# TraceGuard.Storage.Ecto costs

Generated 2026-10-10T00:41:57Z;
Elixir 1.17.0, OTP 26, PostgreSQL via postgres://postgres@127.0.0.1:54329;
report with 20 events (2116 bytes as JSON).

| Measurement | Median | p99 | Max | Samples |
| --- | --: | --: | --: | --: |
| Request side: `Storage.put/1` admission only | 3 µs | 251 µs | 6087 µs | 2000 |
| Submit until committed (`:stored` event) | 5470 µs | 15873 µs | 19946 µs | 500 |
| `get_report/1` (1,000 rows) | 580 µs | 1199 µs | 1470 µs | 1000 |
| `report_status/1` (stored) | 595 µs | 1484 µs | 1830 µs | 1000 |
| `list_reports(trace_id: ...)` (indexed, 1 row) | 459 µs | 1236 µs | 1723 µs | 1000 |
| `list_reports(request_id:, route:)` (1,000 matching) | 9037 µs | 19289 µs | 26026 µs | 500 |
| `list_reports()` (1,000 summaries) | 9786 µs | 15990 µs | 15990 µs | 50 |

Writer process memory after 1,500+ writes (after GC): 2856 bytes.


# TraceGuard demo

A minimal Phoenix 1.8 JSON API that uses TraceGuard through a path
dependency (`{:trace_guard, path: ".."}`). It uses SQLite through
`ecto_sqlite3`, so no database server is needed.

The business logic (`lib/trace_guard_demo/shop.ex`, `payments.ex`) contains
**no TraceGuard code**. The integration consists of:

* `plug TraceGuard.Plug` in `lib/trace_guard_demo_web/endpoint.ex`;
* the `config :trace_guard, ...` block in `config/config.exs`;
* `stacktrace: true` on the repo (dev/test), so query events can name their
  calling function.
* `TraceGuard.wrap/1` around the tasks in `Shop.catalog_summary_parallel/0`
  and `Shop.reconcile_inventory/0`, and `use TraceGuard.Server` plus
  `TraceGuard.call/3` in `TraceGuardDemo.Pricing`. These are the only
  TraceGuard calls in the business logic, and they are opt-in.

## Endpoints

| Method & path | Behaviour |
| --- | --- |
| `GET /api/health` | `200 {"status":"ok"}`, no database. No report. |
| `GET /api/products` | Real `SELECT` through Ecto. No report. |
| `POST /api/checkout` | **Deliberate failure.** Inside a transaction: `begin`, select the product, decrement stock, insert an order, then the stub payment gateway raises `GatewayError` (its message contains a merchant API key). Ecto rolls back and Phoenix returns a generic JSON 500. Reported. |
| `POST /api/inventory/sync` | Reads the catalogue, then returns `503` without raising. Reported as `error_status`. |
| `GET /api/catalog` | 4 read queries in the request process. No report. |
| `GET /api/catalog/parallel` | The same 4 queries, each in a `Task` wrapped with `TraceGuard.wrap/1`. No report. |
| `POST /api/inventory/reconcile` | **Deliberate failure in a child task.** Two unlinked wrapped tasks read stock; the "warehouse feed" task raises `WarehouseError`. `Task.await/2` exits the request process, and Phoenix returns a generic 500. Reported, with both tasks' events. |
| `POST /api/quote` | **GenServer propagation example.** Calls `TraceGuardDemo.Pricing` (a long-lived server with `use TraceGuard.Server`) via `TraceGuard.call/3`. The server's query runs in its own process and appears in the request's trace as `server-1`. `{"sku":"TG-002"}` deliberately crashes the server (its message embeds a credential, which is scrubbed), so the request exits with a 500. Reported. |
| `GET /api/inventory/audit` | 151 single-row queries (an N+1 pattern), which overflows the 100-event buffer. Used by the benchmark. |
| `GET /dev/traces` | Summaries of stored reports (dev/test only). Accepts `list_reports/1` filters as query parameters, e.g. `?incoming_id=...`, `?route=/api/checkout&status=500`. |
| `GET /dev/traces/:trace_id` | One full report (dev/test only). |

The `/dev/traces` routes are compiled in only when
`config :trace_guard_demo, :expose_trace_reports` is true (`config/dev.exs`,
`config/test.exs`).

`config/config.exs` sets `incoming_header: "x-correlation-id"`, so a client
can send its own ID and find the report even when the response carries no
`x-traceguard-id` header (as for the reconcile failure, which exits).

`config/dev.exs` sets `debug_errors: false`, so you see the response an
ordinary API client gets instead of Phoenix's debug page.

## Run it

```bash
mix setup          # deps.get + create/migrate the SQLite DB + seed two products
mix phx.server     # http://localhost:4000
```

In a second terminal:

```bash
./scripts/run_demo.sh report.json task_report.json server_report.json
```

To keep reports across restarts, start the server with SQLite storage
(`config/dev.exs`; the reports file is `trace_guard_reports_dev.db`):

```bash
TRACE_GUARD_STORAGE=sqlite mix phx.server
# run the script, stop the server (Ctrl-C twice), start it again with the
# same variable, then:
curl -s localhost:4000/dev/traces/<trace id printed by the script>
```

Or by hand:

```bash
curl -i -X POST localhost:4000/api/checkout \
  -H 'content-type: application/json' \
  -H 'authorization: Bearer demo-user-session-token' \
  -d '{"sku":"TG-001","quantity":2,"password":"hunter2","card":{"card_number":"4242424242424242"}}'
# → HTTP/1.1 500, {"errors":{"detail":"Internal Server Error"}}, x-traceguard-id: <id>

curl -s localhost:4000/dev/traces/<id>
```

Or from `iex -S mix phx.server`:

```elixir
TraceGuard.list_reports()
TraceGuard.export_json("<id>", pretty: true)
```

## Benchmark

```bash
MIX_ENV=bench mix bench.requests                       # writes bench/results/latest.md
MIX_ENV=bench mix run --no-start bench/event_cost.exs
MIX_ENV=bench mix run --no-start bench/phase4_costs.exs  # propagation, storage, outage
```

`config/bench.exs` is a production-like environment with its own SQLite
database. The benchmark runs paired, alternating rounds (off and on back to
back, order flipped each round) and reports machine drift next to each
delta. It also measures report retention separately from request handling.
The method and results are in
[../docs/performance.md](../docs/performance.md); the raw result files of
every run cited there are in `bench/results/`.

## Tests

```bash
mix test
```

`test/trace_guard_demo_web/trace_guard/` contains:

* `diagnostics_test.exs`: end-to-end through `Phoenix.ConnTest` with real
  SQLite queries. Covers success without a report; the checkout failure's
  ordered timeline (`begin` → `SELECT` → `UPDATE` → `INSERT` → `rollback` →
  exception); the rollback actually happening; absence of the five sensitive
  values; the 503 path; the dev endpoint; and 10 concurrent failing requests
  each getting only their own events. It also covers the parallel catalog (no
  report, same data) and the reconcile failure: task events from two
  processes, the child's exception, and the scrubbed message. It covers the
  quote endpoint too: a traced GenServer call with no report on success, and
  the server's query and crash (`server-1`) in the report on failure.
* `persistent_storage_test.exs`: `TraceGuard.Storage.SQLite` with a real
  failing checkout. The report is persisted with none of the request's
  secrets anywhere in the database files, and is read back after the
  writer restarts.
* `http_server_test.exs`: starts the endpoint under a real Bandit server on a
  random port and sends failure → success → failure → task failure →
  GenServer failure sequentially with `:httpc`, so requests are handled by
  Bandit's own processes and the re-raised exception or exit reaches Bandit.

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

## Endpoints

| Method & path | Behaviour |
| --- | --- |
| `GET /api/health` | `200 {"status":"ok"}`, no database. No report. |
| `GET /api/products` | Real `SELECT` through Ecto. No report. |
| `POST /api/checkout` | **Deliberate failure.** Inside a transaction: `begin`, select the product, decrement stock, insert an order, then the stub payment gateway raises `GatewayError` (its message contains a merchant API key). Ecto rolls back and Phoenix returns a generic JSON 500. Reported. |
| `POST /api/inventory/sync` | Reads the catalogue, then returns `503` without raising. Reported as `error_status`. |
| `GET /dev/traces` | List of stored reports (dev/test only). |
| `GET /dev/traces/:trace_id` | One full report (dev/test only). |

The `/dev/traces` routes are compiled in only when
`config :trace_guard_demo, :expose_trace_reports` is true (`config/dev.exs`,
`config/test.exs`).

`config/dev.exs` sets `debug_errors: false`, so you see the response an
ordinary API client gets instead of Phoenix's debug page.

## Run it

```bash
mix setup          # deps.get + create/migrate the SQLite DB + seed two products
mix phx.server     # http://localhost:4000
```

In a second terminal:

```bash
./scripts/run_demo.sh report.json
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
  each getting only their own events.
* `http_server_test.exs`: starts the endpoint under a real Bandit server on a
  random port and sends failure → success → failure sequentially with
  `:httpc`, so requests are handled by Bandit's own processes and the
  re-raised exception reaches Bandit.

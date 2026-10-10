#!/usr/bin/env bash
# External integration check for TraceGuard.Storage.Ecto: a brand-new Phoenix
# application on PostgreSQL (its own Repo and database, as `mix phx.new`
# generates them) stores TraceGuard reports through that Repo.
#
#   TRACE_GUARD_POSTGRES_URL=postgres://postgres@127.0.0.1:54329 scripts/external_postgres_smoke.sh
#
# Steps: generate the app; add TraceGuard (path dependency); configure the
# Ecto adapter with the app's Repo; generate and run TraceGuard's migration
# with the app's normal `mix ecto.migrate`; run the app's own tests over real
# HTTP; then a two-VM restart check: one VM serves a failing request, a
# separate VM reads the report back from PostgreSQL. Databases created here
# (acme_pg_dev, acme_pg_test) are dropped at the end.
set -uo pipefail

: "${TRACE_GUARD_POSTGRES_URL:?set TRACE_GUARD_POSTGRES_URL (see scripts/local_postgres.sh)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$(mktemp -d -t trace_guard_external_pg.XXXXXX)}"
APP="$WORK/acme_pg"
PORT=4110

echo "== Generating a fresh Phoenix app (PostgreSQL) in $APP"
mkdir -p "$WORK"
(cd "$WORK" && env -u ASDF_ELIXIR_VERSION -u ASDF_ERLANG_VERSION mix phx.new acme_pg --no-install \
  --database postgres --no-assets --no-html --no-dashboard --no-gettext --no-mailer --no-live \
  --no-agents-md --no-version-check > "$WORK/phx_new.log" 2>&1) || { echo "phx.new failed"; exit 1; }
rm -rf "$APP/.git"

python3 - "$APP/mix.exs" "$ROOT" <<'PY'
import sys
p, root = sys.argv[1], sys.argv[2]
s = open(p).read()
s = s.replace('{:bandit, "~> 1.5"}', '{:bandit, "~> 1.5"},\n      {:trace_guard, path: "%s"}' % root)
open(p, "w").write(s)
PY

# The app's own Repo, pointed at the given server (dev and test databases).
cat >> "$APP/config/dev.exs" <<'EOF'

config :acme_pg, AcmePg.Repo, url: System.fetch_env!("TRACE_GUARD_POSTGRES_URL") <> "/acme_pg_dev"
EOF
cat >> "$APP/config/test.exs" <<'EOF'

config :acme_pg, AcmePg.Repo, url: System.fetch_env!("TRACE_GUARD_POSTGRES_URL") <> "/acme_pg_test"
config :acme_pg, AcmePgWeb.Endpoint, server: true, http: [ip: {127, 0, 0, 1}, port: 4110]
EOF

# TraceGuard: documented options only. Storage = the app's existing Repo.
cat >> "$APP/config/config.exs" <<'EOF'

config :trace_guard,
  ecto_telemetry_prefixes: [[:acme_pg, :repo]],
  capture_request_headers: ["authorization"],
  storage: {TraceGuard.Storage.Ecto, repo: AcmePg.Repo}
EOF

python3 - "$APP/lib/acme_pg_web/endpoint.ex" "$APP/lib/acme_pg_web/router.ex" <<'PY'
import sys
e, r = sys.argv[1], sys.argv[2]
s = open(e).read(); s = s.replace("  plug Plug.RequestId\n", "  plug Plug.RequestId\n  plug TraceGuard.Plug\n", 1); open(e, "w").write(s)
s = open(r).read(); s = s.replace("    pipe_through :api\n", """    pipe_through :api

    get "/ok", OrderController, :ok
    get "/orders/:id", OrderController, :show
""", 1); open(r, "w").write(s)
PY

cat > "$APP/lib/acme_pg_web/controllers/order_controller.ex" <<'EOF'
defmodule AcmePgWeb.OrderController do
  use AcmePgWeb, :controller

  def ok(conn, _params) do
    Ecto.Adapters.SQL.query!(AcmePg.Repo, "SELECT 1", [])
    json(conn, %{ok: true})
  end

  def show(_conn, %{"id" => id}) do
    Ecto.Adapters.SQL.query!(AcmePg.Repo, "SELECT 'order'", [])
    raise "order #{id} failed: payment provider rejected api_key=pg_ext_secret_555"
  end
end
EOF

printf 'Mix.ensure_application!(:inets)\n%s\n' "$(cat "$APP/test/test_helper.exs")" > "$APP/test/test_helper.exs"
mkdir -p "$APP/test/acme_pg_web"
cat > "$APP/test/acme_pg_web/trace_guard_postgres_test.exs" <<'EOF'
defmodule AcmePgWeb.TraceGuardPostgresTest do
  # Real HTTP (Bandit) -> TraceGuard -> the app's own Repo -> PostgreSQL.
  use AcmePg.DataCase, async: false

  @base "http://127.0.0.1:4110"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    :ok
  end

  defp get(path, headers \\ []) do
    headers = for {k, v} <- headers, do: {String.to_charlist(k), String.to_charlist(v)}
    {:ok, {{_, status, _}, resp, body}} =
      :httpc.request(:get, {String.to_charlist(@base <> path), headers}, [], body_format: :binary)

    {status, Map.new(resp, fn {k, v} -> {to_string(k), to_string(v)} end), body}
  end

  test "TraceGuard uses the application's Repo, and no other" do
    assert Ecto.Repo.all_running() == [AcmePg.Repo]
    assert %{adapter: TraceGuard.Storage.Ecto, available: true} = TraceGuard.report_stats()
  end

  test "ordinary requests are unchanged and leave no report" do
    {200, headers, body} = get("/api/ok")
    assert Jason.decode!(body) == %{"ok" => true}
    assert TraceGuard.report_status(headers["x-traceguard-id"]) == :unknown
  end

  @tag :capture_log
  test "a failure's report is stored redacted in the app's PostgreSQL database" do
    {500, headers, body} = get("/api/orders/9", [{"authorization", "Bearer pg-ext-token"}])
    assert Jason.decode!(body) == %{"errors" => %{"detail" => "Internal Server Error"}}
    id = headers["x-traceguard-id"]

    assert {:ok, report} = TraceGuard.await_report(id, 5_000)
    assert TraceGuard.report_status(id) == :stored
    assert report["failure"]["message"] =~ "api_key=[REDACTED]"
    assert [%{"trace_id" => ^id}] = TraceGuard.list_reports(route: "/api/orders/:id")

    # Ecto's PostgreSQL query telemetry is captured for the request.
    assert Enum.any?(report["events"], &(&1["name"] == "ecto.query" and &1["metadata"]["repo"] == "AcmePg.Repo"))

    %{rows: rows} = AcmePg.Repo.query!("SELECT t::text FROM trace_guard_reports t WHERE trace_id = $1", [id])
    raw = rows |> List.flatten() |> Enum.join()
    assert raw =~ id
    refute raw =~ "pg_ext_secret_555"
    refute raw =~ "pg-ext-token"
  end
end
EOF

cd "$APP"
export MIX_ENV=dev
mix deps.get > "$WORK/deps.log" 2>&1 || { echo "deps.get failed"; exit 1; }
STATUS=0

echo "== Migration: generated by TraceGuard, run by the app's own ecto.migrate"
mix trace_guard.gen.ecto_migration 2>&1 | tail -1
ls priv/repo/migrations
(mix ecto.create && mix ecto.migrate) > "$WORK/migrate_dev.log" 2>&1 || { echo "dev migrate failed"; cat "$WORK/migrate_dev.log" | tail -5; exit 1; }
MIX_ENV=test mix ecto.create > /dev/null 2>&1; MIX_ENV=test mix ecto.migrate > "$WORK/migrate_test.log" 2>&1 || { echo "test migrate failed"; exit 1; }
tail -3 "$WORK/migrate_dev.log"

echo "== The app's own test suite (MIX_ENV=test, Bandit, real HTTP)"
if PORT=$PORT MIX_ENV=test mix test > "$WORK/test.log" 2>&1; then echo "   PASS: $(grep -E '[0-9]+ tests?, [0-9]+ failures?|^Result: ' "$WORK/test.log" | tail -1)"
else echo "   FAIL: $(grep -E '[0-9]+ tests?, [0-9]+ failures?|^Result: ' "$WORK/test.log" | tail -1)"; STATUS=1; fi

echo "== Two-VM restart check (MIX_ENV=dev, committed data)"
PORT=$PORT mix phx.server > "$WORK/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 90); do curl -s "localhost:$PORT/api/ok" >/dev/null 2>&1 && break; sleep 1; done
TRACE_ID="$(curl -si "localhost:$PORT/api/orders/1" | grep -i '^x-traceguard-id:' | awk '{print $2}' | tr -d '\r')"
echo "   VM 1 served a failing request; trace $TRACE_ID"
sleep 1  # the report is stored asynchronously, just after the response
kill $SERVER; wait $SERVER 2>/dev/null
for _ in $(seq 1 30); do curl -s "localhost:$PORT" >/dev/null 2>&1 || break; sleep 1; done

if mix run -e "
  {:ok, r} = TraceGuard.await_report(\"$TRACE_ID\", 5_000)
  IO.puts(\"   VM 2 read it back from PostgreSQL: route=#{r[\"request\"][\"route\"]} status=#{inspect(TraceGuard.report_status(\"$TRACE_ID\"))}\")
  IO.puts(\"   running repos in VM 2: #{inspect(Ecto.Repo.all_running())}\")
" 2>&1 | grep "VM 2\|running repos"; then :; else echo "   FAIL: report not found after restart"; STATUS=1; fi

echo "== Databases on the server (TraceGuard created none of its own)"
mix run --no-start -e '
  Application.ensure_all_started(:postgrex)
  uri = URI.parse(System.fetch_env!("TRACE_GUARD_POSTGRES_URL"))
  [user | pass] = String.split(uri.userinfo || "postgres", ":", parts: 2)
  {:ok, c} = Postgrex.start_link(hostname: uri.host, port: uri.port || 5432, username: user,
    password: List.first(pass), database: "postgres")
  %{rows: rows} = Postgrex.query!(c, "SELECT datname FROM pg_database WHERE datname LIKE $1 ORDER BY 1", ["%acme%"])
  IO.puts("   " <> Enum.join(List.flatten(rows), ", "))
  %{rows: t} = Postgrex.query!(c, "SELECT count(*) FROM pg_database WHERE datname ILIKE $1", ["%trace%"])
  IO.puts("   databases named *trace*: " <> to_string(hd(hd(t))))
' 2>&1 | tail -2

(mix ecto.drop && MIX_ENV=test mix ecto.drop) > /dev/null 2>&1
echo
echo "Generated app and logs: $WORK"
exit $STATUS

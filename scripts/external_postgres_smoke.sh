#!/usr/bin/env bash
# Clean-install check for TraceGuard.Storage.Ecto: a brand-new Phoenix
# application on PostgreSQL (its own Repo and databases, as `mix phx.new`
# generates them) installs TraceGuard by following the public instructions
# (docs/storage.md) and stores reports through its own Repo.
#
#   TRACE_GUARD_POSTGRES_URL=postgres://postgres@127.0.0.1:54329 scripts/external_postgres_smoke.sh
#
# 1. Add TraceGuard to the app's deps. By default the dependency is the
#    *built package* (`mix hex.build --unpack`), not this repository: only
#    the files that would ship are available. TRACE_GUARD_DEP replaces it
#    with any dependency options, for example the documented Git-tag form:
#      TRACE_GUARD_DEP='github: "HataluliRandima/trace_guard", tag: "v0.1.0-rc.1"'
# 2. Configure the adapter with the app's existing Repo.
# 3. Start the app before migrating: TraceGuard must not create its table.
# 4. Generate the migration (`mix trace_guard.gen.ecto_migration`): it must
#    follow the app's conventions (directory, module name, formatting), be
#    deterministic apart from the timestamp, and refuse a second copy.
# 5. Run it with the app's ordinary `mix ecto.migrate` (and roll back/redo).
# 6-9. The app's own tests over real HTTP: a traced failure, its persisted
#    report, a raw scan for the planted secrets, an unrelated app table left
#    untouched by clearing, only the app's Repo running. Then a two-VM
#    restart check and a list of the server's databases.
#
# Every failed check makes the script exit non-zero. The databases it
# creates (acme_pg_dev, acme_pg_test) are dropped on exit, pass or fail.
# Requires the phx_new archive, curl, python3 and access to hex.pm.
set -uo pipefail

: "${TRACE_GUARD_POSTGRES_URL:?set TRACE_GUARD_POSTGRES_URL (see scripts/local_postgres.sh)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$(mktemp -d -t trace_guard_external_pg.XXXXXX)}"
APP="$WORK/acme_pg"
PKG="$WORK/trace_guard_pkg"
PORT=4110
STATUS=0
SERVER=""

pass() { echo "   ok: $*"; }
fail() { echo "   FAIL: $*"; STATUS=1; }
die() { echo "   FAIL: $*"; STATUS=1; exit 1; }

cleanup() {
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null && wait "$SERVER" 2>/dev/null
  if [ -d "$APP/deps" ]; then
    (cd "$APP" && MIX_ENV=dev mix ecto.drop && MIX_ENV="test" mix ecto.drop) > "$WORK/drop.log" 2>&1 ||
      echo "   warning: dropping the app's databases failed (see $WORK/drop.log)"
  fi
  echo
  echo "Generated app and logs: $WORK"
  exit "$STATUS"
}
trap cleanup EXIT
mkdir -p "$WORK"

if [ -n "${TRACE_GUARD_DEP:-}" ]; then
  echo "== 1. Install: TraceGuard as {:trace_guard, $TRACE_GUARD_DEP}"
  DEP="$TRACE_GUARD_DEP"
else
  echo "== 1. Install: TraceGuard as the app would get it (the built package)"
  (cd "$ROOT" && MIX_ENV=dev mix hex.build --unpack -o "$PKG" > "$WORK/hex_build.log" 2>&1) ||
    die "mix hex.build failed (see $WORK/hex_build.log)"
  pass "package unpacked: $(cd "$PKG" && find . -type f | wc -l) files, no test/ or scripts/: $(
    [ ! -e "$PKG/test" ] && [ ! -e "$PKG/scripts" ] && echo yes || echo NO)"
  DEP="path: \"$PKG\""
fi

(cd "$WORK" && env -u ASDF_ELIXIR_VERSION -u ASDF_ERLANG_VERSION mix phx.new acme_pg --no-install \
  --database postgres --no-assets --no-html --no-dashboard --no-gettext --no-mailer --no-live \
  --no-agents-md --no-version-check > "$WORK/phx_new.log" 2>&1) || die "phx.new failed (see $WORK/phx_new.log)"
rm -rf "$APP/.git"
pass "fresh Phoenix app with --database postgres ($(grep -o '{:phoenix, "[^"]*"' "$APP/mix.exs"))"

python3 -I - "$APP/mix.exs" "$DEP" <<'PY'
import sys
p, dep = sys.argv[1], sys.argv[2]
s = open(p).read()
s = s.replace('{:bandit, "~> 1.5"}', '{:bandit, "~> 1.5"},\n      {:trace_guard, %s}' % dep)
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

echo "== 2. Configure: documented options only, storage = the app's existing Repo"
cat >> "$APP/config/config.exs" <<'EOF'

config :trace_guard,
  ecto_telemetry_prefixes: [[:acme_pg, :repo]],
  capture_request_headers: ["authorization"],
  storage: {TraceGuard.Storage.Ecto, repo: AcmePg.Repo}
EOF

python3 -I - "$APP/lib/acme_pg_web/endpoint.ex" "$APP/lib/acme_pg_web/router.ex" <<'PY'
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
    Ecto.Adapters.SQL.query!(AcmePg.Repo, "SELECT reference FROM orders LIMIT 1", [])
    raise "order #{id} failed: payment provider rejected api_key=pg_ext_secret_555"
  end
end
EOF

cd "$APP" || die "cannot enter $APP"
export MIX_ENV=dev
mix deps.get > "$WORK/deps.log" 2>&1 || die "deps.get failed (see $WORK/deps.log)"
mix compile > "$WORK/compile.log" 2>&1 || die "compile failed (see $WORK/compile.log)"
# All database names on the server, through the app's Postgrex.
databases() {
  mix run --no-start -e '
    Application.ensure_all_started(:postgrex)
    uri = URI.parse(System.fetch_env!("TRACE_GUARD_POSTGRES_URL"))
    [user | pass] = String.split(uri.userinfo || "postgres", ":", parts: 2)
    {:ok, c} = Postgrex.start_link(hostname: uri.host, port: uri.port || 5432, username: user,
      password: List.first(pass), database: "postgres")
    %{rows: rows} = Postgrex.query!(c, "SELECT datname FROM pg_database ORDER BY 1", [])
    IO.puts(rows |> List.flatten() |> Enum.join(" "))
  ' 2>&1 | tail -1
}
pass "app compiles with TraceGuard and ecto_sql $(sed -n 's/.*"ecto_sql": {:hex, :ecto_sql, "\([^"]*\)".*/\1/p' mix.lock)"

# The app's own data, created by the app's own migration.
mix ecto.gen.migration create_orders > /dev/null 2>&1 || die "ecto.gen.migration failed"
ORDERS="$(ls priv/repo/migrations/*_create_orders.exs)"
cat > "$ORDERS" <<'EOF'
defmodule AcmePg.Repo.Migrations.CreateOrders do
  use Ecto.Migration

  def change do
    create table(:orders) do
      add :reference, :string
    end
  end
end
EOF
sleep 1 # distinct migration timestamps

echo "== 3. Start before migrating: TraceGuard creates nothing by itself"
DATABASES_BEFORE="$(databases)"
mix ecto.create > "$WORK/create_dev.log" 2>&1 || die "ecto.create failed (see $WORK/create_dev.log)"
mix run -e '
  %{rows: [[table]]} = AcmePg.Repo.query!("SELECT to_regclass($1)::text", ["trace_guard_reports"])
  stats = TraceGuard.report_stats()
  IO.puts("table=#{inspect(table)} available=#{stats.available} repos=#{inspect(Ecto.Repo.all_running())}")
' > "$WORK/premigrate.log" 2>&1
if grep -q 'table=nil available=false repos=\[AcmePg.Repo\]' "$WORK/premigrate.log"; then
  pass "app started with the adapter configured; no trace_guard_reports table; report_stats available: false"
else
  fail "before migrating: $(tail -3 "$WORK/premigrate.log")"
fi

echo "== 4. Generate the migration (no flags: the Repo comes from :ecto_repos)"
mix trace_guard.gen.ecto_migration > "$WORK/gen.log" 2>&1 || die "generator failed: $(tail -3 "$WORK/gen.log")"
GEN="$(ls priv/repo/migrations/*_add_trace_guard_reports.exs 2>/dev/null)"
[ -f "$GEN" ] && pass "written to $(realpath --relative-to="$APP" "$GEN")" || die "no migration in priv/repo/migrations"
grep -q '^defmodule AcmePg.Repo.Migrations.AddTraceGuardReports do$' "$GEN" &&
  pass "module AcmePg.Repo.Migrations.AddTraceGuardReports (the app's naming convention)" || fail "module name: $(head -1 "$GEN")"
mix format --check-formatted "$GEN" > "$WORK/format.log" 2>&1 &&
  pass "already formatted by the app's own .formatter.exs (mix format --check-formatted)" || fail "not formatted per the app: $(tail -5 "$WORK/format.log")"
if mix trace_guard.gen.ecto_migration > "$WORK/gen_again.log" 2>&1; then
  fail "a second migration was generated"
else
  grep -q "already exists" "$WORK/gen_again.log" && pass "a second run refuses (already exists)" || fail "second run: $(tail -2 "$WORK/gen_again.log")"
fi
mv "$GEN" "$WORK/first_migration.exs"
sleep 1
mix trace_guard.gen.ecto_migration > /dev/null 2>&1
GEN="$(ls priv/repo/migrations/*_add_trace_guard_reports.exs)"
cmp -s "$GEN" "$WORK/first_migration.exs" &&
  pass "deterministic: regenerated content is byte-identical ($(basename "$GEN") vs. the first run)" || fail "regenerated content differs"

echo "== 5. Migrate with the app's ordinary workflow"
mix ecto.migrate > "$WORK/migrate_dev.log" 2>&1 || die "ecto.migrate failed: $(tail -5 "$WORK/migrate_dev.log")"
mix ecto.migrations > "$WORK/migrations.log" 2>&1
grep -E '^\s+up\s+[0-9]+\s+add_trace_guard_reports' "$WORK/migrations.log" > /dev/null &&
  grep -E '^\s+up\s+[0-9]+\s+create_orders' "$WORK/migrations.log" > /dev/null &&
  pass "mix ecto.migrations: create_orders and add_trace_guard_reports are up (the app's migration history)" ||
  fail "migration status: $(cat "$WORK/migrations.log")"
(mix ecto.rollback --step 1 && mix ecto.migrate) > "$WORK/redo.log" 2>&1 &&
  grep -q "drop table if exists trace_guard_reports\|drop_if_exists table trace_guard_reports" "$WORK/redo.log" &&
  pass "rollback (down: drops the table) and migrate again" || fail "rollback/redo: $(grep -i -m3 'error\|drop' "$WORK/redo.log")"
MIX_ENV="test" mix ecto.create > "$WORK/create_test.log" 2>&1 && MIX_ENV="test" mix ecto.migrate > "$WORK/migrate_test.log" 2>&1 ||
  die "test database migrate failed (see $WORK/migrate_test.log)"

echo "== 6-9. The app's own test suite (MIX_ENV=test, Bandit, real HTTP)"
printf 'Mix.ensure_application!(:inets)\n%s\n' "$(cat test/test_helper.exs)" > test/test_helper.exs
mkdir -p test/acme_pg_web
cat > test/acme_pg_web/trace_guard_postgres_test.exs <<'EOF'
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

  defp count(table), do: AcmePg.Repo.query!("SELECT count(*) FROM #{table}").rows |> hd() |> hd()

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
    assert report["request"]["headers"]["authorization"] == "[REDACTED]"
    assert [%{"trace_id" => ^id}] = TraceGuard.list_reports(route: "/api/orders/:id")

    # Ecto's PostgreSQL query telemetry is captured for the request.
    assert Enum.any?(report["events"], &(&1["name"] == "ecto.query" and &1["metadata"]["repo"] == "AcmePg.Repo"))

    # Every column of the stored row, as text: no planted secret.
    %{rows: rows} = AcmePg.Repo.query!("SELECT t::text FROM trace_guard_reports t WHERE trace_id = $1", [id])
    raw = rows |> List.flatten() |> Enum.join()
    assert raw =~ id
    refute raw =~ "pg_ext_secret_555"
    refute raw =~ "pg-ext-token"
  end

  @tag :capture_log
  test "unrelated application tables are unaffected by storing, retention and clearing" do
    AcmePg.Repo.query!("INSERT INTO orders (reference) VALUES ('A-1'), ('A-2')")
    {500, headers, _} = get("/api/orders/1")
    assert {:ok, _} = TraceGuard.await_report(headers["x-traceguard-id"], 5_000)
    assert count("trace_guard_reports") >= 1

    assert {:ok, _} = TraceGuard.Storage.Ecto.cleanup()
    assert :ok = TraceGuard.clear_reports()

    assert count("trace_guard_reports") == 0
    assert count("orders") == 2
    assert AcmePg.Repo.query!("SELECT reference FROM orders ORDER BY id").rows == [["A-1"], ["A-2"]]
  end
end
EOF

if PORT=$PORT MIX_ENV=test mix test > "$WORK/test.log" 2>&1; then
  pass "$(grep -E '[0-9]+ tests?, [0-9]+ failures?|^Result: ' "$WORK/test.log" | tail -1)"
else
  fail "$(grep -E '[0-9]+ tests?, [0-9]+ failures?|^Result: ' "$WORK/test.log" | tail -1) (see $WORK/test.log)"
fi

echo "== Two-VM restart check (MIX_ENV=dev, committed data)"
PORT=$PORT mix phx.server > "$WORK/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 90); do curl -s "localhost:$PORT/api/ok" > /dev/null 2>&1 && break; sleep 1; done
TRACE_ID="$(curl -si "localhost:$PORT/api/orders/1" | grep -i '^x-traceguard-id:' | awk '{print $2}' | tr -d '\r')"
[ -n "$TRACE_ID" ] && pass "VM 1 served a failing request; trace $TRACE_ID" || fail "VM 1: no trace ID"
sleep 1 # the report is stored asynchronously, just after the response
kill "$SERVER"; wait "$SERVER" 2>/dev/null; SERVER=""
for _ in $(seq 1 30); do curl -s "localhost:$PORT" > /dev/null 2>&1 || break; sleep 1; done

mix run -e "
  {:ok, r} = TraceGuard.await_report(\"$TRACE_ID\", 5_000)
  IO.puts(\"VM 2 read it back from PostgreSQL: route=#{r[\"request\"][\"route\"]} status=#{inspect(TraceGuard.report_status(\"$TRACE_ID\"))} repos=#{inspect(Ecto.Repo.all_running())}\")
" > "$WORK/vm2.log" 2>&1
grep -q 'route=/api/orders/:id status=:stored repos=\[AcmePg.Repo\]' "$WORK/vm2.log" &&
  pass "$(grep 'VM 2' "$WORK/vm2.log")" || fail "report not found after restart: $(tail -3 "$WORK/vm2.log")"

echo "== Databases on the server (TraceGuard created none of its own)"
DATABASES_AFTER="$(databases)"
NEW="$(comm -13 <(tr ' ' '\n' <<< "$DATABASES_BEFORE" | sort) <(tr ' ' '\n' <<< "$DATABASES_AFTER" | sort) | paste -sd' ' -)"
[ "$NEW" = "acme_pg_dev acme_pg_test" ] &&
  pass "databases created during the run: $NEW (the app's own; none by TraceGuard)" ||
  fail "databases created during the run: '$NEW' (before: $DATABASES_BEFORE)"

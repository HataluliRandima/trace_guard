#!/usr/bin/env bash
# External integration check: generates a brand-new Phoenix application
# (outside this repository, not derived from demo/), integrates TraceGuard
# through its documented public API only, and runs that application's own
# test suite over real HTTP.
#
#   scripts/external_smoke.sh                  # all four variants
#   VARIANTS="bandit:memory" scripts/external_smoke.sh
#
# Variants are HTTP adapter (bandit | cowboy) x storage (memory | sqlite).
# Requires: the phx_new archive, network access to hex.pm, a C compiler for
# exqlite, and OTP 27+ for the Cowboy variants (current cowlib uses `maybe`).
# Choose the toolchain with asdf, e.g.
#   ASDF_ELIXIR_VERSION=1.17.1 ASDF_ERLANG_VERSION=27.0 scripts/external_smoke.sh Nothing is installed system-wide and the repository is not
# modified. Set WORK to keep the generated app somewhere specific.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$(mktemp -d -t trace_guard_external.XXXXXX)}"
APP="$WORK/acme_shop"
VARIANTS="${VARIANTS:-bandit:memory bandit:sqlite cowboy:memory cowboy:sqlite}"

echo "== Generating a fresh Phoenix app in $APP ($(elixir --version | tail -1))"
mkdir -p "$WORK"
# Generated with the default toolchain (where the phx_new archive is
# installed); built and tested with the requested one.
(cd "$WORK" && env -u ASDF_ELIXIR_VERSION -u ASDF_ERLANG_VERSION mix phx.new acme_shop --no-install --database sqlite3 --no-assets --no-html \
  --no-dashboard --no-gettext --no-mailer --no-live --no-agents-md --no-version-check \
  > "$WORK/phx_new.log" 2>&1) || { echo "phx.new failed, see $WORK/phx_new.log"; exit 1; }
rm -rf "$APP/.git"

# --- 1. Dependency (unreleased package: the built package, as a path) -------
# `mix hex.build --unpack` yields exactly the files that would ship, so the
# app can't depend on anything outside the package.
PKG="$WORK/trace_guard_pkg"
(cd "$ROOT" && MIX_ENV=dev mix hex.build --unpack -o "$PKG" > "$WORK/hex_build.log" 2>&1) ||
  { echo "mix hex.build failed, see $WORK/hex_build.log"; exit 1; }

# plug_cowboy only when a Cowboy variant is requested: current Cowboy
# (2.20, cowlib 2.21) needs OTP 27 or later.
WITH_COWBOY=0
[[ " $VARIANTS " == *"cowboy:"* ]] && WITH_COWBOY=1
python3 - "$APP/mix.exs" "$PKG" "$WITH_COWBOY" <<'PY'
import sys
path, root, cowboy = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
s = open(path).read()
extra = '\n      {:plug_cowboy, "~> 2.7"},' if cowboy else ''
s = s.replace('{:bandit, "~> 1.5"}',
              '{:bandit, "~> 1.5"},%s\n      {:trace_guard, path: "%s"}' % (extra, root))
open(path, "w").write(s)
PY

# --- 2. Configuration ------------------------------------------------------
cat >> "$APP/config/config.exs" <<'EOF'

# TraceGuard (documented options only)
config :trace_guard,
  ecto_telemetry_prefixes: [[:acme_shop, :repo]],
  incoming_header: "x-correlation-id",
  capture_request_headers: ["accept", "content-type", "authorization"]

config :logger, :default_formatter, metadata: [:request_id, :trace_guard_id]
EOF

cat >> "$APP/config/test.exs" <<'EOF'

# External smoke test: a real HTTP server, adapter and storage chosen by env.
config :acme_shop, AcmeShopWeb.Endpoint,
  server: true,
  http: [ip: {127, 0, 0, 1}, port: 4102],
  adapter:
    if(System.get_env("TG_ADAPTER") == "cowboy",
      do: Phoenix.Endpoint.Cowboy2Adapter,
      else: Bandit.PhoenixAdapter
    )

if System.get_env("TG_STORAGE") == "sqlite" do
  config :trace_guard,
    storage:
      {TraceGuard.Storage.SQLite,
       database: Path.expand("../tmp/trace_guard_reports_test.db", __DIR__)}
end
EOF

# --- 3. The plug -----------------------------------------------------------
python3 - "$APP/lib/acme_shop_web/endpoint.ex" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("  plug Plug.RequestId\n", "  plug Plug.RequestId\n  plug TraceGuard.Plug\n", 1)
open(p, "w").write(s)
PY

# --- 4. Application code (public API only) ---------------------------------
mkdir -p "$APP/lib/acme_shop" "$APP/lib/acme_shop_web/controllers"

cat > "$APP/lib/acme_shop/pricing.ex" <<'EOF'
defmodule AcmeShop.Pricing do
  use GenServer
  use TraceGuard.Server

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:quote, sku}, _from, state) do
    Ecto.Adapters.SQL.query!(AcmeShop.Repo, "SELECT 'pricing'", [])
    if sku == "broken", do: raise("pricing backend down (secret=px_secret_123)")
    {:reply, {:ok, 100}, state}
  end
end
EOF

python3 - "$APP/lib/acme_shop/application.ex" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("      {Phoenix.PubSub, name: AcmeShop.PubSub},",
              "      {Phoenix.PubSub, name: AcmeShop.PubSub},\n      AcmeShop.Pricing,", 1)
open(p, "w").write(s)
PY

cat > "$APP/lib/acme_shop_web/controllers/order_controller.ex" <<'EOF'
defmodule AcmeShopWeb.OrderController do
  use AcmeShopWeb, :controller

  def ok(conn, _params) do
    Ecto.Adapters.SQL.query!(AcmeShop.Repo, "SELECT 1", [])
    json(conn, %{ok: true})
  end

  # Raises after a query in the request and one in a wrapped Task.
  def show(_conn, %{"id" => id}) do
    Ecto.Adapters.SQL.query!(AcmeShop.Repo, "SELECT 'order'", [])
    Task.async(TraceGuard.wrap(fn -> Ecto.Adapters.SQL.query!(AcmeShop.Repo, "SELECT 'task'", []) end))
    |> Task.await()

    raise "order #{id} failed: payment provider rejected api_key=sk_ext_secret_999"
  end

  # The pricing server crashes: the caller exits (no trace header).
  def quote(conn, %{"sku" => sku}) do
    {:ok, price} = TraceGuard.call(AcmeShop.Pricing, {:quote, sku})
    json(conn, %{price: price})
  end
end
EOF

python3 - "$APP/lib/acme_shop_web/router.ex" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("    pipe_through :api\n", """    pipe_through :api

    get "/ok", OrderController, :ok
    get "/orders/:id", OrderController, :show
    get "/quote/:sku", OrderController, :quote
""", 1)
open(p, "w").write(s)
PY

# --- 5. The application's own tests (public API only) ----------------------
mkdir -p "$APP/test/acme_shop_web"
# The tests use :httpc as their HTTP client.
printf 'Mix.ensure_application!(:inets)\n%s\n' "$(cat "$APP/test/test_helper.exs")" > "$APP/test/test_helper.exs"
cat > "$APP/test/acme_shop_web/trace_guard_integration_test.exs" <<'EOF'
defmodule AcmeShopWeb.TraceGuardIntegrationTest do
  # Real HTTP against the running endpoint (Bandit or Cowboy, per TG_ADAPTER),
  # with TraceGuard's default or SQLite storage (per TG_STORAGE).
  use AcmeShop.DataCase, async: false

  import ExUnit.CaptureLog

  @base "http://127.0.0.1:4102"
  @secrets ["sk_ext_secret_999", "Bearer ext-token-777", "ext-token-777", "px_secret_123"]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    :ok
  end

  setup do
    TraceGuard.clear_reports()
    :ok
  end

  defp get(path, headers \\ []) do
    headers = for {k, v} <- headers, do: {String.to_charlist(k), String.to_charlist(v)}
    {:ok, {{_, status, _}, resp_headers, body}} =
      :httpc.request(:get, {String.to_charlist(@base <> path), headers}, [], body_format: :binary)

    {status, Map.new(resp_headers, fn {k, v} -> {to_string(k), to_string(v)} end), body}
  end

  test "a successful request leaves no report" do
    {200, headers, _} = get("/api/ok")
    assert TraceGuard.report_status(headers["x-traceguard-id"]) == :unknown
    assert TraceGuard.list_reports() == []
  end

  test "a failure produces a redacted report retrievable by trace ID" do
    log =
      capture_log(fn ->
        {500, headers, body} = get("/api/orders/7", [{"authorization", "Bearer ext-token-777"}])
        send(self(), {:result, headers, body})
        # The adapter logs the crash after it has sent the response.
        Process.sleep(500)
      end)

    assert_received {:result, headers, body}
    assert Jason.decode!(body) == %{"errors" => %{"detail" => "Internal Server Error"}}
    id = headers["x-traceguard-id"]

    assert {:ok, report} = TraceGuard.await_report(id, 2_000)
    assert TraceGuard.report_status(id) == :stored
    assert report["request"]["route"] == "/api/orders/:id"
    assert report["request"]["headers"]["authorization"] == "[REDACTED]"
    assert report["failure"]["message"] =~ "api_key=[REDACTED]"

    sql = for %{"name" => "ecto.query"} = e <- report["events"], do: e["process"]
    assert "request" in sql and "task-1" in sql

    {:ok, json} = TraceGuard.export_json(id, pretty: true)
    File.mkdir_p!("tmp")
    File.write!("tmp/exported_report.json", json)
    for secret <- @secrets, do: refute(json =~ secret, "#{secret} leaked into the export")

    # Recorded for the external-validation notes: does the adapter's crash
    # log carry TraceGuard's Logger metadata?
    IO.puts(
      "\nOBSERVATION adapter=#{System.get_env("TG_ADAPTER", "bandit")} " <>
        "crash_log_has_trace_id=#{log =~ id} crash_log_has_raw_secret=#{log =~ "sk_ext_secret_999"}"
    )
  end

  test "a failure without a trace header is found by correlation ID" do
    capture_log(fn ->
      {500, headers, _} = get("/api/quote/broken", [{"x-correlation-id", "ext-quote-1"}])
      refute Map.has_key?(headers, "x-traceguard-id")
    end)

    [%{"trace_id" => id}] = wait_for(fn -> TraceGuard.list_reports(incoming_id: "ext-quote-1") end)
    {:ok, report} = TraceGuard.await_report(id, 2_000)

    assert report["failure"]["kind"] == "exit"
    server = for e <- report["events"], e["process"] == "server-1", do: e["name"]
    assert server == ["genserver.call.start", "ecto.query", "genserver.call.exception"]
    refute Jason.encode!(report) =~ "px_secret_123"
  end

  test "storage in use matches the configuration" do
    expected =
      if System.get_env("TG_STORAGE") == "sqlite", do: TraceGuard.Storage.SQLite, else: TraceGuard.ReportStore

    assert %{adapter: ^expected, available: true} = TraceGuard.report_stats()
  end

  # Reports are stored asynchronously after the response; header-less
  # failures have no trace ID to await, so wait on the filtered list.
  defp wait_for(fun, attempts \\ 100) do
    case fun.() do
      [] when attempts > 0 -> receive(after: (10 -> wait_for(fun, attempts - 1)))
      result -> result
    end
  end
end
EOF

# --- 6. Install and run each variant ---------------------------------------
cd "$APP" || exit 1
mix deps.get > "$WORK/deps.log" 2>&1 || { echo "deps.get failed, see $WORK/deps.log"; exit 1; }
mix compile --warnings-as-errors > "$WORK/compile.log" 2>&1 || { echo "compile failed, see $WORK/compile.log"; exit 1; }

STATUS=0
for variant in $VARIANTS; do
  adapter="${variant%%:*}"; storage="${variant##*:}"
  rm -f tmp/trace_guard_reports_test.db*
  echo "== variant adapter=$adapter storage=$storage"
  # runtime.exs (Phoenix 1.8) sets the HTTP port from PORT in every env.
  if PORT=4102 TG_ADAPTER="$adapter" TG_STORAGE="$storage" mix test > "$WORK/test_${adapter}_${storage}.log" 2>&1; then
    result="PASS"
  else
    result="FAIL"; STATUS=1
  fi
  echo "   $result: $(grep -E '[0-9]+ tests?, [0-9]+ failures?|^Result: ' "$WORK/test_${adapter}_${storage}.log" | tail -1)"
  grep -h "^OBSERVATION" "$WORK/test_${adapter}_${storage}.log" | sed 's/^/   /'
  [ "$storage" = "sqlite" ] && ls -l tmp/trace_guard_reports_test.db 2>/dev/null | awk '{print "   sqlite file mode: " $1}'
done

echo
echo "Generated app and logs: $WORK"
exit $STATUS

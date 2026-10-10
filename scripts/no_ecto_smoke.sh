#!/usr/bin/env bash
# Optional dependencies stay optional: a fresh Phoenix application generated
# without Ecto (`mix phx.new --no-ecto`) installs the built TraceGuard
# package, configures nothing but the plug, and gets in-memory reports.
#
#   scripts/no_ecto_smoke.sh
#
# Checks: no ecto, ecto_sql, exqlite or postgrex in the app's lock file;
# TraceGuard compiles there without warnings; the Ecto and SQLite adapters
# (and the migration task) are not compiled; a real HTTP failure produces a
# redacted report in memory. Exits non-zero when any check fails.
# Requires the phx_new archive and access to hex.pm.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$(mktemp -d -t trace_guard_no_ecto.XXXXXX)}"
APP="$WORK/plain_shop"
PKG="$WORK/trace_guard_pkg"
STATUS=0

pass() { echo "   ok: $*"; }
fail() { echo "   FAIL: $*"; STATUS=1; }
die() { echo "   FAIL: $*"; STATUS=1; exit 1; }
trap 'echo; echo "Generated app and logs: $WORK"; exit "$STATUS"' EXIT
mkdir -p "$WORK"

echo "== A Phoenix app without Ecto, TraceGuard from the built package"
(cd "$ROOT" && MIX_ENV=dev mix hex.build --unpack -o "$PKG" > "$WORK/hex_build.log" 2>&1) ||
  die "mix hex.build failed (see $WORK/hex_build.log)"
(cd "$WORK" && env -u ASDF_ELIXIR_VERSION -u ASDF_ERLANG_VERSION mix phx.new plain_shop --no-install \
  --no-ecto --no-assets --no-html --no-dashboard --no-gettext --no-mailer --no-live \
  --no-agents-md --no-version-check > "$WORK/phx_new.log" 2>&1) || die "phx.new failed (see $WORK/phx_new.log)"
rm -rf "$APP/.git"

python3 -I - "$APP/mix.exs" "$PKG" "$APP/lib/plain_shop_web/endpoint.ex" "$APP/lib/plain_shop_web/router.ex" <<'PY'
import sys
mix, pkg, endpoint, router = sys.argv[1:5]
s = open(mix).read(); s = s.replace('{:bandit, "~> 1.5"}', '{:bandit, "~> 1.5"},\n      {:trace_guard, path: "%s"}' % pkg); open(mix, "w").write(s)
s = open(endpoint).read(); s = s.replace("  plug Plug.RequestId\n", "  plug Plug.RequestId\n  plug TraceGuard.Plug\n", 1); open(endpoint, "w").write(s)
s = open(router).read(); s = s.replace("    pipe_through :api\n", '    pipe_through :api\n\n    get "/fail", FailController, :show\n', 1); open(router, "w").write(s)
PY

cat > "$APP/lib/plain_shop_web/controllers/fail_controller.ex" <<'EOF'
defmodule PlainShopWeb.FailController do
  use PlainShopWeb, :controller

  def show(_conn, _params), do: raise("checkout failed: token=plain_secret_777")
end
EOF

cat >> "$APP/config/test.exs" <<'EOF'

config :plain_shop, PlainShopWeb.Endpoint, server: true, http: [ip: {127, 0, 0, 1}, port: 4120]
EOF

printf 'Mix.ensure_application!(:inets)\n%s\n' "$(cat "$APP/test/test_helper.exs")" > "$APP/test/test_helper.exs"
cat > "$APP/test/trace_guard_no_ecto_test.exs" <<'EOF'
defmodule PlainShopWeb.TraceGuardNoEctoTest do
  use ExUnit.Case, async: false

  test "the optional adapters are not compiled" do
    refute Code.ensure_loaded?(TraceGuard.Storage.Ecto)
    refute Code.ensure_loaded?(TraceGuard.Storage.Ecto.Migration)
    refute Code.ensure_loaded?(TraceGuard.Storage.SQLite)
    refute Code.ensure_loaded?(Mix.Tasks.TraceGuard.Gen.EctoMigration)
    refute Code.ensure_loaded?(Ecto)
    assert %{adapter: TraceGuard.ReportStore} = TraceGuard.report_stats()
  end

  @tag :capture_log
  test "a real HTTP failure is reported, redacted, in memory" do
    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, {{_, 500, _}, headers, _}} =
      :httpc.request(:get, {~c"http://127.0.0.1:4120/api/fail", []}, [], [])

    id = headers |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end) |> Map.fetch!("x-traceguard-id")
    assert {:ok, report} = TraceGuard.await_report(id, 5_000)
    assert report["failure"]["message"] =~ "token=[REDACTED]"
    assert {:ok, json} = TraceGuard.export_json(id)
    refute json =~ "plain_secret_777"
  end
end
EOF

cd "$APP" || die "cannot enter $APP"
export MIX_ENV=test
mix deps.get > "$WORK/deps.log" 2>&1 || die "deps.get failed (see $WORK/deps.log)"
unwanted="$(grep -o -E '^  "(ecto|ecto_sql|exqlite|postgrex|db_connection)":' mix.lock | tr -d ' ":' | paste -sd' ' -)"
[ -z "$unwanted" ] && pass "lock file has no ecto, ecto_sql, exqlite, postgrex or db_connection" || fail "pulled in: $unwanted"

mix deps.compile > "$WORK/deps_compile.log" 2>&1 || die "deps failed to compile (see $WORK/deps_compile.log)"
# TraceGuard's own section of the output, up to the next dependency.
awk '/^==> /{f = ($2 == "trace_guard")} f' "$WORK/deps_compile.log" > "$WORK/compile_trace_guard.log"
grep -q "Compiling" "$WORK/compile_trace_guard.log" || die "no TraceGuard compilation output (see $WORK/deps_compile.log)"
grep -q -i "warning" "$WORK/compile_trace_guard.log" &&
  fail "TraceGuard compiled with warnings: $(grep -i -m3 -A3 warning "$WORK/compile_trace_guard.log")" ||
  pass "TraceGuard compiles without Ecto and without warnings"

# Phoenix 1.8's runtime.exs takes the port from PORT in every environment.
if PORT=4120 mix test > "$WORK/test.log" 2>&1; then
  pass "$(grep -E '[0-9]+ tests?, [0-9]+ failures?|^Result: ' "$WORK/test.log" | tail -1)"
else
  fail "$(grep -E '[0-9]+ tests?, [0-9]+ failures?|^Result: ' "$WORK/test.log" | tail -1) (see $WORK/test.log)"
fi

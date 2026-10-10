#!/usr/bin/env bash
# Checks what `mix hex.publish` would ship, without publishing anything:
# builds the package locally (`mix hex.build --unpack`), then checks
#
#   * the file list: exactly lib/**/*.ex, mix.exs, .formatter.exs,
#     README.md, LICENSE, CHANGELOG.md (plus Hex's hex_metadata.config);
#   * no secrets, databases or build artefacts in the package;
#   * the metadata: version from mix.exs, Apache-2.0, links, the runtime
#     requirements, exqlite and ecto_sql optional, test/dev-only deps absent.
#
#   scripts/package_check.sh     # exit 0 when every check passes
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d -t trace_guard_pkg.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

cd "$ROOT"
MIX_ENV=dev mix hex.build --unpack -o "$OUT/pkg" > "$OUT/build.log" 2>&1 || {
  cat "$OUT/build.log"
  exit 1
}
if grep -i -E "warning|missing" "$OUT/build.log"; then
  echo "FAIL: mix hex.build reported problems (above)"
  exit 1
fi

STATUS=0
fail() { echo "FAIL: $*"; STATUS=1; }

# 1. File list.
(cd "$OUT/pkg" && find . -type f | sed 's|^\./||' | sort) > "$OUT/files"
unexpected="$(grep -v -E '^(lib/.+\.ex|mix\.exs|\.formatter\.exs|README\.md|LICENSE|CHANGELOG\.md|hex_metadata\.config)$' "$OUT/files" || true)"
[ -z "$unexpected" ] || fail "unexpected files in the package: $unexpected"
for f in mix.exs .formatter.exs README.md LICENSE CHANGELOG.md lib/trace_guard.ex; do
  grep -qx "$f" "$OUT/files" || fail "missing from the package: $f"
done
# Every tracked lib file ships (nothing silently left out).
missing="$(comm -23 <(git ls-files 'lib/*.ex' | sort) "$OUT/files")"
[ -z "$missing" ] || fail "tracked lib files missing from the package: $missing"
echo "files: $(wc -l < "$OUT/files") ($(grep -c '^lib/' "$OUT/files") under lib/)"

# 2. Content scan: secrets, keys, databases (the repository's fake test
#    secrets live in test/, which isn't packaged).
if grep -rIl -E 'sk_(live|test)_|BEGIN [A-Z ]*PRIVATE KEY|tg_demo_secret|postgres://[^@"]+:[^@"]+@' "$OUT/pkg"; then
  fail "secret-like content in the files above"
fi
if find "$OUT/pkg" -name '*.db' -o -name '*.db-*' -o -name '*.beam' -o -name '*.tar' | grep .; then
  fail "databases or build artefacts in the package (above)"
fi

# 3. Metadata (hex_metadata.config is Erlang terms).
MIX_EXS="$ROOT/mix.exs" elixir -e '
  {:ok, terms} = :file.consult(~c"'"$OUT/pkg/hex_metadata.config"'")
  meta = Map.new(terms)
  [_, version] = Regex.run(~r/@version "([^"]+)"/, File.read!(System.fetch_env!("MIX_EXS")))
  reqs = Map.new(meta["requirements"], fn r -> r = Map.new(r); {r["name"], r} end)

  checks = [
    {"version matches mix.exs (#{version})", meta["version"] == version},
    {"license Apache-2.0", meta["licenses"] == ["Apache-2.0"]},
    {"GitHub and Changelog links", Enum.sort(Enum.map(meta["links"], &elem(&1, 0))) == ["Changelog", "GitHub"]},
    {"elixir requirement", meta["elixir"] == "~> 1.15"},
    {"runtime deps: telemetry, plug, jason required",
     Enum.all?(~w(telemetry plug jason), &(reqs[&1] && reqs[&1]["optional"] == false))},
    {"exqlite and ecto_sql optional",
     Enum.all?(~w(exqlite ecto_sql), &(reqs[&1] && reqs[&1]["optional"] == true))},
    {"no test/dev-only deps (postgrex, phoenix, ex_doc)",
     Enum.all?(~w(postgrex phoenix ex_doc), &(not Map.has_key?(reqs, &1)))}
  ]

  for {name, ok?} <- checks, do: IO.puts("#{if ok?, do: "ok  ", else: "FAIL"} #{name}")
  IO.puts("requirements: " <> Enum.map_join(Enum.sort(reqs), ", ", fn {n, r} ->
    "#{n} #{r["requirement"]}#{if r["optional"], do: " (optional)"}" end))
  if Enum.all?(checks, &elem(&1, 1)), do: :ok, else: System.halt(1)
' || STATUS=1

[ "$STATUS" -eq 0 ] && echo "package check: ok" || echo "package check: FAILED"
exit "$STATUS"

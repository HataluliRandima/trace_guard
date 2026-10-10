#!/usr/bin/env bash
# Runs the library's checks (deps resolution, warnings-as-errors compile,
# full test suite) against several toolchain / dependency combinations.
#
#   scripts/compat_matrix.sh                 # all rows
#   ROWS="minimum latest" scripts/compat_matrix.sh
#
# Each row copies the library (tracked + untracked files, without demo/) to
# a scratch directory, pins dependency requirements in that copy's mix.exs
# only, resolves them from scratch (no mix.lock) and runs the checks with
# the requested Elixir/OTP through asdf. The repository is never modified.
# Requires asdf with the listed versions installed, or (as in CI) the row's
# exact toolchain already first on PATH, and access to hex.pm. Each row
# first checks that the Elixir and OTP actually running are the row's.
# Exits non-zero when any selected row fails.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$(mktemp -d -t trace_guard_compat.XXXXXX)}"
SUMMARY="$WORK/summary.md"
mkdir -p "$WORK"

# name | elixir | erlang | phoenix (test) | plug | telemetry | ecto_sql (optional)
# The PostgreSQL suite runs in every row when TRACE_GUARD_POSTGRES_URL is set
# (see scripts/local_postgres.sh); otherwise it is excluded and says so.
ALL_ROWS=(
  "current|1.17.0|26.1.2|~> 1.8.15|~> 1.20.3|~> 1.3|~> 3.14"
  "minimum|1.15.8-otp-26|26.1.2|~> 1.7.0|~> 1.14.0|~> 1.0.0|~> 3.10.0"
  "elixir117-otp27|1.17.1|27.0|~> 1.8.0|~> 1.18|~> 1.3|~> 3.12.0"
  "latest|1.20.1-otp-29|29.0|~> 1.8|~> 1.18|~> 1.3|~> 3.14"
)

ROWS="${ROWS:-current minimum elixir117-otp27 latest}"
for name in $ROWS; do
  printf '%s\n' "${ALL_ROWS[@]}" | grep -q "^$name|" || { echo "unknown row: $name" >&2; exit 2; }
done
STATUS=0

echo "| Row | Elixir | OTP | Resolved phoenix / plug / telemetry / exqlite / ecto_sql / postgrex | deps.get | compile (warnings as errors) | tests |" > "$SUMMARY"
echo "| --- | --- | --- | --- | --- | --- | --- |" >> "$SUMMARY"
if [ -n "${TRACE_GUARD_POSTGRES_URL:-}" ]; then
  echo "PostgreSQL suite: enabled ($TRACE_GUARD_POSTGRES_URL)" | tee -a "$SUMMARY"
else
  echo "PostgreSQL suite: EXCLUDED (TRACE_GUARD_POSTGRES_URL not set)" | tee -a "$SUMMARY"
fi

for row in "${ALL_ROWS[@]}"; do
  IFS='|' read -r name elixir erlang phoenix plug telemetry ecto_sql <<< "$row"
  [[ " $ROWS " == *" $name "* ]] || continue

  dir="$WORK/$name"
  log="$WORK/$name.log"
  mkdir -p "$dir"
  git -C "$ROOT" ls-files -co --exclude-standard | grep -v '^demo/' | grep -v '^scripts/' |
    tar -C "$ROOT" -cf - -T - | tar -C "$dir" -xf -
  rm -f "$dir/mix.lock"

  sed -i \
    -e "s|{:phoenix, \"~> 1.7\", only: :test}|{:phoenix, \"$phoenix\", only: :test}|" \
    -e "s|{:plug, \"~> 1.14\"}|{:plug, \"$plug\"}|" \
    -e "s|{:telemetry, \"~> 1.0\"}|{:telemetry, \"$telemetry\"}|" \
    -e "s|{:ecto_sql, \"~> 3.10\", optional: true}|{:ecto_sql, \"$ecto_sql\", optional: true}|" \
    "$dir/mix.exs"

  echo "== $name: Elixir $elixir, OTP $erlang" | tee "$log"
  export ASDF_ELIXIR_VERSION="$elixir" ASDF_ERLANG_VERSION="$erlang"

  run() { (cd "$dir" && "$@") >> "$log" 2>&1; }
  # ExUnit's summary: "1 doctest, 141 tests, 0 failures" (Elixir <= 1.19)
  # or "Result: 142 passed (1 doctest, 141 tests)" (Elixir 1.20).
  summary_line() { grep -E '([0-9]+ tests?, [0-9]+ failures?|^Result: )' "$1" | tail -1; }

  deps="fail"; compile="not run"; tests="not run"; resolved="n/a"
  # The toolchain that will really run (asdf, or whatever is on PATH).
  actual="$(cd "$dir" && elixir -e 'otp = :erlang.system_info(:otp_release)
    v = File.read!(Path.join([:code.root_dir(), "releases", otp, "OTP_VERSION"])) |> String.trim()
    IO.write("#{System.version()} #{v}")' 2>>"$log")"
  if [ "$actual" != "${elixir%%-otp-*} $erlang" ]; then
    deps="toolchain mismatch: running '$actual', row wants '${elixir%%-otp-*} $erlang'"
  elif run env MIX_ENV=test mix deps.get; then
    deps="ok"
    resolved="$(cd "$dir" && for d in phoenix plug telemetry exqlite ecto_sql postgrex; do
      grep -o "\"$d\": {:hex, :$d, \"[^\"]*\"" mix.lock | sed 's/.*, "\(.*\)"/\1/'; done | paste -sd/ -)"
    if run env MIX_ENV=test mix compile --warnings-as-errors; then
      compile="ok"
      if run mix test; then
        tests="$(summary_line "$log")"
        # With a server configured, nothing may be excluded.
        [[ -n "${TRACE_GUARD_POSTGRES_URL:-}" && "$tests" == *excluded* ]] && tests="FAILED (PostgreSQL tests excluded): $tests"
      else
        tests="FAILED: $(summary_line "$log")"
      fi
    else
      compile="FAILED"
    fi
  fi

  echo "| $name | $elixir | $erlang | $resolved | $deps | $compile | $tests |" | tee -a "$SUMMARY"
  [[ "$deps" == ok && "$compile" == ok && "$tests" != FAILED* && "$tests" != "not run" ]] || STATUS=1
done

echo
echo "Logs and summary in $WORK"
cat "$SUMMARY"
[ "$STATUS" -eq 0 ] && echo "all rows passed" || echo "FAILED: at least one row failed"
exit "$STATUS"

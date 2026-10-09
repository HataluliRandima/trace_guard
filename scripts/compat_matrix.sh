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
# Requires asdf with the listed versions installed and access to hex.pm.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$(mktemp -d -t trace_guard_compat.XXXXXX)}"
SUMMARY="$WORK/summary.md"

# name | elixir | erlang | phoenix (test) | plug | telemetry
ALL_ROWS=(
  "current|1.17.0|26.1.2|~> 1.8.15|~> 1.20.3|~> 1.3"
  "minimum|1.15.8-otp-26|26.1.2|~> 1.7.0|~> 1.14.0|~> 1.0.0"
  "elixir117-otp27|1.17.1|27.0|~> 1.8.0|~> 1.18|~> 1.3"
  "latest|1.20.1-otp-29|29.0|~> 1.8|~> 1.18|~> 1.3"
)

ROWS="${ROWS:-current minimum elixir117-otp27 latest}"

echo "| Row | Elixir | OTP | Resolved phoenix / plug / telemetry / exqlite | deps.get | compile (warnings as errors) | tests |" > "$SUMMARY"
echo "| --- | --- | --- | --- | --- | --- | --- |" >> "$SUMMARY"

for row in "${ALL_ROWS[@]}"; do
  IFS='|' read -r name elixir erlang phoenix plug telemetry <<< "$row"
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
    "$dir/mix.exs"

  echo "== $name: Elixir $elixir, OTP $erlang" | tee "$log"
  export ASDF_ELIXIR_VERSION="$elixir" ASDF_ERLANG_VERSION="$erlang"

  run() { (cd "$dir" && "$@") >> "$log" 2>&1; }
  # ExUnit's summary: "1 doctest, 141 tests, 0 failures" (Elixir <= 1.19)
  # or "Result: 142 passed (1 doctest, 141 tests)" (Elixir 1.20).
  summary_line() { grep -E '([0-9]+ tests?, [0-9]+ failures?|^Result: )' "$1" | tail -1; }

  deps="fail"; compile="not run"; tests="not run"; resolved="n/a"
  if run env MIX_ENV=test mix deps.get; then
    deps="ok"
    resolved="$(cd "$dir" && for d in phoenix plug telemetry exqlite; do
      grep -o "\"$d\": {:hex, :$d, \"[^\"]*\"" mix.lock | sed 's/.*, "\(.*\)"/\1/'; done | paste -sd/ -)"
    if run env MIX_ENV=test mix compile --warnings-as-errors; then
      compile="ok"
      if run mix test; then
        tests="$(summary_line "$log")"
      else
        tests="FAILED: $(summary_line "$log")"
      fi
    else
      compile="FAILED"
    fi
  fi

  echo "| $name | $elixir | $erlang | $resolved | $deps | $compile | $tests |" | tee -a "$SUMMARY"
done

echo
echo "Logs and summary in $WORK"
cat "$SUMMARY"

#!/usr/bin/env bash
# A throwaway, user-local PostgreSQL for TraceGuard's PostgreSQL tests, for
# machines without a PostgreSQL server, Docker or sudo (Ubuntu/Debian only).
#
#   scripts/local_postgres.sh start [dir]   # prints TRACE_GUARD_POSTGRES_URL
#   scripts/local_postgres.sh stop  [dir]
#
# `apt-get download` fetches the distribution's own signed packages without
# installing them; they are extracted under DIR and run as the current user,
# listening on 127.0.0.1 only, with trust authentication (test use only).
# Nothing is installed system-wide; `rm -rf DIR` removes everything.
# On machines with PostgreSQL (or CI services), just set
# TRACE_GUARD_POSTGRES_URL=postgres://user:pass@host:port instead.
set -euo pipefail

CMD="${1:-start}"
DIR="${2:-${TMPDIR:-/tmp}/trace_guard_pg}"
PORT="${PGPORT_TRACE_GUARD:-54329}"
VERSION="${PG_MAJOR:-16}"
BIN="$DIR/root/usr/lib/postgresql/$VERSION/bin"
export LD_LIBRARY_PATH="$DIR/root/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

case "$CMD" in
  start)
    if [ ! -x "$BIN/postgres" ]; then
      mkdir -p "$DIR/debs" "$DIR/root"
      (cd "$DIR/debs" && apt-get download "postgresql-$VERSION" "postgresql-client-$VERSION" libpq5)
      for deb in "$DIR"/debs/*.deb; do dpkg-deb -x "$deb" "$DIR/root"; done
    fi
    [ -d "$DIR/data" ] || "$BIN/initdb" -D "$DIR/data" -U postgres --auth=trust -E UTF8 >/dev/null
    # Unix sockets are disabled (long temp paths exceed the 107-byte limit).
    "$BIN/pg_ctl" -D "$DIR/data" -l "$DIR/server.log" -w \
      -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" start >/dev/null
    "$BIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -Atc "select version()"
    echo "export TRACE_GUARD_POSTGRES_URL=postgres://postgres@127.0.0.1:$PORT"
    ;;
  stop)
    "$BIN/pg_ctl" -D "$DIR/data" -m fast stop
    ;;
  *)
    echo "usage: $0 start|stop [dir]" >&2
    exit 2
    ;;
esac

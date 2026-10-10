#!/usr/bin/env bash
# A throwaway, user-local PostgreSQL for TraceGuard's PostgreSQL tests, for
# machines without a PostgreSQL server, Docker or sudo (Ubuntu/Debian only).
#
#   scripts/local_postgres.sh start [dir]   # prints TRACE_GUARD_POSTGRES_URL
#   scripts/local_postgres.sh stop  [dir]
#   PG_MAJOR=18 scripts/local_postgres.sh start   # another major version
#
# The distribution's own signed packages are fetched with `apt-get download`
# when it has the requested major version. Otherwise they come from the
# PostgreSQL project's apt repository (apt.postgresql.org): its signing key
# must match the pinned fingerprint below, the index must carry a good
# signature, and every package must match the signed index's SHA-256.
# Nothing is installed: packages are extracted under DIR and run as the
# current user, listening on 127.0.0.1 only, with trust authentication (test
# use only). Nothing system-wide changes; `rm -rf DIR` removes everything.
# On machines with PostgreSQL (or in CI, see .github/workflows/ci.yml), just
# set TRACE_GUARD_POSTGRES_URL=postgres://user:pass@host:port instead.
set -euo pipefail

CMD="${1:-start}"
VERSION="${PG_MAJOR:-16}"
DIR="${2:-${TMPDIR:-/tmp}/trace_guard_pg$VERSION}"
PORT="${PGPORT_TRACE_GUARD:-$((54313 + VERSION))}" # 16 -> 54329, 18 -> 54331
BIN="$DIR/root/usr/lib/postgresql/$VERSION/bin"
export LD_LIBRARY_PATH="$DIR/root/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

PGDG="https://apt.postgresql.org/pub/repos/apt"
PGDG_FINGERPRINT="B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8"

# Downloads postgresql-$VERSION, its client and libpq5 from PGDG, verified.
pgdg_download() {
  local codename gnupg want
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  gnupg="$DIR/gnupg"
  mkdir -p "$gnupg" && chmod 700 "$gnupg"
  curl -fsS -o "$DIR/pgdg.asc" https://www.postgresql.org/media/keys/ACCC4CF8.asc
  GNUPGHOME="$gnupg" gpg --batch --show-keys --with-colons "$DIR/pgdg.asc" |
    grep -q "^fpr:::::::::$PGDG_FINGERPRINT:" || { echo "PGDG key fingerprint mismatch" >&2; exit 1; }
  GNUPGHOME="$gnupg" gpg --batch --dearmor < "$DIR/pgdg.asc" > "$DIR/pgdg.gpg"
  curl -fsS -o "$DIR/InRelease" "$PGDG/dists/$codename-pgdg/InRelease"
  gpgv --keyring "$DIR/pgdg.gpg" "$DIR/InRelease" 2>/dev/null || { echo "bad PGDG signature" >&2; exit 1; }
  want="$(awk '/^SHA256:/{f=1;next} /^[A-Za-z]/{f=0} f && $3=="main/binary-amd64/Packages.gz"{print $1}' "$DIR/InRelease")"
  curl -fsS -o "$DIR/Packages.gz" "$PGDG/dists/$codename-pgdg/main/binary-amd64/Packages.gz"
  echo "$want  $DIR/Packages.gz" | sha256sum -c --quiet
  gunzip -c "$DIR/Packages.gz" | python3 -I -c '
import re, subprocess, sys
stanzas = sys.stdin.read().split("\n\n")
for name in sys.argv[1:]:
    found = [s for s in stanzas if re.search(r"^Package: %s$" % re.escape(name), s, re.M)
             and re.search(r"^Architecture: amd64$", s, re.M)]
    if not found:
        sys.exit("no %s in the PGDG index" % name)
    field = lambda s, f: re.search(r"^%s: (.*)$" % f, s, re.M).group(1)
    best = found[0]
    for s in found[1:]:
        if subprocess.call(["dpkg", "--compare-versions", field(s, "Version"), "gt", field(best, "Version")]) == 0:
            best = s
    print(field(best, "SHA256"), field(best, "Filename"))
' "postgresql-$VERSION" "postgresql-client-$VERSION" libpq5 > "$DIR/debs/pgdg.list"
  while read -r sha file; do
    curl -fsS -o "$DIR/debs/$(basename "$file")" "$PGDG/$file"
    echo "$sha  $DIR/debs/$(basename "$file")" | sha256sum -c --quiet
  done < "$DIR/debs/pgdg.list"
  # Runtime libraries newer majors link against (from the distribution).
  (cd "$DIR/debs" && apt-get download libnuma1 liburing2 >/dev/null)
}

case "$CMD" in
  start)
    if [ ! -x "$BIN/postgres" ]; then
      mkdir -p "$DIR/debs" "$DIR/root"
      if apt-cache show "postgresql-$VERSION" >/dev/null 2>&1; then
        (cd "$DIR/debs" && apt-get download "postgresql-$VERSION" "postgresql-client-$VERSION" libpq5)
      else
        pgdg_download
      fi
      for deb in "$DIR"/debs/*.deb; do dpkg-deb -x "$deb" "$DIR/root"; done
      if ldd "$BIN/postgres" | grep "not found" >&2; then
        echo "missing shared libraries (above)" >&2
        exit 1
      fi
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
    echo "usage: [PG_MAJOR=16] $0 start|stop [dir]" >&2
    exit 2
    ;;
esac

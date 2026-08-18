#!/usr/bin/env bash
# ============================================================================
# Terrastep — run the engine acceptance suite against a throwaway Postgres.
#
#   ./tests/run_tests.sh
#
# Verifies 01_DATA_MODEL.sql + 02_CLAIM_ENGINE.sql deploy cleanly and that all
# claim / contest / decay / anti-cheat rules behave correctly.
# Requires: postgresql (any version >= 14). No Supabase account needed.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

# Locate Postgres binaries: honour an explicit PGBIN, else look in the usual
# places (Debian/Ubuntu, Homebrew, Postgres.app), else fall back to $PATH.
if [ -z "${PGBIN:-}" ]; then
  for d in /usr/lib/postgresql/*/bin \
           /opt/homebrew/opt/postgresql*/bin \
           /usr/local/opt/postgresql*/bin \
           /Applications/Postgres.app/Contents/Versions/*/bin; do
    [ -x "$d/initdb" ] && PGBIN="$d"
  done
fi
[ -n "${PGBIN:-}" ] && export PATH="$PGBIN:$PATH"

if ! command -v initdb >/dev/null 2>&1; then
  echo "ERROR: Postgres client tools not found (initdb)." >&2
  echo "  Debian/Ubuntu : sudo apt-get install -y postgresql" >&2
  echo "  macOS         : brew install postgresql@17" >&2
  echo "  Or set PGBIN=/path/to/postgres/bin" >&2
  exit 127
fi

PGDATA=${PGDATA:-/tmp/terrastep_pg}
SOCK=/tmp/terrastep_sock
mkdir -p "$SOCK"

# Stop any server still running from a previous invocation. A stale postmaster
# holding the port is the most common reason a re-run fails (ISSUES_LOG #16).
pg_ctl -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true

if [ ! -d "$PGDATA" ] || [ ! -f "$PGDATA/PG_VERSION" ]; then
  echo "→ initdb"
  rm -rf "$PGDATA"
  initdb -D "$PGDATA" -U postgres >/dev/null
fi

# Find a free port rather than assuming one is available.
PORT=${PGPORT:-}
if [ -z "$PORT" ]; then
  for p in $(seq 5433 5460); do
    if ! (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null; then PORT=$p; break; fi
    exec 3<&- 2>/dev/null || true
  done
fi
[ -z "$PORT" ] && { echo "ERROR: no free port in 5433-5460" >&2; exit 1; }

echo "→ starting postgres on :$PORT"
if ! pg_ctl -D "$PGDATA" -l /tmp/terrastep_pg.log \
            -o "-k $SOCK -p $PORT" -w -t 30 start >/dev/null 2>&1; then
  echo "ERROR: postgres failed to start. Log tail:" >&2
  tail -15 /tmp/terrastep_pg.log >&2
  exit 1
fi

# Always shut the server down on exit, so a later run starts clean.
cleanup() { pg_ctl -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

PSQL="psql -h $SOCK -p $PORT -U postgres -q -v ON_ERROR_STOP=1"

echo "→ recreating database"
$PSQL -d postgres -c "drop database if exists terrastep;" >/dev/null
$PSQL -d postgres -c "create database terrastep;"        >/dev/null

echo "→ applying shim (emulates Supabase auth/realtime/postgis locally)"
$PSQL -d terrastep -f tests/00_shim.sql >/dev/null

echo "→ applying 01_DATA_MODEL.sql"
sed -e 's/^create extension if not exists postgis.*/-- shimmed/' \
    -e 's/^create extension if not exists pg_cron.*/-- shimmed/' \
    -e 's/^create extension if not exists h3.*/-- shimmed/' \
    -e 's/geography(Point, 4326)/geography/' \
    01_DATA_MODEL.sql | $PSQL -d terrastep -f - >/dev/null

echo "→ applying 02_CLAIM_ENGINE.sql"
sed -e 's/::geography//g' 02_CLAIM_ENGINE.sql | $PSQL -d terrastep -f - >/dev/null

$PSQL -d terrastep -c "
  create schema if not exists tests;
  drop table if exists tests.state;
  create table tests.state(failures int default 0);
  insert into tests.state values (0);" >/dev/null

echo "→ running acceptance suite"
echo ""
OUT=$(psql -h "$SOCK" -p "$PORT" -U postgres -q -d terrastep \
        -f tests/01_engine_tests.sql 2>&1)

echo "$OUT" | grep -E "^(---|psql.*(PASS|FAIL))" \
           | sed 's/^psql:[^:]*:[0-9]*: //;s/NOTICE:  //;s/WARNING:  //'

PASSED=$(echo "$OUT" | grep -c "PASS " || true)
FAILED=$(psql -h "$SOCK" -p "$PORT" -U postgres -tAc \
           "select failures from tests.state" -d terrastep)

echo ""
echo "======================================================"
if [ "$FAILED" = "0" ]; then
  echo "  ✅  ALL $PASSED TESTS PASSED"
  exit 0
else
  echo "  ❌  $FAILED FAILED / $PASSED passed"
  exit 1
fi

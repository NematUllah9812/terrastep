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
PORT=${PGPORT:-5433}
SOCK=/tmp/terrastep_sock
mkdir -p "$SOCK"

if [ ! -d "$PGDATA" ]; then
  echo "→ initdb"
  initdb -D "$PGDATA" -U postgres >/dev/null
fi

if ! pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
  echo "→ starting postgres on :$PORT"
  pg_ctl -D "$PGDATA" -l /tmp/terrastep_pg.log \
         -o "-k $SOCK -p $PORT" start >/dev/null
  sleep 2
fi

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

#!/usr/bin/env bash
# Plugin + real server + Anki's own sync server, all local (never AnkiWeb): checks the deck list
# doesn't sync over and over (see koplugin/devtools/test_sync_loop.lua).
#   devtools/sync_loop_test.sh <collection.anki2 to copy> <work dir> <lua rocks tree>
set -euo pipefail
SRC=$1; WORK=$2; ROCKS=$3
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$ROOT/target/release
SYNC_PORT=8092; KPORT=47993
EP="http://127.0.0.1:$SYNC_PORT/"
rm -rf "$WORK" && mkdir -p "$WORK/desktop" "$WORK/data" "$WORK/syncbase"
cp -c "$SRC" "$WORK/desktop/collection.anki2"
cleanup() { kill "${SYNC_PID:-}" "${KANKI_PID:-}" 2>/dev/null || true; }
trap cleanup EXIT

SYNC_USER1=test:test SYNC_BASE="$WORK/syncbase" SYNC_HOST=127.0.0.1 SYNC_PORT=$SYNC_PORT \
  "$BIN/kanki_devsync" server >/dev/null 2>&1 &
SYNC_PID=$!
for _ in $(seq 1 60); do curl -s "$EP" >/dev/null && break; sleep 0.5; done
"$BIN/kanki_devsync" upload "$WORK/desktop/collection.anki2" "$EP" test test >/dev/null

# Like the Kobo after its first successful download: logged in, collection present.
"$BIN/kanki" serve --data-dir "$WORK/data" --port $KPORT >>"$WORK/data/kanki.log" 2>&1 &
KANKI_PID=$!
API="http://127.0.0.1:$KPORT"
for _ in $(seq 1 60); do curl -s "$API/status" >/dev/null && break; sleep 0.5; done
curl -s -X POST -d "{\"username\":\"test\",\"password\":\"test\",\"endpoint\":\"$EP\"}" "$API/login" >/dev/null
curl -s -X POST -d '{"kind":"normal"}' "$API/sync" >/dev/null
for _ in $(seq 1 600); do curl -s "$API/sync" | grep -q '"running"' || break; sleep 0.5; done
curl -s -X POST "$API/shutdown" >/dev/null; sleep 1; KANKI_PID=

export LUA_PATH="$ROCKS/share/lua/5.1/?.lua;$ROCKS/share/lua/5.1/?/init.lua;;" LUA_CPATH="$ROCKS/lib/lua/5.1/?.so;;"
cd "$ROOT/koplugin/devtools"
KANKI_REAL_BIN="$BIN/kanki" KANKI_DATA_DIR="$WORK/data" KANKI_TEST_PORT=$KPORT KANKI_AUTOSTART=1 \
  KANKI_TEST_QUIET=1 luajit test_sync_loop.lua

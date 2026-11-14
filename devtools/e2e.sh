#!/usr/bin/env bash
# End-to-end test of kanki against Anki's own sync server running locally (never touches AnkiWeb).
#   devtools/e2e.sh <source collection.anki2> <work dir>
# The source collection is cloned (APFS copy-on-write), never modified.
set -euo pipefail

SRC=$1
WORK=$2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$ROOT/target/release
SYNC_PORT=8090
KPORT=47999
EP="http://127.0.0.1:$SYNC_PORT/"
API="http://127.0.0.1:$KPORT"

rm -rf "$WORK" && mkdir -p "$WORK/desktop" "$WORK/kobo" "$WORK/syncbase"
cp -c "$SRC" "$WORK/desktop/collection.anki2"

cleanup() { kill "${SYNC_PID:-}" "${KANKI_PID:-}" 2>/dev/null || true; }
trap cleanup EXIT

SYNC_USER1=test:test SYNC_BASE="$WORK/syncbase" SYNC_HOST=127.0.0.1 SYNC_PORT=$SYNC_PORT \
  "$BIN/kanki_devsync" server >"$WORK/syncserver.log" 2>&1 &
SYNC_PID=$!
for _ in $(seq 1 60); do curl -s "$EP" >/dev/null && break; sleep 0.5; done

step() { printf '\n== %s\n' "$*"; }
get() { curl -sS "$API$1"; }
post() { curl -sS -X POST -H 'Content-Type: application/json' -d "${2:-{\}}" "$API$1"; }
wait_sync() {
  for _ in $(seq 1 600); do
    s=$(get /sync)
    state=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' <<<"$s")
    [ "$state" != running ] && { echo "$s"; return; }
    sleep 0.5
  done
  echo "sync timed out"; exit 1
}
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

step "desktop: full upload of a copy of the collection to the local sync server"
"$BIN/kanki_devsync" upload "$WORK/desktop/collection.anki2" "$EP" test test

step "kobo: start server with an empty data dir"
"$BIN/kanki" serve --data-dir "$WORK/kobo" --port $KPORT >"$WORK/kanki.log" 2>&1 &
KANKI_PID=$!
for _ in $(seq 1 60); do curl -s "$API/status" >/dev/null && break; sleep 0.5; done
get /status; echo
step "kobo: /next before login (expect need_login)"
get /next; echo

step "kobo: bad password (expect 401 auth)"
post /login "{\"username\":\"test\",\"password\":\"nope\",\"endpoint\":\"$EP\"}"; echo
step "kobo: login"
post /login "{\"username\":\"test\",\"password\":\"test\",\"endpoint\":\"$EP\"}"; echo

step "kobo: first sync (should become a full download)"
post /sync '{"kind":"normal"}'; echo
wait_sync

step "verify: every card and note arrived"
get /verify; echo
python3 - "$WORK/desktop/collection.anki2" <<'EOF'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?immutable=1", uri=True)
print("desktop:", {"cards": db.execute("select count(*) from cards").fetchone()[0],
                   "notes": db.execute("select count(*) from notes").fetchone()[0]})
EOF

step "kobo: deck list (first 5)"
get /decks | python3 -c 'import json,sys; d=json.load(sys.stdin); print("current", d["current_id"]); [print(x) for x in d["decks"][:5]]'

DECK=$(get /decks | field 'max(d["decks"], key=lambda x: x["review"]+x["learning"]+x["new"])["id"]')
step "kobo: select deck with most due ($DECK) and get next card"
post /deck/select "{\"id\":$DECK}"; echo
get "/next?img_max_px=600" | field '{k: (v if k!="card" else {kk: (vv[:120] if isinstance(vv,str) else vv) for kk,vv in v.items()}) for k,v in d.items()}'
CID=$(get "/next" | field 'd["card"]["id"]')

step "kobo: answer Good, then undo, then answer Again"
post /answer "{\"card_id\":$CID,\"rating\":3,\"ms_taken\":4200}" | field '{"state": d["state"], "counts": d["counts"], "undo": d["undo"], "next": d.get("card",{}).get("id")}'
post /undo | field '{"state": d["state"], "undo": d["undo"], "back_to": d.get("card",{}).get("id")}'
post /answer "{\"card_id\":$CID,\"rating\":1,\"ms_taken\":5100}" | field '{"state": d["state"], "counts": d["counts"], "undo": d["undo"]}'

step "kobo: normal sync uploads the review"
post /sync '{"kind":"normal"}'; echo
wait_sync

step "desktop: normal sync pulls the Kobo review"
"$BIN/kanki_devsync" sync "$WORK/desktop/collection.anki2" "$EP" test test
python3 - "$WORK/desktop/collection.anki2" "$CID" <<'EOF'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?immutable=1", uri=True)
rows = db.execute("select id, ease, time from revlog where cid=? order by id desc limit 3", (int(sys.argv[2]),)).fetchall()
print("desktop revlog for card", sys.argv[2], rows)
EOF

step "desktop: review 3 cards Good and sync; kobo then syncs and should see them"
"$BIN/kanki_devsync" review "$WORK/desktop/collection.anki2" 3
"$BIN/kanki_devsync" sync "$WORK/desktop/collection.anki2" "$EP" test test
post /sync '{"kind":"normal"}'; echo
wait_sync

step "media: desktop uploads 20 files; the Kobo already has 10 of them (like the USB pre-copy)"
MEDIA_SRC="$HOME/Library/Application Support/Anki2/User 1/collection.media"
mkdir -p "$WORK/desktop/collection.media"
ls "$MEDIA_SRC" | grep -E '\.(jpg|png)$' | awk 'NR<=20' > "$WORK/media.list"
while read -r f; do cp -c "$MEDIA_SRC/$f" "$WORK/desktop/collection.media/"; done < "$WORK/media.list"
"$BIN/kanki_devsync" media "$WORK/desktop/collection.anki2" "$EP" test test
awk 'NR<=10' "$WORK/media.list" | while read -r f; do cp -c "$MEDIA_SRC/$f" "$WORK/kobo/collection.media/"; done
post /sync '{"kind":"normal"}'; echo
wait_sync
echo "expect downloaded 10, uploaded 0; kobo media files now: $(ls "$WORK/kobo/collection.media" | wc -l | tr -d ' ')"

step "kobo: shutdown"
post /shutdown; echo
sleep 2
tail -12 "$WORK/kanki.log"

step "desktop reviews reached the Kobo (compared after the Kobo closed its collection)"
python3 - "$WORK/kobo/collection.anki2" "$WORK/desktop/collection.anki2" <<'EOF'
import sqlite3, sys
def counts(p):
    db = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
    return db.execute("select count(*), max(id) from revlog").fetchone()
print("kobo revlog (count, latest id):   ", counts(sys.argv[1]))
print("desktop revlog (count, latest id):", counts(sys.argv[2]))
EOF

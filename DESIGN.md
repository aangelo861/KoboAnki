# kobo-anki (kanki): Anki on a Kobo, synced with AnkiWeb

Target device: Kobo Libra Colour (N428, codename "monza", MTK, 32-bit ARMv7 userland, colour Kaleido 3,
1264x1680 @ 300 dpi, two physical page-turn buttons), stock firmware 4.46, KOReader v2026.07.1 installed at
`/mnt/onboard/.adds/koreader`, NickelMenu v0.6.0.

## Architecture

```
NickelMenu "Anki"  ──>  kanki.koplugin/launch.sh (KANKI_AUTOSTART=1) ──> KOReader
                                                                          │
                         kanki.koplugin (Lua UI)  ── HTTP/JSON on 127.0.0.1:47321 ──>  kanki (Rust, static armv7 musl)
                                                                                         │  Anki's own rslib 26.09.3
                                                                                         ├─ collection.anki2 (SQLite)
                                                                                         ├─ collection.media/
                                                                                         └─ AnkiWeb sync (HTTPS)
```

* `kanki` (Rust) owns everything Anki: AnkiWeb login/sync (collection + media), scheduling (SM-2/FSRS exactly
  as desktop), undo, card rendering (templates, cloze), HTML clean-up for e-ink and image-occlusion flattening.
* `kanki.koplugin` (Lua) is a thin UI: deck list, reviewer, settings, sync progress. It starts/stops the server.
* Never full-UPLOAD from the Kobo. Full sync is download-only (AnkiWeb stays the source of truth).

## Paths on the device

| What | Path |
|---|---|
| Plugin | `/mnt/onboard/.adds/koreader/plugins/kanki.koplugin/` |
| Server binary | `/mnt/onboard/.adds/koreader/plugins/kanki.koplugin/bin/kanki` |
| Data dir (`--data-dir`) | `/mnt/onboard/.adds/kanki/` |
| Collection | `<data>/collection.anki2` |
| Media | `<data>/collection.media/` + `<data>/collection.mdb` (rslib's media DB name) |
| Auth (hkey + endpoint + username, never the password) | `<data>/auth.json` |
| Log | `<data>/kanki.log` |

`/mnt/onboard` is FAT32; dot-folders are excluded from Nickel's library scan via `ExcludeSyncFolders`.

## Server CLI

```
kanki serve --data-dir DIR [--port 47321] [--parent-pid PID]
kanki version
```
`serve` binds 127.0.0.1 only. It exits (closing the collection cleanly) on `POST /shutdown`, when `--parent-pid`
no longer exists (checked every 5 s), or after 30 min without requests. If the port is already bound by a
healthy kanki, the new instance exits with code 3 (the UI just reuses the running one).

## HTTP API (all JSON, UTF-8)

Errors: non-2xx with `{"error": "<human message>", "kind": "<machine kind>"}`; kinds include
`need_login`, `no_collection`, `busy` (collection sync running, HTTP 409), `bad_request`, `network`,
`auth` (bad AnkiWeb credentials), `internal`.

### `GET /status`
```json
{"version":"0.1.0","anki_version":"26.09.3","logged_in":true,"username":"me@example.com",
 "has_collection":true,"card_count":4528,
 "sync":{ ... same as GET /sync ... },
 "undo":"Answer Card"}          // undo label or null
```

### `POST /login` `{"username":"...","password":"..."}` → `{"ok":true}`; bad credentials → 401 kind `auth`.
### `POST /logout` → `{"ok":true}` (deletes auth.json only).

### `POST /sync` `{"kind":"normal"}` or `{"kind":"full_download"}` → 202 `{"started":true}`
Starts a background job: collection sync, then media sync. If there is no local collection (or it has no
cards) a normal sync automatically becomes a full download. Reviews may continue during the media phase.
### `GET /sync`
```json
{"state":"idle|running|done|error|full_sync_required",
 "stage":"collection|media|null",
 "message":"human readable progress or error",
 "server_message":"",                       // AnkiWeb notice, show if non-empty
 "media":{"checked":0,"downloaded":0,"uploaded":0,"deleted":0},
 "last_success":1761999999}                 // unix secs or null
```
`full_sync_required`: the UI must ask the user before `POST /sync {"kind":"full_download"}` (warn that
reviews done on the Kobo since the last sync will be lost).

### `GET /decks`
```json
{"current_id":1,
 "decks":[{"id":1,"name":"Medicine::Paper B","short_name":"Paper B","depth":1,
           "new":0,"learning":2,"review":5,"collapsed":false,"has_children":true}]}
```
Flattened depth-first order (children follow parent), counts already limited like desktop's deck list.

### `POST /deck/select` `{"id":123}` → `{"ok":true}`

### `GET /next?img_max_px=<int>`
`img_max_px` = the reviewer's content width in CSS px; images wider than this get width-capped.
```json
{"state":"card",                      // or "done" (nothing due: show congrats), or "no_collection"
 "counts":{"new":3,"learning":1,"review":12},
 "undo":"Answer Card",               // or null
 "card":{"id":1690000000000,"note_id":1690000000001,"deck":"Medicine::Paper B",
         "kind":"new|learning|review|relearning",
         "question":"<html>","answer":"<html>","css":"<css>",
         "buttons":[{"rating":1,"label":"Again","interval":"<1m"},
                    {"rating":2,"label":"Hard","interval":"6m"},
                    {"rating":3,"label":"Good","interval":"10m"},
                    {"rating":4,"label":"Easy","interval":"4d"}]}}
```
`question`/`answer` are body fragments (no `<html>`), already cleaned: no `<script>`, no `[sound:]`, image
occlusion masks flattened into the image, media `src` relative to the media dir (UI passes the media dir as the
HTML resource directory). `answer` includes the front side as Anki does; the boundary is `<hr id=answer>`.

### `POST /answer` `{"card_id":..., "rating":1-4, "ms_taken":12345}` → same body as `GET /next`
(the next card). `img_max_px` may also be given as a query param.
### `POST /undo` → same body as `GET /next` (the undone card comes back first).
### `POST /bury` `{"card_id":...}` / `POST /suspend` `{"card_id":...}` → same body as `GET /next`.
### `POST /shutdown` → `{"ok":true}` only after the collection is closed (any sync aborted); the process exits ~1 s later.
### `POST /adopt` `{"parent_pid": N}` → `{"ok":true}`: a reused server watches the new KOReader pid.
### `GET /verify` → `{"cards":N,"notes":N,"media_files":N}` (confirms the whole collection is on the device).
### `GET /card?id=CID&img_max_px=N` → `{"id","question","answer","css"}` (flat; renders any card, no queue change).

Card payloads also carry `"ord"` (1-based template number); the UI wraps fragments in `<div class="card card{ord}">`.
Status codes: need_login/auth 401, no_collection 404, busy 409, bad_request 400, others 500 — branch on `kind`.
The server closes inherited fds at startup; the UI launches it with `cd /` and waits for it to exit before USB
mass storage. Before each media sync the server deletes macOS `._*` files from the media folder.

## Reviewer UX (Libra Colour)

* Question side: tap anywhere in the card or press either page button → show answer.
* Answer side: a full-width bottom bar of 4 large buttons, one tap rates:
  `Again | Hard | Good | Easy`, each showing its next interval. Page buttons: forward (PgFwd) = Good,
  back (PgBack) = Again. KOReader's own "invert page-turn buttons" setting is respected automatically.
  The mapping can be swapped in settings.
* Top bar: deck name, counts (new/learn/review, the current card's queue underlined), Undo, menu
  (Bury, Suspend, Sync, Back to decks).
* Long cards scroll (swipe); rating never happens on swipe, only on button tap or page key.
* Full e-ink refresh every N cards (default 6) to clear colour ghosting; partial refresh otherwise.
* `ms_taken` measured from question shown to rating (capped server-side as desktop does).

## v0.2: study timer, Pomodoro, stats screen, sleep screen (Nov 2026)

### Server additions
* `GET /stats` (≈20 ms on a Mac, a few hundred ms on the Kobo — the UI caches it):
```json
{"today":{"answered":2,"seconds":19,"correct":1,"learn":0,"review":2,"relearn":0,"mature_correct":0,"mature_total":0},
 "days":[{"day":-13,"count":0,"seconds":0}, … ,{"day":0,"count":2,"seconds":19}],   // last 14 Anki days, oldest first
 "streak":2, "due_tomorrow":11, "due_today":{"new":543,"learning":1,"review":23},
 "retention":{"today":0.5,"week":0.96,"month":0.95},                                  // true retention, null if no reviews
 "cards":{"new":543,"learn":0,"relearn":1,"young":90,"mature":3525,"suspended":987,"buried":0},
 "studied_text":"Studied 2 cards …", "next_day_at":1793592000, "generated_at":1793552679}
```
  Anki days roll over at the collection's rollover hour (4 am by default): `next_day_at` is when "today" resets.
* `POST /flag {"card_id":…, "flag":0-7}` → `{"ok":true,"flag":n}` (0 clears; 1 red, 2 orange, 3 green, 4 blue,
  5 pink, 6 turquoise, 7 purple). `/next` card payloads carry `"flag"`.
* Idle server wakes only every 30 s (was 1 s).

### Shared plugin modules (written; keep their APIs)
* `kanki/tracking.lua` — per-day counters + small persistent values (`add`, `day`, `lastDays`, `totals`,
  `get`/`set`, `flush`). Writes are deferred: call `Tracking:flush()` at the end of a session, after a finished
  Pomodoro, on suspend and on exit — never per card.
* `kanki/settings.lua` — new keys: `show_session_timer`, `pomodoro_enabled`, `pomodoro_focus_min`,
  `pomodoro_short_break_min`, `pomodoro_long_break_min`, `pomodoro_long_break_every`, `pomodoro_autostart`,
  `sleep_screen_stats`, `wifi_off_after_sync`.
* `kanki/client.lua` — `Client:stats(opts)`, `Client:flag(card_id, flag)`.

### Study timer + Pomodoro (reviewer)
* Session timer runs while the reviewer is open; pauses on Suspend, on a break screen, and resumes on Resume.
  On close: `Tracking:add{study_s=…, cards=…, sessions=1}` then flush.
* Top bar shows e.g. `12 min · 34 cards` and `Focus 18 min` / `Break 3 min`, redrawn once a minute (aligned to
  the minute), `"ui"` refresh of the top-bar region only, never while suspended. No per-second updates.
* Pomodoro: idle → focus → short/long break → focus …; durations from settings; long break every N; completed
  focus → `Tracking:add{pomodoros=1, focus_s=…}` + flush. Focus end → dialog "take a break?"; break → full-screen
  break view with minute countdown and "Skip break" (page keys skip). Paused while asleep.
* Reviewer menu: Flag card (7 colours + remove), Pomodoro pause/resume/skip. A small coloured flag marker in the
  top bar.
* Rotation: reviewer relayouts on `SetDimensions`/`ScreenResize` (the Libra Colour has a G-sensor).
* Wi-Fi: if `wifi_off_after_sync` and Wi-Fi was off before a sync started, turn it off when the sync ends.

### Stats screen + sleep screen
* Anki numbers come only from the cached `/stats` body (`Tracking` key `anki_stats_cache`), refreshed after a
  review session, after a sync and when the stats screen opens — only if the server is already running. Never
  start the server for stats. If `now >= next_day_at`, show today as 0.
* Reading: KOReader's `statistics.sqlite3` (pages/time today and this week, current KOReader book %) and the Kobo's
  own `KoboReader.sqlite` (read-only; Nickel isn't running while KOReader is). Nickel only keeps per-book running
  totals (`content.TimeSpentReading`, `___PercentRead`, `DateLastRead`, `Event` type 46 = page turns), so daily
  numbers come from snapshot deltas stored in `Tracking` (`nickel_snapshot`), attributed to each book's
  `DateLastRead` day. The first snapshot only records a baseline.
* Stats view (reading first, after the owner's feedback): one static full-screen widget, colour on the Kaleido
  screen, greys otherwise. Portrait: header (date, time, battery); READING (~56 %): current book (latest of
  Nickel/KOReader) with its cover (Nickel's `.kobo-images/…/<ImageId> - N3_FULL.parsed` JPEGs, found once by walking
  the tree, path cached in `Tracking`, pre-scaled copy cached in KOReader's `cache/kanki-covers/`; KOReader books
  from CoverBrowser's thumbnail cache), big title, %, thick progress bar, today and last-7-days pages/minutes
  (Kobo + KOReader), 14-day minutes chart, second book on one line; ANKI (~25 %): cards answered, time, % correct,
  streak, due tomorrow (+ chart if it fits); STUDY: one line (study, focus, Pomodoro dots). Landscape: reading left,
  Anki + study right. Covers are prepared in the background (after the Nickel snapshot); never decoded or searched
  at sleep time when cached (≈15–40 ms extra per sleep on the device, estimated).
* Sleep screen: when `sleep_screen_stats` is on, KOReader's sleep screen shows the stats view. Built from caches
  only (no network, no server start, fast), drawn once (E Ink keeps it with zero power), flagged dithered so the
  colour waveform is used. Also reachable in-app ("Today's stats").

# kanki.koplugin devtools

Desktop tooling for the KOReader plugin. Nothing in here is deployed to the Kobo.

| File | What it is |
|---|---|
| `mock_server.py` | Mock of the `kanki serve` HTTP API from `DESIGN.md` (Python 3, stdlib only). |
| `test_client.lua` | Tests for `kanki/json`, `kanki/client`, `kanki/cardhtml` against the mock. |
| `test_ui_smoke.lua` | Headless end-to-end run of the whole plugin (autostart → server spawn → login → first download → deck list → reviewing → crash recovery → auto-sync → exit) with KOReader's UI layer stubbed out. |
| `stubs/` | Minimal stand-ins for KOReader modules (`logger`, `gettext`, widgets, UIManager…), used only by the tests. |
| `check_koreader_api.py` | Static check that every `require()` and every `Module:method` / `Module.field` the plugin uses exists in an installed KOReader (read-only). |
| `luacheckrc.lua` | luacheck config for the plugin. |

## Mock server

```sh
python3 mock_server.py                       # scenario "ready" on 127.0.0.1:47321
python3 mock_server.py --scenario fresh      # logged out, no collection (first-run flow)
python3 mock_server.py --scenario full-sync  # first sync answers full_sync_required
python3 mock_server.py --scenario sync-error
python3 mock_server.py --sync-speed 0.1      # 10x faster simulated syncs
python3 mock_server.py --data-dir /tmp/kanki --write-media   # also writes the sample image
python3 mock_server.py --shutdown-delay 3 --exit-delay 1      # slow, realistic shutdown
python3 mock_server.py --ignore-shutdown                      # never exits (kill fallback)
```

It accepts the same CLI as the real binary (`serve --data-dir DIR --port N --parent-pid PID`),
exits with code 3 if the port is taken, watches `--parent-pid` every 5 s and exits after 30 min
idle, so it can stand in for `bin/kanki` (e.g. in KOReader's desktop emulator, put a two-line
shell wrapper at `kanki.koplugin/bin/kanki` that execs it).

Behaviour worth knowing:
* Login accepts any email and any password except `wrong` (→ 401 `auth`). Passwords are never printed.
* `POST /sync` → 202, then `GET /sync` goes `running/collection` → `running/media` (with growing
  media counters) → `done`. During the collection stage the collection endpoints answer
  409 `busy`. Without a collection a normal sync becomes a full download (like the real server).
* Every third completed sync carries a `server_message`.
* `POST /shutdown` replies only after `--shutdown-delay` (the real server closes the collection
  and aborts any sync first, up to ~15 s), keeps answering for `--exit-delay`, then exits.
* `POST /adopt {"parent_pid": N}` changes the pid the watchdog follows; `GET /status` reports it in
  the mock-only field `mock_parent_pid`. `GET /status` also has `media_dir`.
* `GET /card?id=N&img_max_px=W` renders any card without touching the queue (response
  `{"card": {...}}` — the shape is the mock's guess); `GET /verify` → `{cards, notes, media_files}`.
* Status codes as the real server: need_login 401, auth 401, no_collection 404, busy 409,
  bad_request 400. The plugin branches on `kind` only.
* `/next` returns realistic medical cards with `ord`: basic, cloze, an image card
  (`ecg_stemi.png`, natural width 1600 px, so it gets `width="img_max_px"` like the real server
  does for images wider than `img_max_px`), an image-occlusion card carrying one ~290 KB
  `data:image/png;base64` image per side, a long multi-page card, inline `style` px sizes, a table. Rating 1 re-queues the card; `/undo` restores the previous state and puts
  the undone card first. Integer validation is strict (`card_id`, `ms_taken` must be JSON integers,
  as serde would require).

## Running the Lua tests on a Mac

```sh
brew install luajit luarocks
T=/tmp/kanki-rocks
for r in luasocket luafilesystem dkjson luacheck; do
  luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" --tree=$T install $r
done
export LUA_PATH="$T/share/lua/5.1/?.lua;$T/share/lua/5.1/?/init.lua;;"
export LUA_CPATH="$T/lib/lua/5.1/?.so;;"

cd koplugin/devtools
python3 mock_server.py --scenario fresh --sync-speed 0.1 --port 47399 &
luajit test_client.lua 47399          # the test shuts the mock down at the end

KANKI_AUTOSTART=1 luajit test_ui_smoke.lua fresh       # spawns the mock itself via a bin/kanki wrapper
KANKI_AUTOSTART=1 luajit test_ui_smoke.lua full-sync

$T/bin/luacheck --config luacheckrc.lua ../kanki.koplugin
python3 check_koreader_api.py /Volumes/KOBOeReader/.adds/koreader
for f in $(find ../kanki.koplugin -name '*.lua'); do luajit -bl "$f" >/dev/null || echo "FAIL $f"; done
```

Set `KANKI_TEST_QUIET=1` to hide the stub logger's info lines.

The smoke test only proves the plugin's own logic and its use of the API flows; the stubs don't
paint, lay out, or deliver real touch/key events. Layout, refresh behaviour and MuPDF rendering
must be checked on the device (see the list in the plugin hand-over notes).

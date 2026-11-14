--[[
Headless smoke test of the whole plugin flow on a desktop, against mock_server.py, with KOReader's
UI layer replaced by stubs (stubs/koreader_stubs.lua). It exercises the plugin's own logic:
autostart, spawning the server via bin/kanki (a wrapper around the mock), login, first download,
deck list, reviewing (page keys, taps, guard, key repeat, undo, bury), server crash recovery,
auto-sync after a session, full-sync confirmation, and exit-to-Kobo.

    KANKI_AUTOSTART=1 luajit test_ui_smoke.lua fresh
    KANKI_AUTOSTART=1 luajit test_ui_smoke.lua full-sync

(LUA_PATH/LUA_CPATH must provide luasocket, lfs and dkjson; see README.md.)
]]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local abs_here = io.popen("cd '" .. here .. "' && pwd"):read("*l")
local plugin_src = abs_here .. "/../kanki.koplugin"
package.path = table.concat({
    abs_here .. "/stubs/?.lua",
    plugin_src .. "/?.lua",
    package.path,
}, ";")

local scenario = arg[1] or "fresh"
local PORT = tonumber(os.getenv("KANKI_TEST_PORT") or "") or 47398

local Stubs = require("koreader_stubs")
local UIManager = Stubs.UIManager
local socket = require("socket")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("ok   " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. (detail ~= nil and (": " .. tostring(detail)) or ""))
    end
end
local function wait(s) UIManager:runTasks(s) end
local function waitFor(s, fn) return UIManager:runTasks(s, fn) end

-- Temp plugin dir with bin/kanki = wrapper around the mock server -------------------------------
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p '" .. tmp .. "/kanki.koplugin/bin' '" .. tmp .. "/data'")
local wrapper = tmp .. "/kanki.koplugin/bin/kanki"
local MOCK_FLAGS = "--sync-speed 0.1 --write-media --shutdown-delay 1.0 --exit-delay 0.8"
local function writeWrapper(scen)
    local f = assert(io.open(wrapper, "w"))
    f:write(string.format([[#!/bin/sh
exec python3 -I '%s/mock_server.py' "$@" --scenario %s %s
]], abs_here, scen, MOCK_FLAGS))
    f:close()
end
writeWrapper(scenario)
local function killMock(sig)
    os.execute(string.format("pkill -%s -f '[m]ock_server.py.*--port %d' 2>/dev/null", sig or "9", PORT))
end
Stubs.settings_dir = tmp

local Settings = require("kanki/settings")
Settings:set("data_dir", tmp .. "/data")
local Server = require("kanki/server")
local Client = require("kanki/client")
Server.PORT = PORT
Client:setPort(PORT)
local Sync = require("kanki/sync")
local App = require("kanki/app")

check("KANKI_AUTOSTART=1 in env", os.getenv("KANKI_AUTOSTART") == "1")

-- Instantiate the plugin like PluginLoader + FileManager would ---------------------------------
local registered
local Kanki = dofile(plugin_src .. "/main.lua")
local instance = Kanki:new{
    path = tmp .. "/kanki.koplugin",
    ui = { menu = { registerToMainMenu = function(_, w) registered = w end } },
}
check("registered to main menu", registered == instance)
local order = require("ui/elements/filemanager_menu_order")
check("menu order patched", order.main[1] == "kanki" and order.main[2]:match("^%-+$") ~= nil)
local menu_items = {}
instance:addToMainMenu(menu_items)
check("main menu entry", menu_items.kanki and menu_items.kanki.text == "Anki" and #menu_items.kanki.sub_item_table == 5)

-- Second instance (reader <-> file manager switch) must not autostart again.
Kanki:new{ path = tmp .. "/kanki.koplugin", ui = { menu = { registerToMainMenu = function() end } } }

-- Every Exit/Close broadcast also reaches the plugin instance (it's a child of FileManager).
local exit_broadcast = false
Stubs.broadcast_hook = function(ev)
    if ev.name == "Exit" then exit_broadcast = true end
    instance:handleEvent(ev)
end

-- Autostart -> deck list -> server spawn ------------------------------------------------------------
check("deck list opens on next tick", waitFor(1, function() return App.decklist ~= nil end))
local decklist = App.decklist
check("only one deck list", #UIManager._stack == 1, #UIManager._stack)
check("server spawned and running", waitFor(12, function() return Server.state == "running" end), Server.state)

local function deckItems()
    local n = 0
    for _, item in ipairs(decklist.item_table or {}) do if item.deck then n = n + 1 end end
    return n
end

if scenario == "fresh" then
    check("login dialog shown", waitFor(5, function() return Stubs.lastShown("MultiInputDialog") ~= nil end))
    check("login placeholder row", decklist.item_table[1] and decklist.item_table[1].callback ~= nil)
    -- Wrong password first
    Stubs.login_fields = { " doctor@example.com ", "wrong" }
    local dlg = Stubs.lastShown("MultiInputDialog")
    dlg.buttons[1][2].callback()
    check("bad password reopens dialog with message",
        waitFor(3, function()
            local d = Stubs.lastShown("MultiInputDialog")
            return d and d ~= dlg and d.fields[1].description ~= nil
        end))
    check("username remembered (trimmed)", Settings:get("last_username") == "doctor@example.com")
    Stubs.login_fields = { "doctor@example.com", "correct horse" }
    Stubs.lastShown("MultiInputDialog").buttons[1][2].callback()
    check("first download starts", waitFor(3, function() return Sync:isActive() end))
    check("downloading placeholder", decklist.item_table[1].text:find("Downloading") ~= nil, decklist.item_table[1].text)
    check("decks appear after download", waitFor(20, function() return deckItems() > 0 end))
    waitFor(10, function() return not Sync:isActive() end)
elseif scenario == "full-sync" then
    check("decks shown", waitFor(5, function() return deckItems() > 0 end))
    check("auto-sync started", waitFor(3, function() return Sync:isActive() end))
    check("full-sync confirm shown", waitFor(10, function() return Stubs.lastShown("ConfirmBox") ~= nil end))
    local cb = Stubs.lastShown("ConfirmBox")
    check("confirm warns about lost reviews", cb.text:find("lost") ~= nil)
    UIManager:close(cb)
    cb.ok_callback()
    check("full download runs", waitFor(3, function() return Sync:isActive() end))
    check("full download completes", waitFor(20, function() return not Sync:isActive() end))
    check("decks still there", deckItems() > 0)
end

check("header shows last sync", (decklist.header._status_text or ""):find("Last sync") ~= nil, decklist.header._status_text)

-- Collapse/expand ---------------------------------------------------------------------------------
local before = #decklist.item_table
local medicine
for _, item in ipairs(decklist.item_table) do if item.deck and item.deck.id == 10 then medicine = item end end
decklist:onMenuHold(medicine)
check("collapse hides children", #decklist.item_table < before, #decklist.item_table)
decklist:onMenuHold(decklist.item_table[2])
check("expand restores", #decklist.item_table == before)
local indent_ok = false
for _, item in ipairs(decklist.item_table) do
    if item.deck and item.deck.id == 13 then indent_ok = item.text:find("^\226\128\131\226\128\131") ~= nil end
end
check("depth-2 deck indented", indent_ok)

-- Review --------------------------------------------------------------------------------------------
local paperA
for _, item in ipairs(decklist.item_table) do if item.deck and item.deck.id == 11 then paperA = item end end
check("deck row has counts", paperA and paperA.mandatory:match("^%d+ · %d+ · %d+$") ~= nil, paperA and paperA.mandatory)
decklist:onMenuSelect(paperA)
local r = App.reviewer
check("reviewer opened", r ~= nil)
check("question shown", waitFor(5, function() return r.state == "question" end), r.state)
check("img_max_px = card width minus scrollbar", r.img_max_px == 1264 - 2 * 22 - 13 - 26, r.img_max_px)
-- font_size 22 -> Screen:scaleBySize(22) = 47 device px; Anki's 20px base maps to it.
check("card css scaled", Stubs.last_html.css:find("font-size: 47px", 1, true) ~= nil)
check("scroll keys disabled", next(Stubs.last_html.key_events) == nil)
check("tap scroll disabled", Stubs.last_html.ignore_taps == true)
check("wrapped with card ord", Stubs.last_html.html_body:find('^<div class="card card1">') ~= nil)
check("resource dir = /status media_dir", Stubs.last_html.html_resource_directory == tmp .. "/data/collection.media",
    Stubs.last_html.html_resource_directory)
local first = r.card.id

local Event = require("ui/event")
r:handleEvent(Event:new("KankiTapCard"))
check("guard: immediate tap ignored", r.state == "question")
wait(0.4)
r:handleEvent(Event:new("KankiPageBack"))
check("page key shows answer", r.state == "answer")
check("4 rating buttons with intervals", r.rating_buttons and #r.rating_buttons == 4 and r.rating_buttons[3].sublabel ~= "")
r:handleEvent({ handler = "onKeyRepeat", args = { n = 0 } })
check("key repeat ignored", r.state == "answer")
r:handleEvent(Event:new("KankiTapCard"))
check("tap on answer never rates", r.state == "answer" and r.card.id == first)
wait(0.4)
r:handleEvent(Event:new("KankiPageFwd"))
check("PgFwd = Good -> next card", r.state ~= "answer" and r.answered == 1, r.state)
check("undo enabled", r.undo_label == "Answer Card")
wait(0.4)
r:undo()
check("undo brings the card back", r.card and r.card.id == first and r.answered == 0)

-- Swap page keys: PgFwd = Again
Settings:set("swap_page_keys", true)
wait(0.4)
r:handleEvent(Event:new("KankiTapCard"))
wait(0.4)
r:handleEvent(Event:new("KankiPageFwd"))
check("swapped: PgFwd = Again re-queues", r.answered == 1)
Settings:set("swap_page_keys", false)

-- Server crashes (SIGKILL) -> next action restarts it and reloads.
-- (The real server keeps its state on disk; make the respawned mock start with a collection.)
writeWrapper("ready")
killMock("9")
socket.sleep(0.3)
wait(0.4)
local was = r.state
if was == "question" then r:handleEvent(Event:new("KankiTapCard")) wait(0.4) end
r:rate(3)
check("server restarted after crash", waitFor(12, function() return Server.state == "running" end), Server.state)
check("reviewer reloaded after restart", waitFor(5, function() return r.state == "question" or r.state == "done" end), r.state)

-- Menu: bury
wait(0.4)
r:showMenu()
local menu = Stubs.lastShown("ButtonDialog")
check("reviewer menu", menu and menu.buttons[1][1].text == "Bury card")
if r.state == "question" then
    local before_id = r.card.id
    menu.buttons[1][1].callback()
    check("bury -> different card", r.card == nil or r.card.id ~= before_id)
else
    UIManager:close(menu)
end

-- Rate through the rest of the deck
for _ = 1, 20 do
    if r.state ~= "question" then break end
    wait(0.36)
    r:handleEvent(Event:new("KankiTapCard"))
    wait(0.36)
    r.rating_buttons[3].callback()
end
check("congrats screen", r.state == "done", r.state)

-- Back to decks -> auto-sync after session
r:close()
check("reviewer closed", App.reviewer == nil and not UIManager:isShown(r))
check("auto-sync after session", waitFor(3, function() return Sync:isActive() end))
check("sync finishes", waitFor(20, function() return not Sync:isActive() end))

-- Settings menu (standalone TouchMenu from the deck list's menu)
App:showSettingsMenu()
local tm, tm_container = Stubs.lastShown("TouchMenu")
check("settings touch menu", tm and #tm.tab_item_table[1] >= 6)
UIManager:close(tm_container)

-- Close the deck list: autostarted + setting on -> exit to Kobo.
-- Server:stop() must block until the process is gone (the mock takes 1.0 s to reply to /shutdown
-- and exits 0.8 s after that), so the port must refuse connections right after, with no sleep.
local t_exit = socket.gettime()
decklist.header.on_close()
local exit_s = socket.gettime() - t_exit
check("deck list closed", App.decklist == nil and not UIManager:isShown(decklist))
local st, err = Client:status({ quiet = true })
check("server gone when exit returns (no sleep)", st == nil and err.kind == "server_down", err and err.kind)
check("exit waited for the server", exit_s >= 1.7 and exit_s < 6, exit_s)
check("Exit broadcast", waitFor(2, function() return exit_broadcast end))
-- Only modal messages may remain (InfoMessages time out / are dismissed by a tap in KOReader);
-- none of our full-screen widgets may still be on the stack, or KOReader would not quit.
local leftovers = {}
for _, w in ipairs(UIManager._stack) do
    if w.kind ~= "InfoMessage" then table.insert(leftovers, w.name or w.kind or tostring(w)) end
end
check("no plugin widget left on the stack", #leftovers == 0, table.concat(leftovers, ", "))

-- USB mass storage path: KOReader broadcasts Close (swallowed by the file chooser in the FM, so it
-- never reaches the plugin) and calls UIManager:quit(86). The quit hook must stop the server.
local up = false
Server:ensure(function(ok) up = ok end)
check("server started again", waitFor(12, function() return up end))
local t_quit = socket.gettime()
UIManager:quit(86)
check("quit hook ran original quit", UIManager._quit_code == 86)
st, err = Client:status({ quiet = true })
check("quit hook stopped the server before quitting", st == nil and err.kind == "server_down", err and err.kind)
check("quit hook waited", socket.gettime() - t_quit >= 1.7)
t_quit = socket.gettime()
UIManager:quit(0)
check("quit with nothing running is fast", socket.gettime() - t_quit < 0.5, socket.gettime() - t_quit)

-- A server left over from an earlier KOReader session (and one that won't exit).
os.execute(string.format("python3 -I '%s/mock_server.py' serve --port %d --data-dir '%s' --scenario ready "
    .. "--ignore-shutdown --shutdown-delay 0.1 >/dev/null 2>&1 &", abs_here, PORT, tmp .. "/data"))
check("leftover server up", waitFor(10, function() return Client:status({ quiet = true, timeout = 1 }) ~= nil end))
Server.state = "stopped"
up = false
Server:ensure(function(ok) up = ok end)
check("reused without spawning", up and Server.state == "running")
st = Client:status()
check("POST /adopt sent our pid", st and st.mock_parent_pid == Server.koreaderPid(), st and st.mock_parent_pid)
-- No /proc on macOS: let the test find/kill the process with pgrep / kill -0.
Server._findPids = function()
    local h = io.popen(string.format("pgrep -f '[m]ock_server.py.*--port %d'", PORT))
    local pids = {}
    for line in h:lines() do pids[#pids + 1] = tonumber(line) end
    h:close()
    return pids
end
Server._pidAlive = function(_, pid)
    local rc = os.execute("kill -0 " .. pid .. " 2>/dev/null")
    return rc == 0 or rc == true
end
Server.EXIT_WAIT_S, Server.KILL_WAIT_S = 1.5, 1.5
local stopped = Server:stop("test: hung server")
check("hung server killed (SIGTERM fallback)", stopped == true)
st, err = Client:status({ quiet = true })
check("port closed after kill", st == nil and err.kind == "server_down", err and err.kind)
killMock("9")

os.execute("rm -rf '" .. tmp .. "'")
print(string.format("\n[%s] %d passed, %d failed", scenario, passed, failed))
os.exit(failed == 0 and 0 or 1)

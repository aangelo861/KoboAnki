--[[
Regression test for the first AnkiWeb run on the Kobo: the deck list re-synced every second,
because the plugin read a missing /status "card_count" as 0 cards and restarted the first download
after every sync. Runs the plugin (KOReader UI stubbed) against the REAL kanki server with a
collection that's already been synced, keeps the deck list open, and counts syncs in kanki.log.

Driven by devtools/sync_loop_test.sh (which sets up Anki's own sync server locally):
  KANKI_REAL_BIN=... KANKI_DATA_DIR=... KANKI_TEST_PORT=... KANKI_AUTOSTART=1 luajit test_sync_loop.lua
]]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local abs_here = io.popen("cd '" .. here .. "' && pwd"):read("*l")
local plugin_src = abs_here .. "/../kanki.koplugin"
package.path = table.concat({ abs_here .. "/stubs/?.lua", plugin_src .. "/?.lua", package.path }, ";")

local REAL_BIN = assert(os.getenv("KANKI_REAL_BIN"), "KANKI_REAL_BIN")
local DATA_DIR = assert(os.getenv("KANKI_DATA_DIR"), "KANKI_DATA_DIR")
local PORT = tonumber(os.getenv("KANKI_TEST_PORT") or "") or 47993
local WATCH_S = tonumber(os.getenv("KANKI_WATCH_S") or "") or 20

local Stubs = require("koreader_stubs")
local UIManager = Stubs.UIManager

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("ok   " .. name)
    else failed = failed + 1; print("FAIL " .. name .. (detail ~= nil and (": " .. tostring(detail)) or "")) end
end

-- Plugin dir whose bin/kanki is the real server.
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p '" .. tmp .. "/kanki.koplugin/bin'")
local f = assert(io.open(tmp .. "/kanki.koplugin/bin/kanki", "w"))
f:write(string.format("#!/bin/sh\nexec '%s' \"$@\"\n", REAL_BIN))
f:close()
Stubs.settings_dir = tmp

local Settings = require("kanki/settings")
Settings:set("data_dir", DATA_DIR)
local Server = require("kanki/server")
local Client = require("kanki/client")
Server.PORT = PORT
Client:setPort(PORT)
local App = require("kanki/app")

local function syncsStarted()
    local log = io.open(DATA_DIR .. "/kanki.log", "rb")
    if not log then return 0 end
    local n = 0
    for line in log:lines() do
        if line:find("[kanki] sync started", 1, true) then n = n + 1 end
    end
    log:close()
    return n
end
local before = syncsStarted()

-- Autostart opens the deck list, starts the server and runs the automatic sync once.
local Kanki = dofile(plugin_src .. "/main.lua")
Kanki:new{ path = tmp .. "/kanki.koplugin", ui = { menu = { registerToMainMenu = function() end } } }
UIManager:runTasks(20, function() return App.decklist ~= nil and Server.state == "running" end)
check("real server started by the plugin", Server.state == "running")

print(string.format("     keeping the deck list open for %d s ...", WATCH_S))
UIManager:runTasks(WATCH_S)
local n = syncsStarted() - before
check("at most one automatic sync while the deck list stays open", n <= 1, n .. " syncs started")
local st = Client:status()
check("server reports a positive card_count", st and tonumber(st.card_count) and st.card_count > 0,
    st and st.card_count)
check("deck list shows decks, not the first-download placeholder",
    App.status and tonumber(App.status.card_count) and App.status.card_count > 0)

Server:stop("test end")
print(string.format("\n[sync-loop] %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

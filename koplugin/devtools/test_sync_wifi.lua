--[[
Wi-Fi power saving in kanki/sync.lua (setting wifi_off_after_sync): Wi-Fi that was off when a sync
was requested is switched off again when the sync is over (done / error / full download declined),
but not after full_sync_required (the full download needs it), not while another sync joins the
round, not when it was on before, not when the setting is off; KOReader's wifi_was_on flag is put
back as it was. Server and NetworkMgr are stubbed (stubs/pomodoro_stubs.lua PS.installWifi).

  KANKI_TEST_QUIET=1 luajit test_sync_wifi.lua      (LUA_PATH/LUA_CPATH as in README.md)
]]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local abs_here = io.popen("cd '" .. here .. "' && pwd"):read("*l")
package.path = table.concat({
    abs_here .. "/stubs/?.lua",
    abs_here .. "/../kanki.koplugin/?.lua",
    package.path,
}, ";")

local Stubs = require("koreader_stubs")
local PS = require("pomodoro_stubs")
local NetworkMgr = PS.installWifi()
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p '" .. tmp .. "'")
Stubs.settings_dir = tmp

local Settings = require("kanki/settings")
local Server = require("kanki/server")
local Client = require("kanki/client")
local Sync = require("kanki/sync")
local UIManager = Stubs.UIManager

local passed, failed = 0, 0
local function check(cond, what, detail)
    if cond then
        passed = passed + 1
        print("ok   " .. what)
    else
        failed = failed + 1
        print("FAIL " .. what .. (detail ~= nil and (": " .. tostring(detail)) or ""))
    end
end

-- A server that runs whatever GET /sync script the test gives it.
Server.ensure = function(_, cb) cb(true, {}) end
local script = {}
local success_at = 1000
Client.startSync = function() return { started = true } end
Client.syncStatus = function()
    local st = table.remove(script, 1)
    if st then return st end
    success_at = success_at + 1
    return { state = "done", last_success = success_at }
end
Sync.POLL_S = 0.01

local function running() return { { state = "running", stage = "collection" }, { state = "running", stage = "media" } } end
local function settle()
    UIManager:runTasks(3, function() return not Sync:isActive() end)
    UIManager:runTasks(0.05) -- the deferred Wi-Fi check (next tick)
end
local function reset(wifi_on, was_on)
    Sync.active, Sync._job, Sync._wifi, Sync.last_finished_at = false, nil, nil, nil
    PS.wifi.on, PS.wifi.disabled, PS.wifi.interactive, PS.wifi.decline = wifi_on, 0, nil, false
    NetworkMgr.wifi_was_on = was_on or false
    UIManager._stack, UIManager._tasks = {}, {}
end
local function confirmBox()
    return Stubs.lastShown("ConfirmBox")
end

Settings:set("wifi_off_after_sync", nil) -- default: on

-- 1. Off before, sync done -> off again, wifi_was_on cleared ------------------------------------------
reset(false)
script = running()
Sync:start("normal")
check(PS.wifi.on and PS.wifi.connects >= 1 and Sync:isActive(), "Wi-Fi switched on for the sync")
settle()
check(PS.wifi.disabled == 1 and not PS.wifi.on, "sync done: Wi-Fi switched off again")
check(PS.wifi.interactive == true and NetworkMgr.wifi_was_on == false, "wifi_was_on put back (was off)")
check(Sync._wifi == nil, "snapshot released")

-- 2. On before -> left on -------------------------------------------------------------------------------
reset(true)
script = running()
Sync:start("normal")
settle()
check(PS.wifi.disabled == 0 and PS.wifi.on, "Wi-Fi on before the sync: left on")

-- 3. Setting off -> left on -----------------------------------------------------------------------------
reset(false)
Settings:set("wifi_off_after_sync", false)
script = running()
Sync:start("normal")
settle()
check(PS.wifi.disabled == 0 and PS.wifi.on, "setting off: Wi-Fi left on")
Settings:set("wifi_off_after_sync", nil)

-- 4. Sync error -> off again ------------------------------------------------------------------------------
reset(false)
script = { { state = "running", stage = "collection" }, { state = "error", message = "AnkiWeb said no" } }
Sync:start("normal")
settle()
check(PS.wifi.disabled == 1 and not PS.wifi.on, "sync error: Wi-Fi switched off again")
UIManager._stack = {}

-- 5. full_sync_required: kept on while the user decides; confirmed full download -> off at its end -------
reset(false)
script = { { state = "running", stage = "collection" }, { state = "full_sync_required" } }
Sync:start("normal")
settle()
local cb = confirmBox()
check(cb ~= nil and PS.wifi.disabled == 0 and PS.wifi.on, "full_sync_required: Wi-Fi kept on for the decision")
script = running()
UIManager:close(cb)
cb.ok_callback()
check(Sync:isActive(), "full download started")
settle()
check(PS.wifi.disabled == 1 and not PS.wifi.on, "full download done: Wi-Fi off (the first sync's snapshot)")

-- 6. full_sync_required, declined -> off ------------------------------------------------------------------
reset(false)
script = { { state = "running", stage = "collection" }, { state = "full_sync_required" } }
Sync:start("normal")
settle()
cb = confirmBox()
UIManager:close(cb)
cb.cancel_callback()
UIManager:runTasks(0.05)
check(PS.wifi.disabled == 1 and not PS.wifi.on, "full download declined: Wi-Fi off")

-- 7. Another sync joins as the first ends: no switch-off in between, one at the very end ------------------
reset(false)
local chained = false
local listener = function(event)
    if event == "done" and not chained then
        chained = true
        script = running()
        Sync:start("normal", { auto = true, after_reviews = true })
    end
end
Sync:addListener(listener)
script = running()
Sync:start("normal")
UIManager:runTasks(3, function() return chained end)
UIManager:runTasks(0.05)
check(chained and PS.wifi.disabled == 0 and PS.wifi.on and Sync:isActive(), "second sync running: Wi-Fi left on")
settle()
check(PS.wifi.disabled == 1 and not PS.wifi.on, "after the second sync: Wi-Fi off once")
Sync:removeListener(listener)

-- 7b. ... even when that second sync is still starting (server restarting) at the next tick -----------
reset(false)
chained = false
local slow_ensure = function(_, done) UIManager:scheduleIn(0.3, function() done(true, {}) end) end
listener = function(event)
    if event == "done" and not chained then
        chained = true
        Server.ensure = slow_ensure
        script = running()
        Sync:start("normal", { auto = true, after_reviews = true })
    end
end
Sync:addListener(listener)
script = running()
Sync:start("normal")
UIManager:runTasks(3, function() return chained end)
UIManager:runTasks(0.1)
check(chained and not Sync:isActive() and PS.wifi.disabled == 0 and PS.wifi.on,
    "second sync still starting: Wi-Fi left on")
UIManager:runTasks(1, function() return Sync:isActive() end)
settle()
check(PS.wifi.disabled == 1 and not PS.wifi.on, "after the slow second sync: Wi-Fi off once")
Sync:removeListener(listener)
Server.ensure = function(_, done) done(true, {}) end

-- 8. KOReader meant to restore Wi-Fi on resume (wifi_was_on) -> flag kept ---------------------------------
reset(false, true)
script = running()
Sync:start("normal")
settle()
check(PS.wifi.disabled == 1 and PS.wifi.interactive == false and NetworkMgr.wifi_was_on == true,
    "wifi_was_on was set before: switched off non-interactively, flag kept")

-- 9. Automatic sync while offline (Wi-Fi not switched on by KOReader) -> nothing --------------------------
reset(false)
Sync:start("normal", { auto = true })
UIManager:runTasks(0.05)
check(PS.wifi.disabled == 0 and not Sync:isActive() and Sync._wifi == nil, "offline auto-sync: nothing to restore")

-- 10. The user declined KOReader's Wi-Fi prompt: an orphan snapshot doesn't decide much later -------------
reset(false)
PS.wifi.decline = true
Sync:start("normal")
check(not Sync:isActive() and Sync._wifi and Sync._wifi.off_before, "declined prompt: sync never started")
PS.wifi.decline = false
PS.wifi.on = true                    -- later, Wi-Fi is on for other reasons
Sync._wifi.at = os.time() - 3600     -- an hour ago
script = running()
Sync:start("normal")
settle()
check(PS.wifi.disabled == 0 and PS.wifi.on, "stale snapshot ignored: Wi-Fi on before this sync, left on")

-- 11. No Wi-Fi API (other platforms / older stubs): never touches Wi-Fi ------------------------------------
reset(false)
local saved_is, saved_disable = NetworkMgr.isWifiOn, NetworkMgr.disableWifi
NetworkMgr.isWifiOn, NetworkMgr.disableWifi = nil, nil
script = running()
Sync:start("normal")
settle()
NetworkMgr.isWifiOn, NetworkMgr.disableWifi = saved_is, saved_disable
check(PS.wifi.disabled == 0, "no NetworkMgr:isWifiOn: Wi-Fi left alone")

os.execute("rm -rf '" .. tmp .. "'")
print(string.format("\n[sync-wifi] %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

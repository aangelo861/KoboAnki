--[[
Pomodoro state machine (kanki/pomodoro.lua), driven with an injected clock (plain numbers):
focus -> pending break -> break -> focus, long break every N completed blocks, pause/resume,
skip (focus and break), autostart off, lengths read from Settings per phase, Tracking
(pomodoros + focus_s, one flush per completed block, nothing for abandoned blocks), injected
settings/tracking objects, and the settings menu items.

  KANKI_TEST_QUIET=1 luajit test_pomodoro.lua      (LUA_PATH/LUA_CPATH as in README.md)
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
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p '" .. tmp .. "'")
Stubs.settings_dir = tmp

local Settings = require("kanki/settings")
local Tracking = require("kanki/tracking")
local Pomodoro = require("kanki/pomodoro")
local spy = PS.spyTracking(Tracking)

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

local function resetSettings()
    for _, k in ipairs({ "pomodoro_enabled", "pomodoro_focus_min", "pomodoro_short_break_min",
                         "pomodoro_long_break_min", "pomodoro_long_break_every", "pomodoro_autostart",
                         "show_session_timer" }) do
        Settings:set(k, nil)
    end
end
resetSettings()

-- Defaults: 25 / 5 / 15, long break every 4, autostart ------------------------------------------
local p = Pomodoro.new()
check(p:state() == "idle" and p:remaining(0) == nil and p:dueIn(0) == nil, "starts idle, nothing due")
check(p:lengthOf("focus") == 1500 and p:lengthOf("short_break") == 300 and p:lengthOf("long_break") == 900,
    "lengths from the settings defaults (25/5/15 min)")
check(p:start(100) == true, "start() from idle")
check(p:state() == "focus" and p:isRunning() and not p:isPaused(), "focus running")
check(p:remaining(100) == 1500 and p:dueIn(100) == 1500 and p:remaining(700) == 900, "focus counts down 25 min")
check(p:start(200) == false, "start() refused while a phase is under way")
check(p:update(1599.9) == nil, "update() before the end does nothing")
p:addCards(1); p:addCards(1); p:addCards(-1); p:addCards(1)
local ev = p:update(1600)
check(ev and ev.kind == "focus_done" and ev.focus_s == 1500 and ev.cards == 2 and ev.completed == 1,
    "focus_done at the end of the block (focus_s, cards counted net of undo)", ev and ev.cards)
check(ev and ev.break_kind == "short_break" and ev.break_s == 300, "a short break follows")
local day = Tracking:day()
check(day.pomodoros == 1 and day.focus_s == 1500, "Tracking: pomodoros=1, focus_s=1500",
    day.pomodoros .. "/" .. day.focus_s)
check(spy.flushes == 1, "Tracking flushed once for the completed block", spy.flushes)
check(p:state() == "short_break" and p:isPending() and p:isPaused(), "break is pending")
check(p:dueIn(1600) == nil and p:remaining(99999) == 300, "pending break is frozen at full length")
check(p:update(99999) == nil, "a pending break never ends by itself")
p:addCards(5)
check(p.focus_cards == 2, "cards outside a focus block are not counted")
check(p:startBreak(5000) and p:isRunning() and not p:isPending(), "startBreak() runs it")
check(p:startBreak(5001) == false, "startBreak() only for a pending break")
check(p:remaining(5100) == 200 and p:dueIn(5100) == 200, "break counts down 5 min")
ev = p:update(5300)
check(ev and ev.kind == "break_done" and ev.break_kind == "short_break" and ev.next == "focus",
    "break_done -> next focus block (autostart)")
check(p:state() == "focus" and p:remaining(5300) == 1500 and p.focus_cards == 0, "new focus block from the break end")
check(spy.flushes == 1, "no Tracking write for a break")

-- Long break every 4 completed blocks --------------------------------------------------------------
local t = 5300
local kinds = {}
for _ = 2, 5 do
    t = t + 1500
    ev = p:update(t)
    table.insert(kinds, ev.break_kind)
    p:startBreak(t)
    t = t + p:length()
    p:update(t)
end
check(kinds[1] == "short_break" and kinds[2] == "short_break" and kinds[3] == "long_break" and kinds[4] == "short_break",
    "blocks 2,3 -> short, 4 -> long (15 min), 5 -> short", table.concat(kinds, ","))
check(p.completed == 5 and Tracking:day().pomodoros == 5 and Tracking:day().focus_s == 5 * 1500,
    "5 blocks completed and tracked", Tracking:day().pomodoros)
check(spy.flushes == 5, "one flush per completed block", spy.flushes)

-- Pause / resume -------------------------------------------------------------------------------------
p = Pomodoro.new()
p:start(0)
check(p:pause(600) == true and p:isPaused() and not p:isRunning(), "pause()")
check(p:pause(700) == false, "pause() twice is a no-op")
check(p:remaining(5000) == 900 and p:dueIn(5000) == nil, "paused: frozen, nothing due")
check(p:update(1e9) == nil, "paused focus never completes")
check(p:resume(10000) == true and p:remaining(10000) == 900 and p:dueIn(10000) == 900, "resume() continues where it was")
check(p:resume(10001) == false, "resume() while running is a no-op")
ev = p:update(10900)
check(ev and ev.kind == "focus_done", "completes 900 s after resuming")

-- Skip -------------------------------------------------------------------------------------------------
local pomos = Tracking:day().pomodoros
local flushes = spy.flushes
p = Pomodoro.new()
p:start(0)
p:addCards(3)
check(p:skip(100) == "short_break" and p:isRunning() and not p:isPending() and p:remaining(100) == 300,
    "skip during focus -> short break running now")
check(Tracking:day().pomodoros == pomos and spy.flushes == flushes and p.completed == 0,
    "an abandoned focus block is not counted or written")
check(p:skip(200) == "focus" and p:remaining(200) == 1500, "skip during a running break -> focus (autostart)")
p:update(1700)
check(p:isPending() and p:skip(1800) == "focus" and p:remaining(1800) == 1500,
    "skip a pending break ('keep going') -> focus right away")
check(Pomodoro.new():skip(0) == nil, "skip while idle does nothing")
p:stop()
check(p:state() == "idle" and p:dueIn(0) == nil and p:remaining(0) == nil, "stop() -> idle")

-- Autostart off ------------------------------------------------------------------------------------------
Settings:set("pomodoro_autostart", false)
p = Pomodoro.new()
p:start(0)
p:update(1500)
p:startBreak(1500)
ev = p:update(1800)
check(ev.next == "idle" and p:state() == "idle", "autostart off: break end -> idle")
p:start(2000)
p:update(3500)
check(p:skip(3600) == "idle", "autostart off: skipped break -> idle")
Settings:set("pomodoro_autostart", nil)

-- Lengths are read when a phase starts --------------------------------------------------------------
Settings:set("pomodoro_focus_min", 50)
Settings:set("pomodoro_short_break_min", 10)
Settings:set("pomodoro_long_break_every", 2)
p = Pomodoro.new()
p:start(0)
check(p:remaining(0) == 3000, "focus length from settings (50 min)")
Settings:set("pomodoro_focus_min", 20)
check(p:remaining(0) == 3000, "changing the setting doesn't touch the running block")
ev = p:update(3000)
check(ev.focus_s == 3000 and ev.break_s == 600, "break length from settings (10 min)")
p:startBreak(3000)
p:update(3600)
check(p:remaining(3600) == 1200, "the next block uses the new length (20 min)")
ev = p:update(4800)
check(ev.break_kind == "long_break" and ev.completed == 2, "long break every 2 (setting)")
Settings:set("pomodoro_focus_min", "garbage")
check(Pomodoro.new():lengthOf("focus") == 1500, "unparsable length -> the default (25 min)")
Settings:set("pomodoro_focus_min", 0)
check(Pomodoro.new():lengthOf("focus") == 60, "length below 1 min -> 1 min")
Settings:set("pomodoro_long_break_every", 0)
p = Pomodoro.new()
p.completed = 3
check(p:_breakAfter(4) == "short_break", "long_break_every 0 -> never a long break")
resetSettings()

-- Injected settings and tracking objects -------------------------------------------------------------
local fake_tracking = { added = {}, flushed = 0 }
function fake_tracking:add(fields) table.insert(self.added, fields) end
function fake_tracking:flush() self.flushed = self.flushed + 1 end
local fake_settings = { values = { pomodoro_focus_min = 1, pomodoro_short_break_min = 1,
    pomodoro_long_break_every = 1, pomodoro_long_break_min = 2, pomodoro_autostart = false }, DEFAULTS = {} }
function fake_settings:get(k) return self.values[k] end
p = Pomodoro.new{ settings = fake_settings, tracking = fake_tracking }
p:start(0)
ev = p:update(60)
check(#fake_tracking.added == 1 and fake_tracking.added[1].pomodoros == 1 and fake_tracking.added[1].focus_s == 60
    and fake_tracking.flushed == 1, "injected tracking receives add{pomodoros=1, focus_s=60} + flush")
check(ev.break_kind == "long_break" and ev.break_s == 120, "injected settings drive lengths and the cycle")

-- Settings menu items ---------------------------------------------------------------------------------------
local items = Pomodoro.settingsMenuItems()
check(#items == 7, "7 settings menu items", #items)
local texts = {}
for i, item in ipairs(items) do
    texts[i] = item.text or item.text_func()
end
check(texts[1] == "Pomodoro focus blocks" and texts[2] == "Focus block: 25 min" and texts[3] == "Short break: 5 min"
    and texts[4] == "Long break: 15 min" and texts[5] == "Long break every 4 focus blocks"
    and texts[6] == "Start focus blocks automatically" and texts[7] == "Show study timer",
    "menu texts and order", table.concat(texts, " | "))
check(items[1].checked_func() == true, "Pomodoro on by default")
items[1].callback()
check(Settings:get("pomodoro_enabled") == false and items[1].checked_func() == false, "toggle Pomodoro off")
check(items[2].enabled_func() == false and items[6].enabled_func() == false, "length/autostart items disabled while off")
items[1].callback()
check(items[2].enabled_func() == true, "enabled again")
local updated = 0
items[2].callback({ updateItems = function() updated = updated + 1 end })
local spin = Stubs.lastShown("SpinWidget")
check(spin and spin.value == 25 and spin.value_min == 5 and spin.value_max == 90 and spin.unit == "min",
    "focus length SpinWidget", spin and spin.value)
spin.callback({ value = 30 })
check(Settings:get("pomodoro_focus_min") == 30 and updated == 1 and items[2].text_func() == "Focus block: 30 min",
    "SpinWidget sets the value and refreshes the menu")
items[5].callback(nil)
spin = Stubs.lastShown("SpinWidget")
check(spin and spin.unit == nil and spin.value == 4, "long break every N has no unit")
items[6].callback()
check(Settings:get("pomodoro_autostart") == false, "toggle autostart")
check(items[7].checked_func() == true, "study timer shown by default")
items[7].callback()
check(Settings:get("show_session_timer") == false, "toggle study timer")
resetSettings()

os.execute("rm -rf '" .. tmp .. "'")
print(string.format("\n[pomodoro] %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

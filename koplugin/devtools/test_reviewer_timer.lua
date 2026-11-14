--[[
Study timer, Pomodoro, flags and rotation in the reviewer (kanki/reviewer.lua + breakscreen.lua),
headless, with KOReader stubbed (stubs/koreader_stubs.lua + stubs/pomodoro_stubs.lua), the
server replaced by canned Client answers, and both clocks injected (Reviewer.clock = seconds that
keep counting in standby, Reviewer.wallClock = os.time). Checks:

  * session clock: starts on show, stops while asleep (Suspend .. Resume, also when the sleep screen
    outlives Resume until OutOfScreenSaver) and during breaks; Tracking gets study_s/cards in
    memory at each minute tick, a flush at Suspend, and sessions=1 + flush at close
  * exactly two tasks: the minute tick (1 s past the wall-clock minute) and the Pomodoro phase end;
    nothing while asleep, nothing when nothing on screen depends on the time, nothing after close
  * top bar redraw: only the bar (widgetRepaint + "ui" refresh of its rectangle, no dither) when
    the reviewer is on top; stack repaint, bar rectangle only, when something covers it
  * focus end -> dialog -> break screen (countdown refreshed once a minute, page key / Back skip)
    -> break end -> toast, next focus (autostart); "Keep going"; long break after 4 blocks;
    menu pause / resume / skip; flag dialog (7 tinted colours + remove) and top-bar marker
  * rotation (SetRotationMode: host UI rotated first, deck list gets ScreenResize, card fetched again
    for the new image width, same card and side) and ScreenResize broadcasts

  KANKI_TEST_QUIET=1 luajit test_reviewer_timer.lua      (LUA_PATH/LUA_CPATH as in README.md)
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

local Device = require("device")
local Event = require("ui/event")
local Settings = require("kanki/settings")
Settings:set("data_dir", tmp .. "/data")
local Tracking = require("kanki/tracking")
local spy = PS.spyTracking(Tracking)
local Client = require("kanki/client")
local UIManager = Stubs.UIManager
local Screen = Device.screen

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

-- Canned server ------------------------------------------------------------------------------------
local function card(id, extra)
    local c = {
        id = id, note_id = id + 1000, deck = "Medicine::Paper B", kind = "review", ord = 1, flag = 0, css = "",
        question = "<p>Question " .. id .. "</p>",
        answer = "<p>Question " .. id .. "</p><hr id=answer><p>Answer " .. id .. "</p>",
        buttons = {
            { rating = 1, label = "Again", interval = "<1m" }, { rating = 2, label = "Hard", interval = "6m" },
            { rating = 3, label = "Good", interval = "10m" }, { rating = 4, label = "Easy", interval = "4d" },
        },
    }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end
local deck = { card(101), card(102), card(103, { flag = 3 }) }
local pos = 1
local function nextBody()
    return { state = "card", counts = { new = 1, learning = 0, review = 2 }, undo = pos > 1 and "Answer Card" or nil,
             card = card(deck[(pos - 1) % #deck + 1].id, { flag = deck[(pos - 1) % #deck + 1].flag }) }
end
local flag_calls, card_calls = {}, {}
Client.nextCard = function() return nextBody() end
Client.answer = function() pos = pos + 1; return nextBody() end
Client.flag = function(_, id, flag) table.insert(flag_calls, { id = id, flag = flag }); return { ok = true, flag = flag } end
Client.card = function(_, id, img_max_px)
    table.insert(card_calls, { id = id, img = img_max_px })
    return { card = { id = id, css = "", question = '<img src="ecg.png" width="' .. img_max_px .. '">',
                      answer = '<img src="ecg.png" width="' .. img_max_px .. '"><hr id=answer>STEMI' } }
end

-- Clocks ---------------------------------------------------------------------------------------------
local Reviewer = require("kanki/reviewer")
local BreakScreen = require("kanki/breakscreen")
local now = 1000                    -- Reviewer.clock (seconds, counts in standby)
local wall = 1793499960 + 37        -- Reviewer.wallClock: 37 s past a minute (1793499960 % 60 == 0)
Reviewer.clock = function() return now end
Reviewer.wallClock = function() return wall end
Reviewer.GUARD_MS = 0
BreakScreen.GUARD_MS = 0
local expected_study = 0            -- what the session clock should have counted so far
local function study(dt) now = now + dt; expected_study = expected_study + dt end
local function idle(dt) now = now + dt end -- time that must NOT count (asleep, on a break)

-- Window stack: a fake FileManager (host UI) and deck list under the reviewer --------------------
local function fakeWidget(name)
    local w = { name = name, events = {} }
    function w:handleEvent(ev)
        table.insert(self.events, ev.name)
        if ev.name == "ScreenResize" then self.resized = ev.args[1] end
    end
    return w
end
local fm = fakeWidget("filemanager")
local fm_rotations = {}
function fm:onSetRotationMode(mode)
    table.insert(fm_rotations, { mode = mode, screen_before = Screen:getRotationMode() })
    Screen:setRotationMode(mode) -- like FileManager:onSetRotationMode (+ its reinit)
end
package.loaded["apps/filemanager/filemanager"] = { instance = fm }
local decklist = fakeWidget("kanki_decklist")
table.insert(UIManager._stack, fm)
table.insert(UIManager._stack, decklist)

local function tasks(fn) return PS.taskDelays(fn) end
local function ourTasks(r)
    local n = 0
    for _, t in ipairs(UIManager._tasks) do
        if t.fn == r._tick_fn or t.fn == r._phase_fn then n = n + 1 end
    end
    return n
end
local function near(a, b, tol) return a ~= nil and math.abs(a - b) <= (tol or 0.5) end
local function buttonByText(dialog, text)
    for _, row in ipairs(dialog.buttons or {}) do
        for _, b in ipairs(row) do
            if b.text == text then return b end
        end
    end
end
local function findWidget(w, pred, depth)
    depth = depth or 0
    if type(w) ~= "table" or depth > 30 then return nil end
    if pred(w) then return w end
    for _, child in ipairs(w) do
        local found = findWidget(child, pred, depth + 1)
        if found then return found end
    end
end
local function press(r, key) r:handleEvent(Event:new(key)) end
local function runTicks() UIManager:runTasks(0.05) end

for _, k in ipairs({ "show_session_timer", "pomodoro_enabled", "pomodoro_focus_min", "pomodoro_short_break_min",
                     "pomodoro_long_break_min", "pomodoro_long_break_every", "pomodoro_autostart" }) do
    Settings:set(k, nil) -- defaults: timer shown, Pomodoro on, 25/5/15, every 4, autostart
end

-- Open ---------------------------------------------------------------------------------------------------
local r = Reviewer:new{ deck_name = "Medicine::Paper B" }
UIManager:show(r)
runTicks()
check(r.state == "question" and r.card.id == 101, "question shown", r.state)
check(r.pomodoro and r.pomodoro:state() == "focus" and r.pomodoro:remaining(now) == 1500,
    "focus block autostarted with the session")
local tick = tasks(r._tick_fn)
check(#tick == 1 and near(tick[1], 24), "one minute tick, 1 s past the next wall-clock minute (24 s)", tick[1])
local phase = tasks(r._phase_fn)
check(#phase == 1 and near(phase[1], 1500.05), "one task at the exact focus end", phase[1])
check(#UIManager._tasks == 2, "no other tasks", #UIManager._tasks)
check(r.timer_text == "0 min · 0 cards · Focus 25 min", "top bar timer text at start", r.timer_text)

-- Review two cards, then the minute tick -----------------------------------------------------------------
study(70)
press(r, "KankiPageFwd")
press(r, "KankiPageFwd")
study(30)
press(r, "KankiPageFwd")
press(r, "KankiPageBack")
check(r.answered == 2 and r.card.id == 103, "two cards answered", r.answered)
study(25)
wall = wall + 24
PS.clearLog()
r._tick_fn()
check(r.timer_text == "2 min · 2 cards · Focus 23 min", "tick: study time, cards, focus left", r.timer_text)
check(#PS.repaints == 1 and PS.repaints[1].widget == r.top_slot and PS.repaints[1].y == 0,
    "tick repaints only the top bar")
local rf = PS.refreshes[1]
check(#PS.refreshes == 1 and rf.widget == nil and rf.mode == "ui" and rf.region == r.top_dimen and not rf.dither,
    "tick refreshes only the bar's rectangle, 'ui', not dithered", rf and rf.mode)
check(#tasks(r._tick_fn) == 1 and near(tasks(r._tick_fn)[1], 60), "next tick a minute later", tasks(r._tick_fn)[1])
local day = Tracking:day()
check(day.study_s == expected_study and day.cards == 2 and day.sessions == 0,
    "Tracking updated in memory at the tick", day.study_s .. "/" .. day.cards)
check(spy.flushes == 0, "no Tracking write at a tick", spy.flushes)

-- Image card on screen: still a plain "ui" refresh for the bar
r.dithered = true
PS.clearLog()
study(60); wall = wall + 60
r._tick_fn()
check(PS.refreshes[1].widget == nil and not PS.refreshes[1].dither, "bar refresh not dithered even on an image card")
r.dithered = nil

-- Something drawn over the reviewer (toast): repaint the stack, refresh the bar only
local toast = fakeWidget("toast")
table.insert(UIManager._stack, toast)
PS.clearLog()
study(60); wall = wall + 60
r._tick_fn()
check(#PS.repaints == 0 and PS.refreshes[1].widget == r and PS.refreshes[1].region == r.top_dimen
    and PS.refreshes[1].mode == "ui", "covered: setDirty(reviewer, 'ui', bar rectangle), no direct paint")
UIManager:close(toast)

-- Sleep -----------------------------------------------------------------------------------------------------
study(5)
UIManager:broadcastEvent(Event:new("Suspend"))
check(r.suspended and ourTasks(r) == 0 and #UIManager._tasks == 0, "Suspend: nothing scheduled", #UIManager._tasks)
check(spy.flushes == 1 and Tracking:day().study_s == expected_study, "Suspend: Tracking flushed with the study time",
    Tracking:day().study_s)
check(r.pomodoro:isPaused(), "Suspend: Pomodoro paused")
local left = r.pomodoro:remaining(now)
PS.clearLog()
idle(3600); wall = wall + 3600
UIManager:broadcastEvent(Event:new("Resume"))
runTicks()
check(not r.suspended and #tasks(r._tick_fn) == 1 and #tasks(r._phase_fn) == 1, "Resume: tasks rescheduled")
check(r:_studySeconds(now) == expected_study, "no study time counted while asleep", r:_studySeconds(now))
check(r.pomodoro:isRunning() and r.pomodoro:remaining(now) == left and near(tasks(r._phase_fn)[1], left + 0.05),
    "Pomodoro resumed where it was, focus end rescheduled", r.pomodoro:remaining(now))
check(#PS.repaints == 0, "no paint while waking (the sleep screen's close repaints us)")

-- Sleep screen still up after Resume (screensaver delay): wait for OutOfScreenSaver
study(10)
UIManager:broadcastEvent(Event:new("Suspend"))
idle(100); wall = wall + 100
Device.screen_saver_mode = true
package.loaded["ui/screensaver"] = { screensaver_widget = {} }
UIManager:broadcastEvent(Event:new("Resume"))
runTicks()
check(r.suspended and #UIManager._tasks == 0, "Resume under the sleep screen: still paused, nothing scheduled")
UIManager:broadcastEvent(Event:new("OutOfScreenSaver")) -- sent while the screensaver is still up
Device.screen_saver_mode = false
package.loaded["ui/screensaver"].screensaver_widget = nil
runTicks()
check(not r.suspended and ourTasks(r) == 2, "OutOfScreenSaver: awake again")
check(spy.flushes == 2, "second Suspend flushed too", spy.flushes)

-- Gesture lock without a sleep screen widget: no OutOfScreenSaver will come. Wake at Resume, but
-- paint nothing and show no dialog while the lock is up.
UIManager:broadcastEvent(Event:new("Suspend"))
idle(50); wall = wall + 50
Device.screen_saver_mode = true
UIManager:broadcastEvent(Event:new("Resume"))
runTicks()
check(not r.suspended and ourTasks(r) == 2, "lock without sleep screen widget: awake at Resume")
PS.clearLog()
study(30); wall = wall + 30
r._tick_fn()
check(#PS.repaints == 0 and #PS.refreshes == 0, "nothing painted while the lock is up")
local saved_left = r.pomodoro:remaining(now)
r._phase_fn()
check(not Stubs.lastShown("ConfirmBox") and r.pomodoro:remaining(now) == saved_left
    and near(tasks(r._phase_fn)[1], Reviewer.LOCKED_RETRY_S), "phase end under the lock: postponed, not applied")
Device.screen_saver_mode = false
r:_reschedule()
check(spy.flushes == 3, "third Suspend flushed", spy.flushes)

-- Focus end -> dialog -> break ----------------------------------------------------------------------------
study(r.pomodoro:remaining(now))
r._phase_fn()
local cb = Stubs.lastShown("ConfirmBox")
check(cb and cb.text:find("Focus block done: 25 min, 2 cards.", 1, true) and cb.text:find("5-minute break", 1, true),
    "focus end: 'Focus block done: 25 min, 2 cards. Take a 5-minute break?'", cb and cb.text)
check(cb and cb.ok_text == "Start break" and cb.cancel_text == "Keep going" and cb.flush_events_on_show,
    "dialog buttons [Start break] [Keep going], drops queued input")
check(Tracking:day().pomodoros == 1 and Tracking:day().focus_s == 1500 and spy.flushes == 4,
    "completed block tracked and flushed")
check(r.pomodoro:isPending() and #tasks(r._phase_fn) == 0, "break pending while the dialog is up: no phase task")
check(r.timer_text:find("Break 5 min", 1, true), "top bar shows the pending break", r.timer_text)
study(10)
cb.ok_callback()
UIManager:close(cb)
runTicks()
local bs = r.break_screen
check(bs and UIManager:isShown(bs) and bs.kind == "short_break" and bs.number_widget.text == "5",
    "Start break -> break screen, 5 minutes left")
check(near(tasks(r._phase_fn)[1], 300.05) and #tasks(r._tick_fn) == 1, "break end scheduled, minute tick kept")
local before = r:_studySeconds(now)
idle(120); wall = wall + 120
check(r:_studySeconds(now) == before, "session clock stopped during the break")
PS.clearLog()
r._tick_fn()
check(bs.number_widget.text == "3" and bs.unit_widget.text == "minutes left", "tick updates the countdown (3)")
local cd = PS.refreshes[1]
local mode = cd and type(cd.mode) == "function" and cd.mode()
check(cd and cd.widget == bs and mode == "ui" and #PS.repaints == 0, "only the countdown is refreshed, no top bar paint")
PS.clearLog()
r._tick_fn()
check(#PS.refreshes == 0, "same minute: no refresh at all")
idle(180)
r._phase_fn()
check(r.break_screen == nil and not UIManager:isShown(bs), "break end closes the break screen")
check(Stubs.notifications[#Stubs.notifications] == "Break over: next focus block started.",
    "break end toast", Stubs.notifications[#Stubs.notifications])
check(r.pomodoro:state() == "focus" and r.pomodoro:remaining(now) == 1500, "next focus block started (autostart)")
check(r.state == "question" and r.card.id == 103, "back to the same card")

-- Keep going, twice, then the long break -----------------------------------------------------------------
for i = 2, 3 do
    study(1500)
    r._phase_fn()
    cb = Stubs.lastShown("ConfirmBox")
    cb.cancel_callback()
    UIManager:close(cb)
    check(r.break_screen == nil and r.pomodoro:state() == "focus" and r.pomodoro:remaining(now) == 1500,
        "Keep going after block " .. i .. " -> next focus block now")
end
study(1500)
r._phase_fn()
cb = Stubs.lastShown("ConfirmBox")
check(cb.text:find("15-minute break", 1, true), "4th block: long break offered", cb.text)
cb.ok_callback()
UIManager:close(cb)
runTicks()
bs = r.break_screen
check(bs and bs.kind == "long_break" and bs.number_widget.text == "15", "long break screen, 15 minutes")
check(bs.info_text == "4 focus blocks today", "break screen shows today's focus blocks", bs.info_text)
idle(60)
bs:handleEvent(Event:new("KankiBreakSkip"))
check(r.break_screen == nil and not UIManager:isShown(bs) and r.pomodoro:state() == "focus", "page key skips the break")
check(Tracking:day().pomodoros == 4 and spy.flushes == 7, "4 blocks tracked", Tracking:day().pomodoros)

-- Menu: pause / resume / skip ----------------------------------------------------------------------------
study(30)
r:showMenu()
local menu = Stubs.lastShown("ButtonDialog")
check(menu.buttons[1][1].text == "Bury card" and buttonByText(menu, "Flag card…") and buttonByText(menu, "Skip to break"),
    "menu: Bury first, Flag card…, Pomodoro row")
buttonByText(menu, "Pause Pomodoro").callback()
check(not UIManager:isShown(menu) and r.pomodoro:isPaused() and #tasks(r._phase_fn) == 0, "Pause Pomodoro")
check(r.timer_text:find("(paused)", 1, true), "top bar shows the pause", r.timer_text)
study(100)
r:showMenu()
menu = Stubs.lastShown("ButtonDialog")
buttonByText(menu, "Resume Pomodoro").callback()
check(r.pomodoro:isRunning() and r.pomodoro:remaining(now) == 1470, "Resume Pomodoro", r.pomodoro:remaining(now))
study(100)
r:showMenu()
menu = Stubs.lastShown("ButtonDialog")
buttonByText(menu, "Skip to break").callback()
bs = r.break_screen
check(bs and bs.kind == "short_break" and r.pomodoro:isRunning(), "Skip to break -> short break now")
idle(60)
bs:handleEvent(Event:new("KankiBreakBack"))
check(r.break_screen == nil and r.pomodoro:state() == "focus", "Back skips the break too")

-- Flags ----------------------------------------------------------------------------------------------------
study(20)
check(findWidget(r.top_slot, function(w) return w.background and w.background[1] == "#43A047" end),
    "card 103 has a green flag marker in the top bar")
r:showMenu()
menu = Stubs.lastShown("ButtonDialog")
buttonByText(menu, "Flag card…").callback()
local fd = Stubs.lastShown("ButtonDialog")
local n, tinted = 0, 0
for _, row in ipairs(fd.buttons) do
    for _, b in ipairs(row) do
        n = n + 1
        if b.background then tinted = tinted + 1 end
    end
end
check(fd.title == "Flag card" and n == 8 and tinted == 7 and fd.colorful and fd.dithered, "flag dialog: 7 tinted colours + remove")
check(buttonByText(fd, "Green").checked_func() and not buttonByText(fd, "Blue").checked_func(), "current flag checked")
check(buttonByText(fd, "Remove flag").enabled == true, "Remove flag enabled for a flagged card")
PS.clearLog()
buttonByText(fd, "Blue").callback()
check(#flag_calls == 1 and flag_calls[1].id == 103 and flag_calls[1].flag == 4, "Client:flag(card, 4)")
check(r.card.flag == 4 and findWidget(r.top_slot, function(w) return w.background and w.background[1] == "#1E88E5" end),
    "blue marker in the top bar")
check(PS.repaints[1] and PS.repaints[1].widget == r.top_slot, "marker change repaints only the top bar")
r:showMenu()
buttonByText(Stubs.lastShown("ButtonDialog"), "Flag card…").callback()
buttonByText(Stubs.lastShown("ButtonDialog"), "Remove flag").callback()
check(flag_calls[2].flag == 0 and r.card.flag == 0 and not findWidget(r.top_slot, function(w) return w.background
    and type(w.background[1]) == "string" and w.background[1]:sub(1, 1) == "#" end), "Remove flag clears the marker")

-- Rotation ---------------------------------------------------------------------------------------------------
press(r, "KankiPageFwd") -- answer side
r.card.answer = r.card.answer .. '<img src="ecg.png">'
local card_id = r.card.id
PS.clearLog()
r:handleEvent(Event:new("SetRotationMode", 1))
check(Screen:getRotationMode() == 1 and r.screen_w == 1680 and r.screen_h == 1264, "SetRotationMode: landscape layout")
check(#fm_rotations == 1 and fm_rotations[1].mode == 1 and fm_rotations[1].screen_before == 0,
    "host FileManager rotated through its own handler, before the screen was")
check(decklist.resized and decklist.resized.w == 1680 and not fm.resized, "deck list got ScreenResize, host didn't")
check(r.img_max_px == 1680 - 2 * 22 - 13 - 26 and card_calls[1] and card_calls[1].img == r.img_max_px,
    "card fetched again for the new image width", card_calls[1] and card_calls[1].img)
check(r.state == "answer" and r.card.id == card_id and r.rating_buttons and r.card.question:find("1597", 1, true),
    "same card, same side, new HTML")
check(r.ges_events.KankiTapCard[1].range == r.card_dimen and r.card_dimen.w == 1680, "tap zone follows the layout")
local full = false
for _, x in ipairs(PS.refreshes) do if x.widget == r and x.mode == "full" then full = true end end
check(full and r.top_slot.slot_w == 1680, "full refresh at the new size")
check(r:handleEvent(Event:new("SetRotationMode", 1)) == true and #fm_rotations == 1, "same mode again: nothing to do")
-- 180° flip: no relayout anywhere, just a full repaint the other way up
decklist.resized = nil
local calls_before = #card_calls
r:handleEvent(Event:new("SetRotationMode", 3))
check(Screen:getRotationMode() == 3 and PS.rotation_repaints == 1 and r.screen_w == 1680 and #fm_rotations == 1
    and not decklist.resized and #card_calls == calls_before, "180° flip: UIManager:onRotation, no relayout")
Screen:setRotationMode(1)
-- Window resize broadcast (emulator / Android): SetDimensions + ScreenResize
Screen:setRotationMode(0)
UIManager:broadcastEvent(Event:new("SetDimensions", Screen:getSize()))
local layouts = r.screen_w
UIManager:broadcastEvent(Event:new("ScreenResize", Screen:getSize()))
check(layouts == 1264 and r.screen_w == 1264 and r.card_dimen.w == 1264, "SetDimensions/ScreenResize: relayout once")
-- Rotation while the break screen is up: the break screen hands it to the reviewer
r:pomodoroSkip()
bs = r.break_screen
bs:handleEvent(Event:new("SetRotationMode", 3))
check(Screen:getRotationMode() == 3 and bs.screen_w == 1680 and r.screen_w == 1680, "rotation on the break screen relayouts both")
r:pomodoroSkip()
check(r.break_screen == nil, "break skipped")
Screen:setRotationMode(0)
r:onScreenResize()

-- Close --------------------------------------------------------------------------------------------------------
study(40)
local answered = r.answered
r:close()
day = Tracking:day()
check(day.sessions == 1 and day.study_s == expected_study and day.cards == answered,
    "close: Tracking study_s / cards / sessions=1", day.study_s .. " vs " .. expected_study .. ", " .. day.cards)
check(spy.flushes == 8, "close flushes", spy.flushes)
check(ourTasks(r) == 0 and #UIManager._tasks == 0, "nothing scheduled after close", #UIManager._tasks)
check(not UIManager:isShown(r), "reviewer gone")

-- Closed while on a break: the break screen goes too, the break doesn't count ---------------------------------
local r2 = Reviewer:new{ deck_name = "Test" }
UIManager:show(r2)
runTicks()
study(60)
r2:pomodoroSkip()
local bs2 = r2.break_screen
idle(30)
r2:onExit() -- e.g. KOReader exiting
check(not UIManager:isShown(bs2) and not UIManager:isShown(r2), "Exit closes the break screen with the reviewer")
check(Tracking:day().study_s == expected_study and Tracking:day().sessions == 2, "break time not counted at close")
check(#UIManager._tasks == 0, "no tasks left")

-- Nothing time-dependent on screen: no tick at all ---------------------------------------------------------------
Settings:set("show_session_timer", false)
Settings:set("pomodoro_enabled", false)
local r3 = Reviewer:new{ deck_name = "Test" }
UIManager:show(r3)
runTicks()
check(r3.pomodoro == nil and r3.timer_text == nil and #UIManager._tasks == 0, "timer hidden, Pomodoro off: no tasks, no text")
r3:showMenu()
check(not buttonByText(Stubs.lastShown("ButtonDialog"), "Pause Pomodoro") and #Stubs.lastShown("ButtonDialog").buttons == 4,
    "no Pomodoro row when it's off")
UIManager:close(Stubs.lastShown("ButtonDialog"))
r3:close()
Settings:set("show_session_timer", true)
local r4 = Reviewer:new{ deck_name = "Test" }
UIManager:show(r4)
runTicks()
check(#tasks(r4._tick_fn) == 1 and #tasks(r4._phase_fn) == 0 and r4.timer_text == "0 min · 0 cards",
    "timer only: minute tick, no Pomodoro task", r4.timer_text)
r4:close()
Settings:set("pomodoro_enabled", true)
Settings:set("pomodoro_autostart", false)
local r5 = Reviewer:new{ deck_name = "Test" }
UIManager:show(r5)
runTicks()
check(r5.pomodoro:state() == "idle" and #tasks(r5._phase_fn) == 0, "autostart off: Pomodoro idle at open")
r5:showMenu()
buttonByText(Stubs.lastShown("ButtonDialog"), "Start focus block").callback()
check(r5.pomodoro:state() == "focus" and #tasks(r5._phase_fn) == 1, "Start focus block from the menu")
r5:close()

os.execute("rm -rf '" .. tmp .. "'")
print(string.format("\n[reviewer-timer] %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

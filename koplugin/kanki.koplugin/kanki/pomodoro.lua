--[[--
Pomodoro timer for review sessions: a pure state machine. No UI and no scheduling: the caller
passes `now` (seconds, on a clock that keeps ticking while the device is in standby) to every call,
schedules ONE task for dueIn(now), and reacts to what update(now) returns. The reviewer owns one
per review session (see reviewer.lua).

    idle --start--> focus --(time up)--> break, pending --startBreak--> break --(time up)--> focus | idle
                     |                        \--skip ("keep going")----------------------------^
                     \--skip--> short break, running (the unfinished block is not counted)

* States: "idle", "focus", "short_break", "long_break".
* Lengths come from Settings when a phase starts (pomodoro_focus_min, pomodoro_short_break_min,
  pomodoro_long_break_min), so changed settings apply from the next phase.
* Every `pomodoro_long_break_every`-th *completed* focus block is followed by a long break.
* When a break ends (time up or skipped) the next focus block starts if `pomodoro_autostart` is
  set; otherwise the timer goes idle until the user starts one.
* A focus block that runs to its end is recorded at once: Tracking:add{pomodoros = 1,
  focus_s = <its length>} then Tracking:flush() (one small write every ~25 minutes, never per card).
* A finished focus block leaves its break *pending* (frozen at full length) until the user takes
  it: the reviewer asks first, nothing ticks while nobody is looking, and a break that starts
  after a long pause still lasts its full length.
* pause()/resume() freeze and unfreeze the current phase. The reviewer pauses it while the device
  sleeps (Suspend .. Resume) and when the user asks.

Pomodoro.settingsMenuItems() gives the matching KOReader settings menu entries (the only UI here;
its widgets are required lazily so the state machine itself has no UI dependencies).
]]

local Settings = require("kanki/settings")
local Tracking = require("kanki/tracking")
local _ = require("gettext")
local T = require("ffi/util").template

local Pomodoro = {
    MIN_MINUTES = 1,
}
Pomodoro.__index = Pomodoro

local LENGTH_KEYS = {
    focus = "pomodoro_focus_min",
    short_break = "pomodoro_short_break_min",
    long_break = "pomodoro_long_break_min",
}

--[[--
@tparam[opt] table opts
  settings: object with get(key) and DEFAULTS (default kanki/settings)
  tracking: object with add(fields) and flush() (default kanki/tracking)
]]
function Pomodoro.new(opts)
    opts = opts or {}
    return setmetatable({
        settings = opts.settings or Settings,
        tracking = opts.tracking or Tracking,
        phase = "idle",
        phase_s = 0,       -- full length of the current phase, seconds
        ends_at = nil,     -- running: `now` at which the current phase ends
        left_s = nil,      -- paused or pending: seconds left
        pending = false,   -- a break waiting for startBreak()
        completed = 0,     -- focus blocks completed with this timer
        focus_cards = 0,   -- cards answered during the current focus block (see addCards)
    }, Pomodoro)
end

function Pomodoro:_setting(key)
    local value = self.settings:get(key)
    if value == nil and self.settings.DEFAULTS then
        value = self.settings.DEFAULTS[key]
    end
    return value
end

--- Length of a phase in seconds, from the settings (whole minutes, at least MIN_MINUTES; the
--- default if the stored value isn't a number).
function Pomodoro:lengthOf(phase)
    local key = LENGTH_KEYS[phase]
    local defaults = self.settings.DEFAULTS or {}
    local minutes = tonumber(self:_setting(key)) or tonumber(defaults[key]) or self.MIN_MINUTES
    return math.max(self.MIN_MINUTES, math.floor(minutes)) * 60
end

--- "idle" | "focus" | "short_break" | "long_break"
function Pomodoro:state()
    return self.phase
end

function Pomodoro:isBreak()
    return self.phase == "short_break" or self.phase == "long_break"
end

--- The current phase is counting down.
function Pomodoro:isRunning()
    return self.ends_at ~= nil
end

--- A phase is under way but frozen (paused by the user or the device sleeping, or a pending break).
function Pomodoro:isPaused()
    return self.phase ~= "idle" and self.ends_at == nil
end

--- A break follows a finished focus block and waits for startBreak().
function Pomodoro:isPending()
    return self.pending
end

--- Full length of the current phase in seconds (0 when idle).
function Pomodoro:length()
    return self.phase_s
end

--- Seconds left in the current phase (nil when idle).
function Pomodoro:remaining(now)
    if self.ends_at then
        return math.max(0, self.ends_at - now)
    end
    return self.left_s
end

--- Seconds until update(now) has something to do; nil when nothing is counting down.
function Pomodoro:dueIn(now)
    if self.ends_at then
        return math.max(0, self.ends_at - now)
    end
    return nil
end

function Pomodoro:_enter(phase, now, pending)
    self.phase = phase
    self.pending = pending and true or false
    if phase == "idle" then
        self.phase_s, self.ends_at, self.left_s = 0, nil, nil
        return
    end
    self.phase_s = self:lengthOf(phase)
    if self.pending then
        self.ends_at, self.left_s = nil, self.phase_s
    else
        self.ends_at, self.left_s = now + self.phase_s, nil
    end
    if phase == "focus" then
        self.focus_cards = 0
    end
end

-- Which break follows the n-th completed focus block.
function Pomodoro:_breakAfter(completed)
    local every = math.floor(tonumber(self:_setting("pomodoro_long_break_every")) or 0)
    if every >= 1 and completed > 0 and completed % every == 0 then
        return "long_break"
    end
    return "short_break"
end

function Pomodoro:_afterBreak(now)
    if self:_setting("pomodoro_autostart") then
        self:_enter("focus", now)
    else
        self:_enter("idle")
    end
end

--- idle -> focus. Returns true if a focus block started.
function Pomodoro:start(now)
    if self.phase ~= "idle" then
        return false
    end
    self:_enter("focus", now)
    return true
end

--- Freeze the running phase. Returns true if it was running.
function Pomodoro:pause(now)
    if not self.ends_at then
        return false
    end
    self.left_s = math.max(0, self.ends_at - now)
    self.ends_at = nil
    return true
end

--- Unfreeze a paused phase (also starts a pending break). Returns true if something resumed.
function Pomodoro:resume(now)
    if self.phase == "idle" or self.ends_at then
        return false
    end
    self.ends_at = now + (self.left_s or self.phase_s)
    self.left_s = nil
    self.pending = false
    return true
end

--- Start the break that is pending after a finished focus block.
function Pomodoro:startBreak(now)
    if not (self.pending and self:isBreak()) then
        return false
    end
    return self:resume(now)
end

--[[--
Move on now. In a focus block: abandon it (not counted) and take a short break right away.
In a break (pending or running): end it; the next focus block starts if autostart, else idle.
@treturn string|nil the new state, nil if there was nothing to skip
]]
function Pomodoro:skip(now)
    if self.phase == "focus" then
        self:_enter("short_break", now)
    elseif self:isBreak() then
        self:_afterBreak(now)
    else
        return nil
    end
    return self.phase
end

--- Back to idle (e.g. the review session ends). An unfinished focus block is not counted.
function Pomodoro:stop()
    self:_enter("idle")
end

--- Count cards answered (n = -1 for an undo) towards the current focus block.
function Pomodoro:addCards(n)
    if self.phase == "focus" then
        self.focus_cards = math.max(0, self.focus_cards + (n or 1))
    end
end

--[[--
Apply a phase change that is due at `now`. Call it when the task scheduled for dueIn() fires.
@treturn table|nil nil if nothing was due, else one of
  { kind = "focus_done", focus_s, cards, completed, break_kind, break_s }  (break is now pending)
  { kind = "break_done", break_kind, next }                               (next = "focus" | "idle")
]]
function Pomodoro:update(now)
    if not self.ends_at or now < self.ends_at then
        return nil
    end
    if self.phase == "focus" then
        local focus_s, cards = self.phase_s, self.focus_cards
        self.completed = self.completed + 1
        self.tracking:add({ pomodoros = 1, focus_s = focus_s })
        self.tracking:flush()
        self:_enter(self:_breakAfter(self.completed), now, true)
        return {
            kind = "focus_done",
            focus_s = focus_s,
            cards = cards,
            completed = self.completed,
            break_kind = self.phase,
            break_s = self.phase_s,
        }
    end
    local break_kind = self.phase
    self:_afterBreak(now)
    return { kind = "break_done", break_kind = break_kind, next = self.phase }
end

---------------------------------------------------------------------------------------------------
-- Settings menu

-- A number setting edited with a SpinWidget (`unit` shown next to the value, may be nil).
local function numberItem(key, text_fmt, title, info, unit, min, max)
    return {
        text_func = function()
            return T(text_fmt, tonumber(Settings:get(key)) or Settings.DEFAULTS[key])
        end,
        enabled_func = function() return Settings:get("pomodoro_enabled") and true or false end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local SpinWidget = require("ui/widget/spinwidget")
            local UIManager = require("ui/uimanager")
            UIManager:show(SpinWidget:new{
                title_text = title,
                info_text = info,
                value = tonumber(Settings:get(key)) or Settings.DEFAULTS[key],
                value_min = min,
                value_max = max,
                value_step = 1,
                value_hold_step = 5,
                default_value = Settings.DEFAULTS[key],
                unit = unit,
                callback = function(spin)
                    Settings:set(key, spin.value)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
end

--[[--
KOReader menu items for the study timer and the Pomodoro, in this order: Pomodoro on/off, focus
block, short break and long break lengths, long break every N blocks, autostart, show study timer.
Changes apply from the next review session (lengths: from the next phase).
]]
function Pomodoro.settingsMenuItems()
    local function enabled() return Settings:get("pomodoro_enabled") and true or false end
    local min = _("min")
    return {
        {
            text = _("Pomodoro focus blocks"),
            help_text = _("While reviewing, study in focus blocks with a short break after each one and a long break every few blocks. The reviewer's top bar shows the time left; when a block ends you are asked whether to take the break. The timer is paused while the Kobo sleeps."),
            checked_func = enabled,
            callback = function() Settings:toggle("pomodoro_enabled") end,
        },
        numberItem("pomodoro_focus_min", _("Focus block: %1 min"), _("Focus block"), nil, min, 5, 90),
        numberItem("pomodoro_short_break_min", _("Short break: %1 min"), _("Short break"), nil, min, 1, 30),
        numberItem("pomodoro_long_break_min", _("Long break: %1 min"), _("Long break"), nil, min, 1, 60),
        numberItem("pomodoro_long_break_every", _("Long break every %1 focus blocks"), _("Long break every"),
            _("Number of completed focus blocks before a long break."), nil, 1, 12),
        {
            text = _("Start focus blocks automatically"),
            help_text = _("Start a focus block when a review session starts, and the next one when a break ends. Otherwise start them from the reviewer's menu."),
            enabled_func = enabled,
            checked_func = function() return Settings:get("pomodoro_autostart") and true or false end,
            callback = function() Settings:toggle("pomodoro_autostart") end,
            separator = true,
        },
        {
            text = _("Show study timer"),
            help_text = _("Show the time spent in the current review session and the cards answered in the reviewer's top bar. It is redrawn once a minute, never while the Kobo sleeps."),
            checked_func = function() return Settings:get("show_session_timer") and true or false end,
            callback = function() Settings:toggle("show_session_timer") end,
        },
    }
end

return Pomodoro

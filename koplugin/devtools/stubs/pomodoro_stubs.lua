--[[
Extra KOReader stand-ins for the study timer / Pomodoro / Wi-Fi tests (test_pomodoro.lua,
test_reviewer_timer.lua, test_sync_wifi.lua), layered on top of koreader_stubs.lua without
changing it (the other tests rely on it exactly as it is):

  * UIManager:getTopmostVisibleWidget(), UIManager:topdown_widgets_iter() (KOReader API)
  * UIManager:setDirty() / widgetRepaint() / forceRePaint() record their calls in PS.refreshes,
    PS.repaints, PS.repaint_count instead of doing nothing
  * Screen rotation: getRotationMode()/setRotationMode(); getWidth/getHeight/getSize follow it
    (portrait 1264x1680, landscape 1680x1264), as KOReader's framebuffer does
  * PS.installWifi(): NetworkMgr Wi-Fi state (isWifiOn, disableWifi, runWhenOnline switching it on,
    wifi_was_on), opt-in because it makes the stub device "offline" until Wi-Fi is on
  * PS.spyTracking(Tracking): counts Tracking:add()/flush() calls (the real module keeps working)

Loaded with require("pomodoro_stubs") (it registers itself in package.loaded like any module).
]]

local Stubs = require("koreader_stubs")
local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = Stubs.UIManager

local PS = {
    refreshes = {},
    repaints = {},
    repaint_count = 0,
    rotation = 0,
    wifi = { on = false, disabled = 0, interactive = nil, connects = 0, decline = false },
}

-- UIManager ---------------------------------------------------------------------------------------

function UIManager:getTopmostVisibleWidget()
    for i = #self._stack, 1, -1 do
        local w = self._stack[i]
        if not w.invisible then return w end
    end
end

function UIManager:topdown_widgets_iter()
    local i = #self._stack + 1
    return function()
        i = i - 1
        if i > 0 then return self._stack[i] end
    end
end

function UIManager:setDirty(widget, mode, region, dither)
    table.insert(PS.refreshes, { widget = widget, mode = mode, region = region, dither = dither })
end

function UIManager:widgetRepaint(widget, x, y)
    table.insert(PS.repaints, { widget = widget, x = x, y = y })
end

function UIManager:forceRePaint()
    PS.repaint_count = PS.repaint_count + 1
end

-- KOReader: setDirty("all", "full") + forceRePaint() (180° rotations, no relayout).
PS.rotation_repaints = 0
function UIManager:onRotation()
    PS.rotation_repaints = PS.rotation_repaints + 1
    self:setDirty("all", "full")
    self:forceRePaint()
end

function PS.clearLog()
    PS.refreshes = {}
    PS.repaints = {}
end

--- Seconds until each queued task running `fn` (stub queue is wall-clock based).
function PS.taskDelays(fn)
    local socket = require("socket")
    local out = {}
    for _, t in ipairs(UIManager._tasks) do
        if t.fn == fn then table.insert(out, t.at - socket.gettime()) end
    end
    return out
end

-- Screen rotation ---------------------------------------------------------------------------------

local Screen = Device.screen
local PORTRAIT_W, PORTRAIT_H = 1264, 1680

function Screen:getRotationMode() return PS.rotation end
function Screen:setRotationMode(mode) PS.rotation = mode end
function Screen:getWidth() return PS.rotation % 2 == 1 and PORTRAIT_H or PORTRAIT_W end
function Screen:getHeight() return PS.rotation % 2 == 1 and PORTRAIT_W or PORTRAIT_H end
function Screen:getSize() return Geom:new{ w = self:getWidth(), h = self:getHeight() } end

-- NetworkMgr Wi-Fi (opt-in) -----------------------------------------------------------------------

function PS.installWifi()
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr.wifi_was_on = false
    function NetworkMgr:isWifiOn() return PS.wifi.on end
    function NetworkMgr:isConnected() return PS.wifi.on end
    function NetworkMgr:isOnline() return PS.wifi.on end
    -- Like beforeWifiAction with "turn on": connects, flags wifi_was_on, then runs the callback.
    -- PS.wifi.decline = true: the user said no to the prompt, the callback never runs.
    function NetworkMgr:runWhenOnline(cb)
        if not PS.wifi.on then
            if PS.wifi.decline then return end
            PS.wifi.on = true
            PS.wifi.connects = PS.wifi.connects + 1
            self.wifi_was_on = true
        end
        cb()
    end
    function NetworkMgr:disableWifi(cb, interactive)
        PS.wifi.on = false
        PS.wifi.disabled = PS.wifi.disabled + 1
        PS.wifi.interactive = interactive
        if interactive then self.wifi_was_on = false end
        if cb then cb() end
    end
    return NetworkMgr
end

-- Tracking spy ------------------------------------------------------------------------------------

function PS.spyTracking(Tracking)
    local spy = { flushes = 0, adds = {} }
    local orig_add, orig_flush = Tracking.add, Tracking.flush
    Tracking.add = function(self, fields, t)
        table.insert(spy.adds, fields)
        return orig_add(self, fields, t)
    end
    Tracking.flush = function(self)
        spy.flushes = spy.flushes + 1
        return orig_flush(self)
    end
    return spy
end

package.loaded["pomodoro_stubs"] = PS
return PS

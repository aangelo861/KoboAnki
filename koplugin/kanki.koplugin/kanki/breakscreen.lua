--[[--
Full-screen Pomodoro break view, shown over the reviewer while a break runs:

                        Short break

                             4                  <- whole minutes left, very large
                        minutes left

        Stand up, look into the distance, drink some water.
                   3 focus blocks today

                  [       Skip break       ]

It is passive about time: the reviewer owns the Pomodoro, calls setRemaining() from its
once-a-minute tick (aligned to the wall-clock minute, never while the device sleeps) and closes
this view when the break ends. A minute change repaints and refreshes ("ui") only the countdown's
rectangle; nothing here is colour or an image, so no refresh is dithered.

Input: the button, either page key or Back skips the break. Like the reviewer, input is ignored for
GUARD_MS after the view appears, so a page key pressed for the last card can't skip it by accident;
key repeat is ignored.

Rotation: a SetRotationMode sent to us (we're the topmost widget) is handed to the reviewer
(`on_rotate`), which rotates the whole stack and then calls relayout() on us. SetDimensions /
ScreenResize broadcasts (emulator / Android window resizes) relayout directly.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local time = require("ui/time")
local _ = require("gettext")
local Screen = Device.screen

local BreakScreen = InputContainer:extend{
    name = "kanki_break",
    covers_fullscreen = true,
    kind = "short_break",  -- or "long_break"
    remaining_s = 0,
    info_text = nil,       -- optional line under the hint
    on_skip = nil,         -- function(): the user skipped the break
    on_rotate = nil,       -- function(mode): SetRotationMode reached us
    on_close = nil,        -- function(screen): we left the window stack (any reason)
    GUARD_MS = 350,
}

local function minutesLeft(seconds)
    return math.max(0, math.ceil((tonumber(seconds) or 0) / 60))
end

local function unitText(minutes)
    return minutes == 1 and _("minute left") or _("minutes left")
end

function BreakScreen:init()
    self:_layout()
end

function BreakScreen:_layout()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.screen_w, self.screen_h = w, h
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    local content_w = math.floor(math.min(w, h) * 0.85)
    local gap = Screen:scaleBySize(24)

    self.minutes = minutesLeft(self.remaining_s)
    self.number_widget = TextWidget:new{
        text = tostring(self.minutes),
        face = Font:getFace("cfont", 120),
        bold = true,
    }
    self.unit_widget = TextWidget:new{
        text = unitText(self.minutes),
        face = Font:getFace("cfont", 26),
    }
    -- Fixed-size boxes: "10" -> "9" never moves anything else, and the white frame clears the
    -- old digits when only this part is repainted.
    self.countdown = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = content_w, h = self.number_widget:getSize().h },
                self.number_widget,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = content_w, h = self.unit_widget:getSize().h },
                self.unit_widget,
            },
        },
    }

    local group = VerticalGroup:new{
        align = "center",
        TextWidget:new{
            text = self.kind == "long_break" and _("Long break") or _("Short break"),
            face = Font:getFace("tfont", 30),
        },
        VerticalSpan:new{ width = gap },
        self.countdown,
        VerticalSpan:new{ width = gap },
        TextBoxWidget:new{
            text = _("Stand up, look into the distance, drink some water."),
            face = Font:getFace("infofont", 22),
            width = content_w,
            alignment = "center",
        },
    }
    if self.info_text and self.info_text ~= "" then
        table.insert(group, VerticalSpan:new{ width = Size.padding.default })
        table.insert(group, TextBoxWidget:new{
            text = self.info_text,
            face = Font:getFace("infofont", 18),
            width = content_w,
            alignment = "center",
        })
    end
    table.insert(group, VerticalSpan:new{ width = 2 * gap })
    table.insert(group, Button:new{
        text = _("Skip break"),
        width = math.floor(content_w * 0.8),
        text_font_size = 24,
        bordersize = Size.border.thick,
        radius = Size.radius.button,
        callback = function() self:_skip() end,
        show_parent = self,
    })

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            group,
        },
    }

    if Device:hasKeys() then
        local key = Device.input.group
        self.key_events = {
            KankiBreakSkip = { { key.PgFwd }, { key.PgBack } },
            KankiBreakBack = { { key.Back } },
        }
    end
    self.ready_at = time.now() + time.ms(self.GUARD_MS)
end

--- New time left (from the reviewer's minute tick). Refreshes only the countdown, only when the
--- displayed minute changes.
function BreakScreen:setRemaining(seconds)
    self.remaining_s = seconds
    local minutes = minutesLeft(seconds)
    if minutes == self.minutes then return end
    self.minutes = minutes
    self.number_widget:setText(tostring(minutes))
    self.unit_widget:setText(unitText(minutes))
    UIManager:setDirty(self, function()
        return "ui", self.countdown.dimen
    end)
end

--- Rebuild for the current screen size (after a rotation).
function BreakScreen:relayout()
    self:_layout()
    UIManager:setDirty(self, "full")
end

function BreakScreen:_skip()
    if time.now() < self.ready_at then return end
    if self.on_skip then self.on_skip() end
end

function BreakScreen:onKankiBreakSkip()
    self:_skip()
    return true
end
BreakScreen.onKankiBreakBack = BreakScreen.onKankiBreakSkip

function BreakScreen:onKeyRepeat()
    return true
end

function BreakScreen:onSetRotationMode(mode)
    if self.on_rotate then
        return self.on_rotate(mode)
    end
end

function BreakScreen:onScreenResize()
    if Screen:getWidth() ~= self.screen_w or Screen:getHeight() ~= self.screen_h then
        self:relayout()
    end
end
BreakScreen.onSetDimensions = BreakScreen.onScreenResize

-- KOReader is quitting (Exit), or powering off / rebooting / entering USB mass storage (broadcast
-- Close): get off the window stack. Not true: these are broadcasts.
function BreakScreen:onExit()
    if not self.closed then
        UIManager:close(self)
    end
end
BreakScreen.onClose = BreakScreen.onExit

function BreakScreen:onCloseWidget()
    if self.closed then return end
    self.closed = true
    if self.on_close then
        self.on_close(self)
    end
end

return BreakScreen

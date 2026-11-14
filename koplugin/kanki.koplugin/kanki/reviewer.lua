--[[--
Full-screen Anki reviewer.

Layout (portrait; landscape is the same layout at the other size, see Rotation):
  +-------------------------------------------------------------+
  | [≡]  [■] Deck name     12 min · 34 cards · Focus 18 min [Undo] |  top bar ([■] = card flag)
  |      New 3   Learn 1   Due 12      (sync status)            |
  +-------------------------------------------------------------+
  |                                                             |
  |   card (ScrollHtmlWidget, MuPDF)                            |  card area
  |                                                             |
  +-------------------------------------------------------------+
  |  [   Show answer   ]             (question side)            |  bottom bar,
  |  [Again][ Hard ][ Good ][ Easy ] (answer side, + intervals) |  ~13% of height
  +-------------------------------------------------------------+

Input:
  question side: tap anywhere in the card area, tap "Show answer", or either page key -> answer
  answer side:   one tap on a rating button rates; PgFwd = Good, PgBack = Again (swappable in
                 settings). KOReader's own "invert page-turn buttons" setting is applied by
                 KOReader in the input event map (Device:invertButtons), *before* the PgFwd/PgBack
                 key groups are matched, so we must not (and do not) look at it here.
  swipes:        scroll long cards (ScrollHtmlWidget); never rate.
  key repeat:    ignored (holding a page key must not rate several cards).
  double taps:   every request is synchronous and sets `busy`; after each new screen is painted,
                 input is ignored for GUARD_MS so taps/presses queued while the request and the
                 e-ink refresh were running cannot hit the next card.

Study timer and Pomodoro (DESIGN.md, v0.2):
  * The session clock starts when the reviewer is shown and stops while the device sleeps
    (Suspend .. Resume) and during a Pomodoro break. It reads CLOCK_BOOTTIME: KOReader's UI clock
    (MONOTONIC) stands still while the Kobo is in standby, which AutoSuspend may enter between two
    page turns. Study time and cards go into Tracking *in memory* at every minute tick (so the
    stats and the sleep screen are current) and are written at Suspend and at close, where
    sessions = 1 is added too. Never a write per card.
  * The top bar shows "12 min · 34 cards" (show_session_timer) and "Focus 18 min" / "Break 3 min"
    (a Pomodoro under way). It is redrawn once a minute, 1 s after the wall-clock minute like
    KOReader's own footer clock. Only the bar's rectangle is repainted and refreshed, with "ui" and
    never dithered (the card's `dithered` flag is for its images). Nothing is scheduled while the
    device sleeps, when nothing on screen depends on the time, or after close. No per-second timer.
  * The Pomodoro (kanki/pomodoro.lua) gets one task at the exact end of the running phase. End of
    a focus block -> "take a break?" dialog -> BreakScreen (minute countdown, Skip) -> at the end
    of the break, a toast and back to the card; the next focus block starts if autostart is set.
  * Menu: Flag card (Anki's 7 flag colours + remove, POST /flag; a marker in the top bar shows the
    current card's flag), Pomodoro start / pause / resume / skip.

Rotation (the Libra Colour has a G-sensor): see Reviewer:rotate.
]]

local Blitbuffer = require("ffi/blitbuffer")
local BreakScreen = require("kanki/breakscreen")
local ButtonDialog = require("ui/widget/buttondialog")
local Button = require("ui/widget/button")
local CardHtml = require("kanki/cardhtml")
local CardImages = require("kanki/cardimages")
local CardImageViewer = require("kanki/cardimageviewer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Client = require("kanki/client")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Pomodoro = require("kanki/pomodoro")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Server = require("kanki/server")
local Settings = require("kanki/settings")
local Size = require("ui/size")
local Sync = require("kanki/sync")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Tracking = require("kanki/tracking")
local UI = require("kanki/uihelpers")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local DGENERIC_ICON_SIZE = G_defaults:readSetting("DGENERIC_ICON_SIZE")

-- Light tints for the rating buttons on colour screens (text stays black). On greyscale they're white.
local RATING_TINTS = {
    [1] = "#F4C7C3", -- Again
    [2] = "#E3E3E3", -- Hard
    [3] = "#C8E6C9", -- Good
    [4] = "#C5DCF5", -- Easy
}
local DEFAULT_LABELS = { [1] = _("Again"), [2] = _("Hard"), [3] = _("Good"), [4] = _("Easy") }

-- Anki's card flags (POST /flag, card payload "flag"): saturated colours for the small marker in
-- the top bar, lighter tints behind the black text of the "Flag card" buttons (colour screens).
local FLAGS = {
    [1] = { text = _("Red"), marker = "#E53935", tint = "#F28B82" },
    [2] = { text = _("Orange"), marker = "#FB8C00", tint = "#FBBC66" },
    [3] = { text = _("Green"), marker = "#43A047", tint = "#8FD694" },
    [4] = { text = _("Blue"), marker = "#1E88E5", tint = "#8AB4F8" },
    [5] = { text = _("Pink"), marker = "#EC407A", tint = "#F6A5C0" },
    [6] = { text = _("Turquoise"), marker = "#00ACC1", tint = "#7FDBE6" },
    [7] = { text = _("Purple"), marker = "#8E24AA", tint = "#C58AF9" },
}

-- Seconds on CLOCK_BOOTTIME, which keeps counting in standby (KOReader falls back to REALTIME on
-- kernels without it). Only differences of it are used.
local boottime = time.boottime_or_realtime_coarse or time.now
local to_s = time.to_s or function(t) return t / 1e6 end

local function cardsText(n)
    if n == 1 then return _("1 card") end
    return T(_("%1 cards"), n)
end

local function durationText(seconds)
    local minutes = math.floor((seconds or 0) / 60)
    if minutes < 60 then
        return T(_("%1 min"), minutes)
    end
    return T(_("%1 h %2 min"), math.floor(minutes / 60), minutes % 60)
end

---------------------------------------------------------------------------------------------------
-- Slot: fixed-size placeholder whose single child can be swapped (and freed). With a background
-- it clears its whole rectangle first, so it can be repainted on its own (see _redrawTopBar).

local Slot = WidgetContainer:extend{
    slot_w = 0,
    slot_h = 0,
    background = nil,
}

function Slot:getSize()
    return Geom:new{ w = self.slot_w, h = self.slot_h }
end

function Slot:paintTo(bb, x, y)
    if self.background then
        bb:paintRect(x, y, self.slot_w, self.slot_h, self.background)
    end
    if self[1] then
        self[1]:paintTo(bb, x, y)
    end
end

function Slot:setContent(widget)
    if self[1] and self[1].free then
        self[1]:free()
    end
    self[1] = widget
end

---------------------------------------------------------------------------------------------------
-- BigButton: tall, framed, two-line button (label + interval). Taps only; holds/swipes are ignored.

local BigButton = InputContainer:extend{
    width = nil,
    height = nil,
    label = "",
    sublabel = nil,
    label_size = 24,
    sublabel_size = 18,
    background = nil,
    enabled = true,
    callback = nil,
}

function BigButton:init()
    local border = Size.border.thick
    local inner_w = self.width - 2 * border
    local inner_h = self.height - 2 * border
    local fg = self.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
    local text_w = inner_w - 2 * Size.padding.small
    local group = VerticalGroup:new{ align = "center" }
    table.insert(group, TextWidget:new{
        text = self.label,
        face = Font:getFace("cfont", self.label_size),
        bold = true,
        fgcolor = fg,
        max_width = text_w,
    })
    if self.sublabel and self.sublabel ~= "" then
        table.insert(group, VerticalSpan:new{ width = Size.padding.small })
        table.insert(group, TextWidget:new{
            text = self.sublabel,
            face = Font:getFace("cfont", self.sublabel_size),
            fgcolor = fg,
            max_width = text_w,
        })
    end
    self.frame = FrameContainer:new{
        bordersize = border,
        color = fg,
        radius = Size.radius.button,
        background = self.background or Blitbuffer.COLOR_WHITE,
        padding = 0,
        margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            group,
        },
    }
    self[1] = self.frame
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = {
        TapBigButton = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }
end

function BigButton:onTapBigButton()
    if self.enabled and self.callback then
        self.callback(self)
    end
    return true
end

--- Instant visual feedback (inverted), painted and refreshed *now*, before a blocking request.
function BigButton:highlight()
    if not (self.dimen and self.frame and self.frame.dimen) then return end
    self.frame.invert = true
    UIManager:widgetRepaint(self.frame, self.dimen.x, self.dimen.y)
    UIManager:setDirty(nil, "fast", self.dimen)
    UIManager:forceRePaint()
end

---------------------------------------------------------------------------------------------------

local function hasFrontlight()
    return type(Device.hasFrontlight) == "function" and Device:hasFrontlight() and true or false
end

local Reviewer = InputContainer:extend{
    name = "kanki_reviewer",
    covers_fullscreen = true,
    deck_name = nil,
    on_close = nil,  -- function(answered_count): user went back to the deck list
    on_detach = nil, -- function(): widget left the window stack (any reason)
    GUARD_MS = 350,
    BOTTOM_RATIO = 0.13,
    SYNC_TEXT_MIN_INTERVAL_S = 3,
    PHASE_SLACK_S = 0.05, -- the Pomodoro task fires this much after the phase end
    LOCKED_RETRY_S = 30,  -- a phase ending under a lock screen is looked at again this much later
    -- Clocks, replaceable by tests: seconds that keep counting in standby (differences only), and
    -- wall-clock seconds (only to align redraws with the minute).
    clock = function() return to_s(boottime()) end,
    wallClock = os.time,
}

function Reviewer:init()
    self.font_px = Screen:scaleBySize(Settings:get("font_size"))

    self.state = "loading" -- loading | question | answer | done | message
    self.answered = 0
    self.cards_shown = 0
    self.ready_at = 0
    self.busy = false
    self.shown = false

    -- Sizes that don't depend on the orientation -----------------------------------------------
    self.side_pad = Size.padding.large
    self.gap = Screen:scaleBySize(12)
    self.line_h = Size.line.thick
    self.icon_size = Screen:scaleBySize(DGENERIC_ICON_SIZE * 0.8)
    self.name_face = Font:getFace("smalltfont", 20)
    self.count_face = Font:getFace("cfont", 17)
    self.status_face = Font:getFace("x_smallinfofont", 15)

    -- Study timer & Pomodoro (started in onShow) ----------------------------------------------
    self.study_acc = 0       -- seconds counted up to study_started
    self.study_started = nil -- clock() when the session clock last started; nil while stopped
    self.pomodoro = Settings:get("pomodoro_enabled") and Pomodoro.new() or nil
    self._tick_fn = function() self:_onTick() end
    self._phase_fn = function() self:_onPhaseDue() end
    self._wake_fn = function() self:_wake() end

    self:_layout()
    self:_buildTopBar()
    self.card_slot:setContent(self:_messageWidget(_("Loading…")))
    self.bottom_slot:setContent(nil)

    self._sync_listener = function(event, st) self:_onSync(event, st) end
    Sync:addListener(self._sync_listener)
    if Sync:isActive() then
        self.sync_text = Sync.describe(Sync.last)
    end
end

--- Geometry, widget tree and input zones for the current screen size (again after a rotation).
function Reviewer:_layout()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }

    self.top_h = self:_measureTopBarHeight()
    self.bottom_h = math.floor(self.screen_h * self.BOTTOM_RATIO)
    self.bottom_total_h = self.bottom_h + 2 * self.side_pad
    self.card_h = self.screen_h - self.top_h - self.line_h - self.bottom_total_h
    -- ScrollHtmlWidget width; HtmlBoxWidget (MuPDF) gets width - scroll bar - span.
    self.card_w = self.screen_w - 2 * self.side_pad
    self.html_w = self.card_w - ScrollHtmlWidget.scroll_bar_width - ScrollHtmlWidget.text_scroll_span
    -- In MuPDF's HTML engine 1 CSS px == 1 device px (see cardhtml.lua), and our CSS sets the body
    -- margin to 0, so the content width in CSS px is exactly html_w.
    self.img_max_px = self.html_w
    self.card_dimen = Geom:new{
        x = 0, y = self.top_h + self.line_h,
        w = self.screen_w, h = self.card_h,
    }
    self.top_dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.top_h }

    self.top_slot = Slot:new{ slot_w = self.screen_w, slot_h = self.top_h, background = Blitbuffer.COLOR_WHITE }
    self.card_slot = Slot:new{ slot_w = self.screen_w, slot_h = self.card_h }
    self.bottom_slot = Slot:new{ slot_w = self.screen_w, slot_h = self.bottom_total_h }
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        VerticalGroup:new{
            align = "left",
            self.top_slot,
            LineWidget:new{ dimen = Geom:new{ w = self.screen_w, h = self.line_h } },
            self.card_slot,
            self.bottom_slot,
        },
    }

    -- Input -----------------------------------------------------------------------------------
    if Device:hasKeys() then
        local group = Device.input.group
        self.key_events = {
            KankiPageFwd = { { group.PgFwd } },
            KankiPageBack = { { group.PgBack } },
            KankiBack = { { group.Back } },
        }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            KankiTapCard = {
                GestureRange:new{ ges = "tap", range = self.card_dimen },
            },
        }
    end
end

---------------------------------------------------------------------------------------------------
-- Building blocks

function Reviewer:_measureTopBarHeight()
    local name = TextWidget:new{ text = "Ag", face = self.name_face, bold = true }
    local counts = TextWidget:new{ text = "Ag", face = self.count_face }
    self.name_h = name:getSize().h
    local text_h = self.name_h + counts:getSize().h + 2 * Size.line.thick + 2 * Size.padding.small
    name:free()
    counts:free()
    -- The flag marker sits on the deck name's line.
    self.flag_size = math.floor(self.name_h * 0.6)
    local icon_h = self.icon_size + 2 * Size.padding.default
    return math.max(text_h, icon_h)
end

function Reviewer:_queueOfCard()
    local kind = self.card and self.card.kind
    if kind == "new" then return "new" end
    if kind == "learning" or kind == "relearning" then return "learning" end
    if kind == "review" then return "review" end
    return nil
end

function Reviewer:_countWidget(label, value, emphasised)
    local text = TextWidget:new{
        text = string.format("%s %d", label, tonumber(value) or 0),
        face = self.count_face,
        bold = emphasised,
    }
    local underline_h = 2 * Size.line.thick
    return VerticalGroup:new{
        align = "left",
        text,
        LineWidget:new{
            dimen = Geom:new{ w = text:getSize().w, h = underline_h },
            background = emphasised and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        },
    }
end

--- Flag number (1-7) of the card on screen, or 0.
function Reviewer:_cardFlag()
    if self.card and (self.state == "question" or self.state == "answer") then
        return tonumber(self.card.flag) or 0
    end
    return 0
end

--- Small square in the flag's colour (greyscale screens: dark grey with the flag number).
function Reviewer:_flagMarker()
    local flag = self:_cardFlag()
    local info = FLAGS[flag]
    if not info then return nil end
    local colour = Screen:isColorEnabled()
    return FrameContainer:new{
        bordersize = Size.border.thin,
        radius = Size.radius.default,
        padding = 0,
        margin = 0,
        background = colour and Blitbuffer.colorFromString(info.marker) or Blitbuffer.COLOR_DARK_GRAY,
        CenterContainer:new{
            dimen = Geom:new{ w = self.flag_size, h = self.flag_size },
            colour and VerticalSpan:new{ width = 0 } or TextWidget:new{
                text = tostring(flag),
                face = self.status_face,
                bold = true,
                fgcolor = Blitbuffer.COLOR_WHITE,
            },
        },
    }
end

--- "12 min · 34 cards · Focus 18 min", or nil when there's nothing to show.
function Reviewer:_timerText(now)
    now = now or self.clock()
    local parts = {}
    if self._session_started and Settings:get("show_session_timer") then
        table.insert(parts, durationText(self:_studySeconds(now)))
        table.insert(parts, cardsText(self.answered))
    end
    local p = self.pomodoro
    if p and p:state() ~= "idle" then
        -- Rounded up, like any countdown: "Focus 1 min" until the block is over.
        local minutes = math.ceil((p:remaining(now) or 0) / 60)
        if p:state() == "focus" then
            table.insert(parts, p:isPaused() and T(_("Focus %1 min (paused)"), minutes)
                or T(_("Focus %1 min"), minutes))
        else
            table.insert(parts, T(_("Break %1 min"), minutes))
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " · ")
end

function Reviewer:_buildTopBar()
    local menu_button = IconButton:new{
        icon = "appbar.menu",
        width = self.icon_size,
        height = self.icon_size,
        padding = Size.padding.default,
        padding_left = self.side_pad,
        padding_right = self.side_pad,
        callback = function() self:showMenu() end,
        show_parent = self,
    }
    local undo_w = Screen:scaleBySize(90)
    local undo_button = Button:new{
        text = _("Undo"),
        width = undo_w,
        enabled = self.undo_label ~= nil and self.state ~= "loading",
        text_font_size = 18,
        bordersize = Size.border.button,
        radius = Size.radius.button,
        callback = function() self:undo() end,
        show_parent = self,
    }
    -- Gap between the middle (deck name, timers, counts) and the Undo button: right-aligned timer
    -- text otherwise ends exactly on the button's border (seen on the Libra Colour).
    local undo_gap = Size.span.horizontal_default * 2
    -- ☼ opens KOReader's brightness/warmth dialog (the same glyph KOReader's status bar uses).
    local light_button
    if hasFrontlight() then
        light_button = Button:new{
            text = "☼",
            width = Screen:scaleBySize(54),
            text_font_size = 26,
            bordersize = 0,
            callback = function() self:showLightDialog() end,
            show_parent = self,
        }
    end
    local light_w = light_button and light_button:getSize().w or 0
    -- Only on cards that have images: opens the first one (image-occlusion question sides have no
    -- other way in, a tap there shows the answer).
    local image_button
    if self:_hasCardImages() then
        image_button = Button:new{
            text = _("Image"),
            width = undo_w,
            text_font_size = 18,
            bordersize = Size.border.button,
            radius = Size.radius.button,
            callback = function() self:showImages(1) end,
            show_parent = self,
        }
    end
    local image_w = image_button and (image_button:getSize().w + Size.span.horizontal_default) or 0
    local middle_w = self.screen_w - menu_button:getSize().w - undo_w - 2 * self.side_pad - undo_gap - light_w - image_w

    local counts = self.counts or {}
    local queue = self:_queueOfCard()
    local counts_group = HorizontalGroup:new{
        align = "top",
        self:_countWidget(_("New"), counts.new, queue == "new"),
        HorizontalSpan:new{ width = Size.span.horizontal_default * 2 },
        self:_countWidget(_("Learn"), counts.learning, queue == "learning"),
        HorizontalSpan:new{ width = Size.span.horizontal_default * 2 },
        self:_countWidget(_("Due"), counts.review, queue == "review"),
    }
    local status_w = middle_w - counts_group:getSize().w - Size.span.horizontal_default * 3
    if self.sync_text and self.sync_text ~= "" and status_w > Screen:scaleBySize(40) then
        table.insert(counts_group, HorizontalSpan:new{ width = Size.span.horizontal_default * 3 })
        table.insert(counts_group, TextWidget:new{
            text = self.sync_text,
            face = self.status_face,
            max_width = status_w,
        })
        counts_group:resetLayout() -- getSize() above cached the layout without the status text
    end

    -- First line: [flag] deck name on the left, timers right-aligned against the Undo button.
    local name_row = HorizontalGroup:new{ align = "center" }
    local name_w = middle_w
    local marker = self:_flagMarker()
    if marker then
        table.insert(name_row, marker)
        table.insert(name_row, HorizontalSpan:new{ width = Size.span.horizontal_small })
        name_w = name_w - marker:getSize().w - Size.span.horizontal_small
    end
    self.timer_text = self:_timerText()
    local timer_widget
    if self.timer_text then
        timer_widget = TextWidget:new{
            text = self.timer_text,
            face = self.status_face,
            max_width = math.floor(middle_w * 0.6),
        }
        name_w = name_w - timer_widget:getSize().w - Size.span.horizontal_default
    end
    name_w = math.max(name_w, Screen:scaleBySize(40))
    local deck_title = (self.deck_name or (self.card and self.card.deck) or _("Anki")):gsub("::", " › ")
    local name_widget = TextWidget:new{
        text = deck_title,
        face = self.name_face,
        bold = true,
        max_width = name_w,
        truncate_left = true, -- keep the leaf deck name visible
    }
    if timer_widget then
        table.insert(name_row, LeftContainer:new{
            dimen = Geom:new{ w = name_w, h = name_widget:getSize().h },
            name_widget,
        })
        table.insert(name_row, HorizontalSpan:new{ width = Size.span.horizontal_default })
        table.insert(name_row, timer_widget)
    else
        table.insert(name_row, name_widget)
    end

    local bar = HorizontalGroup:new{
        align = "center",
        menu_button,
        LeftContainer:new{
            dimen = Geom:new{ w = middle_w, h = self.top_h },
            VerticalGroup:new{
                align = "left",
                name_row,
                VerticalSpan:new{ width = Size.padding.small },
                counts_group,
            },
        },
        HorizontalSpan:new{ width = undo_gap },
        image_button or HorizontalSpan:new{ width = 0 },
        HorizontalSpan:new{ width = image_button and Size.span.horizontal_default or 0 },
        light_button or HorizontalSpan:new{ width = 0 },
        undo_button,
        HorizontalSpan:new{ width = self.side_pad },
    }
    self.top_slot:setContent(bar)
end

function Reviewer:_messageWidget(text, size)
    return CenterContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = self.card_h },
        TextBoxWidget:new{
            text = text,
            face = Font:getFace("infofont", size or 22),
            width = self.card_w,
            alignment = "center",
        },
    }
end

function Reviewer:_bottomBar(buttons)
    local group = HorizontalGroup:new{ align = "center" }
    for i, b in ipairs(buttons) do
        if i > 1 then
            table.insert(group, HorizontalSpan:new{ width = self.gap })
        end
        table.insert(group, b)
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = self.bottom_total_h },
        group,
    }
end

--- Width of each of n equal buttons across the bar.
function Reviewer:_buttonWidth(n)
    local total = self.screen_w - 2 * self.side_pad - (n - 1) * self.gap
    return math.floor(total / n)
end

function Reviewer:_tint(rating)
    if Screen:isColorEnabled() and RATING_TINTS[rating] then
        return Blitbuffer.colorFromString(RATING_TINTS[rating])
    end
    return nil
end

function Reviewer:_showAnswerBar()
    return self:_bottomBar({
        BigButton:new{
            width = self:_buttonWidth(1),
            height = self.bottom_h,
            label = _("Show answer"),
            sublabel = _("or tap the card · press a page button"),
            sublabel_size = 15,
            callback = function()
                if self:_inputReady() and self.state == "question" then
                    self:showAnswer()
                end
            end,
        },
    })
end

function Reviewer:_ratingBar()
    local by_rating = {}
    for _, b in ipairs(self.card and self.card.buttons or {}) do
        if type(b) == "table" and b.rating then
            by_rating[b.rating] = b
        end
    end
    local w = self:_buttonWidth(4)
    local widgets = {}
    self.rating_buttons = {}
    for rating = 1, 4 do
        local info = by_rating[rating] or {}
        local button = BigButton:new{
            width = w,
            height = self.bottom_h,
            label = info.label or DEFAULT_LABELS[rating],
            sublabel = info.interval or "",
            background = self:_tint(rating),
            callback = function()
                self:rate(rating)
            end,
        }
        self.rating_buttons[rating] = button
        widgets[rating] = button
    end
    return self:_bottomBar(widgets)
end

function Reviewer:_doneBar()
    local w = self:_buttonWidth(2)
    return self:_bottomBar({
        BigButton:new{
            width = w, height = self.bottom_h,
            label = _("Back to decks"),
            callback = function() self:close() end,
        },
        BigButton:new{
            width = w, height = self.bottom_h,
            label = _("Sync now"),
            callback = function() Sync:start("normal") end,
        },
    })
end

function Reviewer:_setCardHtml(side_html)
    local card = self.card
    local linked_html
    linked_html, self.card_images = CardImages.prepare(side_html, { link_occlusion = self.state == "answer" })
    local body, css = CardHtml.build(linked_html, card.css, { font_px = self.font_px, ord = card.ord })
    local media_dir = Server:mediaDir() -- GET /status "media_dir" (absolute)
    -- MuPDF's open_directory fails on a missing dir (e.g. before the first media sync).
    local resource_dir = lfs.attributes(media_dir, "mode") == "directory" and media_dir or nil
    local ok, widget = pcall(ScrollHtmlWidget.new, ScrollHtmlWidget, {
        html_body = body,
        css = css,
        default_font_size = self.font_px,
        html_resource_directory = resource_dir,
        width = self.card_w,
        height = self.card_h,
        dialog = self,
        html_link_tapped_callback = function(link) self:_onCardLink(link) end,
    })
    local content
    if ok then
        -- Taps on the card are ours (show answer), and page keys show/rate instead of scrolling.
        widget:setTapScrollEnabled(false)
        widget.key_events = {}
        content = HorizontalGroup:new{
            align = "top",
            HorizontalSpan:new{ width = self.side_pad },
            widget,
        }
    else
        logger.err("kanki: could not render card", card.id, widget)
        content = self:_messageWidget(T(_("This card could not be displayed.\n\n%1"), tostring(widget)), 18)
    end
    self.dithered = CardHtml.hasImages(side_html) or nil
    self.card_slot:setContent(content)
end

---------------------------------------------------------------------------------------------------
-- Screens

function Reviewer:_refresh(mode)
    UIManager:setDirty(self, mode or "ui", self.dimen, self.dithered)
    if self.shown then
        -- Paint and refresh *now*, so the input guard starts after the screen really changed.
        UIManager:forceRePaint()
    end
    self.ready_at = time.now() + time.ms(self.GUARD_MS)
end

function Reviewer:_inputReady()
    return not self.busy and time.now() >= self.ready_at
end

-- Card area + bottom bar of each state (also used to rebuild them after a rotation).

function Reviewer:_questionContent()
    self.rating_buttons = nil
    self:_setCardHtml(self.card.question)
    self.bottom_slot:setContent(self:_showAnswerBar())
end

function Reviewer:_answerContent()
    self:_setCardHtml(self.card.answer)
    self.bottom_slot:setContent(self:_ratingBar())
end

function Reviewer:_doneContent()
    self.card_slot:setContent(self:_messageWidget(
        _("Congratulations!\n\nYou have finished this deck for now.")))
    self.bottom_slot:setContent(self:_doneBar())
end

function Reviewer:_messageContent()
    self.card_slot:setContent(self:_messageWidget(self.message_text or ""))
    self.bottom_slot:setContent(self:_bottomBar({
        BigButton:new{
            width = self:_buttonWidth(1), height = self.bottom_h,
            label = _("Back to decks"),
            callback = function() self:close() end,
        },
    }))
end

function Reviewer:_renderState()
    if self.state == "question" and self.card then
        self:_questionContent()
    elseif self.state == "answer" and self.card then
        self:_answerContent()
    elseif self.state == "done" then
        self:_doneContent()
    elseif self.state == "message" then
        self:_messageContent()
    else
        self.card_slot:setContent(self:_messageWidget(_("Loading…")))
        self.bottom_slot:setContent(nil)
    end
end

function Reviewer:showQuestion()
    self.state = "question"
    self:_questionContent()
    self:_buildTopBar()
    self.cards_shown = self.cards_shown + 1
    local every = tonumber(Settings:get("full_refresh_every")) or 0
    local mode = "ui"
    if self.cards_shown == 1 then
        mode = "flashui"
    elseif every > 0 and self.cards_shown % every == 0 then
        mode = "full" -- clears colour ghosting
    end
    self:_refresh(mode)
    self.shown_at = time.now()
end

function Reviewer:showAnswer()
    if not self.card then return end
    self.state = "answer"
    self:_answerContent()
    self:_buildTopBar() -- the answer may have images the question hasn't (Image button)
    self:_refresh("ui")
end

function Reviewer:showDone()
    self.state = "done"
    self.card = nil
    self.rating_buttons = nil
    self.dithered = nil
    self:_doneContent()
    self:_buildTopBar()
    self:_refresh("flashui")
end

function Reviewer:showMessage(text)
    self.state = "message"
    self.message_text = text
    self.card = nil
    self.rating_buttons = nil
    self.dithered = nil
    self:_messageContent()
    self:_buildTopBar()
    self:_refresh("ui")
end

--- Render a GET /next-style body.
function Reviewer:applyNext(res)
    if type(res.counts) == "table" then
        self.counts = res.counts
    end
    self.undo_label = res.undo
    if res.state == "card" and type(res.card) == "table" then
        self.card = res.card
        self:showQuestion()
    elseif res.state == "done" then
        self:showDone()
    elseif res.state == "no_collection" then
        self:showMessage(_("There is no collection on this device yet.\n\nGo back to the deck list and sync with AnkiWeb."))
    else
        self:showMessage(T(_("Unexpected answer from the Anki server: %1"), tostring(res.state)))
    end
end

--[[--
Repaint the top bar on its own: rebuilt, painted into the framebuffer and refreshed with "ui" over
its rectangle only. setDirty(self, …) would repaint the whole reviewer and inherit `dithered` (set
for cards with images, so the Kaleido colour waveform is used for them): the bar is text.
When something is drawn over the reviewer (a menu, a toast), UIManager repaints the stack in order
instead, still refreshing only the bar's rectangle. Nothing while hidden by the break screen or the
sleep screen.
]]
function Reviewer:_redrawTopBar()
    self:_buildTopBar()
    if not self.shown or self.closed or self.suspended or self.break_screen or Device.screen_saver_mode then
        return
    end
    if self:_isTopmost() then
        UIManager:widgetRepaint(self.top_slot, self.top_dimen.x, self.top_dimen.y)
        UIManager:setDirty(nil, "ui", self.top_dimen)
    else
        UIManager:setDirty(self, "ui", self.top_dimen)
    end
end

function Reviewer:_isTopmost()
    -- (Skips invisible widgets such as TrapWidget; toasts count as being over us.)
    return UIManager.getTopmostVisibleWidget ~= nil and UIManager:getTopmostVisibleWidget() == self
end

---------------------------------------------------------------------------------------------------
-- Actions

function Reviewer:_handleError(err)
    if err.kind == "server_down" then
        Server:markDown()
        UI.notify(_("Restarting the Anki server…"))
        Server:ensure(function(ok, ensure_err)
            if ok then
                -- Connection refused => the request never reached the server: just reload.
                self:loadNext()
            else
                UI.showError(ensure_err)
            end
        end)
        return
    end
    UI.showError(err)
end

function Reviewer:loadNext()
    self.busy = true
    local res, err = Client:nextCard(self.img_max_px)
    self.busy = false
    if not res then
        if err.kind ~= "server_down" and (self.state == "loading" or self.state == "message") then
            -- e.g. "Sync in progress": stay on a message screen; the sync listener reloads us
            -- when the collection stage is over.
            self:showMessage(UI.errorText(err))
            return
        end
        return self:_handleError(err)
    end
    self:applyNext(res)
end

function Reviewer:rate(rating)
    if self.state ~= "answer" or not self.card or not self:_inputReady() then
        return
    end
    self.busy = true
    if self.rating_buttons and self.rating_buttons[rating] then
        self.rating_buttons[rating]:highlight()
    end
    local ms_taken = time.to_ms(time.since(self.shown_at or time.now()))
    local res, err = Client:answer(self.card.id, rating, ms_taken, self.img_max_px)
    self.busy = false
    if not res then
        -- Keep the answer side up so the user can try again (busy) or after a server restart.
        self:showAnswer()
        return self:_handleError(err)
    end
    self.answered = self.answered + 1
    if self.pomodoro then self.pomodoro:addCards(1) end
    self:applyNext(res)
end

function Reviewer:undo()
    if not self.undo_label or not self:_inputReady() then
        return
    end
    local label = self.undo_label
    self.busy = true
    local res, err = Client:undo(self.img_max_px)
    self.busy = false
    if not res then
        return self:_handleError(err)
    end
    if self.answered > 0 then
        self.answered = self.answered - 1
        if self.pomodoro then self.pomodoro:addCards(-1) end
    end
    self:applyNext(res)
    UI.notify(T(_("Undone: %1"), label))
end

function Reviewer:_hasCardImages()
    return (self.state == "question" or self.state == "answer") and self.card ~= nil
        and self.card_images ~= nil and #self.card_images > 0
end

--- A link in the card: our image links open the viewer; any other link acts like a tap on the card
--- (cards can't leave the reviewer, and the tap must still show the answer).
function Reviewer:_onCardLink(link)
    local index = link and CardImages.linkIndex(link.uri)
    if index then
        self:showImages(index)
    else
        self:onKankiTapCard()
    end
end

--- Full-screen viewer for this side's images, opened at image number `index`.
function Reviewer:showImages(index)
    if self.image_viewer or not self:_hasCardImages() or not self:_inputReady() then return end
    local items, start = CardImages.viewable(self.card_images, Server:mediaDir(), index)
    if #items == 0 then
        UI.notify(_("This image isn't on the Kobo yet. Sync to download it."))
        return
    end
    local viewer
    local ok, err = pcall(function()
        viewer = CardImageViewer.forItems(items, start, function()
            self.image_viewer = nil
            -- The press or tap that closed it must not land on the card underneath.
            self.ready_at = time.now() + time.ms(self.GUARD_MS)
        end)
    end)
    if not ok then
        logger.err("kanki: could not open the image viewer:", err)
        UI.warn(_("This image could not be opened."))
        return
    end
    self.image_viewer = viewer
    UIManager:show(viewer)
end

function Reviewer:_buryOrSuspend(which)
    if not self.card then return end
    self.busy = true
    local res, err
    if which == "bury" then
        res, err = Client:bury(self.card.id, self.img_max_px)
    else
        res, err = Client:suspend(self.card.id, self.img_max_px)
    end
    self.busy = false
    if not res then
        return self:_handleError(err)
    end
    self:applyNext(res)
    UI.notify(which == "bury" and _("Card buried.") or _("Card suspended."))
end

--- Set the current card's flag (0 clears, 1-7 = Anki's flag colours).
function Reviewer:setFlag(flag)
    local card = self.card
    if not card or self.busy then return end
    self.busy = true
    local res, err = Client:flag(card.id, flag)
    self.busy = false
    if not res then
        return self:_handleError(err)
    end
    if self.card == card then
        card.flag = tonumber(res.flag) or flag
        self:_redrawTopBar()
    end
end

function Reviewer:showFlagDialog()
    local card = self.card
    if not card or not (self.state == "question" or self.state == "answer") then return end
    local current = tonumber(card.flag) or 0
    local colour = Screen:isColorEnabled()
    local dialog
    local function choose(flag)
        UIManager:close(dialog)
        self:setFlag(flag)
    end
    local buttons, row = {}, {}
    for flag = 1, 7 do
        local info = FLAGS[flag]
        table.insert(row, {
            text = info.text,
            background = colour and Blitbuffer.colorFromString(info.tint) or nil,
            checked_func = function() return current == flag end,
            callback = function() choose(flag) end,
        })
        if #row == 2 then
            table.insert(buttons, row)
            row = {}
        end
    end
    table.insert(row, {
        text = _("Remove flag"),
        enabled = current ~= 0,
        callback = function() choose(0) end,
    })
    table.insert(buttons, row)
    dialog = ButtonDialog:new{
        title = _("Flag card"),
        title_align = "center",
        buttons = buttons,
        -- Coloured buttons: like KOReader's own colour pickers, ask for the Kaleido colour waveform.
        colorful = colour,
        dithered = colour or nil,
    }
    UIManager:show(dialog)
end

function Reviewer:_pomodoroMenuRow(close)
    local p = self.pomodoro
    local function item(text, action)
        return {
            text = text,
            callback = function()
                close()
                action(self)
            end,
        }
    end
    if p:state() == "idle" then
        return { item(_("Start focus block"), Reviewer.pomodoroStart) }
    elseif p:state() == "focus" then
        return {
            p:isPaused() and item(_("Resume Pomodoro"), Reviewer.pomodoroResume)
                or item(_("Pause Pomodoro"), Reviewer.pomodoroPause),
            item(_("Skip to break"), Reviewer.pomodoroSkip),
        }
    end
    -- A break we can see the menu over is a pending one (a running break covers the reviewer).
    return {
        item(_("Start break"), Reviewer.pomodoroResume),
        item(_("Skip break"), Reviewer.pomodoroSkip),
    }
end

function Reviewer:showMenu()
    local has_card = self.card ~= nil and (self.state == "question" or self.state == "answer")
    local dialog
    local function close() UIManager:close(dialog) end
    local buttons = {
        {
            {
                text = _("Bury card"),
                enabled = has_card,
                callback = function()
                    close()
                    self:_buryOrSuspend("bury")
                end,
            },
            {
                text = _("Suspend card"),
                enabled = has_card,
                callback = function()
                    close()
                    self:_buryOrSuspend("suspend")
                end,
            },
        },
        {
            {
                text = _("Flag card…"),
                enabled = has_card,
                callback = function()
                    close()
                    self:showFlagDialog()
                end,
            },
        },
    }
    if self:_hasCardImages() then
        table.insert(buttons, {
            {
                text = _("View image"),
                callback = function()
                    close()
                    self:showImages(1)
                end,
            },
        })
    end
    if self.pomodoro then
        table.insert(buttons, self:_pomodoroMenuRow(close))
    end
    table.insert(buttons, {
        {
            text = _("Sync now"),
            callback = function()
                close()
                Sync:start("normal")
            end,
        },
    })
    table.insert(buttons, {
        {
            text = _("Back to decks"),
            callback = function()
                close()
                self:close()
            end,
        },
    })
    dialog = ButtonDialog:new{
        title = self.deck_name,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Reviewer:close()
    if self.closed then return end
    self.closed = true
    Sync:removeListener(self._sync_listener)
    UIManager:close(self, "flashui")
    if self.on_close then
        self.on_close(self.answered)
    end
end

---------------------------------------------------------------------------------------------------
-- Study timer, Pomodoro and their (only) two tasks: the minute tick and the phase end.

function Reviewer:_studySeconds(now)
    return self.study_acc + (self.study_started and (now - self.study_started) or 0)
end

--- Run the session clock exactly when it should: session open, device awake, not on a break.
function Reviewer:_updateStudyClock(now)
    local run = self._session_started and not self._session_ended
        and not self.suspended and not self.break_screen
    if run and not self.study_started then
        self.study_started = now
    elseif not run and self.study_started then
        self.study_acc = self.study_acc + (now - self.study_started)
        self.study_started = nil
    end
end

--- Move study time and cards answered since the last checkpoint into Tracking (memory only).
function Reviewer:_checkpointTracking(now, extra)
    if not self._session_started then return end
    local study = math.floor(self:_studySeconds(now))
    local fields = extra or {}
    fields.study_s = study - (self._recorded_s or 0)
    fields.cards = self.answered - (self._recorded_cards or 0)
    self._recorded_s, self._recorded_cards = study, self.answered
    if extra or fields.study_s ~= 0 or fields.cards ~= 0 then
        Tracking:add(fields)
    end
end

function Reviewer:_startSession()
    if self._session_started then return end
    self._session_started = true
    local now = self.clock()
    self:_updateStudyClock(now)
    if self.pomodoro and Settings:get("pomodoro_autostart") then
        self.pomodoro:start(now)
    end
    self:_buildTopBar()
    self:_reschedule()
end

function Reviewer:_endSession()
    if not self._session_started or self._session_ended then return end
    local now = self.clock()
    self._session_ended = true
    self:_updateStudyClock(now)
    self:_checkpointTracking(now, { sessions = 1 })
    Tracking:flush()
end

--- Something on screen depends on the time: the break countdown, the study timer, a running Pomodoro.
function Reviewer:_needsTick()
    if self.break_screen then return true end
    if Settings:get("show_session_timer") then return true end
    return self.pomodoro ~= nil and self.pomodoro:isRunning()
end

--- 1 s past the next wall-clock minute (as ReaderFooter does for its clock: 61 - seconds).
function Reviewer:_secondsToNextMinute()
    return 61 - math.floor(self.wallClock()) % 60
end

--- (Re)schedule our tasks for the current state: none while hidden, asleep or closed.
function Reviewer:_reschedule()
    UIManager:unschedule(self._tick_fn)
    UIManager:unschedule(self._phase_fn)
    if self.closed or self.suspended or not self.shown then return end
    local due = self.pomodoro and self.pomodoro:dueIn(self.clock())
    if due then
        UIManager:scheduleIn(due + self.PHASE_SLACK_S, self._phase_fn)
    end
    if self:_needsTick() then
        UIManager:scheduleIn(self:_secondsToNextMinute(), self._tick_fn)
    end
end

function Reviewer:_onTick()
    if self.closed or self.suspended then return end
    local now = self.clock()
    self:_checkpointTracking(now)
    -- (While a lock screen is still up, see onSuspend, paint nothing: its close repaints us.)
    if not Device.screen_saver_mode then
        if self.break_screen then
            self.break_screen:setRemaining(self.pomodoro and self.pomodoro:remaining(now) or 0)
        else
            self:_redrawTopBar()
        end
    end
    self:_reschedule()
end

function Reviewer:_onPhaseDue()
    if self.closed or self.suspended or not self.pomodoro then return end
    if Device.screen_saver_mode then
        -- Lock screen still up (see onSuspend): no dialog or break screen over it. Look again later.
        UIManager:unschedule(self._phase_fn)
        UIManager:scheduleIn(self.LOCKED_RETRY_S, self._phase_fn)
        return
    end
    local ev = self.pomodoro:update(self.clock())
    if not ev then
        return self:_reschedule() -- woke up a hair early
    end
    self:_afterPomodoroChange()
    if ev.kind == "focus_done" then
        self:_askForBreak(ev)
    elseif ev.kind == "break_done" then
        UI.notify(ev.next == "focus" and _("Break over: next focus block started.")
            or _("Break over: back to the cards!"))
    end
end

--- Bring screen, session clock and tasks in line with the Pomodoro's state.
function Reviewer:_afterPomodoroChange()
    if self.closed then return end
    local now = self.clock()
    local p = self.pomodoro
    local on_break = p ~= nil and p:isBreak() and not p:isPending()
    if on_break and not self.break_screen then
        self:_showBreakScreen(now)
    elseif not on_break and self.break_screen then
        self:_closeBreakScreen()
    elseif self.break_screen then
        self.break_screen:setRemaining(p:remaining(now))
    end
    self:_updateStudyClock(now)
    self:_redrawTopBar()
    self:_reschedule()
end

function Reviewer:_askForBreak(ev)
    if self.pomo_dialog then
        UIManager:close(self.pomo_dialog)
    end
    self.pomo_dialog = ConfirmBox:new{
        text = T(_("Focus block done: %1 min, %2.\n\nTake a %3-minute break?"),
            math.floor(ev.focus_s / 60 + 0.5), cardsText(ev.cards), math.floor(ev.break_s / 60 + 0.5)),
        ok_text = _("Start break"),
        cancel_text = _("Keep going"),
        -- It pops up by itself: drop taps and key presses already on their way to the card.
        flush_events_on_show = true,
        ok_callback = function()
            self.pomo_dialog = nil
            -- Once the dialog is gone, so the break screen isn't painted under it first.
            UIManager:nextTick(function() self:_takeBreak() end)
        end,
        cancel_callback = function() -- "Keep going", tap outside, Back
            self.pomo_dialog = nil
            if self.closed or not self.pomodoro then return end
            self.pomodoro:skip(self.clock())
            self:_afterPomodoroChange()
        end,
    }
    UIManager:show(self.pomo_dialog)
end

function Reviewer:_takeBreak()
    if self.closed or self.suspended or not self.pomodoro then return end
    if self.pomodoro:startBreak(self.clock()) then
        self:_afterPomodoroChange()
    end
end

function Reviewer:_showBreakScreen(now)
    local p = self.pomodoro
    local today = Tracking:day().pomodoros
    local info
    if today == 1 then
        info = _("1 focus block today")
    elseif today > 1 then
        info = T(_("%1 focus blocks today"), today)
    end
    self.break_screen = BreakScreen:new{
        kind = p:state(),
        remaining_s = p:remaining(now),
        info_text = info,
        on_skip = function() self:pomodoroSkip() end,
        on_rotate = function(mode) return self:rotate(mode) end,
        on_close = function(screen)
            if self.break_screen == screen then
                self.break_screen = nil
                if not self.closed then self:_updateStudyClock(self.clock()) end
            end
        end,
    }
    UIManager:show(self.break_screen, "flashui")
end

function Reviewer:_closeBreakScreen()
    local screen = self.break_screen
    if not screen then return end
    self.break_screen = nil
    UIManager:close(screen, "flashui")
    -- Like after any new screen: a page key pressed twice to skip mustn't reach the card.
    self.ready_at = time.now() + time.ms(self.GUARD_MS)
end

-- Menu actions (also used by the break screen and the "take a break?" dialog).

function Reviewer:pomodoroStart()
    local p = self.pomodoro
    if p and p:start(self.clock()) then
        self:_afterPomodoroChange()
    end
end

function Reviewer:pomodoroPause()
    local p = self.pomodoro
    if p and p:pause(self.clock()) then
        self._pomodoro_slept = nil
        self:_afterPomodoroChange()
    end
end

function Reviewer:pomodoroResume()
    local p = self.pomodoro
    if p and p:resume(self.clock()) then
        self:_afterPomodoroChange()
    end
end

function Reviewer:pomodoroSkip()
    local p = self.pomodoro
    if p and p:skip(self.clock()) then
        self:_afterPomodoroChange()
    end
end

--[[ Sleep. KOReader broadcasts Suspend after the sleep screen is up and Resume after waking. With a
"screensaver delay" (tap / seconds / gesture to exit) the sleep screen widget may still be shown at
Resume; it broadcasts OutOfScreenSaver when it goes away (while still on the stack, hence the
nextTick). A gesture lock *without* a sleep screen widget broadcasts nothing: then we wake at Resume,
but paint nothing and show no dialog while Device.screen_saver_mode says the lock is still up (its
prompt is painted straight into the framebuffer; closing it repaints everything). ]]

local function screensaverWidgetShown()
    local Screensaver = package.loaded["ui/screensaver"]
    return Device.screen_saver_mode and type(Screensaver) == "table" and Screensaver.screensaver_widget ~= nil
end

function Reviewer:onSuspend()
    if self.closed then return end
    if self.suspended then
        self._resumed = nil -- back to sleep from the lock screen
        return
    end
    self.suspended = true
    local now = self.clock()
    self:_updateStudyClock(now)
    if self.pomodoro and self.pomodoro:pause(now) then
        self._pomodoro_slept = true
    end
    self:_checkpointTracking(now)
    Tracking:flush()
    UIManager:unschedule(self._wake_fn)
    self:_reschedule() -- unschedules everything else
end

function Reviewer:onResume()
    if self.closed or not self.suspended then return end
    self._resumed = true
    if not screensaverWidgetShown() then
        UIManager:nextTick(self._wake_fn)
    end
end

function Reviewer:onOutOfScreenSaver()
    if self.closed or not self.suspended or not self._resumed then return end
    UIManager:nextTick(self._wake_fn)
end

function Reviewer:_wake()
    if self.closed or not self.suspended then return end
    self.suspended = false
    self._resumed = nil
    local now = self.clock()
    if self._pomodoro_slept then
        self._pomodoro_slept = nil
        self.pomodoro:resume(now)
    end
    -- Nothing shown changed while asleep (both clocks were stopped), and closing the sleep screen
    -- repaints us: no redraw here.
    self:_updateStudyClock(now)
    self:_reschedule()
end

function Reviewer:_teardown()
    if self._torn_down then return end
    self._torn_down = true
    UIManager:unschedule(self._tick_fn)
    UIManager:unschedule(self._phase_fn)
    UIManager:unschedule(self._wake_fn)
    local viewer = self.image_viewer
    self.image_viewer = nil
    if viewer then UIManager:close(viewer) end
    local dialog = self.pomo_dialog
    self.pomo_dialog = nil
    if dialog then UIManager:close(dialog) end
    local screen = self.break_screen
    self.break_screen = nil
    if screen then UIManager:close(screen) end
    self:_endSession()
end

---------------------------------------------------------------------------------------------------
-- Rotation

--[[--
On the Kobo, the G-sensor's rotation reaches only the topmost widget: Input:handleMiscGyroEv
returns a SetRotationMode event to UIManager:sendEvent (with "lock auto rotation" set, only 180°
flips happen, via Screen:setRotationMode + UIManager:onRotation, which need no relayout). A
full-screen widget that ignores it simply doesn't rotate. KOReader's own full-screen Menus
(History, Collections…) handle it by rotating the FileManager or ReaderUI underneath through their
own handlers, which set the screen's rotation and relayout them, then rebuild themselves
(Menu:onSetRotationMode). We do the same, relayout in place (same card, same side), and send
ScreenResize to the full-screen widgets in between (our deck list: Menu:onScreenResize rebuilds
it). The emulator and Android broadcast SetDimensions + ScreenResize on window resizes instead.
]]
function Reviewer:onSetRotationMode(mode)
    return self:rotate(mode)
end

function Reviewer:_hostUI()
    for _, name in ipairs({ "apps/reader/readerui", "apps/filemanager/filemanager" }) do
        local module = package.loaded[name]
        if type(module) == "table" and module.instance then
            return module.instance
        end
    end
end

function Reviewer:rotate(mode)
    if mode == nil or self.closed then return end
    local old_mode = Screen:getRotationMode()
    if mode == old_mode then return true end
    if bit.band(mode, 1) == bit.band(old_mode, 1) then
        -- 180° flip: same layout everywhere, just repaint the other way up (what Input does itself
        -- when the G-sensor is locked to the current orientation).
        Screen:setRotationMode(mode)
        UIManager:onRotation()
        return true
    end
    local host = self:_hostUI()
    if host then
        -- They only act when the screen isn't in `mode` yet: call them before rotating it ourselves.
        if host.view and host.view.onSetRotationMode then
            host.view:onSetRotationMode(mode)
        elseif host.onSetRotationMode then
            host:onSetRotationMode(mode)
        end
    end
    if Screen:getRotationMode() ~= mode then
        Screen:setRotationMode(mode)
    end
    local size = Screen:getSize()
    local below = false
    for widget in UIManager:topdown_widgets_iter() do
        if widget == self then
            below = true
        elseif below and widget ~= host then
            widget:handleEvent(Event:new("ScreenResize", size))
        end
    end
    -- Break screen first: our forced repaint below then paints both at their new size, once.
    if self.break_screen then
        self.break_screen:relayout()
    end
    self:_relayout()
    return true
end

function Reviewer:onScreenResize()
    if self.closed then return end
    if Screen:getWidth() ~= self.screen_w or Screen:getHeight() ~= self.screen_h then
        self:_relayout()
    end
end
Reviewer.onSetDimensions = Reviewer.onScreenResize

function Reviewer:_relayout()
    local old_img_max = self.img_max_px
    -- Free the old content (MuPDF documents) before building the new tree.
    self.top_slot:setContent(nil)
    self.card_slot:setContent(nil)
    self.bottom_slot:setContent(nil)
    self:_layout()
    if self.card and self.img_max_px ~= old_img_max then
        self:_refetchCard()
    end
    self:_renderState()
    self:_buildTopBar()
    self:_refresh("full")
end

--- The server width-caps images to img_max_px: fetch the current card again for the new width
--- (GET /card, no queue change). On failure the old HTML is kept (CSS caps images at 100% too).
function Reviewer:_refetchCard()
    local card = self.card
    if not (CardHtml.hasImages(card.question) or CardHtml.hasImages(card.answer)) then return end
    self.busy = true
    local res = Client:card(card.id, self.img_max_px)
    self.busy = false
    local body = type(res) == "table" and (type(res.card) == "table" and res.card or res) or nil
    if body and type(body.question) == "string" and type(body.answer) == "string" then
        card.question, card.answer = body.question, body.answer
        if type(body.css) == "string" then
            card.css = body.css
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Sync progress while reviewing (reviews may continue during the media phase).

function Reviewer:_setSyncText(text, force)
    if text == self.sync_text then return end
    local now = os.time()
    if not force and self._sync_text_at and now - self._sync_text_at < self.SYNC_TEXT_MIN_INTERVAL_S then
        return
    end
    self._sync_text_at = now
    self.sync_text = text
    self:_redrawTopBar()
end

function Reviewer:_onSync(event, st)
    if self.closed then return end
    if event == "progress" then
        self:_setSyncText(Sync.describe(st))
    elseif event == "collection_done" then
        self:_setSyncText(Sync.describe(st), true)
        -- The collection may have changed under us: reload unless the user is looking at an answer.
        if self.state ~= "answer" and self.state ~= "loading" and self:_inputReady() then
            self:loadNext()
        end
    elseif event == "done" then
        self:_setSyncText(nil, true)
        if self.state == "done" or self.state == "message" then
            self:loadNext()
        elseif self.state == "question" and self.card then
            -- Media may have just arrived: re-render the current question so images show.
            self:_setCardHtml(self.card.question)
            self:_refresh("ui")
        end
        UI.notify(_("Sync complete."))
    elseif event == "error" or event == "full_sync_required" or event == "cancelled" then
        self:_setSyncText(Sync.describe(st), true)
    end
end

---------------------------------------------------------------------------------------------------
-- Events

function Reviewer:onShow()
    self.shown = true
    self:_startSession()
    UIManager:nextTick(function()
        if not self.closed then
            self:loadNext()
        end
    end)
end

---------------------------------------------------------------------------------------------------
-- Light (frontlight brightness and, on the Libra Colour, warmth)

--- Fraction of the screen width, on each side, where vertical swipes adjust the light.
Reviewer.EDGE_LIGHT_FRACTION = 0.1

function Reviewer:showLightDialog()
    if hasFrontlight() and type(Device.showLightDialog) == "function" then
        Device:showLightDialog()
    end
end

--[[--
A vertical swipe that starts in the left strip changes brightness, in the right strip warmth, using
KOReader's own DeviceListener logic (gesture-length scaling, "Frontlight intensity set to N" toast).
Only below the top bar, so its buttons keep working; never a tap, so cards still flip and rate.
@treturn bool true when the swipe was used
]]
function Reviewer:_edgeLightSwipe(ges)
    if type(ges) ~= "table" or ges.ges ~= "swipe" or not ges.pos then return false end
    if ges.direction ~= "north" and ges.direction ~= "south" then return false end
    if not Settings:get("edge_swipe_light") or not hasFrontlight() then return false end
    if ges.pos.y < (self.top_h or 0) then return false end
    local strip = math.floor((self.screen_w or Screen:getWidth()) * self.EDGE_LIGHT_FRACTION)
    local direction = ges.direction == "north" and 1 or -1
    local ok, DeviceListener = pcall(require, "device/devicelistener")
    if not ok then return false end
    if ges.pos.x <= strip and type(DeviceListener.onChangeFlIntensity) == "function" then
        DeviceListener:onChangeFlIntensity(ges, direction)
        return true
    end
    if ges.pos.x >= (self.screen_w or Screen:getWidth()) - strip
            and type(Device.hasNaturalLight) == "function" and Device:hasNaturalLight()
            and type(DeviceListener.onChangeFlWarmth) == "function" then
        DeviceListener:onChangeFlWarmth(ges, direction)
        return true
    end
    return false
end

--- KOReader hands gestures to child widgets first (the card's scroller would take the swipe), so
--- edge swipes are caught here, before the normal dispatch.
function Reviewer:handleEvent(event)
    if event.handler == "onGesture" and event.args and self:_edgeLightSwipe(event.args[1]) then
        return true
    end
    return InputContainer.handleEvent(self, event)
end

function Reviewer:onKankiTapCard()
    if self.state == "question" then
        if self:_inputReady() then
            self:showAnswer()
        end
        return true
    end
    -- Answer side: a tap on the card never rates.
    return true
end

function Reviewer:_pageKey(forward)
    if not self:_inputReady() then return end
    if self.state == "question" then
        self:showAnswer()
    elseif self.state == "answer" then
        -- Default: forward = Good (3), back = Again (1); swapped if the setting says so.
        local good = (forward ~= (Settings:get("swap_page_keys") and true or false))
        self:rate(good and 3 or 1)
    end
end

function Reviewer:onKankiPageFwd()
    self:_pageKey(true)
    return true
end

function Reviewer:onKankiPageBack()
    self:_pageKey(false)
    return true
end

function Reviewer:onKankiBack()
    self:close()
    return true
end

-- Holding a page key must never rate several cards.
function Reviewer:onKeyRepeat()
    return true
end

function Reviewer:onExit()
    -- KOReader is quitting (Exit), or powering off / rebooting / entering USB mass storage
    -- (broadcast Close): get off the window stack so UIManager can actually exit.
    if not self.closed then
        self.closed = true
        Sync:removeListener(self._sync_listener)
        UIManager:close(self)
    end
end
Reviewer.onClose = Reviewer.onExit

function Reviewer:onCloseWidget()
    self.closed = true
    Sync:removeListener(self._sync_listener)
    -- Stops our tasks, closes the break screen / dialog, records the session in Tracking.
    self:_teardown()
    if self.on_detach then
        self.on_detach()
    end
end

return Reviewer

--[[--
Today's statistics as ONE static full-screen widget (no timers), reading first:

* Reading (Kobo + KOReader), the lead: the current book (cover, title, author, progress, where and
  when it was last read), pages and time today and over the last 7 days, minutes read per day over
  14 days, and a second book still in progress on one line.
* Anki (cached GET /stats), compact: cards answered, time, % correct, streak, due tomorrow; a smaller
  14-day chart when there is room for it.
* Study on this Kobo, one line: study time, focus time, Pomodoros.

Two ways to use it:
* `StatsView:new{ data = Stats:collect(), sleep = true, footer_text = "…" }` builds the content
  widget for KOReader's sleep screen: no input handling at all (ScreenSaverWidget handles input).
* `StatsView.show()` opens it in-app as a full-screen view that closes on tap, Back or a page key.

Layout, from the current Screen size: portrait = one column (reading about the top half, Anki about a
third, study one line); landscape = reading on the left, Anki and study on the right. When the page
doesn't fit, the Anki chart goes first, then the fonts shrink; free height goes to the charts, and
when much of the screen would stay empty everything grows a little.

Cover: the current book's cover comes pre-scaled from kanki/readingstats' cover cache (normally a
small file read, no image decoding); it is scaled to its box at first paint, converted to grey when
colour rendering is off, and freed with the widget. Without a cover the book is laid out text-only.

Colour: on the Kaleido screen colours go only into solid marks (section chips, chart bars, Pomodoro
dots, progress fills, a low battery) and the cover, never into text: colour text is blurry on the
150 ppi colour layer, and KOReader's TextWidget renders text in grey levels anyway. With colour
rendering disabled the grey palette is used. The widget is flagged `dithered`, which makes KOReader
refresh it with the Kaleido colour waveforms (GCC16 for "full", GLRC16 for "partial").

Everything tunable is in LAYOUT and PALETTES just below.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

---------------------------------------------------------------------------------------------------
-- Tunables. Font sizes are KOReader font units and spacings are "scaleBySize" units: both are
-- multiplied by Screen:scaleBySize() (x2.1 on the 1264x1680 Libra Colour), so 10 units ~ 21 px.

local LAYOUT = {
    font_face = "cfont",       -- KOReader's UI sans (Noto Sans); bold uses its real bold variant
    -- header
    font_date = 18,            -- date (bold)
    font_clock = 18,           -- time (bold)
    font_battery = 14,         -- battery percentage
    -- sections
    font_section = 12,         -- section titles (bold, upper case)
    font_note = 11,            -- right-hand note on a section title ("as of 14:30")
    font_label = 12,           -- tile labels, chart captions
    font_placeholder = 13,
    font_footer = 12,
    -- reading
    font_title = 26,           -- current book title (bold), up to title_lines lines
    title_lines = 3,
    title_leading = 0.86,      -- line step / line height for the title
    font_author = 16,
    font_percent = 36,         -- current book progress ("65%")
    font_percent_unit = 18,
    font_book_meta = 12,       -- "Kobo · last read 14:30"
    font_read_value = 30,      -- pages and time, today and last 7 days
    font_read_unit = 15,
    font_detail = 11,          -- where it was read (Kobo / KOReader)
    font_book2 = 15,           -- second book (bold)
    font_book2_meta = 12,
    -- anki
    font_hero = 34,            -- cards answered today (smaller than the reading numbers' block)
    font_hero_label = 13,
    font_value = 22,           -- tile numbers
    font_unit = 13,            -- tile units ("min", "%", "days")
    -- study line
    font_study_value = 19,
    font_study_unit = 13,
    -- charts
    font_chart = 10,           -- day labels
    font_chart_value = 11,     -- values on bar caps

    margin = 14,               -- around the screen
    gutter = 14,               -- between columns, tiles
    header_gap = 6,            -- header text to its rule
    rule_heavy = 2,            -- rule under the header
    rule_hair = 1,             -- chart baselines, column divider, cover outline
    section_gap = 12,          -- minimum space between sections (grows to fill the screen)
    section_gap_max = 30,
    title_gap = 7,             -- section title to its content
    tile_row_gap = 8,          -- between rows of tiles
    unit_gap = 2,              -- number to unit
    sep_gap = 6,               -- around "·" between two values
    block_gap = 10,            -- between blocks inside a section
    book_gap = 8,              -- author to progress
    meta_gap = 5,              -- progress bar to "Kobo · last read …"
    cover_ratio = 0.30,        -- cover column / reading width (keep <= 0.30: the cached covers are
                               -- pre-scaled for that, see kanki/readingstats coverMaxSize)
    cover_max_aspect = 1.6,    -- tallest cover box: height / width
    cover_gap = 18,            -- cover to the text beside it
    inline_numbers_min = 330,  -- text column width from which today / 7 days sit beside the cover
    meter_book = 9,            -- current book progress bar (thick)
    meter_book2 = 4,           -- second book progress bar (thin)
    read_chart_height = 46,    -- reading chart bar area (grows into free space, up to _grow_max x)
    read_chart_grow_max = 1.8,
    anki_chart_height = 30,    -- Anki chart bar area (dropped first when the page doesn't fit)
    anki_chart_grow_max = 2.4, -- portrait: stays below the reading chart
    anki_chart_grow_max_landscape = 3.6, -- landscape: fills the right-hand column
    chart_bar_ratio = 0.56,    -- bar width / day slot width
    chart_radius = 3,          -- rounded bar tops (bars are square at the baseline)
    chart_gap = 4,             -- caption to bars, bars to day labels
    chip = 9,                  -- section colour chip (square, rounded)
    dot_radius = 6,            -- Pomodoro dots
    dot_gap = 4,
    battery_w = 21,
    battery_h = 11,
    hero_ratio = 0.24,         -- Anki, wide: share of the width for the big number
    wide_min = 430,            -- content width from which the big number sits beside the tiles
    tile_min = 80,             -- narrowest Anki tile (4 in a row when they fit, else 2)
    landscape_min_width = 700, -- two columns when the screen is wider than tall and at least this wide
    landscape_left = 0.56,     -- landscape: share of the width for reading
    min_scale = 0.6,           -- never shrink fonts below 60 % to fit
    max_scale = 1.15,          -- grow fonts up to this when a lot of the screen would stay empty
    grow_below = 0.82,         -- ... i.e. when the content uses less than this share of the height
}

local function rgb(hex) return Blitbuffer.colorFromString(hex) end

-- Kaleido 3 shows saturated mid-tones best; pale tints fade to grey (which suits past days: today
-- stands out). Same hues as KOReader's own highlight colours, which were picked for these screens.
local PALETTES = {
    color = {
        paper = Blitbuffer.COLOR_WHITE,
        ink = Blitbuffer.COLOR_BLACK,
        ink2 = Blitbuffer.COLOR_GRAY_3,      -- secondary text (units, details)
        muted = Blitbuffer.COLOR_GRAY_5,     -- labels, captions, footer
        rule = Blitbuffer.COLOR_GRAY_9,      -- hairlines, cover outline
        track = Blitbuffer.COLOR_LIGHT_GRAY, -- progress bar track, empty Pomodoro ring
        bar = Blitbuffer.COLOR_DARK_GRAY,    -- Anki chart, past days (today is the accent); 3.5:1 on white
        anki = rgb("#0066FF"),               -- blue
        study = rgb("#FF3300"),              -- tomato red (Pomodoro)
        reading = rgb("#00AA66"),            -- green: chip, progress, today's reading
        reading_past = rgb("#7FCFA8"),       -- reading chart, past days
        low = rgb("#FF3300"),                -- battery <= LOW_BATTERY
    },
    grey = {
        paper = Blitbuffer.COLOR_WHITE,
        ink = Blitbuffer.COLOR_BLACK,
        ink2 = Blitbuffer.COLOR_GRAY_3,
        muted = Blitbuffer.COLOR_GRAY_5,
        rule = Blitbuffer.COLOR_GRAY_9,
        track = Blitbuffer.COLOR_LIGHT_GRAY,
        bar = Blitbuffer.COLOR_DARK_GRAY,
        anki = Blitbuffer.COLOR_BLACK,
        study = Blitbuffer.COLOR_BLACK,
        reading = Blitbuffer.COLOR_GRAY_3,
        reading_past = Blitbuffer.COLOR_DARK_GRAY,
        low = Blitbuffer.COLOR_BLACK,
    },
}

local LOW_BATTERY = 15

---------------------------------------------------------------------------------------------------
-- Formatting

local function num(v)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

local function int(n)
    return tostring(math.floor((num(n) or 0) + 0.5))
end

local function minutesOf(s)
    return math.floor((num(s) or 0) / 60 + 0.5)
end

--- A value as runs of { text, kind } where kind "num" is drawn big and bold, "unit" small.
local function durationParts(s)
    local m = minutesOf(s)
    if m < 60 then
        return { { tostring(m), "num" }, { _("min"), "unit" } }
    end
    return { { tostring(math.floor(m / 60)), "num" }, { _("h"), "unit" },
             { string.format("%02d", m % 60), "num" }, { _("min"), "unit" } }
end

local function durationText(s)
    local m = minutesOf(s)
    if m < 60 then return T(_("%1 min"), m) end
    return T(_("%1 h %2 min"), math.floor(m / 60), string.format("%02d", m % 60))
end

local function percentParts(ratio)
    ratio = num(ratio)
    if not ratio then return { { "–", "num" } } end
    return { { tostring(math.floor(ratio * 100 + 0.5)), "num" }, { "%", "unit", tight = true } }
end

local function countParts(n, singular, plural)
    n = num(n)
    if not n then return { { "–", "num" } } end
    n = math.floor(n + 0.5)
    local parts = { { tostring(n), "num" } }
    if singular then table.insert(parts, { n == 1 and singular or plural, "unit" }) end
    return parts
end

--- "34 pages · 41 min"
local function pagesParts(pages, s)
    local p = math.floor(num(pages) or 0)
    local parts = { { tostring(p), "num" }, { p == 1 and _("page") or _("pages"), "unit" },
                    { "·", "sep" } }
    for _, part in ipairs(durationParts(s)) do table.insert(parts, part) end
    return parts
end

local function sourceName(source)
    return source == "kobo" and _("Kobo") or _("KOReader")
end

local function loadDatetime()
    local ok, datetime = pcall(require, "datetime")
    return ok and type(datetime) == "table" and datetime or nil
end

local function twelveHour()
    return G_reader_settings ~= nil and type(G_reader_settings.isTrue) == "function"
        and G_reader_settings:isTrue("twelve_hour_clock") or false
end

local function clockText(t)
    local datetime = loadDatetime()
    if datetime and datetime.secondsToHour then
        local ok, s = pcall(datetime.secondsToHour, t, twelveHour())
        if ok and s then return s end
    end
    return os.date("%H:%M", t)
end

local function dateText(t)
    local datetime = loadDatetime()
    local wday, month = os.date("%a", t), os.date("%B", t)
    local day = tostring(tonumber(os.date("%d", t)))
    if datetime then
        wday = (datetime.shortDayOfWeekToLongTranslation or {})[wday] or os.date("%A", t)
        month = (datetime.longMonthTranslation or {})[month] or month
    else
        wday = os.date("%A", t)
    end
    -- @translators %1 weekday, %2 day of the month, %3 month name
    return T(_("%1 %2 %3"), wday, day, month)
end

--- "14:30" today, "Sat 22:10" within a week, "2026-10-20" before.
local function whenText(t, now)
    if not t then return nil end
    if os.date("%Y-%m-%d", t) == os.date("%Y-%m-%d", now) then
        return clockText(t)
    elseif now - t < 6 * 86400 then
        local datetime = loadDatetime()
        local wday = os.date("%a", t)
        wday = datetime and (datetime.shortDayOfWeekTranslation or {})[wday] or wday
        return wday .. " " .. clockText(t)
    end
    return os.date("%Y-%m-%d", t)
end

---------------------------------------------------------------------------------------------------
-- Painting primitives (colour-aware: Color8 grey levels or ColorRGB32)

local function isColor8(c)
    if type(Blitbuffer.isColor8) == "function" then return Blitbuffer.isColor8(c) end
    return true
end

local function fill(bb, x, y, w, h, color, radius)
    if not color or w <= 0 or h <= 0 then return end
    if radius and radius > 0 then
        if isColor8(color) then
            bb:paintRoundedRect(x, y, w, h, color, radius)
        else
            bb:paintRoundedRectRGB32(x, y, w, h, color, radius)
        end
    elseif isColor8(color) then
        bb:paintRect(x, y, w, h, color)
    else
        bb:paintRectRGB32(x, y, w, h, color)
    end
end

--- Chart bar: rounded data end, square at the baseline.
local function paintBar(bb, x, y, w, h, color, radius)
    if w <= 0 or h <= 0 then return end
    radius = math.min(radius or 0, math.floor(w / 2))
    if radius <= 0 or h <= 2 * radius then
        fill(bb, x, y, w, h, color)
        return
    end
    fill(bb, x, y, w, 2 * radius, color, radius)
    fill(bb, x, y + radius, w, h - radius, color)
end

local function paintBattery(bb, x, y, w, h, level, outline, fill_color)
    local t = math.max(1, math.floor(h / 8))
    local nub = math.max(2, math.floor(w / 10))
    local body = w - nub
    bb:paintBorder(x, y, body, h, t, outline)
    local nub_h = math.max(2, math.floor(h / 2))
    fill(bb, x + body, y + math.floor((h - nub_h) / 2), nub, nub_h, outline)
    local inner_w = body - 4 * t
    local fw = math.floor(inner_w * math.max(0, math.min(100, level or 0)) / 100 + 0.5)
    fill(bb, x + 2 * t, y + 2 * t, fw, h - 4 * t, fill_color)
end

--[[--
An image: img = { src = blitbuffer, w, h, grey = bool, border = Color8 or nil }. The bitmap actually
blitted (src scaled to w x h, grey when asked) is made once, at the first paint, and kept in
img.ready until the page is freed; src itself belongs to the StatsView.
]]
local function readyImage(img)
    if img.ready == nil then
        local ok, res = pcall(function()
            local out = img.src
            if out:getWidth() ~= img.w or out:getHeight() ~= img.h then
                out = require("ui/renderimage"):scaleBlitBuffer(img.src, img.w, img.h, false)
            end
            if img.grey and out:getType() ~= Blitbuffer.TYPE_BB8 then
                local g = Blitbuffer.new(img.w, img.h, Blitbuffer.TYPE_BB8)
                g:blitFrom(out, 0, 0, 0, 0, img.w, img.h)
                if out ~= img.src then out:free() end
                out = g
            end
            return out
        end)
        if not ok then logger.warn("kanki statsview: preparing the cover failed:", res) end
        img.ready = ok and res or false
    end
    return img.ready or nil
end

local function paintImage(bb, x, y, img)
    local pic = readyImage(img)
    if not pic then return end
    -- as KOReader's ImageWidget does
    if Screen.sw_dithering then
        bb:ditherblitFrom(pic, x, y, 0, 0, img.w, img.h)
    else
        bb:blitFrom(pic, x, y, 0, 0, img.w, img.h)
    end
    if img.border then
        bb:paintBorder(x, y, img.w, img.h, img.border_w or 1, img.border)
    end
end

local function freeImage(img)
    if img.ready and img.ready ~= img.src then
        pcall(img.ready.free, img.ready)
    end
    img.ready = nil
end

---------------------------------------------------------------------------------------------------
-- Block: things to paint at block-relative positions. Blocks nest; sizes are known up front.

local Block = {}
Block.__index = Block

function Block.new(w)
    return setmetatable({ w = w, h = 0, ops = {} }, Block)
end

function Block:_grow(bottom)
    if bottom > self.h then self.h = bottom end
end

function Block:widget(wg, x, y)
    table.insert(self.ops, { "widget", wg, x, y })
    self:_grow(y + wg:getSize().h)
    return wg
end

function Block:rect(x, y, w, h, color, radius)
    table.insert(self.ops, { "rect", x, y, w, h, color, radius })
    self:_grow(y + h)
end

function Block:bar(x, y, w, h, color, radius)
    table.insert(self.ops, { "bar", x, y, w, h, color, radius })
    self:_grow(y + h)
end

function Block:circle(cx, cy, r, color, line_w)
    table.insert(self.ops, { "circle", cx, cy, r, color, line_w })
    self:_grow(cy + r + 1)
end

function Block:battery(x, y, w, h, level, outline, fill_color)
    table.insert(self.ops, { "battery", x, y, w, h, level, outline, fill_color })
    self:_grow(y + h)
end

function Block:image(img, x, y)
    table.insert(self.ops, { "image", img, x, y })
    self:_grow(y + img.h)
end

function Block:block(child, x, y)
    table.insert(self.ops, { "block", child, x, y })
    self:_grow(y + child.h)
    return child
end

function Block:paint(bb, x, y, on_error)
    for _, op in ipairs(self.ops) do
        local kind = op[1]
        local ok, err = pcall(function()
            if kind == "widget" then
                op[2]:paintTo(bb, x + op[3], y + op[4])
            elseif kind == "rect" then
                fill(bb, x + op[2], y + op[3], op[4], op[5], op[6], op[7])
            elseif kind == "bar" then
                paintBar(bb, x + op[2], y + op[3], op[4], op[5], op[6], op[7])
            elseif kind == "circle" then
                bb:paintCircle(x + op[2], y + op[3], op[4], op[5], op[6])
            elseif kind == "battery" then
                paintBattery(bb, x + op[2], y + op[3], op[4], op[5], op[6], op[7], op[8])
            elseif kind == "image" then
                paintImage(bb, x + op[3], y + op[4], op[2])
            elseif kind == "block" then
                op[2]:paint(bb, x + op[3], y + op[4], on_error)
            end
        end)
        if not ok and on_error then on_error(kind, err) end
    end
end

function Block:free()
    for _, op in ipairs(self.ops) do
        if op[1] == "widget" and op[2].free then
            pcall(op[2].free, op[2])
        elseif op[1] == "image" then
            freeImage(op[2])
        elseif op[1] == "block" then
            op[2]:free()
        end
    end
    self.ops = {}
end

--- The widget that paints a laid-out page (full screen). (A WidgetContainer without children.)
local Canvas = WidgetContainer:extend{
    width = nil,
    height = nil,
    background = nil,
    root = nil,     -- Block
}

function Canvas:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function Canvas:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local reported = false
    local function onError(kind, err)
        if not reported then
            reported = true
            logger.warn("kanki statsview: painting", kind, "failed:", err)
        end
    end
    local ok, err = pcall(function()
        fill(bb, x, y, self.width, self.height, self.background or Blitbuffer.COLOR_WHITE)
        if self.root then self.root:paint(bb, x, y, onError) end
    end)
    if not ok then onError("page", err) end
end

function Canvas:free()
    if self.root then self.root:free() end
end

---------------------------------------------------------------------------------------------------
-- Builder: lays the page out for one width/height/scale.

local Builder = {}
Builder.__index = Builder

function Builder.new(opts)
    local b = setmetatable({}, Builder)
    b.data = opts.data or {}
    b.pal = opts.palette
    b.grey = opts.palette == PALETTES.grey
    b.scale = opts.scale or 1
    b.width, b.height = opts.width, opts.height
    b.footer_text = opts.footer_text
    b.cover = opts.cover            -- { bb, w, h } of the current book's cover, or nil
    b.anki_chart = true             -- false once dropped to make the page fit
    b.now = num(b.data.now) or os.time()
    return b
end

function Builder:px(units)
    return math.max(1, math.floor(Screen:scaleBySize(units) * self.scale + 0.5))
end

function Builder:fs(size)
    return math.max(6, math.floor(size * self.scale + 0.5))
end

--- TextWidget at an effective font size (already scaled).
function Builder:textAt(text, eff_size, opts)
    opts = opts or {}
    return TextWidget:new{
        text = text,
        face = Font:getFace(LAYOUT.font_face, math.max(6, eff_size)),
        bold = opts.bold or false,
        fgcolor = opts.color or self.pal.ink,
        max_width = opts.max_width,
        padding = 0,
    }
end

--- TextWidget at a LAYOUT font size (scaled by the current page scale).
function Builder:text(text, size, opts)
    return self:textAt(text, self:fs(size), opts)
end

local function freeRun(r)
    for _, it in ipairs(r.items) do it[1]:free() end
end

--[[--
A run of text pieces on one baseline: parts = { { text, kind }, ... } with kind "num" (value font,
bold), "unit" (unit font, secondary ink; `tight = true`: no space before it, e.g. "%"), "sep" (a
separator with room on both sides) or "text"; or { text = , size = , bold = , color = }.
Shrinks the whole run (down to 60 %) when it is wider than max_w, or uses `shrink` as given.
Returns the run (r.shrink = the factor used).
]]
function Builder:run(parts, sizes, max_w, shrink)
    sizes = sizes or {}
    local function make(factor)
        -- factor < 1: every piece one font size step smaller at least (sizes are whole numbers)
        local r = { items = {}, w = 0, base = 0, below = 0, shrink = factor }
        local gap = self:px(LAYOUT.unit_gap * factor)
        local sep_gap = self:px(LAYOUT.sep_gap * factor)
        local prev_sep = false
        for i, p in ipairs(parts) do
            local text, size, bold, color
            local kind = p[2]
            if p.text then
                text, size, bold, color = p.text, p.size, p.bold, p.color
            elseif kind == "num" then
                text, size, bold, color = p[1], sizes.num or LAYOUT.font_value, true, self.pal.ink
            elseif kind == "unit" or kind == "sep" then
                text, size, bold, color = p[1], sizes.unit or LAYOUT.font_unit, false, self.pal.ink2
            else
                text, size, bold, color = p[1], sizes.text or sizes.unit or LAYOUT.font_unit, false, self.pal.muted
            end
            local eff = self:fs(size)
            if factor < 1 then eff = math.min(eff - 1, math.floor(eff * factor)) end
            local tw = self:textAt(text, eff, { bold = bold, color = color })
            local sz = tw:getSize()
            local asc = tw:getBaseline()
            local space = 0
            if i > 1 and not p.tight then
                space = (kind == "sep" or prev_sep) and sep_gap or gap
            end
            local x = r.w + space
            table.insert(r.items, { tw, x, asc })
            r.w = x + sz.w
            r.base = math.max(r.base, asc)
            r.below = math.max(r.below, sz.h - asc)
            prev_sep = (kind == "sep")
        end
        r.h = r.base + r.below
        return r
    end
    if shrink then return make(shrink) end
    local r = make(1)
    local factor = 1
    while max_w and r.w > max_w and r.w > 0 and factor > 0.6 do
        factor = math.max(0.6, math.min(factor * 0.95, factor * max_w / r.w))
        freeRun(r)
        r = make(factor)
    end
    return r
end

--- A text that shrinks (down to 75 %) to fit max_w, and is truncated with an ellipsis below that.
function Builder:fitText(text, size, opts, max_w)
    opts = opts or {}
    local eff = self:fs(size)
    local tw = self:textAt(text, eff, opts)
    if not max_w or tw:getSize().w <= max_w then return tw end
    local min_eff = math.max(6, math.floor(eff * 0.75))
    while tw:getSize().w > max_w and eff > min_eff do
        eff = math.max(min_eff, math.min(eff - 1, math.floor(eff * max_w / tw:getSize().w)))
        tw:free()
        tw = self:textAt(text, eff, opts)
    end
    if tw:getSize().w > max_w then
        tw:free()
        local o = {}
        for k, v in pairs(opts) do o[k] = v end
        o.max_width = max_w
        tw = self:textAt(text, eff, o)
    end
    return tw
end

--[[--
Word-wrapped text: at most max_lines lines no wider than max_w. The font shrinks (down to 80 %)
before the last line gets truncated with an ellipsis. Returns the line TextWidgets.
]]
function Builder:wrap(text, size, opts, max_w, max_lines)
    opts = opts or {}
    local words = {}
    for word in tostring(text or ""):gmatch("%S+") do table.insert(words, word) end
    if #words == 0 then words[1] = "?" end
    local function widthAt(s, eff)
        local tw = self:textAt(s, eff, opts)
        local w = tw:getSize().w
        tw:free()
        return w
    end
    local function layout(eff)
        local lines, fits, i = {}, true, 1
        while i <= #words do
            if #lines == max_lines - 1 then -- last line: whatever is left
                local rest = table.concat(words, " ", i)
                table.insert(lines, rest)
                return lines, fits and widthAt(rest, eff) <= max_w
            end
            local line, j = words[i], i + 1
            while j <= #words do
                local candidate = line .. " " .. words[j]
                if widthAt(candidate, eff) > max_w then break end
                line, j = candidate, j + 1
            end
            if j == i + 1 and widthAt(line, eff) > max_w then fits = false end -- one word too wide
            table.insert(lines, line)
            i = j
        end
        return lines, fits
    end
    local base = self:fs(size)
    local min_eff = math.max(6, math.floor(base * 0.8))
    local eff = base
    local lines, fits = layout(eff)
    while not fits and eff > min_eff do
        eff = math.max(min_eff, eff - math.max(1, math.floor(base * 0.06)))
        lines, fits = layout(eff)
    end
    local out = {}
    for _, s in ipairs(lines) do
        table.insert(out, self:textAt(s, eff, { bold = opts.bold, color = opts.color, max_width = max_w }))
    end
    return out
end

--- Stack text lines (TextWidgets) with a line step of `leading` x their height. Returns the height.
function Builder:placeLines(block, lines, x, y, leading)
    local h = 0
    for i, tw in ipairs(lines) do
        local lh = tw:getSize().h
        local step = math.floor(lh * (leading or 1) + 0.5)
        block:widget(tw, x, y + h)
        h = h + (i < #lines and step or lh)
    end
    return h
end

function Builder:placeRun(block, r, x, y)
    for _, it in ipairs(r.items) do
        block:widget(it[1], x + it[2], y + r.base - it[3])
    end
    block:_grow(y + r.h)
    return r.h
end

--- Single text line, shrunk a little or truncated with an ellipsis to fit opts.max_width.
function Builder:line(block, text, size, x, y, opts)
    opts = opts or {}
    local tw = self:fitText(text, size, { bold = opts.bold, color = opts.color }, opts.max_width)
    block:widget(tw, x, y)
    return tw
end

--- Progress bar: rounded track, fill from the left. Returns the height.
function Builder:meter(block, x, y, w, h, ratio, color)
    local radius = math.floor(h / 2)
    block:rect(x, y, w, h, self.pal.track, radius)
    ratio = num(ratio)
    if ratio and ratio > 0 then
        block:rect(x, y, math.max(h, math.floor(w * math.min(1, ratio) + 0.5)), h, color, radius)
    end
    return h
end

--- Section title: colour chip, upper-case title, optional right-hand note. Returns the height.
function Builder:sectionTitle(block, w, title, color, note)
    local chip = self:px(LAYOUT.chip)
    local tw = self:text(title:upper(), LAYOUT.font_section, { bold = true })
    local asc = tw:getBaseline()
    local cap_mid = asc - math.floor(asc * 0.36 + 0.5)
    block:rect(0, math.max(0, cap_mid - math.floor(chip / 2)), chip, chip, color, math.floor(chip / 4))
    local tx = chip + self:px(5)
    block:widget(tw, tx, 0)
    local h = tw:getSize().h
    if note and note ~= "" then
        local room = w - tx - tw:getSize().w - self:px(LAYOUT.gutter)
        if room > self:px(20) then
            local nw = self:text(note, LAYOUT.font_note, { color = self.pal.muted, max_width = room })
            block:widget(nw, w - nw:getSize().w, asc - nw:getBaseline())
        end
    end
    return h + self:px(LAYOUT.title_gap)
end

--- Stat tile: label above a value run. Returns the height.
function Builder:tile(block, x, y, w, label, parts)
    local lw = self:fitText(label, LAYOUT.font_label, { color = self.pal.muted }, w)
    block:widget(lw, x, y)
    local h = lw:getSize().h
    local r = self:run(parts, nil, w)
    return h + self:placeRun(block, r, x, y + h)
end

function Builder:tileGrid(block, x, y, w, tiles, cols)
    local gutter = self:px(LAYOUT.gutter)
    local tile_w = math.floor((w - (cols - 1) * gutter) / cols)
    local row_h, total = 0, 0
    for i, t in ipairs(tiles) do
        local col = (i - 1) % cols
        if col == 0 and i > 1 then
            total = total + row_h + self:px(LAYOUT.tile_row_gap)
            row_h = 0
        end
        local h = self:tile(block, x + col * (tile_w + gutter), y + total, tile_w, t[1], t[2])
        row_h = math.max(row_h, h)
    end
    return total + row_h
end

function Builder:placeholder(block, y, w, text)
    local tw = self:fitText(text, LAYOUT.font_placeholder, { color = self.pal.muted }, w)
    block:widget(tw, 0, y)
    return tw:getSize().h
end

--[[--
14-day bar chart: caption, bars (rounded tops, square at the baseline), the value of today and of
the busiest other day above their bars, day-of-month labels with "Today" under today's bar.
spec = { caption =, days = { { value =, label =, today = bool }, ... } (oldest first),
         bars_h = px, color = past days, color_today =, fmt = function(value) -> text, empty = text }
Returns the bottom (block coordinates).
]]
function Builder:barChart(block, y, w, spec)
    local pal = self.pal
    local days = spec.days
    local n = #days
    if n == 0 then return y end
    local caption = self:text(spec.caption, LAYOUT.font_label, { color = pal.muted, max_width = w })
    block:widget(caption, 0, y)
    y = y + caption:getSize().h + self:px(LAYOUT.chart_gap)

    -- max_v scales the bars; max_i = the busiest day other than today (its value gets a label too)
    local max_v, max_i, max_other = 0, nil, 0
    for i, d in ipairs(days) do
        local v = num(d.value) or 0
        if v > max_v then max_v = v end
        if not d.today and v > max_other then max_i, max_other = i, v end
    end
    local slot = w / n
    local bar_w = math.max(2, math.floor(slot * LAYOUT.chart_bar_ratio))
    local value_probe = self:text("0", LAYOUT.font_chart_value, { bold = true })
    local value_h = value_probe:getSize().h
    value_probe:free()
    local bars_top = y + value_h
    local bars_h = spec.bars_h
    local baseline = bars_top + bars_h
    local radius = self:px(LAYOUT.chart_radius)

    for i, d in ipairs(days) do
        local v = num(d.value) or 0
        local bx = math.floor((i - 1) * slot + (slot - bar_w) / 2)
        local h = 0
        if v > 0 and max_v > 0 then
            h = math.max(self:px(1), math.floor(v / max_v * bars_h + 0.5))
        end
        if h > 0 then
            block:bar(bx, baseline - h, bar_w, h, d.today and spec.color_today or spec.color, radius)
        end
        -- Selective labels: today's value, and the busiest other day's.
        if (d.today and v > 0) or (i == max_i and v > 0) then
            local vw = self:text(spec.fmt(v), LAYOUT.font_chart_value,
                { bold = d.today, color = d.today and pal.ink or pal.muted })
            local vx = math.floor(bx + bar_w / 2 - vw:getSize().w / 2)
            vx = math.max(0, math.min(w - vw:getSize().w, vx))
            block:widget(vw, vx, baseline - h - value_h)
        end
    end
    if max_v <= 0 and spec.empty then
        local ew = self:text(spec.empty, LAYOUT.font_label, { color = pal.muted, max_width = w })
        block:widget(ew, math.floor((w - ew:getSize().w) / 2), baseline - math.floor(bars_h / 2)
            - math.floor(ew:getSize().h / 2))
    end
    block:rect(0, baseline, w, self:px(LAYOUT.rule_hair), pal.rule)

    -- Day labels: day of the month; "Today" under today. A label that would touch its neighbour is
    -- dropped (today's never is).
    local label_y = baseline + self:px(LAYOUT.rule_hair) + self:px(LAYOUT.chart_gap)
    local min_space = self:px(4)
    local labels = {}
    for i, d in ipairs(days) do
        local text = d.today and _("Today") or (d.label or "")
        local lw = self:text(text, LAYOUT.font_chart, { bold = d.today, color = d.today and pal.ink or pal.muted })
        local lx = math.floor((i - 0.5) * slot - lw:getSize().w / 2)
        lx = math.max(0, math.min(w - lw:getSize().w, lx))
        labels[i] = { widget = lw, x = lx, w = lw:getSize().w, keep = true, today = d.today }
    end
    for i = 1, #labels do
        local l = labels[i]
        if l.today then
            for j = i - 1, 1, -1 do -- clear the room today's label needs on its left
                if labels[j].keep and labels[j].x + labels[j].w + min_space > l.x then
                    labels[j].keep = false
                else
                    break
                end
            end
        else
            local prev
            for j = i - 1, 1, -1 do
                if labels[j].keep then prev = labels[j] break end
            end
            if prev and prev.x + prev.w + min_space > l.x then l.keep = false end
        end
    end
    local bottom = label_y
    for _, l in ipairs(labels) do
        if l.keep then
            block:widget(l.widget, l.x, label_y)
            bottom = math.max(bottom, label_y + l.widget:getSize().h)
        else
            l.widget:free()
        end
    end
    return bottom
end

---------------------------------------------------------------------------------------------------
-- Header and footer

function Builder:header(w)
    local b = Block.new(w)
    local pal = self.pal
    local clock = self:text(clockText(self.now), LAYOUT.font_clock, { bold = true })
    local bat = self.data.battery
    local bat_text
    if type(bat) == "table" and num(bat.level) then
        local s = int(bat.level) .. "%"
        if bat.charging then s = T(_("%1 charging"), s) end
        bat_text = self:text(s, LAYOUT.font_battery, { color = pal.ink2 })
    end
    local gap = self:px(8)
    local bw, bh = self:px(LAYOUT.battery_w), self:px(LAYOUT.battery_h)
    local right_w = clock:getSize().w
    if bat_text then right_w = right_w + gap * 2 + bw + self:px(3) + bat_text:getSize().w end
    local date = self:text(dateText(self.now), LAYOUT.font_date,
        { bold = true, max_width = math.max(self:px(40), w - right_w - gap * 2) })
    local base = math.max(date:getBaseline(), clock:getBaseline(), bat_text and bat_text:getBaseline() or 0)
    b:widget(date, 0, base - date:getBaseline())
    local x = w - right_w
    b:widget(clock, x, base - clock:getBaseline())
    if bat_text then
        x = x + clock:getSize().w + gap * 2
        local level = num(bat.level)
        local cap_mid = base - math.floor(clock:getBaseline() * 0.36 + 0.5)
        b:battery(x, cap_mid - math.floor(bh / 2), bw, bh, level, pal.ink,
            (level <= LOW_BATTERY and not bat.charging) and pal.low or pal.ink)
        x = x + bw + self:px(3)
        b:widget(bat_text, x, base - bat_text:getBaseline())
    end
    local y = b.h + self:px(LAYOUT.header_gap)
    b:rect(0, y, w, self:px(LAYOUT.rule_heavy), pal.ink)
    return b
end

function Builder:footer(w)
    local b = Block.new(w)
    local text = self.footer_text
    if not text or text == "" then return b end
    local tw = self:fitText(text, LAYOUT.font_footer, { color = self.pal.muted }, w)
    b:widget(tw, math.floor((w - tw:getSize().w) / 2), 0)
    return b
end

---------------------------------------------------------------------------------------------------
-- Reading

--- Where a period's reading was done: "Kobo: 30 p. · 35 min" / "KOReader: …" (sources with reading).
function Builder:readingSources(t)
    local lines = {}
    if (num(t.kobo_pages) or 0) > 0 or (num(t.kobo_s) or 0) >= 30 then
        table.insert(lines, T(_("Kobo: %1 · %2"), T(_("%1 p."), int(t.kobo_pages)), durationText(t.kobo_s)))
    end
    if (num(t.koreader_pages) or 0) > 0 or (num(t.koreader_s) or 0) >= 30 then
        table.insert(lines, T(_("KOReader: %1 · %2"), T(_("%1 p."), int(t.koreader_pages)), durationText(t.koreader_s)))
    end
    return lines
end

--- Today and the last 7 days side by side: pages · time in one common size, then where. Returns the height.
function Builder:readingNumbers(block, x, y, w, r)
    local pal = self.pal
    local gutter = self:px(LAYOUT.gutter) * 2
    local col_w = math.floor((w - gutter) / 2)
    local periods = { { _("Today"), r.today }, { _("Last 7 days"), r.week } }
    local sizes = { num = LAYOUT.font_read_value, unit = LAYOUT.font_read_unit }
    local runs, factor = {}, 1
    for i, p in ipairs(periods) do
        runs[i] = self:run(pagesParts(p[2].pages, p[2].s), sizes, col_w)
        factor = math.min(factor, runs[i].shrink)
    end
    for i, p in ipairs(periods) do
        if runs[i].shrink ~= factor then -- both in the same size
            freeRun(runs[i])
            runs[i] = self:run(pagesParts(p[2].pages, p[2].s), sizes, nil, factor)
        end
    end
    local h = 0
    for i, p in ipairs(periods) do
        local cx, cy = x + (i - 1) * (col_w + gutter), y
        local lw = self:fitText(p[1], LAYOUT.font_label, { color = pal.muted }, col_w)
        block:widget(lw, cx, cy)
        cy = cy + lw:getSize().h
        cy = cy + self:placeRun(block, runs[i], cx, cy)
        for _, text in ipairs(self:readingSources(p[2])) do
            local dw = self:fitText(text, LAYOUT.font_detail, { color = pal.muted }, col_w)
            block:widget(dw, cx, cy)
            cy = cy + dw:getSize().h
        end
        h = math.max(h, cy - y)
    end
    return h
end

--[[--
The current book: cover on the left (when there is one), then title (big, bold, up to 3 lines),
author, progress (big percentage, thick bar) and "Kobo · last read 14:30"; today / last 7 days go
beside the cover, bottom-aligned with it, when the text column is wide enough.
@treturn int height, bool whether the numbers were placed
]]
function Builder:currentBook(block, y0, w, book, r)
    local pal = self.pal
    local cover = self.cover
    local x, tw, cover_h = 0, w, 0
    if cover then
        local cw = math.floor(w * LAYOUT.cover_ratio)
        local ch = math.floor(cw * LAYOUT.cover_max_aspect)
        local s = math.min(cw / cover.w, ch / cover.h)
        local bw = math.max(1, math.floor(cover.w * s + 0.5))
        local bh = math.max(1, math.floor(cover.h * s + 0.5))
        block:image({ src = cover.bb, w = bw, h = bh, grey = self.grey, border = pal.rule,
                      border_w = self:px(LAYOUT.rule_hair) }, math.floor((cw - bw) / 2), y0)
        cover_h = bh
        x = cw + self:px(LAYOUT.cover_gap)
        tw = w - x
    end
    local y = y0
    local lines = self:wrap(book.title or "?", LAYOUT.font_title, { bold = true }, tw, LAYOUT.title_lines)
    y = y + self:placeLines(block, lines, x, y, LAYOUT.title_leading)
    if book.author then
        local aw = self:fitText(book.author, LAYOUT.font_author, { color = pal.ink2 }, tw)
        block:widget(aw, x, y)
        y = y + aw:getSize().h
    end
    local pct = num(book.percent)
    if pct then
        y = y + self:px(LAYOUT.book_gap)
        local parts = {
            { text = int(pct * 100), size = LAYOUT.font_percent, bold = true, color = pal.ink },
            { text = "%", size = LAYOUT.font_percent_unit, color = pal.ink2, tight = true },
        }
        if book.finished then
            table.insert(parts, { text = _("finished"), size = LAYOUT.font_percent_unit, color = pal.ink2 })
        end
        local pr = self:run(parts, nil, tw)
        y = y + self:placeRun(block, pr, x, y) + self:px(2)
        y = y + self:meter(block, x, y, tw, self:px(LAYOUT.meter_book), pct, pal.reading)
    end
    local meta = sourceName(book.source)
    local when = whenText(num(book.last_read), self.now)
    if when then meta = T(_("%1 · last read %2"), meta, when) end
    y = y + self:px(LAYOUT.meta_gap)
    local mw = self:fitText(meta, LAYOUT.font_book_meta, { color = pal.muted }, tw)
    block:widget(mw, x, y)
    y = y + mw:getSize().h

    local inline = cover ~= nil and tw >= self:px(LAYOUT.inline_numbers_min)
    if inline then
        local nb = Block.new(tw)
        self:readingNumbers(nb, 0, 0, tw, r)
        local ny = math.max(y + self:px(LAYOUT.block_gap), y0 + cover_h - nb.h)
        block:block(nb, x, ny)
        y = ny + nb.h
    end
    return math.max(y, y0 + cover_h) - y0, inline
end

--- Another book in progress, on one line: title · author · source, percentage; thin bar below.
function Builder:otherBook(block, y, w, book)
    local pal = self.pal
    local pct = num(book.percent)
    local pct_w
    if pct then pct_w = self:text(int(pct * 100) .. "%", LAYOUT.font_book2, { bold = true }) end
    local room = w - (pct_w and (pct_w:getSize().w + self:px(LAYOUT.gutter)) or 0)
    local title = self:text(book.title or "?", LAYOUT.font_book2, { bold = true, max_width = room })
    block:widget(title, 0, y)
    local base = title:getBaseline()
    local sep = self:px(LAYOUT.sep_gap)
    local meta_room = room - title:getSize().w - sep
    if meta_room > self:px(60) then
        local meta = sourceName(book.source)
        if book.author then meta = book.author .. " · " .. meta end
        local mw = self:text("· " .. meta, LAYOUT.font_book2_meta, { color = pal.muted, max_width = meta_room })
        block:widget(mw, title:getSize().w + sep, y + base - mw:getBaseline())
    end
    if pct_w then block:widget(pct_w, w - pct_w:getSize().w, y + base - pct_w:getBaseline()) end
    y = y + title:getSize().h + self:px(3)
    return y + self:meter(block, 0, y, w, self:px(LAYOUT.meter_book2), pct, pal.reading)
end

function Builder:readingChart(block, y, w, days)
    local list = {}
    for i, d in ipairs(type(days) == "table" and days or {}) do
        local date = type(d.date) == "string" and d.date or nil
        list[i] = {
            value = minutesOf(d.s),
            today = num(d.day) == 0,
            label = date and tostring(tonumber(date:sub(9, 10)) or "") or "",
        }
    end
    if #list == 0 then return y end
    return self:barChart(block, y, w, {
        caption = T(_("Minutes read, last %1 days"), #list),
        days = list,
        bars_h = self:px(LAYOUT.read_chart_height) + (self.read_chart_extra or 0),
        color = self.pal.reading_past,
        color_today = self.pal.reading,
        fmt = function(v) return int(v) end,
        empty = _("No reading in the last 14 days"),
    })
end

function Builder:reading(w)
    local b = Block.new(w)
    local pal = self.pal
    local y = self:sectionTitle(b, w, _("Reading"), pal.reading)
    local r = self.data.reading
    if type(r) ~= "table" or type(r.today) ~= "table" or type(r.week) ~= "table" then
        y = y + self:placeholder(b, y, w, _("No reading statistics available."))
        b.h = y
        return b
    end
    local gap = self:px(LAYOUT.block_gap)
    local books = type(r.books) == "table" and r.books or {}
    local numbers_done = false
    if type(books[1]) == "table" then
        local h
        h, numbers_done = self:currentBook(b, y, w, books[1], r)
        y = y + h + gap
    end
    if not numbers_done then
        y = y + self:readingNumbers(b, 0, y, w, r) + gap
    end
    y = self:readingChart(b, y, w, r.days)
    if type(books[2]) == "table" then
        y = self:otherBook(b, y + gap + self:px(4), w, books[2])
    end
    b.h = math.max(b.h, y)
    return b
end

---------------------------------------------------------------------------------------------------
-- Anki

function Builder:ankiTiles(a)
    local today = type(a.today) == "table" and a.today or {}
    local answered = num(today.answered) or 0
    local correct = num(today.correct)
    local rolled = (num(a.rolled_over_days) or 0) > 0
    return {
        { _("Time"), durationParts(today.seconds) },
        { _("Correct"), answered > 0 and correct and percentParts(correct / answered) or { { "–", "num" } } },
        { _("Streak"), countParts(a.streak, _("day"), _("days")) },
        -- after a rollover the cached "due tomorrow" is today's workload
        rolled and { _("Due today"), countParts(a.left_today) } or { _("Due tomorrow"), countParts(a.due_tomorrow) },
    }
end

function Builder:ankiChart(block, y, w, a)
    local list = {}
    for i, d in ipairs(type(a.days) == "table" and a.days or {}) do
        local today = num(d.day) == 0
        local t = num(d.start) and (num(d.start) + 12 * 3600) or (self.now + (num(d.day) or 0) * 86400)
        list[i] = { value = num(d.count) or 0, today = today, label = tostring(tonumber(os.date("%d", t))) }
    end
    if #list == 0 then return y end
    return self:barChart(block, y, w, {
        caption = T(_("Reviews, last %1 days"), #list),
        days = list,
        bars_h = self:px(LAYOUT.anki_chart_height) + (self.anki_chart_extra or 0),
        color = self.pal.bar,
        color_today = self.pal.anki,
        fmt = function(v) return int(v) end,
        empty = _("No reviews in the last 14 days"),
    })
end

function Builder:anki(w)
    local b = Block.new(w)
    local a = self.data.anki
    local pal = self.pal
    local note
    if type(a) == "table" and num(a.as_of) then
        note = T(_("as of %1"), whenText(num(a.as_of), self.now))
    end
    local y = self:sectionTitle(b, w, _("Anki"), pal.anki, note)
    if type(a) ~= "table" then
        y = y + self:placeholder(b, y, w, _("No Anki statistics yet. Open Anki once to load them."))
        b.h = y
        return b
    end

    local today = type(a.today) == "table" and a.today or {}
    local answered = math.floor((num(today.answered) or 0) + 0.5)
    local hero_label = answered == 1 and _("card answered") or _("cards answered")
    local gutter = self:px(LAYOUT.gutter)
    local tiles = self:ankiTiles(a)

    if w >= self:px(LAYOUT.wide_min) then
        local probe = self:text(hero_label, LAYOUT.font_hero_label)
        local hero_w = math.min(math.floor(w * 0.4),
            math.max(math.floor(w * LAYOUT.hero_ratio), probe:getSize().w + gutter))
        probe:free()
        local hero = self:run({ { text = tostring(answered), size = LAYOUT.font_hero, bold = true, color = pal.ink } },
            nil, hero_w)
        self:placeRun(b, hero, 0, y)
        local lbl = self:fitText(hero_label, LAYOUT.font_hero_label, { color = pal.ink2 }, hero_w)
        -- right under the digits (they have no descenders)
        local lbl_y = y + hero.base + self:px(4)
        b:widget(lbl, 0, lbl_y)
        local hero_h = lbl_y - y + lbl:getSize().h
        local area = w - hero_w - gutter
        local cols = (area - 3 * gutter) / 4 >= self:px(LAYOUT.tile_min) and 4 or 2
        local grid_h = self:tileGrid(b, hero_w + gutter, y, area, tiles, cols)
        y = y + math.max(hero_h, grid_h)
    else
        local hero = self:run({
            { text = tostring(answered), size = LAYOUT.font_hero, bold = true, color = pal.ink },
            { text = hero_label, size = LAYOUT.font_hero_label, color = pal.ink2 },
        }, nil, w)
        y = y + self:placeRun(b, hero, 0, y) + self:px(LAYOUT.tile_row_gap)
        y = y + self:tileGrid(b, 0, y, w, tiles, 2)
    end

    if self.anki_chart then
        y = self:ankiChart(b, y + self:px(LAYOUT.block_gap), w, a)
    end
    b.h = math.max(b.h, y)
    return b
end

---------------------------------------------------------------------------------------------------
-- Study on this Kobo (one line: title, study time, focus time, Pomodoros)

function Builder:study(w)
    local b = Block.new(w)
    local pal = self.pal
    local chip = self:px(LAYOUT.chip)
    local title = self:text(_("Study on this Kobo"):upper(), LAYOUT.font_section, { bold = true })
    local title_w = chip + self:px(5) + title:getSize().w
    local gap = self:px(LAYOUT.gutter) * 2
    local radius = self:px(LAYOUT.dot_radius)
    local step = 2 * radius + self:px(LAYOUT.dot_gap)

    local s = self.data.study
    local parts, count
    if type(s) == "table" and type(s.today) == "table" then
        local today = s.today
        count = math.max(0, math.floor(num(today.pomodoros) or 0))
        parts = { { _("Study"), "text" } }
        for _, p in ipairs(durationParts(today.study_s)) do table.insert(parts, p) end
        table.insert(parts, { "·", "sep" })
        table.insert(parts, { _("Focus"), "text" })
        for _, p in ipairs(durationParts(today.focus_s)) do table.insert(parts, p) end
        table.insert(parts, { "·", "sep" })
        table.insert(parts, { tostring(count), "num" })
        table.insert(parts, { count == 1 and _("Pomodoro") or _("Pomodoros"), "unit" })
    else
        parts = { { text = _("No study recorded yet."), size = LAYOUT.font_placeholder, color = pal.muted } }
    end
    local sizes = { num = LAYOUT.font_study_value, unit = LAYOUT.font_study_unit, text = LAYOUT.font_study_unit }
    -- The count is in the text; the dots only decorate: as many as fit after it (room for a few
    -- is kept when deciding whether the values fit beside the title).
    local dots_w = count and (self:px(LAYOUT.dot_gap) * 2 + math.max(1, math.min(count, 3)) * step) or 0
    local r = self:run(parts, sizes)
    local inline = title_w + gap + r.w + dots_w <= w
    if not inline and r.w > w then
        freeRun(r)
        r = self:run(parts, sizes, w)
    end

    -- title (and the values on the same baseline when they fit beside it)
    local tasc = title:getBaseline()
    local base = inline and math.max(tasc, r.base) or tasc
    local ty = base - tasc
    local cap_mid = ty + tasc - math.floor(tasc * 0.36 + 0.5)
    b:rect(0, math.max(0, cap_mid - math.floor(chip / 2)), chip, chip, pal.study, math.floor(chip / 4))
    b:widget(title, chip + self:px(5), ty)
    local rx, ry
    if inline then
        rx, ry = title_w + gap, base - r.base
    else
        rx, ry = 0, ty + title:getSize().h + self:px(LAYOUT.title_gap)
    end
    self:placeRun(b, r, rx, ry)
    if count then
        -- after the values; on the title row when the values are on their own row
        local cy, cx
        if inline then
            cy = ry + r.base - math.floor(r.base * 0.36 + 0.5)
            cx = rx + r.w + self:px(LAYOUT.dot_gap) * 2 + radius
        else
            cy = cap_mid
            cx = title_w + gap + radius
        end
        local fit = math.max(0, math.floor((w - (cx - radius)) / step))
        if count > 0 then
            for i = 1, math.min(count, fit) do
                b:circle(cx + (i - 1) * step, cy, radius, pal.study)
            end
        elseif fit > 0 then
            b:circle(cx, cy, radius, pal.track, math.max(1, math.floor(radius / 3)))
        end
    end
    return b
end

---------------------------------------------------------------------------------------------------
-- Page

--- Stack blocks in a column from y = top, spreading leftover space between them.
local function stack(root, blocks, x, top, avail, min_gap, max_gap)
    local sum = 0
    for _, blk in ipairs(blocks) do sum = sum + blk.h end
    local gap = min_gap
    if #blocks > 1 then
        gap = math.max(min_gap, math.min(max_gap, math.floor((avail - sum) / (#blocks - 1))))
    end
    local y = top
    for i, blk in ipairs(blocks) do
        root:block(blk, x, y)
        y = y + blk.h + (i < #blocks and gap or 0)
    end
    return y - top
end

local function columnHeight(blocks, min_gap)
    local h = 0
    for i, blk in ipairs(blocks) do
        h = h + blk.h + (i > 1 and min_gap or 0)
    end
    return h
end

--- Rebuild blocks[i] with a taller chart (self[field] extra pixels), taking up to `share` of the
--- column's free height and at most (grow_max - 1) x the chart's base height.
function Builder:growChart(blocks, i, build, field, base_units, grow_max, avail, min_gap, share)
    local slack = avail - columnHeight(blocks, min_gap)
    local extra = math.min(math.floor(slack * share), math.floor(self:px(base_units) * (grow_max - 1)))
    if extra <= 0 then return end
    blocks[i]:free()
    self[field] = extra
    blocks[i] = build()
end

--[[--
Lay out the page.
@treturn Block root
@treturn bool fits
@treturn int height the content needs at this scale (before growing the charts into free space)
@treturn int height available for it
]]
function Builder:page()
    local W, H = self.width, self.height
    local m = self:px(LAYOUT.margin)
    local cw = W - 2 * m
    local root = Block.new(W)
    local header = self:header(cw)
    local footer = self:footer(cw)
    local min_gap, max_gap = self:px(LAYOUT.section_gap), self:px(LAYOUT.section_gap_max)
    local top = m + header.h + min_gap
    local bottom = H - m - (footer.h > 0 and (footer.h + min_gap) or 0)
    local avail = bottom - top
    root:block(header, m, m)
    if footer.h > 0 then root:block(footer, m, H - m - footer.h) end

    local need
    if W > H and W >= self:px(LAYOUT.landscape_min_width) then
        local gutter = self:px(LAYOUT.gutter) * 2
        local left_w = math.floor((cw - gutter) * LAYOUT.landscape_left)
        local right_w = cw - left_w - gutter
        local function buildReading() return self:reading(left_w) end
        local function buildAnki() return self:anki(right_w) end
        local left = { buildReading() }
        local right = { buildAnki(), self:study(right_w) }
        if columnHeight(right, min_gap) > avail then -- the Anki chart goes first
            self.anki_chart = false
            right[1]:free()
            right[1] = buildAnki()
        end
        need = math.max(columnHeight(left, min_gap), columnHeight(right, min_gap))
        if need <= avail then
            self:growChart(left, 1, buildReading, "read_chart_extra", LAYOUT.read_chart_height,
                LAYOUT.read_chart_grow_max, avail, min_gap, 1)
            if self.anki_chart then
                self:growChart(right, 1, buildAnki, "anki_chart_extra", LAYOUT.anki_chart_height,
                    LAYOUT.anki_chart_grow_max_landscape, avail, min_gap, 1)
            end
        end
        local left_h = stack(root, left, m, top, avail, min_gap, max_gap)
        local right_h = stack(root, right, m + left_w + gutter, top, avail, min_gap, max_gap)
        -- vertical hairline between the columns
        root:rect(m + left_w + math.floor(gutter / 2), top, self:px(LAYOUT.rule_hair),
            math.max(0, math.min(avail, math.max(left_h, right_h))), self.pal.rule)
    else
        local function buildReading() return self:reading(cw) end
        local function buildAnki() return self:anki(cw) end
        local blocks = { buildReading(), buildAnki(), self:study(cw) }
        if columnHeight(blocks, min_gap) > avail then -- the Anki chart goes first
            self.anki_chart = false
            blocks[2]:free()
            blocks[2] = buildAnki()
        end
        need = columnHeight(blocks, min_gap)
        if need <= avail then
            -- free height: half to the reading chart, then more than half of the rest to Anki's
            self:growChart(blocks, 1, buildReading, "read_chart_extra", LAYOUT.read_chart_height,
                LAYOUT.read_chart_grow_max, avail, min_gap, 0.5)
            if self.anki_chart then
                self:growChart(blocks, 2, buildAnki, "anki_chart_extra", LAYOUT.anki_chart_height,
                    LAYOUT.anki_chart_grow_max, avail, min_gap, 0.6)
            end
        end
        stack(root, blocks, m, top, avail, min_gap, max_gap)
    end
    root.h = H
    return root, need <= avail, need, avail
end

---------------------------------------------------------------------------------------------------
-- The widget

local StatsView = InputContainer:extend{
    name = "kanki_stats",
    data = nil,            -- Stats:collect() result; collected (caches only) when nil
    sleep = false,         -- sleep-screen look: footer shows footer_text (KOReader's sleep message)
    interactive = false,   -- in-app: closes on tap, Back or a page key
    footer_text = nil,
    covers = true,         -- false: never show a cover
    cover_loader = nil,    -- function(book, max_w, max_h) -> blitbuffer|nil (default: kanki/readingstats)
    width = nil,           -- default: current screen size
    height = nil,
    dithered = true,       -- tells UIManager to use the Kaleido colour waveforms
    covers_fullscreen = true,
}
StatsView.LAYOUT = LAYOUT
StatsView.PALETTES = PALETTES

function StatsView:init()
    self.width = self.width or Screen:getWidth()
    self.height = self.height or Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    if not self.data then
        self.data = require("kanki/stats"):collect()
    end
    if self.interactive then
        if Device:hasKeys() then
            local group = Device.input and Device.input.group or {}
            local keys = {}
            for _, name in ipairs({ "Back", "PgFwd", "PgBack" }) do
                if group[name] then table.insert(keys, { group[name] }) end
            end
            if #keys > 0 then self.key_events.KankiStatsClose = keys end
        end
        if Device:isTouchDevice() then
            self.ges_events.Tap = {
                GestureRange:new{ ges = "tap", range = function() return self.dimen end },
            }
        end
    end
    self:_layout()
end

function StatsView:_palette()
    local ok, color = pcall(function() return Screen:isColorEnabled() end)
    return (ok and color) and PALETTES.color or PALETTES.grey
end

--- The current book's cover, loaded once per view ({ bb, w, h } or nil). Never raises.
function StatsView:_loadCover()
    if self._cover ~= nil then return self._cover or nil end
    self._cover = false
    if not self.covers then return nil end
    local ok, err = pcall(function()
        local r = type(self.data) == "table" and self.data.reading
        local book = type(r) == "table" and type(r.books) == "table" and r.books[1]
        if type(book) ~= "table" then return end
        local Readingstats = require("kanki/readingstats")
        local max_w, max_h = Readingstats.coverMaxSize()
        local bb
        if self.cover_loader then
            bb = self.cover_loader(book, max_w, max_h)
        else
            bb = Readingstats:coverBB(book, max_w, max_h)
        end
        if not bb then return end
        local w, h = bb:getWidth(), bb:getHeight()
        if w > 0 and h > 0 then
            self._cover = { bb = bb, w = w, h = h }
        else
            bb:free()
        end
    end)
    if not ok then logger.warn("kanki statsview: no cover:", err) end
    return self._cover or nil
end

function StatsView:_layout()
    if self[1] then
        self[1]:free()
        self[1] = nil
    end
    local footer = self.footer_text
    if not footer and self.interactive and not self.sleep then
        footer = _("Tap or press a page button to close")
    end
    local palette = self:_palette()
    local cover = self:_loadCover()
    local function build(scale)
        local builder = Builder.new{ data = self.data, palette = palette, scale = scale, cover = cover,
            width = self.width, height = self.height, footer_text = footer }
        local ok, page, fits, need, avail = pcall(builder.page, builder)
        if not ok then
            logger.warn("kanki statsview: layout failed:", page)
            return nil
        end
        return page, fits, need, avail
    end
    -- Scale 1; shrink until it fits (fonts >= min_scale); or, when most of the screen would stay
    -- empty, grow a little (<= max_scale) and keep that if it still fits.
    local scale = 1
    local root, fits, need, avail = build(scale)
    if root and fits and need < avail * LAYOUT.grow_below then
        local up = math.min(LAYOUT.max_scale, avail / need * LAYOUT.grow_below)
        if up > 1.02 then
            local r2, fits2 = build(up)
            if r2 and fits2 then
                root:free()
                root, scale = r2, up
            elseif r2 then
                r2:free()
            end
        end
    end
    for _ = 1, 3 do
        if not root or fits or scale <= LAYOUT.min_scale then break end
        local next_scale = math.max(LAYOUT.min_scale, scale * avail / need * 0.98)
        if next_scale >= scale then break end
        local r2, fits2, need2, avail2 = build(next_scale)
        if not r2 then break end
        root:free()
        root, fits, need, avail, scale = r2, fits2, need2, avail2, next_scale
    end
    self.layout_failed = (root == nil)
    if not root then
        -- Never show a blank page: minimal page with the footer text. (The sleep screen checks
        -- layout_failed and leaves KOReader's own sleep screen in place instead.)
        root = Block.new(self.width)
        local ok_min = pcall(function()
            local tw = TextWidget:new{ text = footer or _("Anki statistics unavailable"),
                face = Font:getFace(LAYOUT.font_face, LAYOUT.font_footer), fgcolor = Blitbuffer.COLOR_BLACK }
            root:widget(tw, math.floor((self.width - tw:getSize().w) / 2), math.floor(self.height / 2))
        end)
        if not ok_min then root = Block.new(self.width) end
    end
    self.scale = scale
    self[1] = Canvas:new{ width = self.width, height = self.height, background = palette.paper, root = root }
end

function StatsView:getSize()
    return Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

--- Free the page and the cover bitmap (also on close).
function StatsView:free()
    if self[1] then self[1]:free() end
    if self._cover then pcall(self._cover.bb.free, self._cover.bb) end
    self._cover = nil
end

function StatsView:onKankiStatsClose()
    if not self.interactive then return false end
    UIManager:close(self, "flashui")
    return true
end

function StatsView:onTap()
    return self:onKankiStatsClose()
end

function StatsView:onCloseWidget()
    self:free()
end

--- Rotation while shown in-app: step aside so the views below rotate as usual, then come back
--- laid out for the new orientation.
function StatsView:onSetRotationMode(mode)
    if not self.interactive or mode == nil or mode == Screen:getRotationMode() then
        return false
    end
    UIManager:close(self)
    UIManager:sendEvent(Event:new("SetRotationMode", mode))
    StatsView.show{ data = self.data, sleep = self.sleep, footer_text = self.footer_text, refresh = false }
    return true
end

function StatsView:_relayout()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self:_layout()
    UIManager:setDirty(self, "full")
end

function StatsView:onScreenResize()
    if self.interactive then self:_relayout() end
    return false
end
StatsView.onSetDimensions = StatsView.onScreenResize

--[[--
Open the stats view in-app (full screen, "full" refresh with dithering).

@tparam[opt] table opts {
    refresh = false: don't fetch fresh Anki stats (default: fetch if the server is already running),
    sleep = true + footer_text: show the sleep-screen variant (preview),
    data = an existing Stats:collect() result }
@treturn StatsView
]]
function StatsView.show(opts)
    opts = opts or {}
    local data = opts.data
    if not data then
        local Stats = require("kanki/stats")
        local Readingstats = require("kanki/readingstats")
        if opts.refresh ~= false then
            pcall(Stats.refreshAnki, Stats)
        end
        if not Readingstats:nickelSnapshotDone() then
            pcall(Readingstats.snapshotNickel, Readingstats)
        end
        pcall(function()
            local ReaderUI = require("apps/reader/readerui")
            local ui = ReaderUI.instance
            if ui then Readingstats.flushKOReader(ui.statistics) end
        end)
        -- In-app we may look for Nickel's cover files (the sleep screen only uses cached paths).
        pcall(function()
            local ids = {}
            for i, b in ipairs(Stats:books()) do
                if i > 3 then break end
                if b.source == "kobo" and b.image_id then table.insert(ids, b.image_id) end
            end
            Readingstats:resolveNickelCovers(ids)
        end)
        data = Stats:collect()
    end
    local view = StatsView:new{
        data = data,
        interactive = true,
        sleep = opts.sleep or false,
        footer_text = opts.footer_text,
    }
    UIManager:show(view, "full", nil, nil, nil, true)
    return view
end

StatsView.Builder = Builder -- for tests
return StatsView

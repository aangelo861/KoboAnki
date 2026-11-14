--[[
Extra KOReader stand-ins for the stats / sleep-screen tests (test_stats.lua, preview_statsview.lua).
Loads koreader_stubs first and adds, at runtime only (koreader_stubs.lua itself is not changed):

* Blitbuffer colours (Color8 levels + ColorRGB32 via colorFromString, isColor8)
* "ui/widget/widget" (base class), font-aware TextWidget metrics measured from Noto Sans (the UI
  font KOReader uses), so layouts get realistic sizes; TextWidget:paintTo records text on a recorder
* Screen size / rotation / colour switches, Device battery, UIManager:sendEvent
* fakes for datetime, docsettings, readhistory, apps/reader/readerui, G_reader_settings values
* SQLite: KOReader's own lua-ljsqlite3 (common/lua-ljsqlite3/init.lua from a KOReader tree:
  $KOREADER_SRC, or a few known places) loaded with an ffi.loadlib shim against the system
  libsqlite3; if no KOReader tree is around, a minimal FFI stand-in with the same API subset
  (open "ro", prepare/step/close, INTEGER columns as int64 cdata).
* Images (covers): Blitbuffer.new / fromstring with real pixel memory (BB8, RGB24, RGB32),
  "ui/renderimage" decoding binary PPM/PGM files (our synthetic covers; the device decodes JPEG)
  and box-filter scaling, an optional stand-in for "ffi/zstd" (Extra.setZstd), and
  Extra.writeSyntheticCover() which draws a made-up cover (never a real one).
* Recorder: a fake blitbuffer that records every paint call and checks it stays on screen; image
  blits are recorded too (and their pixels dumped to files when Extra.image_dump_dir is set).
]]

local ffi = require("ffi")
local Stubs = require("koreader_stubs")

local Extra = { Stubs = Stubs }

---------------------------------------------------------------------------------------------------
-- Blitbuffer

local BB = require("ffi/blitbuffer")
local Color8_mt = { __tostring = function(c) return string.format("gray#%02X", c.v) end }
local function color8(v) return setmetatable({ v = v, gray = true }, Color8_mt) end
BB.COLOR_WHITE.v, BB.COLOR_WHITE.gray = 0xFF, true
BB.COLOR_BLACK.v, BB.COLOR_BLACK.gray = 0x00, true
BB.COLOR_DARK_GRAY.v, BB.COLOR_DARK_GRAY.gray = 0x88, true
for name, v in pairs({ GRAY_E = 0xEE, GRAY_D = 0xDD, LIGHT_GRAY = 0xCC, GRAY_B = 0xBB, GRAY = 0xAA,
                       GRAY_9 = 0x99, GRAY_7 = 0x77, GRAY_6 = 0x66, GRAY_5 = 0x55, GRAY_4 = 0x44,
                       GRAY_3 = 0x33, GRAY_2 = 0x22, GRAY_1 = 0x11 }) do
    BB["COLOR_" .. name] = BB["COLOR_" .. name] or color8(v)
end
function BB.colorFromString(s)
    local hex = s:gsub("#", "")
    if #hex ~= 6 then return nil end
    return { rgb = true, hex = "#" .. hex:upper(),
             r = tonumber(hex:sub(1, 2), 16), g = tonumber(hex:sub(3, 4), 16), b = tonumber(hex:sub(5, 6), 16) }
end
function BB.isColor8(c) return not (type(c) == "table" and c.rgb) end
function BB.gray(level) return color8(math.floor(0xFF * (1 - level))) end

--- "#rrggbb" for any of our colours (for the preview renderer).
function Extra.colorHex(c)
    if type(c) ~= "table" then return "#FF00FF" end
    if c.rgb then return c.hex end
    local v = c.v or 0x80
    return string.format("#%02X%02X%02X", v, v, v)
end

---------------------------------------------------------------------------------------------------
-- Image blitbuffers: real pixels in FFI memory, the subset of KOReader's BlitBuffer API the cover
-- code uses (new, fromstring, getWidth/Height/Type, w/h/stride/data, setAllocated, free, blitFrom).

pcall(ffi.cdef, "void *malloc(size_t size);")
pcall(ffi.cdef, "void free(void *ptr);")

BB.TYPE_BB4, BB.TYPE_BB8, BB.TYPE_BB8A, BB.TYPE_BBRGB16, BB.TYPE_BBRGB24, BB.TYPE_BBRGB32 = 0, 1, 2, 3, 4, 5
BB.TYPE_TO_BPP = { [0] = 4, [1] = 8, [2] = 16, [3] = 16, [4] = 24, [5] = 32 }
Extra.live_images = 0 -- allocated and not freed yet (leak checks)

local Image = {}
Image.__index = Image

function BB.new(w, h, t, dataptr, stride)
    t = t or BB.TYPE_BB8
    local bpp = assert(BB.TYPE_TO_BPP[t], "unknown blitbuffer type " .. tostring(t))
    stride = stride or math.floor((w * bpp + 7) / 8)
    local img = setmetatable({ w = w, h = h, stride = stride, btype = t }, Image)
    if dataptr == nil then
        img.mem = ffi.new("uint8_t[?]", stride * h) -- zeroed, GC-owned
        img.data = img.mem
    else
        img.data = ffi.cast("uint8_t *", dataptr)
    end
    Extra.live_images = Extra.live_images + 1
    return img
end

function BB.fromstring(w, h, t, str, stride)
    local img = BB.new(w, h, t, nil, stride)
    ffi.copy(img.data, str, math.min(#str, img.stride * h))
    return img
end

function Image:getWidth() return self.w end
function Image:getHeight() return self.h end
function Image:getType() return self.btype end
function Image:setAllocated(a) self.c_owned = (a == 1) end
function Image:free()
    if self.freed then return end
    self.freed = true
    if self.c_owned then ffi.C.free(self.data) end
    self.data, self.mem = nil, nil
    Extra.live_images = Extra.live_images - 1
end

function Image:getRGB(x, y)
    local p = self.data + y * self.stride
    local t = self.btype
    if t == BB.TYPE_BBRGB24 then
        local o = x * 3
        return p[o], p[o + 1], p[o + 2]
    elseif t == BB.TYPE_BBRGB32 then
        local o = x * 4
        return p[o], p[o + 1], p[o + 2]
    elseif t == BB.TYPE_BB8A then
        local v = p[x * 2]
        return v, v, v
    end
    local v = p[x]
    return v, v, v
end

function Image:setRGB(x, y, r, g, b)
    local p = self.data + y * self.stride
    local t = self.btype
    if t == BB.TYPE_BBRGB24 then
        local o = x * 3
        p[o], p[o + 1], p[o + 2] = r, g, b
    elseif t == BB.TYPE_BBRGB32 then
        local o = x * 4
        p[o], p[o + 1], p[o + 2], p[o + 3] = r, g, b, 0xFF
    else -- grey, as KOReader converts (ColorRGB24:getColor8)
        p[x] = bit.rshift(4898 * r + 9618 * g + 1869 * b, 14)
    end
end

function Image:blitFrom(src, dx, dy, ox, oy, w, h)
    dx, dy, ox, oy = dx or 0, dy or 0, ox or 0, oy or 0
    w, h = w or src.w, h or src.h
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            self:setRGB(dx + x, dy + y, src:getRGB(ox + x, oy + y))
        end
    end
end

--- Pixels as a binary PPM (P6) or, for grey buffers, PGM (P5).
function Extra.imageToPNM(img, ox, oy, w, h)
    ox, oy, w, h = ox or 0, oy or 0, w or img.w, h or img.h
    local grey = img.btype == BB.TYPE_BB8
    local n = grey and 1 or 3
    local buf = ffi.new("uint8_t[?]", w * h * n)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local r, g, b = img:getRGB(ox + x, oy + y)
            local o = (y * w + x) * n
            if grey then
                buf[o] = r
            else
                buf[o], buf[o + 1], buf[o + 2] = r, g, b
            end
        end
    end
    return string.format("%s\n%d %d\n255\n", grey and "P5" or "P6", w, h) .. ffi.string(buf, w * h * n)
end

---------------------------------------------------------------------------------------------------
-- "ui/renderimage": decodes binary PPM/PGM (the device decodes JPEG through TurboJPEG/MuPDF) and
-- scales with a box filter (the device uses MuPDF). Counts what it does, for the cost checks.

local RenderImage = { decodes = 0, scales = 0, fail = nil }

local function parsePNM(data)
    local magic, w, h, maxval, pos = data:match("^(P[56])%s+(%d+)%s+(%d+)%s+(%d+)%s()")
    if not magic then return nil end
    w, h = tonumber(w), tonumber(h)
    if tonumber(maxval) ~= 255 or w < 1 or h < 1 then return nil end
    local n = magic == "P6" and 3 or 1
    if #data - pos + 1 < w * h * n then return nil end
    local img = BB.new(w, h, n == 3 and BB.TYPE_BBRGB24 or BB.TYPE_BB8)
    ffi.copy(img.data, data:sub(pos, pos + w * h * n - 1), w * h * n)
    return img
end

function RenderImage:renderImageData(data, size, want_frames, width, height)
    if self.fail then error(self.fail) end
    if type(data) ~= "string" then return nil end
    self.decodes = self.decodes + 1
    local img = parsePNM(data)
    if img and width and height then img = self:scaleBlitBuffer(img, width, height) end
    return img
end

function RenderImage:renderImageFile(filename, want_frames, width, height)
    local f = io.open(filename, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return self:renderImageData(data, #data, want_frames, width, height)
end

function RenderImage:scaleBlitBuffer(bb, width, height, free_orig)
    if not width or not height then return bb end
    width, height = math.floor(width), math.floor(height)
    if bb.w == width and bb.h == height then return bb end
    self.scales = self.scales + 1
    local out = BB.new(width, height, bb.btype == BB.TYPE_BB8 and BB.TYPE_BB8 or BB.TYPE_BBRGB24)
    for y = 0, height - 1 do
        local y0 = math.floor(y * bb.h / height)
        local y1 = math.max(y0 + 1, math.floor((y + 1) * bb.h / height))
        for x = 0, width - 1 do
            local x0 = math.floor(x * bb.w / width)
            local x1 = math.max(x0 + 1, math.floor((x + 1) * bb.w / width))
            local sr, sg, sb, n = 0, 0, 0, 0
            for yy = y0, y1 - 1 do
                for xx = x0, x1 - 1 do
                    local r, g, b = bb:getRGB(xx, yy)
                    sr, sg, sb, n = sr + r, sg + g, sb + b, n + 1
                end
            end
            out:setRGB(x, y, math.floor(sr / n + 0.5), math.floor(sg / n + 0.5), math.floor(sb / n + 0.5))
        end
    end
    if free_orig ~= false then bb:free() end
    return out
end

package.loaded["ui/renderimage"] = RenderImage
Extra.RenderImage = RenderImage

--- A stand-in for KOReader's "ffi/zstd" (on) or none at all (off: the raw cache format is used).
--- Its "compression" only adds a marker, which is enough to exercise both code paths.
Extra.zstd_calls = { compress = 0, uncompress = 0 }
function Extra.setZstd(on)
    if not on then
        package.loaded["ffi/zstd"] = nil
        return
    end
    package.loaded["ffi/zstd"] = {
        zstd_compress = function(ptr, size)
            Extra.zstd_calls.compress = Extra.zstd_calls.compress + 1
            local buf = ffi.C.malloc(size + 4)
            ffi.copy(buf, "ZST1", 4)
            ffi.copy(ffi.cast("uint8_t *", buf) + 4, ptr, size)
            return buf, size + 4
        end,
        zstd_uncompress = function(ptr, size)
            Extra.zstd_calls.uncompress = Extra.zstd_calls.uncompress + 1
            local p = ffi.cast("const uint8_t *", ptr)
            assert(size >= 4 and ffi.string(p, 4) == "ZST1", "not a zstd frame")
            local buf = ffi.C.malloc(size - 4)
            ffi.copy(buf, p + 4, size - 4)
            return buf, size - 4
        end,
    }
end

--[[--
Write a made-up book cover as a binary PPM (P6): a two-colour gradient with diagonal stripes, a
pale title band holding dark bars (no text), a disc and an author band. opts = { top =, bottom =,
disc = } as { r, g, b }. Synthetic on purpose: no real cover ever goes into the repo or previews.
]]
function Extra.writeSyntheticCover(path, w, h, opts)
    opts = opts or {}
    local top = opts.top or { 0x1F, 0x4E, 0x79 }
    local bottom = opts.bottom or { 0x2A, 0x8C, 0x6E }
    local disc = opts.disc or { 0xF2, 0x8C, 0x28 }
    local band = { 0xF4, 0xEC, 0xD6 }
    local ink = { 0x2B, 0x2B, 0x33 }
    local buf = ffi.new("uint8_t[?]", w * h * 3)
    local cx, cy, rr = w * 0.5, h * 0.64, (w * 0.22) ^ 2
    local bars = { { 0.20, 0.72 }, { 0.255, 0.58 }, { 0.31, 0.44 } } -- { y (share of h), width (share) }
    for y = 0, h - 1 do
        local t = y / (h - 1)
        for x = 0, w - 1 do
            local c = { top[1] + (bottom[1] - top[1]) * t, top[2] + (bottom[2] - top[2]) * t,
                        top[3] + (bottom[3] - top[3]) * t }
            if (x + y) % 48 < 14 then c = { c[1] + 22, c[2] + 22, c[3] + 22 } end
            if (x - cx) ^ 2 + (y - cy) ^ 2 <= rr then c = disc end
            if y >= h * 0.13 and y < h * 0.37 and x >= w * 0.08 and x < w * 0.92 then
                c = band
                for _, b in ipairs(bars) do
                    local bx0 = w * (0.5 - b[2] / 2)
                    if y >= h * b[1] and y < h * (b[1] + 0.03) and x >= bx0 and x < w - bx0 then c = ink end
                end
            end
            if y >= h * 0.87 and y < h * 0.91 and x >= w * 0.25 and x < w * 0.75 then c = band end
            if x < 3 or y < 3 or x >= w - 3 or y >= h - 3 then c = { 0x14, 0x14, 0x18 } end
            local o = (y * w + x) * 3
            buf[o] = math.max(0, math.min(255, math.floor(c[1])))
            buf[o + 1] = math.max(0, math.min(255, math.floor(c[2])))
            buf[o + 2] = math.max(0, math.min(255, math.floor(c[3])))
        end
    end
    local f = assert(io.open(path, "wb"))
    f:write(string.format("P6\n%d %d\n255\n", w, h))
    f:write(ffi.string(buf, w * h * 3))
    f:close()
end

---------------------------------------------------------------------------------------------------
-- Widget base class (KOReader's frontend/ui/widget/widget.lua semantics)

local Widget = {}
Widget.__index = Widget
function Widget:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
function Widget:new(o)
    o = self:extend(o or {})
    if o._init then o:_init() end
    if o.init then o:init() end
    return o
end
function Widget:getSize() return self.dimen end
function Widget:paintTo() end
function Widget:free() end
function Widget:handleEvent(ev)
    local h = self[ev.handler]
    if h then return h(self, unpack(ev.args or {}, 1, ev.args and ev.args.n or 0)) end
end
package.loaded["ui/widget/widget"] = Widget

---------------------------------------------------------------------------------------------------
-- Screen / Device

local Device = require("device")
local Screen = Device.screen
local screen = { w = 1264, h = 1680, color = true, rotation = 0 }
function Screen:getWidth() return screen.w end
function Screen:getHeight() return screen.h end
function Screen:getSize() return require("ui/geometry"):new{ w = screen.w, h = screen.h } end
function Screen:isColorEnabled() return screen.color end
function Screen:getRotationMode() return screen.rotation end
function Screen:setRotationMode(mode)
    screen.rotation = mode
    if mode % 2 == 1 then
        screen.w, screen.h = math.max(screen.w, screen.h), math.min(screen.w, screen.h)
    else
        screen.w, screen.h = math.min(screen.w, screen.h), math.max(screen.w, screen.h)
    end
end
-- scaleBySize as KOReader: min(w, h) / 600 (the same in both orientations)
function Screen:scaleBySize(px)
    local s = math.min(screen.w, screen.h) / 600
    return math.ceil(px * s)
end

--- Switch the fake screen: Extra.setScreen(1680, 1264, false) = landscape, colour off.
function Extra.setScreen(w, h, color)
    screen.w, screen.h = w, h
    if color ~= nil then screen.color = color end
    screen.rotation = (w > h) and 1 or 0
end

-- KOReader's data dir (its cache/ holds the pre-scaled covers): the settings dir in the tests.
local DataStorage = require("datastorage")
DataStorage.getDataDir = DataStorage.getDataDir or function()
    return Stubs.data_dir or Stubs.settings_dir or "/tmp"
end

Extra.battery = { level = 83, charging = false }
local powerd = {}
function powerd:getCapacity() return Extra.battery.level end
function powerd:isCharging() return Extra.battery.charging end
function Device:hasBattery() return Extra.battery.level ~= nil end
function Device:getPowerDevice() return powerd end

---------------------------------------------------------------------------------------------------
-- Text: Noto Sans metrics (advances in 1/1000 em, measured from NotoSans-Regular/Bold.ttf)

local NOTO = {
    regular = {
        ascii = { 260, 269, 408, 646, 572, 831, 732, 225, 300, 300, 551, 572, 268, 322, 268, 372, 572, 572, 572, 572, 572, 572, 572, 572, 572, 572, 268, 268, 572, 572, 572, 434, 899, 639, 650, 632, 730, 556, 519, 728, 741, 339, 273, 619, 524, 907, 760, 781, 605, 781, 622, 549, 556, 731, 600, 930, 586, 566, 572, 329, 372, 329, 572, 444, 281, 561, 615, 480, 615, 564, 344, 615, 618, 258, 258, 534, 258, 935, 618, 605, 615, 615, 413, 479, 361, 618, 508, 786, 529, 510, 470, 380, 551, 380, 572 },
        extra = { [0xB7] = 268, [0x2013] = 500, [0x2014] = 1000, [0x2026] = 791, [0xE9] = 564, [0x2019] = 175 },
    },
    bold = {
        ascii = { 260, 282, 479, 646, 572, 902, 750, 266, 339, 339, 542, 572, 285, 320, 281, 415, 572, 572, 572, 572, 572, 572, 572, 572, 572, 572, 281, 285, 572, 572, 572, 477, 898, 692, 665, 642, 732, 560, 549, 724, 765, 389, 331, 664, 559, 943, 813, 791, 621, 791, 656, 551, 577, 756, 650, 967, 670, 626, 579, 331, 415, 331, 572, 411, 365, 599, 632, 516, 632, 597, 387, 632, 650, 299, 298, 620, 298, 975, 650, 625, 632, 632, 447, 502, 434, 650, 571, 856, 578, 571, 493, 394, 551, 394, 572 },
        extra = { [0xB7] = 281, [0x2013] = 500, [0x2014] = 1000, [0x2026] = 855, [0xE9] = 597, [0x2019] = 217 },
    },
    height = 1362, ascender = 1069, -- hhea: 1069 / -293, no line gap
}

local function codepoints(s)
    local cps = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local c = ch:byte(1)
        local cp
        if c < 0x80 then cp = c
        elseif c < 0xE0 then cp = (c - 0xC0) * 64 + (ch:byte(2) - 0x80)
        elseif c < 0xF0 then cp = ((c - 0xE0) * 64 + (ch:byte(2) - 0x80)) * 64 + (ch:byte(3) - 0x80)
        else cp = 0x2B1C end
        table.insert(cps, { cp = cp, ch = ch })
    end
    return cps
end

local function advance(cp, bold)
    local t = bold and NOTO.bold or NOTO.regular
    if cp >= 32 and cp <= 126 then return t.ascii[cp - 31] end
    return t.extra[cp] or 600
end

function Extra.textWidth(text, px, bold)
    local w = 0
    for _, c in ipairs(codepoints(text)) do w = w + advance(c.cp, bold) end
    return math.floor(w * px / 1000 + 0.5)
end

local Font = require("ui/font")
function Font:getFace(name, size)
    size = size or 20
    return { name = name, orig_size = size, size = Screen:scaleBySize(size) }
end

local TextWidget = require("ui/widget/textwidget")
TextWidget.padding = 4
function TextWidget:_measure()
    local px = (self.face and self.face.size) or 40
    local pad = self.padding or 0
    local text = tostring(self.text or "")
    local w = Extra.textWidth(text, px, self.bold)
    if self.max_width and w > self.max_width then
        -- truncate with an ellipsis, like KOReader
        local cps, out = codepoints(text), ""
        local ell = Extra.textWidth("…", px, self.bold)
        local acc = 0
        for _, c in ipairs(cps) do
            local a = advance(c.cp, self.bold) * px / 1000
            if acc + a + ell > self.max_width then break end
            acc = acc + a
            out = out .. c.ch
        end
        self._drawn = out .. "…"
        w = Extra.textWidth(self._drawn, px, self.bold)
        self._truncated = true
    else
        self._drawn = text
    end
    self._w = w
    self._h = math.ceil(NOTO.height * px / 1000) + 2 * pad
    self._base = math.floor(NOTO.ascender * px / 1000 + 0.5) + pad
end
function TextWidget:getSize()
    self:_measure()
    return require("ui/geometry"):new{ w = self._w, h = self._h }
end
function TextWidget:getBaseline()
    self:_measure()
    return self._base
end
function TextWidget:getWidth() return self:getSize().w end
function TextWidget:isTruncated() self:_measure() return self._truncated or false end
function TextWidget:free() self._freed = (self._freed or 0) + 1 end
function TextWidget:paintTo(bb, x, y)
    self:_measure()
    if bb and bb.recordText then
        bb:recordText(self, x, y)
    end
end

---------------------------------------------------------------------------------------------------
-- UIManager additions

local UIManager = Stubs.UIManager
function UIManager:sendEvent(ev)
    local top = self._stack[#self._stack]
    if top and top.handleEvent then return top:handleEvent(ev) end
end
Extra.dirty = {}
function UIManager:setDirty(w, mode) table.insert(Extra.dirty, { w = w, mode = mode }) end
local orig_show = UIManager.show
function UIManager:show(w, mode, region, x, y, dither)
    Extra.last_show = { w = w, mode = mode, dither = dither }
    return orig_show(self, w, mode)
end
local orig_close = UIManager.close
function UIManager:close(w, mode)
    Extra.last_close = { w = w, mode = mode }
    return orig_close(self, w, mode)
end

---------------------------------------------------------------------------------------------------
-- KOReader settings and modules around reading

Extra.gsettings = {}
-- luacheck: push ignore 122
G_reader_settings.readSetting = function(_, k) return Extra.gsettings[k] end
G_reader_settings.isTrue = function(_, k) return Extra.gsettings[k] == true end
G_reader_settings.isFalse = function(_, k) return Extra.gsettings[k] == false end
G_reader_settings.has = function(_, k) return Extra.gsettings[k] ~= nil end
G_reader_settings.hasNot = function(_, k) return Extra.gsettings[k] == nil end
G_reader_settings.nilOrTrue = function(_, k) return Extra.gsettings[k] == nil or Extra.gsettings[k] == true end
-- luacheck: pop

package.loaded["datetime"] = {
    shortDayOfWeekTranslation = { Mon = "Mon", Tue = "Tue", Wed = "Wed", Thu = "Thu", Fri = "Fri", Sat = "Sat", Sun = "Sun" },
    shortDayOfWeekToLongTranslation = { Mon = "Monday", Tue = "Tuesday", Wed = "Wednesday", Thu = "Thursday",
                                         Fri = "Friday", Sat = "Saturday", Sun = "Sunday" },
    longMonthTranslation = {},
    secondsToHour = function(t, twelve) return os.date(twelve and "%I:%M %p" or "%H:%M", t) end,
}

-- Sidecar settings per document path: Extra.sidecars[path] = { percent_finished = 0.4, doc_props = {...} }
Extra.sidecars = {}
local DocSettings = {}
function DocSettings:hasSidecarFile(path) return Extra.sidecars[path] ~= nil end
function DocSettings:open(path)
    local data = Extra.sidecars[path] or {}
    return { readSetting = function(_, k) return data[k] end }
end
package.loaded["docsettings"] = DocSettings
package.loaded["readhistory"] = { hist = {} }
package.loaded["apps/reader/readerui"] = { instance = nil }

---------------------------------------------------------------------------------------------------
-- SQLite

local function exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function findLjsqlite3()
    local candidates = {}
    -- KOREADER_SRC: an unpacked KOReader release (the folder containing common/, frontend/, ...).
    if os.getenv("KOREADER_SRC") then table.insert(candidates, os.getenv("KOREADER_SRC")) end
    table.insert(candidates, "/Volumes/KOBOeReader/.adds/koreader") -- the Kobo, when mounted over USB
    -- Otherwise the built-in minimal binding below is used (same API subset).
    for _, dir in ipairs(candidates) do
        local p = dir .. "/common/lua-ljsqlite3/init.lua"
        if exists(p) then return p end
    end
end

local function minimalSQ3()
    ffi.cdef[[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close_v2(sqlite3 *db);
const char *sqlite3_errmsg(sqlite3 *db);
int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_step(sqlite3_stmt *stmt);
int sqlite3_finalize(sqlite3_stmt *stmt);
int sqlite3_column_count(sqlite3_stmt *stmt);
int sqlite3_column_type(sqlite3_stmt *stmt, int iCol);
long long sqlite3_column_int64(sqlite3_stmt *stmt, int iCol);
double sqlite3_column_double(sqlite3_stmt *stmt, int iCol);
const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int iCol);
int sqlite3_column_bytes(sqlite3_stmt *stmt, int iCol);
]]
    local lib = ffi.load("sqlite3")
    local MODES = { ro = 1, rw = 2, rwc = 6 }
    local Stmt = {}
    Stmt.__index = Stmt
    function Stmt:step()
        local rc = lib.sqlite3_step(self.ptr)
        if rc == 100 then
            local row = {}
            for i = 0, lib.sqlite3_column_count(self.ptr) - 1 do
                local t = lib.sqlite3_column_type(self.ptr, i)
                if t == 1 then row[i + 1] = lib.sqlite3_column_int64(self.ptr, i)
                elseif t == 2 then row[i + 1] = lib.sqlite3_column_double(self.ptr, i)
                elseif t == 3 then
                    row[i + 1] = ffi.string(lib.sqlite3_column_text(self.ptr, i), lib.sqlite3_column_bytes(self.ptr, i))
                end
            end
            return row
        elseif rc == 101 then
            return nil
        end
        error("ljsqlite3[step] " .. ffi.string(lib.sqlite3_errmsg(self.db)))
    end
    function Stmt:close() lib.sqlite3_finalize(self.ptr) end
    local Conn = {}
    Conn.__index = Conn
    function Conn:prepare(sql)
        local p = ffi.new("sqlite3_stmt*[1]")
        if lib.sqlite3_prepare_v2(self.ptr, sql, #sql, p, nil) ~= 0 then
            error("ljsqlite3[error] " .. ffi.string(lib.sqlite3_errmsg(self.ptr)))
        end
        return setmetatable({ ptr = p[0], db = self.ptr }, Stmt)
    end
    function Conn:close() lib.sqlite3_close_v2(self.ptr) end
    return {
        open = function(path, mode)
            local p = ffi.new("sqlite3*[1]")
            local rc = lib.sqlite3_open_v2(path, p, MODES[mode or "rwc"], nil)
            if rc ~= 0 then
                local msg = ffi.string(lib.sqlite3_errmsg(p[0]))
                lib.sqlite3_close_v2(p[0])
                error("ljsqlite3[cantopen] " .. msg)
            end
            return setmetatable({ ptr = p[0] }, Conn)
        end,
    }
end

--- Make require("lua-ljsqlite3/init") work. Returns a description of what is used.
--- KANKI_TEST_SQLITE=minimal forces the FFI stand-in.
function Extra.setupSQLite()
    local path = os.getenv("KANKI_TEST_SQLITE") ~= "minimal" and findLjsqlite3() or nil
    if path then
        ffi.loadlib = ffi.loadlib or function(name) return ffi.load(name) end
        pcall(ffi.cdef, "void free(void *ptr);")
        package.preload["lua-ljsqlite3/init"] = function() return dofile(path) end
        local ok, mod = pcall(require, "lua-ljsqlite3/init")
        if ok then return "KOReader lua-ljsqlite3 (" .. path .. ")" end
        package.loaded["lua-ljsqlite3/init"] = nil
        io.stderr:write("could not load KOReader's lua-ljsqlite3: " .. tostring(mod) .. "\n")
    end
    package.loaded["lua-ljsqlite3/init"] = minimalSQ3()
    return "minimal FFI stand-in (set KOREADER_SRC to a KOReader tree to use the real lua-ljsqlite3)"
end

---------------------------------------------------------------------------------------------------
-- Recorder: a fake blitbuffer that records paint calls

local Recorder = {}
Recorder.__index = Recorder

function Extra.newRecorder(w, h)
    return setmetatable({ w = w, h = h, ops = {}, out_of_bounds = {}, rgb_used = false }, Recorder)
end

function Recorder:_check(kind, x, y, w, h)
    if x < 0 or y < 0 or x + w > self.w or y + h > self.h then
        table.insert(self.out_of_bounds, string.format("%s at %d,%d %dx%d", kind, x, y, w, h))
    end
end

function Recorder:_rect(kind, x, y, w, h, c, r)
    if w <= 0 or h <= 0 then return end
    self:_check(kind, x, y, w, h)
    if type(c) == "table" and c.rgb then self.rgb_used = true end
    table.insert(self.ops, { op = "rect", x = x, y = y, w = w, h = h, color = Extra.colorHex(c), r = r or 0 })
end

function Recorder:paintRect(x, y, w, h, c) self:_rect("paintRect", x, y, w, h, c) end
function Recorder:paintRoundedRect(x, y, w, h, c, r) self:_rect("paintRoundedRect", x, y, w, h, c, r) end
function Recorder:paintRectRGB32(x, y, w, h, c)
    assert(type(c) == "table" and c.rgb, "paintRectRGB32 needs an RGB colour")
    self:_rect("paintRectRGB32", x, y, w, h, c)
end
function Recorder:paintRoundedRectRGB32(x, y, w, h, c, r)
    assert(type(c) == "table" and c.rgb, "paintRoundedRectRGB32 needs an RGB colour")
    self:_rect("paintRoundedRectRGB32", x, y, w, h, c, r)
end
function Recorder:paintBorder(x, y, w, h, bw, c)
    self:_check("paintBorder", x, y, w, h)
    table.insert(self.ops, { op = "border", x = x, y = y, w = w, h = h, bw = bw, color = Extra.colorHex(c) })
end
function Recorder:paintCircle(cx, cy, r, c, lw)
    self:_check("paintCircle", cx - r, cy - r, 2 * r, 2 * r)
    if type(c) == "table" and c.rgb then self.rgb_used = true end
    table.insert(self.ops, { op = "circle", x = cx, y = cy, r = r, lw = lw, color = Extra.colorHex(c) })
end
--- Image blits (covers): recorded with their rectangle; grey = a BB8 source. With
--- Extra.image_dump_dir set, the blitted pixels are written there and op.file names the file.
function Recorder:blitFrom(src, x, y, ox, oy, w, h)
    w, h = w or src.w, h or src.h
    self:_check("image", x, y, w, h)
    local grey = src.btype == BB.TYPE_BB8
    if not grey then self.rgb_image = true end
    local op = { op = "image", x = x, y = y, w = w, h = h, grey = grey }
    if Extra.image_dump_dir then
        Extra.image_n = (Extra.image_n or 0) + 1
        local file = string.format("%s/%s%d.%s", Extra.image_dump_dir, Extra.image_prefix or "image-",
            Extra.image_n, grey and "pgm" or "ppm")
        local f = assert(io.open(file, "wb"))
        f:write(Extra.imageToPNM(src, ox or 0, oy or 0, w, h))
        f:close()
        op.file = file
    end
    table.insert(self.ops, op)
end
Recorder.ditherblitFrom = Recorder.blitFrom

function Recorder:images()
    local out = {}
    for _, op in ipairs(self.ops) do
        if op.op == "image" then table.insert(out, op) end
    end
    return out
end

function Recorder:recordText(tw, x, y)
    local px = tw.face and tw.face.size or 40
    self:_check("text '" .. tostring(tw._drawn) .. "'", x, y, tw._w, tw._h)
    table.insert(self.ops, { op = "text", x = x, y = y, w = tw._w, h = tw._h, base = tw._base,
        text = tw._drawn, px = px, bold = tw.bold and true or false, color = Extra.colorHex(tw.fgcolor) })
end

function Recorder:texts()
    local out = {}
    for _, op in ipairs(self.ops) do
        if op.op == "text" then table.insert(out, op.text) end
    end
    return out
end

function Recorder:hasText(pattern)
    for _, op in ipairs(self.ops) do
        if op.op == "text" and op.text:find(pattern) then return op end
    end
    return nil
end

return Extra

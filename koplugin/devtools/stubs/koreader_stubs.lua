--[[
Minimal, permissive stand-ins for the KOReader modules kanki.koplugin uses, so the plugin's own
logic can be driven headless on a desktop (devtools/test_ui_smoke.lua). These do NOT paint
anything and only model what the plugin relies on (sizes, callbacks, the window stack, tasks).
They are not a substitute for testing on the device.
]]

local socket = require("socket")

local Stubs = { shown = {}, notifications = {}, log = {} }

local function noop() end
local function pack(...) return { n = select("#", ...), ... } end

-- Class helpers mimicking Widget:extend / Widget:new
local function class(base)
    local C = {}
    if base then setmetatable(C, { __index = base }) end
    C.__index = C
    function C:extend(o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        return o
    end
    function C:new(o)
        o = self:extend(o or {})
        if o._init then o:_init() end
        if o.init then o:init() end
        return o
    end
    return C
end

local Geom = {}
Geom.__index = Geom
function Geom:new(o) o = o or {}; o.x = o.x or 0; o.y = o.y or 0; o.w = o.w or 0; o.h = o.h or 0; return setmetatable(o, Geom) end
function Geom:copy() return Geom:new{ x = self.x, y = self.y, w = self.w, h = self.h } end
function Geom:combine(o) return self end
function Geom:contains(p) return p.x >= self.x and p.y >= self.y and p.x < self.x + self.w and p.y < self.y + self.h end

local Widget = class()
function Widget:getSize() return self.dimen or Geom:new{ w = 10, h = 10 } end
function Widget:paintTo() end
function Widget:free() end
function Widget:handleEvent(ev)
    local h = self[ev.handler]
    if h then return h(self, unpack(ev.args, 1, ev.args.n)) end
end

local WidgetContainer = class(Widget)
function WidgetContainer:getSize()
    if self.dimen then return self.dimen end
    if self[1] then return self[1]:getSize() end
    return Geom:new()
end
function WidgetContainer:free()
    for _, w in ipairs(self) do if w.free then w:free() end end
end
function WidgetContainer:handleEvent(ev)
    for _, w in ipairs(self) do
        if w.handleEvent and w:handleEvent(ev) then return true end
    end
    return Widget.handleEvent(self, ev)
end
function WidgetContainer:clear() for i = #self, 1, -1 do self[i] = nil end end

local InputContainer = class(WidgetContainer)
function InputContainer:_init()
    self.key_events = self.key_events or {}
    self.ges_events = self.ges_events or {}
end

local FocusManager = class(InputContainer)
function FocusManager:_init()
    InputContainer._init(self)
    self.selected = { x = 1, y = 1 }
end

local function sumGroup(self, horizontal)
    local w, h = 0, 0
    for _, c in ipairs(self) do
        local s = c:getSize()
        if horizontal then w = w + s.w; h = math.max(h, s.h) else h = h + s.h; w = math.max(w, s.w) end
    end
    return Geom:new{ w = w, h = h }
end
local HorizontalGroup = class(WidgetContainer)
function HorizontalGroup:getSize() return sumGroup(self, true) end
function HorizontalGroup:resetLayout() end
local VerticalGroup = class(WidgetContainer)
function VerticalGroup:getSize() return sumGroup(self, false) end
function VerticalGroup:resetLayout() end
local OverlapGroup = class(WidgetContainer)

local HorizontalSpan = class(Widget)
function HorizontalSpan:getSize() return Geom:new{ w = self.width or 0, h = 0 } end
local VerticalSpan = class(Widget)
function VerticalSpan:getSize() return Geom:new{ w = 0, h = self.width or 0 } end
local LineWidget = class(Widget)

local CenterContainer = class(WidgetContainer)
local LeftContainer = class(WidgetContainer)
local FrameContainer = class(WidgetContainer)
function FrameContainer:getSize()
    local s = self[1] and self[1]:getSize() or Geom:new()
    local pad = (self.bordersize or 0) + (self.padding or 0) + (self.margin or 0)
    return Geom:new{ w = s.w + 2 * pad, h = s.h + 2 * pad }
end

local TextWidget = class(Widget)
function TextWidget:getSize()
    local n = #(self.text or "")
    local w = n * 12
    if self.max_width and w > self.max_width then w = self.max_width end
    return Geom:new{ w = w, h = 40 }
end
function TextWidget:setText(t) self.text = t end
local TextBoxWidget = class(Widget)
function TextBoxWidget:getSize() return Geom:new{ w = self.width or 100, h = 80 } end

local Button = class(InputContainer)
function Button:init() self.dimen = Geom:new{ w = self.width or 100, h = 60 } end
function Button:enable() self.enabled = true end
function Button:disable() self.enabled = false end
local IconButton = class(InputContainer)
function IconButton:init()
    local p = self.padding or 0
    self.dimen = Geom:new{ w = (self.width or 40) + (self.padding_left or p) + (self.padding_right or p),
                           h = (self.height or 40) + 2 * p }
end

local TitleBar = class(OverlapGroup)
function TitleBar:init() self.dimen = Geom:new{ w = self.width or 1264, h = 90 } end
function TitleBar:getHeight() return 90 end

local ScrollHtmlWidget = class(InputContainer)
ScrollHtmlWidget.scroll_bar_width = 13
ScrollHtmlWidget.text_scroll_span = 26
function ScrollHtmlWidget:init()
    assert(type(self.html_body) == "string", "html_body must be a string")
    assert(type(self.css) == "string", "css must be a string")
    assert(self.dialog, "dialog is required by ScrollHtmlWidget:scrollText")
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.key_events = { ScrollDown = {}, ScrollUp = {} }
    Stubs.last_html = self
end
function ScrollHtmlWidget:setTapScrollEnabled(e) self.ignore_taps = not e end

local Menu = class(FocusManager)
function Menu:init()
    self.item_table = self.item_table or {}
    self.title_bar = self.custom_title_bar
    self.key_events = { Close = { { "Back" } }, NextPage = {}, PrevPage = {} }
end
function Menu:switchItemTable(_title, items, _n) if items then self.item_table = items end end
function Menu:onMenuSelect(item) if item.select_enabled == false then return true end if item.callback then item.callback() end return true end

-- Dialog-ish widgets: just remember them so tests can press their buttons.
local function dialog(kind)
    local D = class(InputContainer)
    D._kind = kind
    function D:init() self.kind = kind end
    return D
end
local ButtonDialog = dialog("ButtonDialog")
local ConfirmBox = dialog("ConfirmBox")
local InfoMessage = dialog("InfoMessage")
local SpinWidget = dialog("SpinWidget")
local ImageViewer = dialog("ImageViewer")
function ImageViewer:init()
    self.kind = "ImageViewer"
    if type(self.image) == "table" then
        self._images_list = self.image
        self._images_list_nb = self.images_list_nb or #self.image
        self._images_list_cur = 1
        self.image = self._images_list[1]()
    end
end
function ImageViewer:switchToImageNum(n) self._images_list_cur = n; self.image = self._images_list[n]() end
function ImageViewer:onClose() require("ui/uimanager"):close(self) return true end
function ImageViewer:onCloseWidget() end
local TouchMenu = dialog("TouchMenu")
local MultiInputDialog = dialog("MultiInputDialog")
function MultiInputDialog:getFields() return Stubs.login_fields or { "", "" } end
function MultiInputDialog:onShowKeyboard() end

local Notification = class(InputContainer)
Notification.SOURCE_ALWAYS_SHOW = 0x8000
function Notification:notify(text) table.insert(Stubs.notifications, text) return true end

-- UIManager with a real task queue (wall clock).
local UIManager = { _stack = {}, _tasks = {} }
function UIManager:show(w, mode)
    table.insert(self._stack, w)
    table.insert(Stubs.shown, w)
    if w.handleEvent then w:handleEvent({ handler = "onShow", args = pack() }) end
end
function UIManager:close(w)
    for i = #self._stack, 1, -1 do
        if self._stack[i] == w then
            table.remove(self._stack, i)
            if w.handleEvent then w:handleEvent({ handler = "onCloseWidget", args = pack() }) end
        end
    end
end
function UIManager:isShown(w) for _, x in ipairs(self._stack) do if x == w then return true end end return false end
function UIManager:scheduleIn(s, fn, ...) table.insert(self._tasks, { at = socket.gettime() + s, fn = fn, args = pack(...) }) end
function UIManager:nextTick(fn, ...) return self:scheduleIn(0, fn, ...) end
function UIManager:unschedule(fn)
    for i = #self._tasks, 1, -1 do if self._tasks[i].fn == fn then table.remove(self._tasks, i) end end
end
function UIManager:runTasks(max_seconds, until_fn)
    local deadline = socket.gettime() + (max_seconds or 1)
    while socket.gettime() < deadline do
        if until_fn and until_fn() then return true end
        local now = socket.gettime()
        local ran = false
        for i, t in ipairs(self._tasks) do
            if t.at <= now then
                table.remove(self._tasks, i)
                t.fn(unpack(t.args, 1, t.args.n))
                ran = true
                break
            end
        end
        if not ran then socket.sleep(0.02) end
    end
    return until_fn and until_fn() or false
end
function UIManager:broadcastEvent(ev)
    local copy = {}
    for i, w in ipairs(self._stack) do copy[i] = w end
    for i = #copy, 1, -1 do copy[i]:handleEvent(ev) end
    if Stubs.broadcast_hook then Stubs.broadcast_hook(ev) end
end
function UIManager:quit(code) self._quit_code = code or 0; return self._quit_code end
UIManager.setDirty = noop
UIManager.forceRePaint = noop
UIManager.widgetRepaint = noop
UIManager.widgetInvert = noop

local Event = {}
function Event:new(name, ...) return { handler = "on" .. name, args = pack(...), name = name } end

local Screen = {}
function Screen:getWidth() return 1264 end
function Screen:getHeight() return 1680 end
function Screen:getSize() return Geom:new{ w = 1264, h = 1680 } end
function Screen:scaleBySize(x) return math.ceil(x * (1264 / 600 + 1264 / 600) / 2) end
function Screen:isColorEnabled() return true end

local Device = {
    screen = Screen,
    input = { group = { PgFwd = { "RPgFwd", "LPgFwd" }, PgBack = { "RPgBack", "LPgBack" }, Back = { "Back" } } },
}
function Device:hasKeys() return true end
function Device:isTouchDevice() return true end

local Size = {
    border = { default = 3, thin = 2, button = 4, window = 4, thick = 5 },
    margin = { default = 11, small = 5 },
    padding = { default = 11, small = 5, large = 22, button = 5 },
    radius = { default = 5, window = 15, button = 15 },
    line = { thin = 2, medium = 3, thick = 4 },
    span = { horizontal_default = 22, horizontal_small = 11, vertical_default = 5 },
}

local Blitbuffer = {
    COLOR_WHITE = { "white" }, COLOR_BLACK = { "black" }, COLOR_DARK_GRAY = { "dgray" },
}
function Blitbuffer.colorFromString(s) return { s } end

local Font = {}
function Font:getFace(name, size) return { name = name, orig_size = size } end

local time = {}
function time.now() return math.floor(socket.gettime() * 1e6) end
function time.s(s) return math.floor(s * 1e6) end
function time.ms(ms) return math.floor(ms * 1e3) end
function time.since(t) return time.now() - t end
function time.to_ms(t) return math.floor(t / 1000 + 0.5) end

local function template(str, ...)
    local params = { ... }
    return (str:gsub("%%(%d)", function(i) return tostring(params[tonumber(i)]) end))
end

local LuaSettings = {}
LuaSettings.__index = LuaSettings
function LuaSettings:open(path) return setmetatable({ file = path, data = {} }, LuaSettings) end
function LuaSettings:readSetting(k) return self.data[k] end
function LuaSettings:saveSetting(k, v) self.data[k] = v end
function LuaSettings:delSetting(k) self.data[k] = nil end
function LuaSettings:flush() end

local NetworkMgr = {}
function NetworkMgr:isConnected() return true end
function NetworkMgr:isOnline() return true end
function NetworkMgr:runWhenOnline(cb) cb() end

local util = {}
function util.trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end
function util.makePath(p) os.execute("mkdir -p '" .. p .. "'") return true end
function util.arrayContains(t, v) for i, x in ipairs(t) do if x == v then return i end end return false end

G_defaults = { readSetting = function(_, k) if k == "DGENERIC_ICON_SIZE" then return 40 end end } -- luacheck: ignore
G_reader_settings = { -- luacheck: ignore
    readSetting = function() return nil end,
    isTrue = function() return false end,
    isFalse = function() return false end,
    nilOrTrue = function() return true end,
}

local modules = {
    ["device"] = Device,
    ["dispatcher"] = { registerAction = noop },
    ["datastorage"] = { getSettingsDir = function() return Stubs.settings_dir or "/tmp" end },
    ["luasettings"] = LuaSettings,
    ["ffi/blitbuffer"] = Blitbuffer,
    ["ffi/util"] = { template = template },
    ["ffi/posix_h"] = (function() require("ffi").cdef("int getpid(void);") return {} end)(),
    ["libs/libkoreader-lfs"] = require("lfs"),
    ["util"] = util,
    ["ui/event"] = Event,
    ["ui/font"] = Font,
    ["ui/geometry"] = Geom,
    ["ui/gesturerange"] = { new = function(_, o) return o end },
    ["ui/size"] = Size,
    ["ui/time"] = time,
    ["ui/uimanager"] = UIManager,
    ["ui/network/manager"] = NetworkMgr,
    ["ui/widget/button"] = Button,
    ["ui/widget/buttondialog"] = ButtonDialog,
    ["ui/widget/confirmbox"] = ConfirmBox,
    ["ui/widget/container/centercontainer"] = CenterContainer,
    ["ui/widget/container/framecontainer"] = FrameContainer,
    ["ui/widget/container/inputcontainer"] = InputContainer,
    ["ui/widget/container/leftcontainer"] = LeftContainer,
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    ["ui/widget/horizontalgroup"] = HorizontalGroup,
    ["ui/widget/horizontalspan"] = HorizontalSpan,
    ["ui/widget/iconbutton"] = IconButton,
    ["ui/widget/imageviewer"] = ImageViewer,
    ["ui/widget/infomessage"] = InfoMessage,
    ["ui/widget/linewidget"] = LineWidget,
    ["ui/widget/menu"] = Menu,
    ["ui/widget/multiinputdialog"] = MultiInputDialog,
    ["ui/widget/notification"] = Notification,
    ["ui/widget/scrollhtmlwidget"] = ScrollHtmlWidget,
    ["ui/widget/spinwidget"] = SpinWidget,
    ["ui/widget/textboxwidget"] = TextBoxWidget,
    ["ui/widget/textwidget"] = TextWidget,
    ["ui/widget/titlebar"] = TitleBar,
    ["ui/widget/touchmenu"] = TouchMenu,
    ["ui/widget/verticalgroup"] = VerticalGroup,
    ["ui/widget/verticalspan"] = VerticalSpan,
    ["ui/elements/filemanager_menu_order"] = { main = { "history", "exit_menu" } },
    ["ui/elements/reader_menu_order"] = { main = { "history", "exit_menu" } },
}
for name, mod in pairs(modules) do
    package.preload[name] = function() return mod end
end

Stubs.UIManager = UIManager
function Stubs.lastShown(kind)
    for i = #Stubs.shown, 1, -1 do
        local w = Stubs.shown[i]
        if UIManager:isShown(w) then
            if w.kind == kind then return w, w end
            if w[1] and w[1].kind == kind then return w[1], w end
        end
    end
end
return Stubs

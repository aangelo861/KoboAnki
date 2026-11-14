--[[--
Deck list: a full-screen KOReader Menu (so paging, page keys and swipes behave like the rest of
KOReader) with a custom header:

  [≡]                    Anki                        [X]
  Last sync: 5 min ago · me@example.com          [ Sync ]
  ----------------------------------------------------------
  Medicine                                  3 · 1 · 12
    ▾ Paper B                               0 · 2 · 5
        Cardiology                          0 · 0 · 3

Rows are indented by depth; the right column is "new · learn · due". Tap a deck to study it,
long-press a parent deck to collapse/expand it (local to this device, for this session).
Decks with nothing due are greyed.

All behaviour (open deck, sync, close) is delegated to `app` (kanki/app.lua).
]]

local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local Screen = Device.screen

---------------------------------------------------------------------------------------------------
-- Header used as Menu's custom_title_bar. Implements the bits of TitleBar's interface Menu uses:
-- getHeight(), getSize(), paintTo(), generateVerticalLayout(), setTitle(), setSubTitle().

local DeckHeader = WidgetContainer:extend{
    width = nil,
    show_parent = nil,
    on_menu = nil,
    on_close = nil,
    on_sync = nil,
}

function DeckHeader:init()
    self.title_bar = TitleBar:new{
        width = self.width,
        fullscreen = true,
        align = "center",
        title = _("Anki"),
        left_icon = "appbar.menu",
        left_icon_tap_callback = function()
            if self.on_menu then self.on_menu() end
        end,
        close_callback = function()
            if self.on_close then self.on_close() end
        end,
        show_parent = self.show_parent,
    }
    local pad = Size.padding.large
    self.sync_button = Button:new{
        text = _("Sync"),
        width = Screen:scaleBySize(120),
        text_font_size = 20,
        bordersize = Size.border.button,
        radius = Size.radius.button,
        callback = function()
            if self.on_sync then self.on_sync() end
        end,
        show_parent = self.show_parent,
    }
    local button_size = self.sync_button:getSize()
    local status_w = self.width - button_size.w - 3 * pad
    self._status_text = " "
    self.status_widget = TextWidget:new{
        text = self._status_text,
        face = Font:getFace("x_smallinfofont", 17),
        max_width = status_w,
    }
    local status_row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = pad },
        LeftContainer:new{
            dimen = Geom:new{ w = status_w, h = button_size.h },
            self.status_widget,
        },
        HorizontalSpan:new{ width = pad },
        self.sync_button,
        HorizontalSpan:new{ width = pad },
    }
    -- TitleBar's corner icons have extended tap zones (padding_bottom = icon size) that overflow
    -- below TitleBar:getHeight(). Without this spacer, a tap on the top edge of our Sync button
    -- (under the X) would hit Close, i.e. exit KOReader when autostarted.
    local overflow = 0
    for _, b in ipairs({ self.title_bar.left_button, self.title_bar.right_button }) do
        if b then
            overflow = math.max(overflow, b:getSize().h - self.title_bar:getHeight())
        end
    end
    local group = VerticalGroup:new{
        align = "left",
        self.title_bar,
        VerticalSpan:new{ width = overflow },
        status_row,
        VerticalSpan:new{ width = Size.padding.default },
        LineWidget:new{ dimen = Geom:new{ w = self.width, h = Size.line.thick } },
    }
    self[1] = group
    local size = group:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = size.h }
end

function DeckHeader:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function DeckHeader:getHeight()
    return self.dimen.h
end

function DeckHeader:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    self[1]:paintTo(bb, x, y)
end

function DeckHeader:generateVerticalLayout()
    return {}
end

function DeckHeader:generateHorizontalLayout()
    return {}
end

function DeckHeader:setTitle() end
function DeckHeader:setSubTitle() end
function DeckHeader:setLeftIcon() end

function DeckHeader:setStatus(text)
    if not text or text == "" then
        text = " "
    end
    if text == self._status_text then return end
    self._status_text = text
    self.status_widget:setText(text)
    UIManager:setDirty(self.show_parent, "ui", self.dimen)
end

---------------------------------------------------------------------------------------------------

local DeckList = Menu:extend{
    name = "kanki_decklist",
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    single_line = true,
    app = nil, -- kanki/app.lua
}

function DeckList:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.collapsed_override = {}
    self.decks = nil
    self.header = DeckHeader:new{
        width = self.width,
        show_parent = self,
        on_menu = function() self.app:showDeckListMenu() end,
        on_close = function() self:onKankiUserClose() end,
        on_sync = function() self.app:syncNow() end,
    }
    self.custom_title_bar = self.header
    self.item_table = self:_placeholderItems(_("Starting Anki…"))
    Menu.init(self)
    -- Menu binds the Back key to "Close". But "Close" is also *broadcast* by KOReader at power off,
    -- reboot and USB mass storage, where we must just get out of the way (not run the
    -- exit-to-Kobo logic). So the user's Back key gets its own event name.
    if self.key_events.Close then
        self.key_events.KankiUserClose = self.key_events.Close
        self.key_events.Close = nil
    end
end

function DeckList:setStatus(text)
    self.header:setStatus(text)
end

function DeckList:_placeholderItems(text, callback)
    return {
        {
            text = text,
            dim = callback == nil,
            select_enabled = callback ~= nil,
            callback = callback,
        },
    }
end

--- Replace the list with a single message row (optionally tappable).
function DeckList:showPlaceholder(text, callback)
    self.decks = nil
    self:switchItemTable(nil, self:_placeholderItems(text, callback))
end

function DeckList:_isCollapsed(deck)
    local override = self.collapsed_override[deck.id]
    if override ~= nil then
        return override
    end
    return deck.collapsed and true or false
end

local INDENT = "\u{2003}" -- em space
local function countsText(deck)
    return string.format("%d · %d · %d", tonumber(deck.new) or 0, tonumber(deck.learning) or 0,
        tonumber(deck.review) or 0)
end

function DeckList:_deckItem(deck, collapsed)
    local depth = tonumber(deck.depth) or 0
    local marker = ""
    if deck.has_children then
        marker = collapsed and "▸ " or "▾ "
    end
    local due = (tonumber(deck.new) or 0) + (tonumber(deck.learning) or 0) + (tonumber(deck.review) or 0)
    return {
        text = string.rep(INDENT, depth) .. marker .. (deck.short_name or deck.name or "?"),
        mandatory = countsText(deck),
        bold = deck.id == self.current_id,
        dim = due == 0,
        deck = deck,
        callback = function()
            self.app:openDeck(deck)
        end,
    }
end

function DeckList:_rebuild(keep_page)
    local items = {}
    local hide_below
    for _, deck in ipairs(self.decks or {}) do
        local depth = tonumber(deck.depth) or 0
        if hide_below and depth > hide_below then -- luacheck: ignore 542
            -- inside a collapsed parent
        else
            hide_below = nil
            local collapsed = self:_isCollapsed(deck)
            if deck.has_children and collapsed then
                hide_below = depth
            end
            table.insert(items, self:_deckItem(deck, collapsed))
        end
    end
    if #items == 0 then
        items = self:_placeholderItems(_("No decks."))
    end
    self:switchItemTable(nil, items, keep_page and -1 or nil)
end

--- Show a GET /decks body.
function DeckList:setDecks(body, keep_page)
    self.decks = body.decks or {}
    self.current_id = body.current_id
    self:_rebuild(keep_page)
end

-- Long-press: collapse/expand a parent deck.
function DeckList:onMenuHold(item)
    local deck = item and item.deck
    if deck and deck.has_children then
        self.collapsed_override[deck.id] = not self:_isCollapsed(deck)
        self:_rebuild(true)
    end
    return true
end

-- Title bar X / Back key: let the app decide (close, or exit to Kobo when autostarted).
function DeckList:onKankiUserClose()
    self.app:onDeckListClose()
    return true
end

function DeckList:closeWidget()
    if self.app and self.app.decklist == self then
        self.app.decklist = nil
    end
    UIManager:close(self, "flashui")
end

-- KOReader is quitting (Exit), powering off / rebooting / entering USB mass storage (Close):
-- just get off the window stack so UIManager can exit. Don't return true: these are broadcasts.
function DeckList:onExit()
    if self.app and self.app.decklist == self then
        self.app.decklist = nil
    end
    UIManager:close(self)
end
DeckList.onClose = DeckList.onExit

return DeckList

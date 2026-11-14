--[[
Brightness/warmth from the reviewer (Libra Colour has a frontlight with warmth):
  * top bar ☼ button opens KOReader's light dialog (Device:showLightDialog)
  * a vertical swipe starting in the left 10 % changes brightness, in the right 10 % warmth, via KOReader's
    own DeviceListener handlers (north = up, south = down)
  * swipes elsewhere, horizontal swipes, swipes on the top bar and taps are NOT taken (cards still scroll,
    flip and rate); setting off -> nothing is taken; a device without warmth ignores the right edge

  KANKI_TEST_QUIET=1 luajit test_light.lua      (LUA_PATH/LUA_CPATH as in README.md)
]]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local abs_here = io.popen("cd '" .. here .. "' && pwd"):read("*l")
package.path = table.concat({
    abs_here .. "/stubs/?.lua",
    abs_here .. "/../kanki.koplugin/?.lua",
    package.path,
}, ";")

local Stubs = require("koreader_stubs")
require("pomodoro_stubs")
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p '" .. tmp .. "'")
Stubs.settings_dir = tmp

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local Settings = require("kanki/settings")
Settings:set("data_dir", tmp .. "/data")
local Client = require("kanki/client")

-- Frontlight hardware + KOReader's DeviceListener, recorded.
local calls = {}
local natural_light = true
function Device:hasFrontlight() return true end
function Device:hasNaturalLight() return natural_light end
function Device:showLightDialog() table.insert(calls, "dialog") end
package.loaded["device/devicelistener"] = {
    onChangeFlIntensity = function(_, ges, dir) table.insert(calls, "intensity " .. dir .. " " .. ges.direction) end,
    onChangeFlWarmth = function(_, ges, dir) table.insert(calls, "warmth " .. dir .. " " .. ges.direction) end,
}

local passed, failed = 0, 0
local function check(cond, what, detail)
    if cond then passed = passed + 1; print("ok   " .. what)
    else failed = failed + 1; print("FAIL " .. what .. (detail ~= nil and (": " .. tostring(detail)) or "")) end
end

local function card(id)
    return { id = id, note_id = id + 1, deck = "Medicine", kind = "review", ord = 1, flag = 0, css = "",
             question = "<p>Q</p>", answer = "<p>Q</p><hr id=answer><p>A</p>",
             buttons = { { rating = 1, label = "Again", interval = "<1m" }, { rating = 2, label = "Hard", interval = "6m" },
                         { rating = 3, label = "Good", interval = "10m" }, { rating = 4, label = "Easy", interval = "4d" } } }
end
Client.nextCard = function() return { state = "card", counts = { new = 1, learning = 0, review = 2 }, card = card(1) } end

local Reviewer = require("kanki/reviewer")
local r = Reviewer:new{ deck_name = "Medicine" }
r:onShow()

local W, H = r.screen_w, r.screen_h
local function swipe(x, y, direction)
    calls = {}
    local handled = r:handleEvent(Event:new("Gesture", {
        ges = "swipe", direction = direction, distance = 400, pos = Geom:new{ x = x, y = y, w = 0, h = 0 },
    }))
    return handled, calls[1]
end

-- ☼ button
local function findLightButton(w)
    if type(w) ~= "table" then return nil end
    if w.text == "☼" and w.callback then return w end
    for _, child in ipairs(w) do
        local found = findLightButton(child)
        if found then return found end
    end
    if w.content then return findLightButton(w.content) end
    if w[1] == nil and w.widget then return findLightButton(w.widget) end
end
local button = findLightButton(r.top_slot)
check(button ~= nil, "top bar has a ☼ light button")
if button then
    calls = {}
    button.callback()
    check(calls[1] == "dialog", "☼ opens KOReader's light dialog", calls[1])
end

local mid_y = math.floor(H / 2)
local h, c = swipe(20, mid_y, "north")
check(h and c == "intensity 1 north", "left-edge swipe up raises brightness", c)
h, c = swipe(20, mid_y, "south")
check(h and c == "intensity -1 south", "left-edge swipe down lowers brightness", c)
h, c = swipe(W - 20, mid_y, "north")
check(h and c == "warmth 1 north", "right-edge swipe up warms the light", c)
h, c = swipe(W - 20, mid_y, "south")
check(h and c == "warmth -1 south", "right-edge swipe down cools the light", c)

h, c = swipe(math.floor(W / 2), mid_y, "north")
check(not c, "swipe in the middle is left to the card (scrolling)", c)
h, c = swipe(20, mid_y, "east")
check(not c, "horizontal swipe on the edge is not taken", c)
h, c = swipe(20, 5, "south")
check(not c, "swipe starting on the top bar is not taken", c)

calls = {}
r:handleEvent(Event:new("Gesture", { ges = "tap", pos = Geom:new{ x = 20, y = mid_y, w = 0, h = 0 } }))
check(calls[1] == nil, "a tap on the edge is not a light change (cards still flip)")

natural_light = false
h, c = swipe(W - 20, mid_y, "north")
check(not c, "no warmth control on a device without natural light", c)
natural_light = true

Settings:set("edge_swipe_light", false)
h, c = swipe(20, mid_y, "north")
check(not c, "setting off: edge swipes are left alone", c)
Settings:set("edge_swipe_light", nil)

print(string.format("\n[light] %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

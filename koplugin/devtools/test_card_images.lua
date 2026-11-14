--[[
Viewing a card's images (kanki/cardimages.lua, kanki/cardimageviewer.lua, Reviewer:showImages):
  * <img> tags are linked and their src collected; image-occlusion pictures stay unlinked on the question side
  * src rules match the server's (entities, percent-encoding, no leaving the media folder, data: base64)
  * reviewer: a tap on an image opens the viewer, other links still show the answer, the Image button appears
    only on cards with images, closing brings back the card, and page keys never rate through the viewer

  KANKI_TEST_QUIET=1 luajit test_card_images.lua      (LUA_PATH/LUA_CPATH as in README.md)
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
os.execute("mkdir -p '" .. tmp .. "/media'")
Stubs.settings_dir = tmp

local passed, failed = 0, 0
local function check(cond, what, detail)
    if cond then
        passed = passed + 1
        if os.getenv("KANKI_TEST_QUIET") ~= "1" then print("ok   " .. what) end
    else
        failed = failed + 1
        print("FAIL " .. what .. (detail ~= nil and (": " .. tostring(detail)) or ""))
    end
end

local function touch(name)
    local f = assert(io.open(tmp .. "/media/" .. name, "wb"))
    f:write("x")
    f:close()
end
touch("ecg 1.png")
touch("a&b.jpg")

local CardImages = require("kanki/cardimages")
local media = tmp .. "/media"

-- prepare ------------------------------------------------------------------------------------------
local html, images = CardImages.prepare('<p>x</p><img src="a.png" width="3"><IMG alt=q SRC=\'b.jpg\'/><img data-src="no">')
check(#images == 2 and images[1] == "a.png" and images[2] == "b.jpg", "src of each image collected", #images)
check(html:find('<a class="kanki-img" href="kanki:image:1"><img src="a.png" width="3"></a>', 1, true) ~= nil, "image wrapped in its link")
check(html:find('href="kanki:image:2"', 1, true) ~= nil, "second image numbered 2")
check(html:find('<img data-src="no">', 1, true) ~= nil and not html:find("kanki:image:3", 1, true), "an img without src is left alone")
local plain = "<p>no pictures</p>"
html, images = CardImages.prepare(plain)
check(html == plain and #images == 0, "no images: html untouched")
html, images = CardImages.prepare(nil)
check(html == nil and #images == 0, "nil side")

local io_html = '<div class="kanki-io"><img src="data:image/png;base64,QUJD" width="9" alt=""></div>'
html, images = CardImages.prepare(io_html, { link_occlusion = false })
check(html == io_html and #images == 1, "occlusion picture stays unlinked on the question side")
html = CardImages.prepare(io_html, { link_occlusion = true })
check(html:find("kanki:image:1", 1, true) ~= nil, "occlusion picture linked on the answer side")
local big = '<img src="data:image/jpeg;base64,' .. string.rep("QUJD", 250000) .. '">'
html, images = CardImages.prepare(big)
check(#images == 1 and #html > #big, "1 MB inline image is handled")

check(CardImages.linkIndex("kanki:image:12") == 12, "link index")
check(CardImages.linkIndex("https://x.org") == nil and CardImages.linkIndex(nil) == nil, "other links are not ours")

-- resolve ------------------------------------------------------------------------------------------
local function file(src)
    local r = CardImages.resolve(src, media)
    return r and r.file
end
check(file("ecg 1.png") == media .. "/ecg 1.png", "plain name")
check(file("ecg%201.png") == media .. "/ecg 1.png", "percent-encoded name")
check(file("a&amp;b.jpg") == media .. "/a&b.jpg", "entity-encoded name")
check(file("./ecg 1.png") == media .. "/ecg 1.png", "leading ./")
check(file("missing.png") == nil, "missing file")
check(file("https://x.org/a.png") == nil and file("//x.org/a.png") == nil, "remote images are not viewable")
check(file("../ecg 1.png") == nil and file("sub/ecg 1.png") == nil and file("%2e%2e%2fecg 1.png") == nil, "cannot leave the media folder")
local item = CardImages.resolve("data:image/png;base64,QUJD", media)
check(item and item.data_uri and CardImages.decode(item) == "ABC", "inline image decoded")
check(CardImages.resolve("data:image/svg+xml,<svg/>", media) == nil, "non-base64 data: is not viewable")
local list, start = CardImages.viewable({ "missing.png", "ecg 1.png", "a&amp;b.jpg" }, media, 3)
check(#list == 2 and start == 2, "viewable list skips missing files and maps the tapped image", start)
list, start = CardImages.viewable({ "missing.png", "ecg 1.png" }, media, 1)
check(#list == 1 and start == 1, "tapped image missing: opens the first viewable")

-- Reviewer ------------------------------------------------------------------------------------------
local rendered = {}
package.loaded["ui/renderimage"] = {
    renderImageFile = function(_, path) table.insert(rendered, path); return { file = path, free = function() end } end,
    renderImageData = function(_, bytes) table.insert(rendered, bytes); return { free = function() end } end,
    renderCheckerboard = function() return { checker = true } end,
}
local Settings = require("kanki/settings")
Settings:set("data_dir", tmp .. "/data")
local Client = require("kanki/client")
local Server = require("kanki/server")
Server.mediaDir = function() return media end
local UIManager = Stubs.UIManager
UIManager.setDirty = function() end
UIManager.forceRePaint = function() end
UIManager.widgetRepaint = function() end
UIManager.getTopmostVisibleWidget = function(self) return self._stack[#self._stack] end

local rated = {}
local function card(id, q, a)
    return { id = id, note_id = id + 1, deck = "Medicine", kind = "review", ord = 1, flag = 0, css = "",
             question = q, answer = a,
             buttons = { { rating = 1, label = "Again", interval = "<1m" }, { rating = 3, label = "Good", interval = "10m" } } }
end
local current = card(1, '<p>Which?</p><img src="ecg 1.png"><img src="a&amp;b.jpg">', '<p>Sinus</p><img src="ecg 1.png">')
Client.nextCard = function() return { state = "card", counts = { new = 1, learning = 0, review = 2 }, card = current } end
Client.answer = function(_, _, rating) table.insert(rated, rating); return { state = "done", counts = {} } end

local Reviewer = require("kanki/reviewer")
local r = Reviewer:new{ deck_name = "Medicine" }
UIManager:show(r)
r:loadNext()
check(r.state == "question" and #r.card_images == 2, "reviewer sees the question's two images", r.state)

local function findButton(w, text)
    if type(w) ~= "table" then return nil end
    if w.text == text and w.callback then return w end
    for _, child in ipairs(w) do
        local found = findButton(child, text)
        if found then return found end
    end
end
check(findButton(r.top_slot, "Image") ~= nil, "Image button on a card with images")
check(Stubs.last_html.html_body:find("kanki:image:2", 1, true) ~= nil, "images linked in the card html")
check(type(Stubs.last_html.html_link_tapped_callback) == "function", "link taps reach the reviewer")

r.ready_at = 0
Stubs.last_html.html_link_tapped_callback({ uri = "kanki:image:2" })
local viewer = r.image_viewer
check(viewer ~= nil and UIManager:isShown(viewer), "tap on an image opens the viewer")
check(viewer and viewer._images_list_cur == 2 and viewer._images_list_nb == 2, "opens at the tapped image")
check(r.state == "question", "the card is still on its question")
check(viewer.fullscreen and viewer.with_title_bar and viewer.buttons_visible, "fullscreen, with ✕ and the Close button showing")
Stubs.last_html.html_link_tapped_callback({ uri = "kanki:image:1" })
check(r.image_viewer == viewer, "no second viewer on top")

local stack_before = #UIManager._stack
viewer:onKeyRepeat()
check(viewer._images_list_cur == 2 and #UIManager._stack == stack_before, "held key does nothing")
viewer:onKankiImagePrev()
check(viewer._images_list_cur == 1, "page back: previous image")
viewer:onKankiImageNext()
check(viewer._images_list_cur == 2, "page forward: next image")
viewer:onKankiImageNext()
check(not UIManager:isShown(viewer) and r.image_viewer == nil, "past the last image a page key closes it")
check(#rated == 0, "page keys in the viewer never rate")
check(r.ready_at > 0 and not r:_inputReady(), "input guard after closing")
r:_pageKey(true)
check(r.state == "question" and #rated == 0, "the closing press can't flip or rate the card")

r.ready_at = 0
r:showImages(1)
viewer = r.image_viewer
check(viewer ~= nil and viewer._images_list_cur == 1, "Image button opens the first image")
viewer:onClose()
check(r.image_viewer == nil and not UIManager:isShown(viewer), "Close closes it")
check(UIManager:isShown(r) and r.state == "question", "back on the same card")

r.ready_at = 0
Stubs.last_html.html_link_tapped_callback({ uri = "https://example.org" })
check(r.state == "answer", "an ordinary link still acts as a tap: shows the answer")
check(#r.card_images == 1, "answer side has its own image list")
check(findButton(r.top_slot, "Image") ~= nil, "Image button on the answer side")
r.ready_at = 0
r:showImages(1)
check(r.image_viewer ~= nil, "viewer opens from the answer")
r.image_viewer:onClose()

-- A card without images, and an image not synced yet.
current = card(2, "<p>Words</p>", "<p>Only</p>")
r.ready_at = 0
r:loadNext()
check(findButton(r.top_slot, "Image") == nil, "no Image button without images")
r:showImages(1)
check(r.image_viewer == nil, "nothing to open")
current = card(3, '<img src="later.png">', "<p>A</p>")
r.ready_at = 0
r:loadNext()
Stubs.notifications = {}
r.ready_at = 0
r:showImages(1)
check(r.image_viewer == nil and Stubs.notifications[1] and Stubs.notifications[1]:find("isn't on the Kobo", 1, true), "image not synced yet: a message, no viewer")

-- Leaving the reviewer closes the viewer.
current = card(4, '<img src="ecg 1.png">', "<p>A</p>")
r.ready_at = 0
r:loadNext()
r.ready_at = 0
r:showImages(1)
viewer = r.image_viewer
r:_teardown()
check(not UIManager:isShown(viewer) and r.image_viewer == nil, "teardown closes the viewer")

os.execute("rm -rf '" .. tmp .. "'")
print(string.format("\n[card_images] %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

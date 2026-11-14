--[[--
Full-screen viewer for a card's images: KOReader's ImageViewer (pinch to zoom, drag to pan, Original
size, Rotate), with what the reviewer needs on top:

* Closing is always in sight: ✕ in the title bar and the Close button (buttons shown from the start).
* Page buttons: next / previous image; past the last (or first) image they close the viewer. They
  must never fall through to the reviewer, where they rate the card.
* Each image is decoded when it is shown and freed when it's replaced.
]]

local CardImages = require("kanki/cardimages")
local Device = require("device")
local ImageViewer = require("ui/widget/imageviewer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local function titleFor(n, total)
    if total <= 1 then return _("Card image") end
    return T(_("Card image %1 of %2"), n, total)
end

local function loader(item)
    return function()
        local RenderImage = require("ui/renderimage")
        local ok, bb = pcall(function()
            if item.file then
                return RenderImage:renderImageFile(item.file, false)
            end
            local bytes = CardImages.decode(item)
            return RenderImage:renderImageData(bytes, #bytes, false)
        end)
        if ok and bb then return bb end
        logger.warn("kanki: could not decode card image", item.file or "(inline)", ok and "" or bb)
        return RenderImage:renderCheckerboard(400, 400)
    end
end

local CardImageViewer = ImageViewer:extend{
    name = "kanki_image_viewer",
    fullscreen = true,
    with_title_bar = true,
    buttons_visible = true,
    images_keep_pan_and_zoom = false, -- each image starts fitted to the screen
    start_index = 1,
    on_close = nil, -- function(): the viewer left the screen
}

function CardImageViewer:init()
    ImageViewer.init(self)
    if Device:hasKeys() then
        local group = Device.input.group
        self.key_events = {
            Close = { { group.Back } },
            KankiImageNext = { { group.PgFwd } },
            KankiImagePrev = { { group.PgBack } },
        }
    end
    if self.start_index > 1 then
        self:switchToImageNum(self.start_index)
    end
end

function CardImageViewer:switchToImageNum(n)
    if n ~= self._images_list_cur and self.title_bar then
        self.title_bar:setTitle(titleFor(n, self._images_list_nb), true)
    end
    ImageViewer.switchToImageNum(self, n)
end

function CardImageViewer:_step(delta)
    local n = self._images_list_cur + delta
    if n < 1 or n > self._images_list_nb then
        self:onClose()
    else
        self:switchToImageNum(n)
    end
    return true
end

function CardImageViewer:onKankiImageNext() return self:_step(1) end
function CardImageViewer:onKankiImagePrev() return self:_step(-1) end

-- Holding a page key must not run through the images and on into the reviewer.
function CardImageViewer:onKeyRepeat() return true end

function CardImageViewer:onCloseWidget()
    ImageViewer.onCloseWidget(self)
    if self.on_close then self.on_close() end
end

--- @param items list from CardImages.viewable (at least one)
function CardImageViewer.forItems(items, start, on_close)
    local images = { image_disposable = true }
    for i, item in ipairs(items) do
        images[i] = loader(item)
    end
    return CardImageViewer:new{
        image = images,
        images_list_nb = #items,
        title_text = titleFor(start, #items),
        start_index = start,
        on_close = on_close,
    }
end

return CardImageViewer

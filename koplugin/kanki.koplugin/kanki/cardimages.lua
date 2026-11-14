--[[--
Images in a card side, for the full-screen viewer (kanki/cardimageviewer.lua).

prepare() wraps each <img> of the HTML in a link `kanki:image:N`, so a tap on the picture reaches the
reviewer: MuPDF gives a link the box of what's inside it. Image-occlusion cards come from the server
as one picture filling the card (<div class="kanki-io"><img …>): on the question side that picture
stays unlinked, because a tap on the card must still show the answer there.

resolve() follows the server's rules for `src` (kanki_html/src/media.rs, resolve_media): entity- and
percent-decoded names directly inside the media folder, `data:image/…;base64` inline. Remote URLs and
anything that could leave the media folder are not viewable.

Files are looked up only when the viewer opens: stat-by-name is slow on FAT32 (CLAUDE.md, gotcha 7)
and most cards are never opened in it.
]]

local lfs = require("libs/libkoreader-lfs")

local CardImages = {}

local IO_PREFIX = '<div class="kanki-io">'
local NAMED = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function utf8Char(c)
    if c < 0x80 then return string.char(c) end
    if c < 0x800 then return string.char(0xC0 + math.floor(c / 64), 0x80 + c % 64) end
    if c < 0x10000 then
        return string.char(0xE0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
    end
    return string.char(0xF0 + math.floor(c / 262144), 0x80 + math.floor(c / 4096) % 64,
        0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
end

local function decodeEntities(s)
    return (s:gsub("&(#?%w+);", function(e)
        local code
        if e:sub(1, 2):lower() == "#x" then
            code = tonumber(e:sub(3), 16)
        elseif e:sub(1, 1) == "#" then
            code = tonumber(e:sub(2))
        else
            return NAMED[e]
        end
        if code and code > 0 and code <= 0x10FFFF then return utf8Char(code) end
    end))
end

local function percentDecode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function attrSrc(tag)
    -- %f[%w%-]: not the end of "data-src".
    local prefix = "%f[%w%-][sS][rR][cC]%s*=%s*"
    return tag:match(prefix .. '"([^"]*)"') or tag:match(prefix .. "'([^']*)'") or tag:match(prefix .. "([^%s/>]+)")
end

--[[--
@string html a card side
@tparam table opts { link_occlusion = bool } link image-occlusion pictures too (answer side)
@treturn string html with the images linked
@treturn table the raw `src` of every image, in order (N in `kanki:image:N` is an index into it)
]]
function CardImages.prepare(html, opts)
    local images = {}
    if not html or not html:find("<[iI][mM][gG][%s/]") then
        return html, images
    end
    local out = html:gsub("()(<[iI][mM][gG][%s/][^>]*>)", function(pos, tag)
        local src = attrSrc(tag)
        if not src or src == "" then return nil end
        images[#images + 1] = src
        if not (opts and opts.link_occlusion)
                and html:sub(math.max(1, pos - #IO_PREFIX), pos - 1) == IO_PREFIX then
            return nil
        end
        return '<a class="kanki-img" href="kanki:image:' .. #images .. '">' .. tag .. "</a>"
    end)
    return out, images
end

--- The image number of a link from prepare(), or nil for any other link.
function CardImages.linkIndex(uri)
    return tonumber(type(uri) == "string" and uri:match("^kanki:image:(%d+)$") or nil)
end

local function safeName(n)
    return n ~= "" and n ~= "." and n ~= ".." and not n:find("[/\\%z]")
end

--- Where an image's bytes are: { file = path }, { data_uri = uri }, or nil if not viewable.
function CardImages.resolve(src, media_dir)
    local s = trim(src)
    if s:sub(1, 11):lower() == "data:image/" then
        local comma = s:find(",", 1, true)
        if comma and s:sub(1, comma - 1):lower():find(";base64", 1, true) then
            return { data_uri = s, comma = comma }
        end
        return nil
    end
    s = trim(decodeEntities(s))
    if s == "" or s:find(":", 1, true) or s:sub(1, 2) == "//" or not media_dir then
        return nil
    end
    for _, candidate in ipairs({ s, percentDecode(s) }) do
        local name = candidate:gsub("^%./", "")
        if safeName(name) then
            local path = media_dir .. "/" .. name
            if lfs.attributes(path, "mode") == "file" then
                return { file = path }
            end
        end
    end
    return nil
end

--[[--
The images that can actually be shown.
@treturn table list of resolve() results
@treturn int position in that list of image number `wanted` (1 if that one isn't viewable)
]]
function CardImages.viewable(images, media_dir, wanted)
    local list, start = {}, 1
    for i, src in ipairs(images or {}) do
        local item = CardImages.resolve(src, media_dir)
        if item then
            list[#list + 1] = item
            if i == wanted then start = #list end
        end
    end
    return list, start
end

local function unbase64(text)
    if text:find("%s") then text = text:gsub("%s+", "") end
    local ok, mime = pcall(require, "mime")
    if ok and type(mime) == "table" and mime.unb64 then
        return (mime.unb64(text))
    end
    return require("ffi/sha2").base64_to_bin(text)
end

--- The decoded bytes of a { data_uri } item.
function CardImages.decode(item)
    return unbase64(item.data_uri:sub(item.comma + 1))
end

return CardImages

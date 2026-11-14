--[[--
Prepare a card side (HTML fragment + note-type CSS from the server) for KOReader's MuPDF HTML engine.

Units, worked out from the installed KOReader source:

* HtmlBoxWidget:setContent() calls `document:layoutDocument(dimen.w, dimen.h, default_font_size)`
  and HtmlBoxWidget:_render() draws with `DrawContext.new()`, i.e. zoom 1.0. MuPDF lays HTML out in
  points and, at zoom 1.0, 1 layout unit = 1 framebuffer pixel. MuPDF's CSS parser treats `px` and
  `pt` as that same unit (KOReader says so in DictQuickLookup:getHtmlDictionaryCss(): "MuPDF doesn't
  currently scale CSS pixels"), `em` is relative to `default_font_size` (device px), and `rem` is
  hard-wired to 16 units.
  => In this engine, 1 CSS px == 1 device pixel. The card content width in CSS px (what the server's
     `img_max_px` wants) is therefore simply the HtmlBoxWidget width in device pixels, which is
     ScrollHtmlWidget.width - scroll_bar_width - text_scroll_span (see reviewer.lua).

* Anki note-type CSS is written for desktop/web CSS px (96 dpi; `.card { font-size: 20px }` by
  default). Taken literally on a 300 dpi panel that is ~1.7 mm text. So we rescale author lengths:
  every `Npx` (and `Npt`, `Nrem`) in the card CSS and in inline style="" attributes is multiplied by
  k = font_px / 20, where font_px is the body font size the user chose (device px). Anki's default
  20px text thus becomes exactly the chosen size and the note type's relative sizes are kept.
  url(...) and quoted strings are left alone. The server must NOT do the same scaling.

* Images: the server only adds width="img_max_px" (an attribute, already in device px: not
  rescaled here) to images whose natural width exceeds img_max_px. Image occlusion cards arrive as
  one <img src="data:image/jpeg;base64,..."> of 100–900 KB, which is kept byte-for-byte.
  We also cap images with CSS (max-width: 100%) in case MuPDF ignores the attribute; image scale
  is to be tuned on the device.

Our own e-ink overrides are appended after the card CSS, use !important (MuPDF honours it, though
inline style="" attributes still win), and are written in device px (not rescaled).
]]

local CardHtml = {
    ANKI_BASE_PX = 20, -- Anki's default `.card { font-size: 20px; }`
    ROOT_REM_PX = 16,  -- browser default root font size, for rem -> px
}

function CardHtml.scaleFactor(font_px)
    return font_px / CardHtml.ANKI_BASE_PX
end

local function fmt(n)
    -- Keep one decimal; strip ".0".
    local s = string.format("%.1f", n)
    return (s:gsub("%.0$", ""))
end

local function protect(text)
    local saved = {}
    local function keep(s)
        saved[#saved + 1] = s
        return "\1" .. #saved .. "\2"
    end
    text = text:gsub("[uU][rR][lL]%s*%b()", keep)
    text = text:gsub('"[^"\n]*"', keep)
    text = text:gsub("'[^'\n]*'", keep)
    return text, saved
end

local function restore(text, saved)
    return (text:gsub("\1(%d+)\2", function(i) return saved[tonumber(i)] end))
end

--- Multiply px/pt/rem lengths in a CSS fragment by k (rem and pt converted to px first).
function CardHtml.scaleCssLengths(css, k)
    if not css or css == "" or not k or k == 1 then
        return css
    end
    local text, saved = protect(css)
    -- %f[%w%.] : the number must not continue an identifier (e.g. ".h10px", "img_10px.png")
    -- %f[^%w%-]: the unit must end the token
    text = text:gsub("%f[%w%.](%d*%.?%d+)([pPrR][xXtTeE][mM]?)%f[^%w%-]", function(num, unit)
        local n = tonumber(num)
        if not n then return nil end
        unit = unit:lower()
        local px
        if unit == "px" then
            px = n
        elseif unit == "pt" then
            px = n * 4 / 3
        elseif unit == "rem" then
            px = n * CardHtml.ROOT_REM_PX
        else
            return nil -- leave anything else untouched
        end
        return fmt(px * k) .. "px"
    end)
    return restore(text, saved)
end

--- Scale lengths inside style="..." / style='...' attributes of an HTML fragment.
function CardHtml.scaleInlineStyles(html, k)
    if not html or html == "" or not k or k == 1 then
        return html
    end
    -- First set src/href values aside: image occlusion cards carry a 100–900 KB
    -- src="data:image/jpeg;base64,..." whose contents must never be rewritten (nor scanned).
    local saved = {}
    local function keep(pre, value)
        saved[#saved + 1] = value
        return pre .. "\3" .. #saved .. "\4"
    end
    for _, attr in ipairs({ "[sS][rR][cC]", "[hH][rR][eE][fF]" }) do
        html = html:gsub("(%f[%w%-]" .. attr .. '%s*=%s*)("[^"]*")', keep)
        html = html:gsub("(%f[%w%-]" .. attr .. "%s*=%s*)('[^']*')", keep)
    end
    -- %f[%w%-] so that "data-style=" or "lifestyle =" in text don't match.
    html = html:gsub('(%f[%w%-][sS][tT][yY][lL][eE]%s*=%s*")([^"]*)(")', function(pre, value, post)
        return pre .. CardHtml.scaleCssLengths(value, k) .. post
    end)
    html = html:gsub("(%f[%w%-][sS][tT][yY][lL][eE]%s*=%s*')([^']*)(')", function(pre, value, post)
        return pre .. CardHtml.scaleCssLengths(value, k) .. post
    end)
    html = html:gsub("\3(%d+)\4", function(i) return saved[tonumber(i)] end)
    return html
end

--- Wrap the fragment in <div class="card"> (Anki puts that class on <body>, and note-type CSS
--- targets `.card`), unless the server already did.
function CardHtml.wrapCard(html, ord)
    html = html or ""
    if html:find("^%s*<[dD][iI][vV][^>]-class%s*=%s*[\"']?card[%s\"'>]") then
        return html
    end
    local classes = "card"
    if ord then
        classes = classes .. " card" .. tostring(ord)
    end
    return string.format('<div class="%s">%s</div>', classes, html)
end

--- Our e-ink overrides, in device px.
function CardHtml.overrideCss(font_px)
    local rule_px = math.max(2, math.floor(font_px / 16 + 0.5))
    return table.concat({
        "html, body { margin: 0 !important; padding: 0 !important; background-color: #ffffff !important; }",
        "body { color: #000000; }",
        ".card { background-color: #ffffff !important; color: #000000 !important;",
        "        margin: 0 !important; padding: 0 !important; }",
        "img { max-width: 100%; height: auto; }",
        string.format("hr { border: none; border-top: %dpx solid #000000; margin: 0.6em 0; }", rule_px),
        ".replay-button, .soundLink, audio, video { display: none; }",
        "table { border-collapse: collapse; }",
        "a.kanki-img { text-decoration: none !important; }",
    }, "\n")
end

--[[--
Build what HtmlBoxWidget:setContent() needs.
@string side_html question or answer fragment from the server
@string card_css note-type CSS from the server
@tparam table opts { font_px = device px for 1em (required), ord = card ordinal (optional) }
@treturn string body html
@treturn string css
]]
function CardHtml.build(side_html, card_css, opts)
    local font_px = assert(opts and opts.font_px, "font_px required")
    local k = CardHtml.scaleFactor(font_px)
    local body = CardHtml.wrapCard(CardHtml.scaleInlineStyles(side_html or "", k), opts.ord)
    local css = (CardHtml.scaleCssLengths(card_css or "", k) or "") .. "\n" .. CardHtml.overrideCss(font_px)
    return body, css
end

function CardHtml.hasImages(html)
    return html ~= nil and html:find("<[iI][mM][gG][%s>/]") ~= nil
end

return CardHtml

--[[
Layout preview of kanki/statsview on a desktop: lays the stats screen out with sample data (stub
widgets, Noto Sans metrics) and writes every paint call as JSON; render_preview.py draws them.

    luajit preview_statsview.lua OUT_DIR [sample|nocover|crowded|empty]
    python3 render_preview.py OUT_DIR/*.json --fonts DIR_WITH_NotoSans-Regular.ttf_AND_-Bold.ttf

Writes statsview-{portrait,landscape}-{color,grey}.json (+ the blitted cover pixels as .ppm/.pgm).
The current book's cover is a SYNTHETIC image (stats_stubs.writeSyntheticCover: gradient, stripes,
bars, a disc), put in a fake .kobo-images tree and found, decoded, pre-scaled and cached by the real
kanki/readingstats code (decoding is the stubs' PPM reader; the device decodes Nickel's JPEGs).
A layout check only: the device renders with HarfBuzz/FreeType and the Kaleido screen looks much
paler than these PNGs. (LUA_PATH/LUA_CPATH as in README.md; needs dkjson.)
]]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local abs_here = io.popen("cd '" .. here .. "' && pwd"):read("*l")
package.path = table.concat({
    abs_here .. "/stubs/?.lua",
    abs_here .. "/../kanki.koplugin/?.lua",
    package.path,
}, ";")

local out_dir = arg[1] or "."
local variant = arg[2] or "sample"
local Extra = require("stats_stubs")
local dkjson = require("dkjson")

local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p '" .. tmp .. "'")
Extra.Stubs.settings_dir = tmp
Extra.Stubs.data_dir = tmp

-- Synthetic cover in a fake Nickel cover cache (same layout as /mnt/onboard/.kobo-images).
local Readingstats = require("kanki/readingstats")
Readingstats.KOBO_IMAGES = tmp .. "/kobo-images"
Readingstats.cover_cache_dir = tmp .. "/cache/kanki-covers"
local COVER_ID = "00000000-synthetic-cover-0001"
os.execute("mkdir -p '" .. Readingstats.KOBO_IMAGES .. "/244/233'")
Extra.writeSyntheticCover(Readingstats.KOBO_IMAGES .. "/244/233/" .. COVER_ID .. " - N3_FULL.parsed", 600, 900)
Readingstats:resolveNickelCovers({ COVER_ID })

local now = os.time()
local function midnight(days_back)
    local d = os.date("*t", now)
    return os.time{ year = d.year, month = d.month, day = d.day - days_back, hour = 0 }
end

local function sample()
    local next_day_at = midnight(-1) + 4 * 3600
    local counts = { 52, 0, 61, 75, 40, 33, 0, 88, 64, 70, 45, 58, 66, 128 }
    local days = {}
    for i, c in ipairs(counts) do
        local d = i - 14
        days[i] = { day = d, count = c, seconds = c * 11, start = next_day_at - (1 - d) * 86400 }
    end
    -- minutes read per day, oldest first (today = 41: 35 on the Kobo, 6 in KOReader)
    local minutes = { 25, 0, 38, 52, 30, 18, 0, 64, 41, 27, 55, 33, 47, 41 }
    local rdays = {}
    for i, m in ipairs(minutes) do
        rdays[i] = { date = os.date("%Y-%m-%d", midnight(14 - i) + 12 * 3600), day = i - 14, s = m * 60,
                     pages = math.floor(m * 0.8) }
    end
    return {
        now = now,
        anki = {
            today = { answered = 128, seconds = 1380, correct = 117 },
            days = days, streak = 12, left_today = 24, due_tomorrow = 87,
            retention = { week = 0.94 }, as_of = now - 600, rolled_over_days = 0,
        },
        study = {
            today = { study_s = 2520, cards = 128, pomodoros = 3, focus_s = 4500 },
            week = { study_s = 11100, cards = 612, pomodoros = 11, focus_s = 16500 },
        },
        reading = {
            today = { pages = 34, s = 2460, kobo_pages = 30, kobo_s = 2100, koreader_pages = 4, koreader_s = 360 },
            week = { pages = 236, s = 18480, kobo_pages = 206, kobo_s = 16680, koreader_pages = 30, koreader_s = 1800 },
            has_kobo = true, has_koreader = true,
            days = rdays,
            books = {
                { source = "kobo", title = "The Trial", author = "Franz Kafka", percent = 0.65,
                  last_read = now - 3600, image_id = COVER_ID },
                { source = "kobo", title = "Nineteen Eighty-Four", author = "George Orwell", percent = 0.32,
                  last_read = now - 86400 },
            },
        },
        battery = { level = 83, charging = false },
    }
end

local data
if variant == "empty" then
    local zeros = {}
    for i = 1, 14 do
        zeros[i] = { date = os.date("%Y-%m-%d", midnight(14 - i) + 12 * 3600), day = i - 14, s = 0, pages = 0 }
    end
    data = { now = now, study = { today = {}, week = {} },
             reading = { today = { pages = 0, s = 0 }, week = { pages = 0, s = 0 }, books = {}, days = zeros } }
elseif variant == "crowded" then
    data = sample()
    data.anki.today.answered = 1234
    data.anki.today.seconds = 4 * 3600 + 120
    data.study.today.pomodoros = 14
    data.reading.books[1].title = "The Strange Case of Dr Jekyll and Mr Hyde and Other Tales of Terror"
    data.reading.books[1].author = "Robert Louis Stevenson"
    data.reading.books[2].title = "A Very Long Second Book Title That Does Not Fit On One Line At All"
    data.reading.week.pages, data.reading.week.s = 1234, 45 * 3600
    data.battery = { level = 9, charging = false }
elseif variant == "nocover" then
    data = sample()
    data.reading.books[1].image_id = nil
else
    data = sample()
end

local StatsView = require("kanki/statsview")
Extra.image_dump_dir = out_dir
for _, o in ipairs({ { "portrait", 1264, 1680 }, { "landscape", 1680, 1264 } }) do
    for _, mode in ipairs({ "color", "grey" }) do
        Extra.setScreen(o[2], o[3], mode == "color")
        Extra.image_prefix = string.format("statsview-%s-%s-image-", o[1], mode)
        Extra.image_n = 0
        local view = StatsView:new{ data = data, sleep = true, footer_text = "Sleeping" }
        local rec = Extra.newRecorder(o[2], o[3])
        view[1]:paintTo(rec, 0, 0)
        local name = string.format("%s/statsview-%s-%s.json", out_dir, o[1], mode)
        local f = assert(io.open(name, "w"))
        f:write(dkjson.encode({ w = o[2], h = o[3], scale = view.scale, ops = rec.ops }))
        f:close()
        print(name, "scale " .. view.scale, #rec:images() .. " image(s)",
            #rec.out_of_bounds == 0 and "on screen" or ("OFF SCREEN: " .. rec.out_of_bounds[1]))
        view:onCloseWidget()
    end
end
os.execute("rm -rf '" .. tmp .. "'")

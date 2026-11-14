--[[--
Data for the stats screen and the sleep screen, from caches and local files only.

* Anki numbers come from the cached GET /stats body (Tracking key "anki_stats_cache"). refreshAnki()
  updates it, but only when the server is already running (Client:probe): this module never starts
  the server and never touches the network otherwise. Callers refresh after a review session, after a
  sync and when the stats screen opens.
* Study on this device: Tracking's per-day counters (study timer, Pomodoro).
* Reading: KOReader's statistics.sqlite3 and Nickel's snapshot deltas (see kanki/readingstats), per
  day over the chart's 14 days, and the books being read (KOReader's last book, the books read last
  in Nickel). Covers are not loaded here: the view asks kanki/readingstats for the current book's.

collect() never throws: every section is built in its own pcall and is nil when it failed.
]]

local Client = require("kanki/client")
local Device = require("device")
local Readingstats = require("kanki/readingstats")
local Tracking = require("kanki/tracking")
local logger = require("logger")

local Stats = {
    CACHE_KEY = "anki_stats_cache",
    PROBE_TIMEOUT_S = 1,
    FETCH_TIMEOUT_S = 5,
    CHART_DAYS = 14,
}

local function num(v)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

--- Copy of a decoded JSON value keeping only what LuaSettings can serialise (finite numbers,
--- strings, booleans, nested tables), so a surprising body can never corrupt the tracking file.
local function sanitize(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "number" then
        return num(v)
    elseif t == "string" then
        return #v <= 2000 and v or v:sub(1, 2000)
    elseif t == "boolean" then
        return v
    elseif t == "table" and depth < 6 then
        local out = {}
        for k, item in pairs(v) do
            local kt = type(k)
            if kt == "string" or (kt == "number" and k == math.floor(k)) then
                local clean = sanitize(item, depth + 1)
                if clean ~= nil then out[k] = clean end
            end
        end
        return out
    end
    return nil
end

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, item in pairs(v) do out[k] = deepCopy(item) end
    return out
end

---------------------------------------------------------------------------------------------------
-- Anki

--[[--
Fetch GET /stats and cache it, only if the kanki server is already running.
@treturn table|nil the body, or nil + reason ("server_not_running" or a KankiError)
]]
function Stats:refreshAnki()
    local ok_probe, state = pcall(Client.probe, Client, self.PROBE_TIMEOUT_S)
    if not ok_probe or state ~= "open" then
        return nil, "server_not_running"
    end
    local ok, body, err = pcall(Client.stats, Client, { timeout = self.FETCH_TIMEOUT_S, quiet = true })
    if not ok then
        logger.warn("kanki stats: GET /stats raised:", body)
        return nil, body
    end
    if type(body) ~= "table" or type(body.today) ~= "table" then
        if err then logger.info("kanki stats: GET /stats failed:", tostring(err)) end
        return nil, err or "bad_response"
    end
    local clean = sanitize(body)
    clean.fetched_at = os.time()
    Tracking:set(self.CACHE_KEY, clean)
    Tracking:flush()
    return clean
end

--[[--
The cached Anki stats, adjusted to `now`. Nil if nothing was ever cached.

Adds: `as_of` (when the server computed them), `rolled_over_days` (Anki days started since then:
today's numbers are zeroed and `days` shifted, the streak survives one rollover only if the cached
day had reviews), `left_today` (due reviews + learning still to do, nil when unknown) and `days`
normalised to CHART_DAYS entries, oldest first, each { day = -13..0, count, seconds, start = unix
start of that Anki day (or nil) }.
]]
function Stats:anki(now)
    now = now or os.time()
    local c = Tracking:get(self.CACHE_KEY)
    if type(c) ~= "table" or type(c.today) ~= "table" then return nil end
    local a = deepCopy(c)
    a.as_of = num(c.generated_at) or num(c.fetched_at)
    a.rolled_over_days = 0

    local by_day = {}
    if type(c.days) == "table" then
        for _, d in ipairs(c.days) do
            if type(d) == "table" and num(d.day) then
                by_day[num(d.day)] = d
            end
        end
    end
    local due = type(c.due_today) == "table" and c.due_today or {}
    a.left_today = (num(due.review) or 0) + (num(due.learning) or 0)
    if due.review == nil and due.learning == nil then a.left_today = nil end
    a.due_tomorrow = num(c.due_tomorrow)
    a.streak = num(c.streak) or 0

    local next_day_at = num(c.next_day_at)
    local shift = 0
    if next_day_at and now >= next_day_at then
        shift = math.floor((now - next_day_at) / 86400) + 1
        a.rolled_over_days = shift
        local today = {}
        for k, v in pairs(c.today) do
            today[k] = type(v) == "number" and 0 or v
        end
        a.today = today
        if type(a.retention) == "table" then a.retention.today = nil end
        local cached_today = by_day[0] and num(by_day[0].count) or num(c.today.answered) or 0
        if shift > 1 or cached_today == 0 then a.streak = 0 end
        -- Yesterday's "due tomorrow" is today's workload (approximately: it ignores what was left over).
        a.left_today = (shift == 1) and a.due_tomorrow or nil
        a.due_tomorrow = nil
        a.next_day_at = next_day_at + shift * 86400
    end

    local days = {}
    local nda = num(a.next_day_at)
    for d = -(self.CHART_DAYS - 1), 0 do
        local src = by_day[d + shift]
        if d + shift > 0 then src = nil end
        days[#days + 1] = {
            day = d,
            count = src and num(src.count) or 0,
            seconds = src and num(src.seconds) or 0,
            start = nda and (nda - (1 - d) * 86400) or nil,
        }
    end
    a.days = days
    return a
end

---------------------------------------------------------------------------------------------------
-- Study (this device) and reading

function Stats:study(now)
    return {
        today = Tracking:day(now),
        week = Tracking:totals(7, now),
    }
end

local function sourceTotals(kobo_pages, kobo_s, ko_pages, ko_s)
    return {
        kobo_pages = kobo_pages or 0, kobo_s = kobo_s or 0,
        koreader_pages = ko_pages or 0, koreader_s = ko_s or 0,
        pages = (kobo_pages or 0) + (ko_pages or 0),
        s = (kobo_s or 0) + (ko_s or 0),
    }
end

local function titleKey(title)
    if type(title) ~= "string" then return nil end
    local k = title:lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return k ~= "" and k or nil
end

--[[--
The books being read, most recently read first: KOReader's last book and the few books read last in
the Kobo's own reader (from the Nickel snapshot: no DB access), the same title only once.
Each: { source = "kobo"|"koreader", title, author, percent (0..1 or nil), last_read, finished,
        image_id (kobo), file + exclude_cover (koreader) }.
]]
function Stats:books()
    local list = {}
    local ok_k, kobook = pcall(Readingstats.koreaderBook, Readingstats)
    if ok_k and type(kobook) == "table" then table.insert(list, kobook) end
    local ok_n, recent = pcall(Readingstats.nickelRecent, Readingstats)
    if ok_n and type(recent) == "table" then
        for _, nb in ipairs(recent) do
            if type(nb) == "table" then
                table.insert(list, {
                    source = "kobo", title = nb.title, author = nb.author,
                    percent = num(nb.percent), last_read = num(nb.last_read),
                    image_id = type(nb.image_id) == "string" and nb.image_id or nil,
                    finished = nb.finished == true,
                })
            end
        end
    end
    for i, b in ipairs(list) do b._order = i end
    table.sort(list, function(x, y)
        local a, b = x.last_read or 0, y.last_read or 0
        if a ~= b then return a > b end
        return x._order < y._order
    end)
    local seen, out = {}, {}
    for _, b in ipairs(list) do
        b._order = nil
        local key = titleKey(b.title)
        if not key or not seen[key] then
            if key then seen[key] = true end
            table.insert(out, b)
        end
    end
    return out
end

--[[--
Reading today and over the last 7 days (today included), Kobo + KOReader; minutes and pages per day
over CHART_DAYS days (`days`, oldest first); and `books`: the current book (the one read most
recently, wherever) and a second book still in progress, if any.
]]
function Stats:reading(now)
    now = now or os.time()
    local ko = Readingstats:koreaderStats(now, self.CHART_DAYS)
    local day = Tracking:day(now)
    local week = Tracking:totals(7, now)
    local r = {
        today = sourceTotals(day.read_nickel_pages, day.read_nickel_s, ko.today_pages, ko.today_s),
        week = sourceTotals(week.read_nickel_pages, week.read_nickel_s, ko.week_pages, ko.week_s),
        has_koreader = ko.ok,
        has_kobo = Readingstats:hasNickelData(),
        days = Readingstats:readingDays(self.CHART_DAYS, now, ko),
        books = {},
    }
    local books = self:books()
    if books[1] then
        r.books[1] = books[1]
        for i = 2, #books do
            if not books[i].finished then
                r.books[2] = books[i]
                break
            end
        end
    end
    return r
end

function Stats:battery()
    if type(Device.hasBattery) == "function" and not Device:hasBattery() then return nil end
    if type(Device.getPowerDevice) ~= "function" then return nil end
    local powerd = Device:getPowerDevice()
    if not powerd then return nil end
    local level = num(powerd:getCapacity())
    local charging = type(powerd.isCharging) == "function" and powerd:isCharging() and true or false
    if not level then return nil end
    return { level = math.max(0, math.min(100, level)), charging = charging }
end

--[[--
Everything the stats view shows. Each section is nil if it couldn't be built.
@tparam[opt] table opts { now = unix time }
@treturn table { now, anki, study, reading, battery }
]]
function Stats:collect(opts)
    opts = opts or {}
    local now = opts.now or os.time()
    local out = { now = now }
    local function section(name, fn)
        local ok, res = pcall(fn)
        if ok then
            out[name] = res
        else
            logger.warn("kanki stats: building", name, "failed:", res)
        end
    end
    section("anki", function() return self:anki(now) end)
    section("study", function() return self:study(now) end)
    section("reading", function() return self:reading(now) end)
    section("battery", function() return self:battery() end)
    return out
end

return Stats

--[[--
Reading statistics, the books being read and their covers, for the stats screen and the sleep screen.

Two sources, both opened READ-ONLY through KOReader's own lua-ljsqlite3 (`SQ3.open(path, "ro")`):

* KOReader: `<settings>/statistics.sqlite3`, written by KOReader's statistics plugin. Pages and
  seconds per local calendar day, computed exactly like KOReader's own "Reading progress" screen
  (distinct pages per book and day from the `page_stat` view). May not exist or be empty.
* Kobo (Nickel): `/mnt/onboard/.kobo/KoboReader.sqlite`. Nickel isn't running while KOReader is, so
  the file is stable for the whole KOReader session, and we must never write to it. Nickel only keeps
  running totals per book (content.TimeSpentReading, ___PercentRead, DateLastRead; Event type 46 =
  page turns), so daily numbers come from snapshot deltas: snapshotNickel() compares the current
  totals with the previous snapshot (Tracking key "nickel_snapshot") and adds the positive
  differences to Tracking's per-day counters (read_nickel_s / read_nickel_pages), on the local day of
  each book's DateLastRead. The very first snapshot only records a baseline. The snapshot also keeps
  the few books read most recently in Nickel (title, author, %, ImageId, finished) for the screen.

Covers (see the "Covers" section): Nickel's own cover cache files for Kobo books, CoverBrowser's
cached thumbnail for KOReader books; both pre-scaled once into a small cache file so that going to
sleep only reads a few hundred KB (no image decoding, never a document opened).

Nothing in here throws: every DB/file access is wrapped in pcall, failures are logged and partial
data is returned. All numbers handed out (and stored in Tracking) are plain Lua numbers:
lua-ljsqlite3 returns INTEGER columns as int64 cdata, which LuaSettings could not serialise.
]]

local DataStorage = require("datastorage")
local Tracking = require("kanki/tracking")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")

local Readingstats = {
    NICKEL_DB = "/mnt/onboard/.kobo/KoboReader.sqlite",
    KOBO_IMAGES = "/mnt/onboard/.kobo-images",  -- Nickel's cover cache (two levels of hash dirs)
    PAGE_TURN_EVENT = 46,       -- Event.EventType for page turns (per book, running total)
    SNAPSHOT_KEY = "nickel_snapshot",
    SNAPSHOT_VERSION = 1,       -- format of the per-book totals (a change would reset the baseline)
    SNAPSHOT_META = 2,          -- format of the book list kept with them (a change only forces a re-read)
    RECENT_BOOKS = 3,           -- Nickel books kept in the snapshot, most recently read first
    COVER_PATHS_KEY = "nickel_cover_paths", -- Tracking: { [ImageId] = cover file path }
    COVER_PATHS_MAX = 16,
    -- Nickel's cover files, best first: "<ImageId> - N3_FULL.parsed" (JPEG despite the extension).
    -- Not every book has N3_FULL; every book seen in the library has the two others.
    COVER_FILES = { " - N3_FULL.parsed", " - N3_LIBRARY_FULL.parsed", " - N3_LIBRARY_GRID.parsed" },
    WALK_MAX_ENTRIES = 20000,   -- give up walking .kobo-images after this many entries ...
    WALK_MAX_MS = 3000,         -- ... or this long (a few hundred files take a few ms)
    COVER_CACHE_FILES = 12,     -- pre-scaled covers kept (oldest written are removed)
    COVER_SOURCE_MAX_BYTES = 8 * 1024 * 1024, -- never decode anything bigger (N3_FULL is ~130 KB)
    SLOW_MS = 150,              -- log a warning when a DB read takes longer than this
    koreader_db = nil,          -- override for tests; default <settings dir>/statistics.sqlite3
    cover_cache_dir = nil,      -- override for tests; default <data dir>/cache/kanki-covers
    _sq3 = nil,                 -- lua-ljsqlite3 module (injectable for tests)
    _zstd = nil,                -- ffi/zstd module, false when unavailable
    _snapshot_done = false,     -- snapshotNickel() ran in this KOReader process
    _nickel_current = nil,      -- current Nickel book from the last snapshot (in memory)
    _nickel_recent = nil,       -- recent Nickel books from the last snapshot (in memory)
    _walked = {},               -- ImageIds already searched for in .kobo-images by this process
}

---------------------------------------------------------------------------------------------------
-- Small helpers

local function num(v)
    -- int64 cdata, numbers and numeric strings -> Lua number; anything else -> nil
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

local function str(v)
    if type(v) == "string" then return v end
    if v == nil then return nil end
    return tostring(v)
end

local function trim(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

local function elapsedMs(t0)
    return time.to_ms(time.since(t0))
end

--- First line of an error (lua-ljsqlite3 appends a whole traceback to its messages).
local function errText(err)
    return (tostring(err):match("^[^\n]*"))
end

--- Plain (no patterns) "ends with".
local function endsWith(s, suffix)
    return #s > #suffix and s:sub(-#suffix) == suffix
end

--- Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's days_from_civil).
local function daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--[[--
Unix time of an ISO 8601 timestamp as Nickel stores them ("2026-11-01T00:28:04Z", optionally with
fractional seconds or a "+01:00" offset; no zone = UTC). Pure arithmetic, so the device's time zone
never matters. Returns nil for anything unparseable.
]]
function Readingstats.parseUtc(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, rest = s:match("^%s*(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
    if not y then return nil end
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
    if mo < 1 or mo > 12 or d < 1 or d > 31 then return nil end
    local h, mi, sec = 0, 0, 0
    local hh, mm, tail = rest:match("^[T ](%d%d):(%d%d)(.*)$")
    if hh then
        h, mi = tonumber(hh), tonumber(mm)
        local ss, tail2 = tail:match("^:(%d%d)(.*)$")
        if ss then
            sec = tonumber(ss)
            tail = tail2
        end
        tail = tail:gsub("^[.,]%d+", "") -- fractional seconds
    else
        tail = rest
    end
    if h > 23 or mi > 59 or sec > 60 then return nil end
    local t = daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec
    local sign, oh, om = tail:match("^%s*([+-])(%d%d):?(%d%d)%s*$")
    if sign then
        local offset = tonumber(oh) * 3600 + tonumber(om) * 60
        -- local time = UTC + offset  =>  UTC = local - offset
        t = sign == "+" and (t - offset) or (t + offset)
    elseif not tail:match("^%s*[Zz]?%s*$") then
        return nil
    end
    return t
end

--- Local midnight of the day `days_back` days before the day of `t` (DST-safe via os.time).
local function localMidnight(t, days_back)
    local d = os.date("*t", t)
    return os.time{ year = d.year, month = d.month, day = d.day - (days_back or 0), hour = 0, min = 0, sec = 0 }
end

---------------------------------------------------------------------------------------------------
-- SQLite access (read-only)

function Readingstats:_lib()
    if self._sq3 == nil then
        local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
        if ok and type(SQ3) == "table" then
            self._sq3 = SQ3
        else
            logger.warn("kanki readingstats: lua-ljsqlite3 unavailable:", SQ3)
            self._sq3 = false
        end
    end
    return self._sq3 or nil
end

--- Open an existing DB read-only. Returns conn, or nil + reason ("missing" when there's no file).
function Readingstats:_open(path)
    if lfs.attributes(path, "mode") ~= "file" then
        return nil, "missing"
    end
    local SQ3 = self:_lib()
    if not SQ3 then return nil, "no sqlite" end
    -- "ro" = SQLITE_OPEN_READONLY: never creates, never writes (not even a hot-journal rollback).
    local ok, conn = pcall(SQ3.open, path, "ro")
    if not ok or not conn then
        return nil, errText(conn)
    end
    return conn
end

local function closeQuietly(obj)
    if obj then pcall(function() obj:close() end) end
end

--- Run `sql` and call fn(row) for each row (row values are raw: int64 cdata, strings or nil).
--- Raises on SQL errors (callers pcall); the statement is always closed.
local function eachRow(conn, sql, fn)
    local stmt = conn:prepare(sql)
    local ok, err = pcall(function()
        local row = stmt:step()
        while row do
            fn(row)
            row = stmt:step()
        end
    end)
    closeQuietly(stmt)
    if not ok then error(err, 0) end
end

---------------------------------------------------------------------------------------------------
-- KOReader (statistics.sqlite3)

function Readingstats:koreaderDbPath()
    return self.koreader_db or (DataStorage:getSettingsDir() .. "/statistics.sqlite3")
end

-- Same counting as KOReader's own ReaderStatistics:getReadingProgressStats(): a page counts once per
-- book and local day; durations are summed. %s = the page rows of the period (see sources below).
local KOREADER_DAYS_SQL = [[
    SELECT dates, count(*), sum(sum_duration)
    FROM (
        SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS dates,
               sum(duration) AS sum_duration
        FROM   %s
        GROUP  BY id_book, page, dates
    )
    GROUP BY dates
]]

-- Page rows since %d, best first:
-- 1. the page_stat view's own SQL (KOReader statistics, DB schema 20221111: pages rescaled to the
--    book's current layout, as KOReader shows them) applied to the period's rows only, through the
--    start_time index. Querying the view itself makes SQLite scan the whole page_stat_data table
--    (~11x slower with a few years of history).
-- 2. the page_stat view (if the schema ever differs from the copy above)
-- 3. the raw table (view missing: old or damaged DB)
local KOREADER_SOURCES = {
    [[(
        SELECT id_book, first_page + idx - 1 AS page, start_time, duration / (last_page - first_page + 1) AS duration
        FROM (
            SELECT id_book, page, total_pages, pages, start_time, duration,
                   ((page - 1) * pages) / total_pages + 1 AS first_page,
                   max(((page - 1) * pages) / total_pages + 1, (page * pages) / total_pages) AS last_page,
                   idx
            FROM (SELECT * FROM page_stat_data INDEXED BY page_stat_data_start_time WHERE start_time >= %d)
            JOIN book ON book.id = id_book
            JOIN (SELECT number AS idx FROM numbers) AS N ON idx <= (last_page - first_page + 1)
        )
    )]],
    "(SELECT * FROM page_stat WHERE start_time >= %d)",
    "(SELECT * FROM page_stat_data WHERE start_time >= %d)",
}

--[[--
KOReader reading of today and the last 7 days (today included), and per day over `n_days`.

@tparam[opt] int now unix time
@tparam[opt=7] int n_days days covered by `days` (at least 7)
@treturn table { ok = bool (data source readable), today_pages, today_s, week_pages, week_s,
                 days = { ["YYYY-MM-DD"] = { pages =, s = } }, error = string|nil }
]]
function Readingstats:koreaderStats(now, n_days)
    now = now or os.time()
    n_days = math.max(7, math.floor(num(n_days) or 7))
    local res = { ok = false, today_pages = 0, today_s = 0, week_pages = 0, week_s = 0, days = {} }
    local t0 = time.now()
    local conn, err = self:_open(self:koreaderDbPath())
    if not conn then
        res.error = err
        if err ~= "missing" then logger.warn("kanki readingstats: cannot open KOReader statistics:", err) end
        return res
    end
    local window_start = localMidnight(now, n_days - 1)
    local week_key = os.date("%Y-%m-%d", localMidnight(now, 6))
    local today_key = os.date("%Y-%m-%d", now)
    local function collect(source)
        res.days = {}
        res.today_pages, res.today_s, res.week_pages, res.week_s = 0, 0, 0, 0
        eachRow(conn, string.format(KOREADER_DAYS_SQL, string.format(source, window_start)), function(row)
            local date, pages, secs = str(row[1]), num(row[2]) or 0, num(row[3]) or 0
            if date then
                res.days[date] = { pages = pages, s = secs }
                if date >= week_key then
                    res.week_pages = res.week_pages + pages
                    res.week_s = res.week_s + secs
                end
                if date == today_key then
                    res.today_pages, res.today_s = pages, secs
                end
            end
        end)
    end
    local ok, qerr
    for i, source in ipairs(KOREADER_SOURCES) do
        ok, qerr = pcall(collect, source)
        if ok then break end
        logger.dbg("kanki readingstats: KOReader statistics query", i, "failed:", errText(qerr))
    end
    closeQuietly(conn)
    res.ok = ok
    if not ok then
        res.error = errText(qerr)
        logger.warn("kanki readingstats: KOReader statistics query failed:", res.error)
    end
    local ms = elapsedMs(t0)
    if ms > self.SLOW_MS then
        logger.warn("kanki readingstats: KOReader statistics took", ms, "ms")
    else
        logger.dbg("kanki readingstats: KOReader statistics in", ms, "ms")
    end
    return res
end

--[[--
Reading per local calendar day over the last `n` days, oldest first and today last: the Kobo's own
reader (Tracking's read_nickel_s / read_nickel_pages, booked by snapshotNickel) plus KOReader
(statistics.sqlite3, counted like KOReader does).

@tparam int n number of days
@tparam[opt] int now unix time
@tparam[opt] table ko a koreaderStats(now, >= n) result to reuse (queried when nil)
@treturn table list of { date = "YYYY-MM-DD", day = -(n-1)..0, s, pages, kobo_s, kobo_pages,
                         koreader_s, koreader_pages }
]]
function Readingstats:readingDays(n, now, ko)
    now = now or os.time()
    n = math.max(1, math.floor(num(n) or 14))
    if type(ko) ~= "table" then ko = self:koreaderStats(now, n) end
    local ko_days = type(ko.days) == "table" and ko.days or {}
    local out = {}
    local recs = Tracking:lastDays(n, now)
    for i, rec in ipairs(recs) do
        local k = type(ko_days[rec.date]) == "table" and ko_days[rec.date] or {}
        local ko_s, ko_p = num(k.s) or 0, num(k.pages) or 0
        local kobo_s, kobo_p = num(rec.read_nickel_s) or 0, num(rec.read_nickel_pages) or 0
        out[i] = {
            date = rec.date, day = i - #recs,
            kobo_s = kobo_s, kobo_pages = kobo_p, koreader_s = ko_s, koreader_pages = ko_p,
            s = kobo_s + ko_s, pages = kobo_p + ko_p,
        }
    end
    return out
end

--[[--
Have KOReader's statistics plugin write its in-memory page stats to statistics.sqlite3 (it does so
itself every 50 page turns, on suspend and when closing a book), so "today" includes the current
session. Same call KOReader makes before its own reading-progress screen. Safe without a book open.
]]
function Readingstats.flushKOReader(statistics)
    if type(statistics) == "table" and type(statistics.insertDB) == "function" then
        local ok, err = pcall(statistics.insertDB, statistics)
        if not ok then logger.warn("kanki readingstats: statistics insertDB failed:", errText(err)) end
    end
end

local function baseName(path)
    local name = path:match("([^/]+)$") or path
    return (name:gsub("%.[^.]+$", ""))
end

local function authorsText(a)
    a = trim(a)
    if not a then return nil end
    return (a:gsub("%s*\n%s*", ", "))
end

--[[--
The last book opened in KOReader (G_reader_settings "lastfile"): live values when it is open in the
reader, otherwise its sidecar (DocSettings).

@treturn table|nil { source = "koreader", title, author, percent (0..1 or nil), last_read (unix or nil),
                     status ("reading", "complete", ...), finished, exclude_cover, file }
]]
function Readingstats:koreaderBook()
    local file = G_reader_settings and G_reader_settings:readSetting("lastfile")
    if type(file) ~= "string" or file == "" then return nil end
    if lfs.attributes(file, "mode") ~= "file" then return nil end -- deleted or on a missing card
    local book = { source = "koreader", file = file }

    -- Open in the reader right now: the footer has the live position.
    local ok_ui, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = ok_ui and type(ReaderUI) == "table" and ReaderUI.instance
    local live = false
    if ui and ui.document and ui.document.file == file then
        live = true
        pcall(function()
            local props = ui.doc_props or {}
            book.title = trim(props.display_title) or trim(props.title)
            book.author = authorsText(props.authors)
            local footer = ui.view and ui.view.footer
            book.percent = footer and num(footer.percent_finished)
            book.last_read = os.time()
            local ds = ui.doc_settings
            if ds and type(ds.readSetting) == "function" then
                local summary = ds:readSetting("summary")
                book.status = type(summary) == "table" and summary.status or nil
                book.exclude_cover = ds:readSetting("exclude_screensaver") == true
            end
        end)
    end

    if not live or book.percent == nil or book.title == nil then
        pcall(function()
            local DocSettings = require("docsettings")
            if DocSettings:hasSidecarFile(file) then
                local ds = DocSettings:open(file)
                if book.percent == nil then book.percent = num(ds:readSetting("percent_finished")) end
                local props = ds:readSetting("doc_props")
                if type(props) == "table" then
                    book.title = book.title or trim(props.title)
                    book.author = book.author or authorsText(props.authors)
                end
                if book.status == nil then
                    local summary = ds:readSetting("summary")
                    book.status = type(summary) == "table" and summary.status or nil
                end
                if book.exclude_cover == nil then
                    -- KOReader's "exclude this book's cover from the sleep screen": respected here too
                    book.exclude_cover = ds:readSetting("exclude_screensaver") == true
                end
            end
        end)
    end
    book.title = book.title or baseName(file)

    if not book.last_read then
        pcall(function()
            local ReadHistory = require("readhistory")
            for _, item in ipairs(ReadHistory.hist or {}) do
                if item.file == file then
                    book.last_read = num(item.time)
                    break
                end
            end
        end)
    end
    if book.percent then
        book.percent = math.max(0, math.min(1, book.percent))
    end
    book.finished = book.status == "complete"
    book.exclude_cover = book.exclude_cover == true
    return book
end

---------------------------------------------------------------------------------------------------
-- Kobo / Nickel (KoboReader.sqlite)

-- Book rows have no BookID (chapters point to their book), which is also what calibre's Kobo driver
-- relies on; it lets SQLite use Nickel's BookID index instead of scanning every chapter row. If that
-- finds nothing (some firmware we don't know), the query is retried on ContentType alone. The extra
-- columns (ImageId names the cover files, ReadStatus 2 = finished) are dropped if a firmware lacks them.
local NICKEL_BOOKS_SQL = [[
    SELECT %s
    FROM   content
    WHERE  ContentType = 6%s
]]
local NICKEL_COLUMNS = {
    "ContentID, Title, Attribution, TimeSpentReading, ___PercentRead, DateLastRead, ImageId, ReadStatus",
    "ContentID, Title, Attribution, TimeSpentReading, ___PercentRead, DateLastRead",
}

local NICKEL_PAGES_SQL = [[
    SELECT ContentID, EventCount FROM Event WHERE EventType = %d
]]

--- The ImageId Nickel derives from a sideloaded book's ContentID (as calibre's Kobo driver computes
--- it): "file:///mnt/onboard/a b.epub" -> "file____mnt_onboard_a_b_epub". Used when the column is empty.
function Readingstats.imageIdFromContentId(id)
    if type(id) ~= "string" or id == "" then return nil end
    return (id:gsub("[/ :.]", "_"))
end

--[[--
Read Nickel's per-book running totals.

@treturn table|nil { books = { [ContentID] = { t = seconds, p = page turns, title, author,
                     percent (0..1), last_read (unix), image_id, finished } },
                     recent = { up to RECENT_BOOKS books, most recently read first },
                     current = recent[1] or nil }, or nil + error
]]
function Readingstats:readNickel(path)
    path = path or self.NICKEL_DB
    local conn, err = self:_open(path)
    if not conn then return nil, err end
    local books = {}
    local function bookFor(id)
        local b = books[id]
        if not b then
            b = { id = id, t = 0, p = 0 }
            books[id] = b
        end
        return b
    end
    local found = 0
    local function onBook(row)
        local id = str(row[1])
        if not id then return end
        local b = bookFor(id)
        b.title = trim(str(row[2]))
        b.author = trim(str(row[3]))
        b.t = math.max(0, num(row[4]) or 0)
        local pct = num(row[5])
        b.percent = pct and math.max(0, math.min(1, pct / 100)) or nil
        b.last_read = Readingstats.parseUtc(str(row[6]))
        b.image_id = trim(str(row[7])) or Readingstats.imageIdFromContentId(id)
        b.finished = num(row[8]) == 2
        b.in_content = true
        found = found + 1
    end
    local ok, qerr
    for _, cols in ipairs(NICKEL_COLUMNS) do
        found = 0
        ok, qerr = pcall(eachRow, conn, string.format(NICKEL_BOOKS_SQL, cols, " AND BookID IS NULL"), onBook)
        if ok and found == 0 then
            ok, qerr = pcall(eachRow, conn, string.format(NICKEL_BOOKS_SQL, cols, ""), onBook)
        end
        if ok then break end
        logger.dbg("kanki readingstats: Nickel books query failed, retrying with fewer columns:", errText(qerr))
    end
    if not ok then
        closeQuietly(conn)
        return nil, "content: " .. errText(qerr)
    end
    -- Page turns are optional (older firmware without the Event table still gives times).
    local ok_ev, ev_err = pcall(eachRow, conn, string.format(NICKEL_PAGES_SQL, self.PAGE_TURN_EVENT), function(row)
        local id = str(row[1])
        if not id then return end
        bookFor(id).p = math.max(0, num(row[2]) or 0)
    end)
    if not ok_ev then
        logger.warn("kanki readingstats: Nickel page turns unavailable:", errText(ev_err))
    end
    closeQuietly(conn)

    local read = {}
    for _, b in pairs(books) do
        if b.in_content and b.last_read then table.insert(read, b) end
    end
    table.sort(read, function(x, y)
        if x.last_read ~= y.last_read then return x.last_read > y.last_read end
        return x.id < y.id
    end)
    local recent = {}
    for i = 1, math.min(self.RECENT_BOOKS, #read) do
        local b = read[i]
        recent[i] = { source = "kobo", id = b.id, title = b.title or b.id, author = b.author,
                      percent = b.percent, last_read = b.last_read, image_id = b.image_id,
                      finished = b.finished == true }
    end
    return { books = books, recent = recent, current = recent[1] }
end

--[[--
Compare Nickel's totals with the stored snapshot and book the positive differences as reading done in
the Kobo's own reader, then store the new snapshot (Tracking key "nickel_snapshot") and flush.

* First run (no snapshot): baseline only, nothing is added.
* Each book's difference goes to the local day of its DateLastRead, clamped between the previous
  snapshot and now; a book's time difference is capped at the time elapsed since the previous
  snapshot (protects against totals arriving through Kobo's cloud sync).
* Negative differences (book reset or removed and re-added) are ignored; the new totals become the
  reference.
* If the DB file is unchanged since the previous snapshot (same mtime and size), nothing is read
  (unless the stored book list is from an older plugin version: then it is read once more).

@tparam[opt] table opts { now = unix time, path = DB path, force = bool }
@treturn table { status = "baseline"|"delta"|"unchanged"|"no_db"|"error", added_s, added_pages,
                 books_changed, current = current Nickel book or nil, recent = list,
                 error = string|nil, ms }
]]
function Readingstats:snapshotNickel(opts)
    opts = opts or {}
    local now = opts.now or os.time()
    local path = opts.path or self.NICKEL_DB
    local t0 = time.now()
    local result = { status = "error", added_s = 0, added_pages = 0, books_changed = 0 }

    local ok, err = pcall(function()
        local attr = lfs.attributes(path)
        if type(attr) ~= "table" or attr.mode ~= "file" then
            result.status = "no_db"
            return
        end
        local prev = Tracking:get(self.SNAPSHOT_KEY)
        if type(prev) ~= "table" or prev.v ~= self.SNAPSHOT_VERSION or type(prev.books) ~= "table" then
            prev = nil
        end
        if prev and not opts.force and prev.meta == self.SNAPSHOT_META
                and prev.db_mtime == attr.modification and prev.db_size == attr.size then
            result.status = "unchanged"
            result.current = type(prev.current) == "table" and prev.current or nil
            result.recent = type(prev.recent) == "table" and prev.recent or nil
            return
        end

        local data, read_err = self:readNickel(path)
        if not data then
            result.status = "error"
            result.error = errText(read_err)
            return
        end

        local new_books = {}
        for id, b in pairs(data.books) do
            if b.t > 0 or b.p > 0 then
                new_books[id] = { t = b.t, p = b.p }
            end
        end

        -- Work out every addition first, store the new snapshot, then apply: if anything failed
        -- half-way we'd rather lose a little reading than count it twice next time.
        local adds = {}
        if prev then
            result.status = "delta"
            local prev_at = num(prev.at)
            local max_dt = (prev_at and now > prev_at) and (now - prev_at) or nil
            for id, b in pairs(data.books) do
                local old = prev.books[id]
                local dt = b.t - (type(old) == "table" and num(old.t) or 0)
                local dp = b.p - (type(old) == "table" and num(old.p) or 0)
                if dt < 0 then dt = 0 end
                if dp < 0 then dp = 0 end
                if max_dt and dt > max_dt then dt = max_dt end
                if dt > 0 or dp > 0 then
                    local when = b.last_read or now
                    if when > now then when = now end
                    if prev_at and when < prev_at then when = math.min(prev_at, now) end
                    table.insert(adds, { s = dt, p = dp, when = when })
                end
            end
        else
            result.status = "baseline"
        end

        Tracking:set(self.SNAPSHOT_KEY, {
            v = self.SNAPSHOT_VERSION,
            meta = self.SNAPSHOT_META,
            at = now,
            db_mtime = num(attr.modification),
            db_size = num(attr.size),
            books = new_books,
            current = data.current,
            recent = data.recent,
        })
        for _, a in ipairs(adds) do
            Tracking:add({ read_nickel_s = a.s, read_nickel_pages = a.p }, a.when)
            result.added_s = result.added_s + a.s
            result.added_pages = result.added_pages + a.p
            result.books_changed = result.books_changed + 1
        end
        Tracking:flush()
        result.current = data.current
        result.recent = data.recent
    end)
    if not ok then
        result.status = "error"
        result.error = errText(err)
    end
    if result.status == "error" then
        logger.warn("kanki readingstats: Nickel snapshot failed:", result.error)
    else
        self._snapshot_done = true
        self._nickel_current = result.current
        self._nickel_recent = result.recent
    end
    result.ms = elapsedMs(t0)
    logger.info("kanki readingstats: Nickel snapshot", result.status, "in", result.ms, "ms;",
        "added", result.added_s, "s,", result.added_pages, "pages from", result.books_changed, "books")
    return result
end

--- Whether snapshotNickel() already ran (successfully) in this KOReader process.
function Readingstats:nickelSnapshotDone()
    return self._snapshot_done
end

--- The book last read in Nickel, from the last snapshot (memory, else the stored snapshot). No DB access.
function Readingstats:nickelCurrent()
    if self._nickel_current then return self._nickel_current end
    local snap = Tracking:get(self.SNAPSHOT_KEY)
    if type(snap) == "table" and type(snap.current) == "table" then
        return snap.current
    end
    return nil
end

--- The books last read in Nickel, most recent first (memory, else the stored snapshot). No DB access.
function Readingstats:nickelRecent()
    if type(self._nickel_recent) == "table" then return self._nickel_recent end
    local snap = Tracking:get(self.SNAPSHOT_KEY)
    if type(snap) == "table" then
        if type(snap.recent) == "table" then return snap.recent end
        if type(snap.current) == "table" then return { snap.current } end -- snapshot of an older version
    end
    local current = self:nickelCurrent()
    return current and { current } or {}
end

--- Whether we have ever read Nickel's DB on this device (a snapshot exists).
function Readingstats:hasNickelData()
    local snap = Tracking:get(self.SNAPSHOT_KEY)
    return type(snap) == "table" and snap.v ~= nil
end

---------------------------------------------------------------------------------------------------
-- Covers
--
-- Sources:
-- * Kobo book: Nickel's cover cache, /mnt/onboard/.kobo-images/<d1>/<d2>/<ImageId> - N3_FULL.parsed
--   (or N3_LIBRARY_FULL / N3_LIBRARY_GRID). <d1>/<d2> come from a hash of the ImageId that changed
--   with the Qt 6 firmwares, so it isn't computed: the tree is walked (resolveNickelCovers, in the
--   background or in-app, never while going to sleep) and ImageId -> path is kept in Tracking
--   ("nickel_cover_paths"); searched again only when a cached path vanished. File names are compared
--   as plain strings: sideloaded books' ImageIds contain parentheses and other punctuation.
-- * KOReader book: the thumbnail CoverBrowser cached (BookInfoManager:getBookInfo(file, true)), only
--   when that plugin is loaded and its DB exists. Documents are never opened. A book flagged "exclude
--   from the sleep screen" in KOReader gets no cover.
-- Pre-scaled cache: <data dir>/cache/kanki-covers/<hash of source path|mtime|size>-<box>.kcover holds
-- the scaled blitbuffer's raw pixels (zstd-compressed when available, like CoverBrowser stores its
-- thumbnails). Loading it is a file read + decompress: no image decoding, and the pixels are exactly
-- what KOReader's own image pipeline produced (same channel order as its cover thumbnails).

--- The box covers are pre-scaled to: at least as large as any cover box the stats view draws on
--- this screen (its cover column is at most 0.30 x the short side; the view scales the cover down
--- to its box once, at first paint). 392 x 627 on the Libra Colour.
function Readingstats.coverMaxSize()
    local w, h = 1264, 1680
    pcall(function()
        local Screen = require("device").screen
        w, h = Screen:getWidth(), Screen:getHeight()
    end)
    local cw = math.max(64, math.floor(math.min(w, h) * 0.31 + 0.5))
    return cw, math.floor(cw * 1.6 + 0.5)
end

--- Cached cover file path of a Nickel ImageId, if it still exists. Cheap (one stat). No walking.
function Readingstats:nickelCoverPath(image_id)
    if type(image_id) ~= "string" or image_id == "" then return nil end
    local paths = Tracking:get(self.COVER_PATHS_KEY)
    local p = type(paths) == "table" and paths[image_id] or nil
    if type(p) == "string" and lfs.attributes(p, "mode") == "file" then return p end
    return nil
end

--[[--
Walk KOBO_IMAGES (at most 3 levels) for the cover files of `ids`. Returns { [ImageId] = best path },
the number of directory entries seen and the time taken (ms). A book's files all sit in one
directory, so an id is done as soon as its directory has been listed; the walk stops when every id
is done, or after WALK_MAX_ENTRIES entries / WALK_MAX_MS.
]]
function Readingstats:_findNickelCovers(ids)
    local wanted, remaining = {}, 0
    for _, id in ipairs(ids) do
        if type(id) == "string" and id ~= "" and not wanted[id] then
            wanted[id] = true
            remaining = remaining + 1
        end
    end
    local found, rank_of = {}, {}
    local t0 = time.now()
    local entries, stop = 0, remaining == 0
    local files = self.COVER_FILES
    local function visit(dir, depth)
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok or type(iter) ~= "function" then return end
        local here = {}
        for name in iter, dir_obj do
            entries = entries + 1
            if name ~= "." and name ~= ".." then
                if endsWith(name, ".parsed") then
                    for rank, suffix in ipairs(files) do
                        if endsWith(name, suffix) then
                            local id = name:sub(1, #name - #suffix)
                            if wanted[id] then
                                here[id] = true
                                if not rank_of[id] or rank < rank_of[id] then
                                    rank_of[id] = rank
                                    found[id] = dir .. "/" .. name
                                end
                            end
                            break
                        end
                    end
                elseif depth < 3 and not name:find(".", 1, true) then
                    -- the hash directories are plain numbers; anything with a dot is a file
                    visit(dir .. "/" .. name, depth + 1)
                end
            end
            if stop or entries >= self.WALK_MAX_ENTRIES or elapsedMs(t0) > self.WALK_MAX_MS then
                stop = true
                break
            end
        end
        if dir_obj then pcall(function() dir_obj:close() end) end
        for id in pairs(here) do
            if wanted[id] then
                wanted[id] = nil
                remaining = remaining - 1
            end
        end
        if remaining <= 0 then stop = true end
    end
    if not stop then visit(self.KOBO_IMAGES, 0) end
    return found, entries, elapsedMs(t0)
end

--[[--
Make sure the cover files of these Nickel ImageIds are known (Tracking "nickel_cover_paths"). Ids
whose cached path still exists cost one stat each; the others are searched for in ONE walk of
KOBO_IMAGES, at most once per id and KOReader process. For the background / in-app, not for sleep.
@treturn int how many of the ids have a cover file now
]]
function Readingstats:resolveNickelCovers(ids)
    local ok, res = pcall(function()
        local paths = Tracking:get(self.COVER_PATHS_KEY)
        if type(paths) ~= "table" then paths = {} end
        local have, missing, asked = 0, {}, {}
        for _, id in ipairs(ids or {}) do
            if type(id) == "string" and id ~= "" and not asked[id] then
                asked[id] = true
                local p = paths[id]
                if type(p) == "string" and lfs.attributes(p, "mode") == "file" then
                    have = have + 1
                elseif not self._walked[id] then
                    table.insert(missing, id)
                end
            end
        end
        if #missing == 0 then return have end
        local found, entries, ms = self:_findNickelCovers(missing)
        local n_found = 0
        for _, id in ipairs(missing) do
            self._walked[id] = true
            if found[id] then
                paths[id] = found[id]
                have = have + 1
                n_found = n_found + 1
            else
                paths[id] = nil -- vanished (or never there)
            end
        end
        -- Keep the map small; the ids asked for now are kept first.
        local count = 0
        for _ in pairs(paths) do count = count + 1 end
        if count > self.COVER_PATHS_MAX then
            local kept, n = {}, 0
            for id in pairs(asked) do
                if paths[id] then kept[id], n = paths[id], n + 1 end
            end
            for id, p in pairs(paths) do
                if n >= self.COVER_PATHS_MAX then break end
                if not kept[id] then kept[id], n = p, n + 1 end
            end
            paths = kept
        end
        -- Written with the next flush (every sleep flushes Tracking).
        Tracking:set(self.COVER_PATHS_KEY, paths)
        logger.info("kanki readingstats: looked for", #missing, "Nickel covers:", n_found, "found;",
            entries, "entries in", ms, "ms")
        return have
    end)
    if not ok then
        logger.warn("kanki readingstats: Nickel cover lookup failed:", errText(res))
        return 0
    end
    return res
end

--[[--
Where a book's cover comes from, cheaply (a cached path and a stat; no image access):
{ kind = "image", path = cover file } for a Kobo book, { kind = "bookinfo", path = book file } for a
KOReader book; with `key` = kind|path|mtime|size (a new version of the source gets a new cache entry).
Nil when no cover is known.
]]
function Readingstats:coverSource(book)
    if type(book) ~= "table" then return nil end
    local kind, path
    if book.source == "kobo" then
        kind, path = "image", self:nickelCoverPath(book.image_id)
    elseif book.source == "koreader" and not book.exclude_cover then
        kind, path = "bookinfo", book.file
    end
    if type(path) ~= "string" then return nil end
    local attr = lfs.attributes(path)
    if type(attr) ~= "table" or attr.mode ~= "file" then return nil end
    local mtime, size = num(attr.modification) or 0, num(attr.size) or 0
    return { kind = kind, path = path, mtime = mtime, size = size,
             key = table.concat({ kind, path, string.format("%d", mtime), string.format("%d", size) }, "|") }
end

--- 32-bit FNV-1a of a string, as 8 hex digits (cache file names).
local function fnv1a(s)
    local h = 0x811C9DC5
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i))
        -- h * 16777619 (2^24 + 403) modulo 2^32, without losing precision in doubles
        h = bit.tobit(bit.lshift(h, 24) + (h % 0x100000000) * 403)
    end
    return bit.tohex(h)
end

function Readingstats:coverCacheDir()
    return self.cover_cache_dir or (DataStorage:getDataDir() .. "/cache/kanki-covers")
end

function Readingstats:_coverCacheFile(src, max_w, max_h)
    return string.format("%s/%s-%dx%d.kcover", self:coverCacheDir(), fnv1a(src.key), max_w, max_h)
end

function Readingstats:_zstdLib()
    if self._zstd == nil then
        local ok, z = pcall(require, "ffi/zstd")
        self._zstd = (ok and type(z) == "table" and type(z.zstd_compress) == "function") and z or false
    end
    return self._zstd or nil
end

local CACHE_MAGIC = "KANKICOVER"

--- Store a cover blitbuffer in the pre-scaled cache (write to .tmp, then rename). Best effort.
function Readingstats:_storeCover(file, bb)
    local ok, err = pcall(function()
        local ffi = require("ffi")
        local dir = self:coverCacheDir()
        if lfs.attributes(dir, "mode") ~= "directory" then
            lfs.mkdir((dir:match("^(.*)/[^/]+$")) or dir) -- <data dir>/cache normally exists
            lfs.mkdir(dir)
        end
        local w, h, stride = tonumber(bb.w), tonumber(bb.h), tonumber(bb.stride)
        local size = stride * h
        local payload, fmt
        local z = self:_zstdLib()
        if z then
            local ok_z, cbuf, clen = pcall(z.zstd_compress, bb.data, size)
            if ok_z and cbuf ~= nil then
                payload = ffi.string(cbuf, clen)
                ffi.C.free(cbuf)
                fmt = "zstd"
            end
        end
        if not payload then
            payload, fmt = ffi.string(bb.data, size), "raw"
        end
        local tmp = file .. ".tmp"
        local f = assert(io.open(tmp, "wb"))
        local ok_w, werr = pcall(function()
            assert(f:write(string.format("%s 1 %d %d %d %d %s %d\n", CACHE_MAGIC, w, h, bb:getType(), stride,
                fmt, #payload)))
            assert(f:write(payload))
        end)
        f:close()
        if not ok_w then
            os.remove(tmp)
            error(werr, 0)
        end
        os.remove(file)
        assert(os.rename(tmp, file))
        self:_pruneCoverCache(file)
    end)
    if not ok then logger.warn("kanki readingstats: could not cache a cover:", errText(err)) end
    return ok
end

--- Load a pre-scaled cover. Returns a blitbuffer (caller frees it) or nil; drops broken files.
function Readingstats:_loadCover(file)
    local f = io.open(file, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    local function bad(why)
        logger.warn("kanki readingstats: dropping cached cover", file, "(" .. why .. ")")
        os.remove(file)
        return nil
    end
    local nl = type(content) == "string" and content:find("\n", 1, true)
    if not nl or nl > 120 then return bad("header") end
    local v, w, h, bbtype, stride, fmt, len = content:sub(1, nl - 1):match(
        "^" .. CACHE_MAGIC .. " (%d+) (%d+) (%d+) (%d+) (%d+) (%a+) (%d+)$")
    v, w, h, bbtype, stride, len = tonumber(v), tonumber(w), tonumber(h), tonumber(bbtype),
        tonumber(stride), tonumber(len)
    if v ~= 1 or not w or w < 1 or h < 1 or w > 4096 or h > 4096 then return bad("header") end
    local BB = require("ffi/blitbuffer")
    local bpp = BB.TYPE_TO_BPP and BB.TYPE_TO_BPP[bbtype]
    if not bpp or stride < math.ceil(w * bpp / 8) then return bad("type") end
    local payload = content:sub(nl + 1)
    if #payload ~= len then return bad("truncated") end
    local size = stride * h
    if fmt == "raw" then
        if len ~= size then return bad("size") end
        return BB.fromstring(w, h, bbtype, payload, stride)
    elseif fmt == "zstd" then
        local z = self:_zstdLib()
        if not z then return nil end
        local ffi = require("ffi")
        local ok, buf, ulen = pcall(z.zstd_uncompress, ffi.cast("const char *", payload), len)
        if not ok or buf == nil then return bad("zstd") end
        if tonumber(ulen) ~= size then
            ffi.C.free(buf)
            return bad("size")
        end
        local bb = BB.new(w, h, bbtype, buf, stride)
        bb:setAllocated(1) -- free() releases buf
        return bb
    end
    return bad("format")
end

--- Keep at most COVER_CACHE_FILES covers (the most recently written; `keep` always survives).
function Readingstats:_pruneCoverCache(keep)
    local dir = self:coverCacheDir()
    local files = {}
    pcall(function()
        for name in lfs.dir(dir) do
            if endsWith(name, ".kcover") or endsWith(name, ".tmp") then
                local p = dir .. "/" .. name
                table.insert(files, { path = p, m = lfs.attributes(p, "modification") or 0,
                                      tmp = endsWith(name, ".tmp") })
            end
        end
    end)
    local covers = {}
    for _, f in ipairs(files) do
        if f.tmp then os.remove(f.path) else table.insert(covers, f) end -- leftovers of a crash
    end
    if #covers <= self.COVER_CACHE_FILES then return end
    -- newest first, `keep` before everything (mtimes have a 1-2 s resolution: ties are common)
    table.sort(covers, function(a, b)
        if (a.path == keep) ~= (b.path == keep) then return a.path == keep end
        return a.m > b.m
    end)
    for i = self.COVER_CACHE_FILES + 1, #covers do
        os.remove(covers[i].path)
    end
end

local function fitSize(w, h, max_w, max_h)
    if w <= max_w and h <= max_h then return w, h end
    local s = math.min(max_w / w, max_h / h)
    return math.max(1, math.floor(w * s + 0.5)), math.max(1, math.floor(h * s + 0.5))
end

--- Decode a cover from its source and scale it down to fit max_w x max_h (never up).
function Readingstats:_decodeCover(src, max_w, max_h)
    local RenderImage = require("ui/renderimage")
    local bb
    if src.kind == "image" then
        if src.size <= 0 or src.size > self.COVER_SOURCE_MAX_BYTES then return nil, "source size" end
        bb = RenderImage:renderImageFile(src.path, false)
    elseif src.kind == "bookinfo" then
        local BIM = package.loaded["bookinfomanager"] -- loaded by the CoverBrowser plugin, if enabled
        if type(BIM) ~= "table" or type(BIM.getBookInfo) ~= "function" then return nil, "no CoverBrowser" end
        if type(BIM.db_location) ~= "string" or lfs.attributes(BIM.db_location, "mode") ~= "file" then
            return nil, "no CoverBrowser cache" -- (getBookInfo would create the DB)
        end
        local info = BIM:getBookInfo(src.path, true)
        if type(info) ~= "table" then return nil, "not in CoverBrowser's cache" end
        bb = info.cover_bb
        if bb and (info.ignore_cover == "Y" or not info.has_cover) then
            bb:free()
            bb = nil
        end
    end
    if type(bb) ~= "cdata" and type(bb) ~= "table" then return nil, "no image" end
    local w, h = bb:getWidth(), bb:getHeight()
    if w < 8 or h < 8 then
        bb:free()
        return nil, "image too small"
    end
    local fw, fh = fitSize(w, h, max_w, max_h)
    if fw ~= w or fh ~= h then
        bb = RenderImage:scaleBlitBuffer(bb, fw, fh, true) -- frees the full-size one
    end
    return bb
end

--[[--
A book's cover as a blitbuffer fitting max_w x max_h (aspect kept, never upscaled), from the
pre-scaled cache; decoded, scaled and cached first when missing, unless `opts.cached_only`.
The caller owns (frees) the result. Never raises.
@treturn BlitBuffer|nil, string|nil why not
]]
function Readingstats:coverBB(book, max_w, max_h, opts)
    opts = opts or {}
    local ok, bb, why = pcall(function()
        local src = self:coverSource(book)
        if not src then return nil, "no cover" end
        local file = self:_coverCacheFile(src, max_w, max_h)
        local cached = self:_loadCover(file)
        if cached then return cached end
        if opts.cached_only then return nil, "not cached" end
        local t0 = time.now()
        local built, err = self:_decodeCover(src, max_w, max_h)
        if not built then return nil, err end
        self:_storeCover(file, built)
        logger.info("kanki readingstats: cover of", book.title, "prepared in", elapsedMs(t0), "ms")
        return built
    end)
    if not ok then
        logger.warn("kanki readingstats: cover failed:", errText(bb))
        return nil, "error"
    end
    return bb, why
end

--[[--
Make sure a book's pre-scaled cover is cached (decode + scale + store only when missing).
@treturn string "cached" (nothing to do), "built", "none" (no cover) or "error"
]]
function Readingstats:prepareCover(book, max_w, max_h)
    local ok, res = pcall(function()
        local src = self:coverSource(book)
        if not src then return "none" end
        local file = self:_coverCacheFile(src, max_w, max_h)
        if lfs.attributes(file, "mode") == "file" then return "cached" end
        local t0 = time.now()
        local bb = self:_decodeCover(src, max_w, max_h)
        if not bb then return "none" end
        self:_storeCover(file, bb)
        bb:free()
        logger.info("kanki readingstats: cover of", book.title, "prepared in", elapsedMs(t0), "ms")
        return "built"
    end)
    if not ok then
        logger.warn("kanki readingstats: preparing a cover failed:", errText(res))
        return "error"
    end
    return res
end

return Readingstats

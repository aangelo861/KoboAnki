--[[
Tests for the stats screen and the sleep screen:

  * kanki/readingstats: KOReader statistics.sqlite3 (today / last 7 days, same counting as KOReader),
    Nickel's KoboReader.sqlite read-only (books, page turns, current book), snapshot deltas
    (first-run baseline, unchanged file, day attribution, clamping, cap, reset, new book, errors),
    the snapshot's recent books (ImageId, finished) and its upgrade, reading per day over 14 days,
    Nickel cover files found in a fake .kobo-images tree (preference, punctuation in ImageIds,
    Tracking cache, one walk, re-walk when a path vanished), the pre-scaled cover cache (built once,
    then loaded without decoding; new source version, corrupt file, raw and zstd formats, pruning,
    failures) and KOReader covers from a stand-in of CoverBrowser's BookInfoManager.
  * kanki/stats: Anki cache refresh only when the server runs, day rollover, collect(), the current
    and second book.
  * kanki/statsview: builds and paints in portrait and landscape, colour and grey, full and empty
    data, everything on screen; with and without a cover (cover beside the text, never under it,
    grey when colour is off, freed with the view, no decoding when cached); in-app view.
  * kanki/sleepscreen: hooks into a stand-in of KOReader's Screensaver (same setup/show contract):
    setting on -> our widget is shown and ui.statistics restored; off -> untouched; errors; covers
    prepared in the background, never searched for while going to sleep.

Covers in here are SYNTHETIC images (stats_stubs.writeSyntheticCover), written as PPM files: the
stubs' RenderImage decodes PPM where the device decodes Nickel's JPEGs.

Fixture DBs are generated with python3's sqlite3 module in a temp dir. SQLite access goes through
KOReader's own lua-ljsqlite3 when a KOReader tree is found (KOREADER_SRC=/path/to/koreader), else a
minimal FFI stand-in with the same API (see stubs/stats_stubs.lua).

  KANKI_TEST_QUIET=1 luajit test_stats.lua      (LUA_PATH/LUA_CPATH as in README.md)
]]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local abs_here = io.popen("cd '" .. here .. "' && pwd"):read("*l")
package.path = table.concat({
    abs_here .. "/stubs/?.lua",
    abs_here .. "/../kanki.koplugin/?.lua",
    package.path,
}, ";")

local ffi = require("ffi")
local Extra = require("stats_stubs")
local Stubs = Extra.Stubs
local UIManager = Stubs.UIManager
local sqlite_impl = Extra.setupSQLite()

local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p '" .. tmp .. "'")
Stubs.settings_dir = tmp
Stubs.data_dir = tmp

local passed, failed = 0, 0
local function check(cond, what, detail)
    if cond then
        passed = passed + 1
        print("ok   " .. what)
    else
        failed = failed + 1
        print("FAIL " .. what .. (detail ~= nil and (": " .. tostring(detail)) or ""))
    end
end
local function section(name) print("\n## " .. name) end

---------------------------------------------------------------------------------------------------
-- Fixture helpers

local function writeFile(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

--- Run SQL against a DB file with python3's sqlite3 (creates the file if needed).
local sql_n = 0
local function sql(db, script)
    sql_n = sql_n + 1
    local script_path = tmp .. "/script" .. sql_n .. ".sql"
    writeFile(script_path, script)
    local py = tmp .. "/run_sql.py"
    writeFile(py, [[
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.executescript(open(sys.argv[2]).read())
con.commit()
con.close()
]])
    local ok = os.execute(string.format("python3 -I '%s' '%s' '%s'", py, db, script_path))
    assert(ok == 0 or ok == true, "python3 sqlite3 failed for " .. db)
end

local function localMidnight(t, days_back)
    local d = os.date("*t", t)
    return os.time{ year = d.year, month = d.month, day = d.day - (days_back or 0), hour = 0, min = 0, sec = 0 }
end

local function isoUtc(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function listDir(dir, suffix)
    local out = {}
    local p = io.popen("ls -1 '" .. dir .. "' 2>/dev/null")
    for name in p:lines() do
        if not suffix or name:sub(-#suffix) == suffix then table.insert(out, name) end
    end
    p:close()
    return out
end

local function overlaps(a, b)
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

local function bytesOf(bb) return ffi.string(bb.data, bb.stride * bb.h) end

local function noCdata(v, path)
    path = path or "value"
    local t = type(v)
    if t == "cdata" or t == "userdata" or t == "function" then return false, path .. " is " .. t end
    if t == "table" then
        for k, item in pairs(v) do
            if type(k) == "cdata" then return false, path .. " has a cdata key" end
            local ok, where = noCdata(item, path .. "." .. tostring(k))
            if not ok then return false, where end
        end
    end
    return true
end

local NOW = os.time()

-- KOReader statistics DB: the exact schema of plugins/statistics.koplugin (DB_SCHEMA_VERSION 20221111)
local KO_DB = tmp .. "/statistics.sqlite3"
do
    local today = localMidnight(NOW, 0)
    local function at(days_back, offset) return localMidnight(NOW, days_back) + offset end
    local rows = {
        -- today: book 1 pages 10, 11, 12 and page 11 again (one page per book and day), book 2 page 5
        { 1, 10, today + 60, 60 }, { 1, 11, today + 160, 90 }, { 1, 12, today + 260, 30 },
        { 1, 11, today + 900, 20 }, { 2, 5, today + 1200, 40 },
        -- 2 days ago: book 1 pages 11 and 13
        { 1, 11, at(2, 3600), 50 }, { 1, 13, at(2, 3700), 70 },
        -- 6 days ago (first day of the 7-day window) and 7 / 10 days ago (outside it)
        { 2, 1, at(6, 120), 30 }, { 2, 2, at(7, 120), 999 }, { 1, 2, at(10, 50), 500 },
    }
    local values = {}
    for _, r in ipairs(rows) do
        table.insert(values, string.format("(%d, %d, %d, %d, %d)", r[1], r[2], r[3], r[4], r[1] == 1 and 300 or 200))
    end
    sql(KO_DB, [[
CREATE TABLE IF NOT EXISTS book (id integer PRIMARY KEY autoincrement, title text, authors text, notes integer,
    last_open integer, highlights integer, pages integer, series text, language text, md5 text,
    total_read_time integer, total_read_pages integer);
CREATE UNIQUE INDEX IF NOT EXISTS book_title_authors_md5 ON book(title, authors, md5);
CREATE TABLE IF NOT EXISTS page_stat_data (id_book integer, page integer NOT NULL DEFAULT 0,
    start_time integer NOT NULL DEFAULT 0, duration integer NOT NULL DEFAULT 0, total_pages integer NOT NULL DEFAULT 0,
    UNIQUE (id_book, page, start_time), FOREIGN KEY(id_book) REFERENCES book(id));
CREATE INDEX IF NOT EXISTS page_stat_data_start_time ON page_stat_data(start_time);
CREATE TABLE IF NOT EXISTS numbers (number INTEGER PRIMARY KEY);
WITH RECURSIVE counter AS (SELECT 1 as N UNION ALL SELECT N + 1 FROM counter WHERE N < 1000)
    INSERT INTO numbers SELECT N AS number FROM counter;
CREATE VIEW IF NOT EXISTS page_stat AS
    SELECT id_book, first_page + idx - 1 AS page, start_time, duration / (last_page - first_page + 1) AS duration
    FROM (
        SELECT id_book, page, total_pages, pages, start_time, duration,
            ((page - 1) * pages) / total_pages + 1 AS first_page,
            max(((page - 1) * pages) / total_pages + 1, (page * pages) / total_pages) AS last_page,
            idx
        FROM page_stat_data
        JOIN book ON book.id = id_book
        JOIN (SELECT number as idx FROM numbers) AS N ON idx <= (last_page - first_page + 1)
    );
PRAGMA user_version=20221111;
INSERT INTO book (id, title, authors, pages, md5) VALUES (1, 'Dune', 'Frank Herbert', 300, 'a'), (2, 'Emma', 'Jane Austen', 200, 'b');
INSERT INTO page_stat_data VALUES ]] .. table.concat(values, ", ") .. ";\n")
end

-- Nickel subset: content (books + chapters) and Event (46 = page turns)
local KOBO_DB = tmp .. "/KoboReader.sqlite"
local TRIAL = "file:///mnt/onboard/Books/The Trial.epub"
local MIDDLE = "0a1b2c3d-store-uuid"
sql(KOBO_DB, string.format([[
CREATE TABLE content (ContentID TEXT NOT NULL, ContentType TEXT NOT NULL, MimeType TEXT, BookID TEXT,
    BookTitle TEXT, Title TEXT, Attribution TEXT, DateLastRead TEXT, ___PercentRead INTEGER, ReadStatus INTEGER,
    TimeSpentReading INTEGER DEFAULT 0, Description TEXT, PRIMARY KEY (ContentID));
CREATE TABLE Event (EventType INTEGER NOT NULL, FirstOccurrence TEXT, LastOccurrence TEXT, EventCount INTEGER DEFAULT 0,
    ContentID TEXT, ExtraData BLOB, Checksum TEXT, PRIMARY KEY (EventType, ContentID));
INSERT INTO content VALUES ('%s', '6', 'application/epub+zip', NULL, NULL, 'The Trial', 'Franz Kafka',
    '2026-11-01T00:28:04Z', 65, 1, 32709, 'long text');
INSERT INTO content VALUES ('%s#ch1', '9', NULL, '%s', 'The Trial', 'Chapter 1', NULL, NULL, 0, 0, 999999, NULL);
INSERT INTO content VALUES ('%s', '6', 'application/x-kobo-epub+zip', NULL, NULL, 'Middlemarch', 'George Eliot',
    '2026-10-20T08:00:00Z', 12, 1, 5000, NULL);
INSERT INTO content VALUES ('file:///mnt/onboard/Books/Unread.epub', '6', NULL, NULL, NULL, 'Unread', 'Nobody',
    NULL, 0, 0, 0, NULL);
INSERT INTO Event VALUES (46, NULL, NULL, 812, '%s', NULL, NULL);
INSERT INTO Event VALUES (46, NULL, NULL, 120, '%s', NULL, NULL);
INSERT INTO Event VALUES (3, NULL, NULL, 5, '%s', NULL, NULL);
]], TRIAL, TRIAL, TRIAL, MIDDLE, TRIAL, MIDDLE, TRIAL))

---------------------------------------------------------------------------------------------------
local Tracking = require("kanki/tracking")
local Readingstats = require("kanki/readingstats")
local Settings = require("kanki/settings")
Readingstats.koreader_db = KO_DB
Readingstats.NICKEL_DB = KOBO_DB

print("SQLite: " .. sqlite_impl)

section("readingstats: ISO dates")
do
    local p = Readingstats.parseUtc
    check(p("2026-11-01T00:28:04Z") == 1793492884, "Nickel UTC timestamp", p("2026-11-01T00:28:04Z"))
    check(p("1970-01-01T00:00:00Z") == 0, "epoch")
    check(p("2024-02-29T12:00:00.123Z") == 1709208000, "leap day + fractional seconds")
    check(p("2026-11-01T01:28:04+01:00") == 1793492884, "+01:00 offset")
    check(p("2026-10-31T19:28:04-0500") == 1793492884, "-0500 offset")
    check(p("2026-11-01 00:28:04") == 1793492884, "space separator, no zone = UTC")
    check(p("2026-11-01") == 1793491200, "date only")
    check(p("") == nil and p(nil) == nil and p("yesterday") == nil and p("2026-13-01T00:00:00Z") == nil,
        "garbage gives nil")
end

section("readingstats: KOReader statistics.sqlite3")
do
    local s = Readingstats:koreaderStats(NOW)
    check(s.ok, "query ok", s.error)
    check(s.today_pages == 4 and s.today_s == 240, "today: 4 pages (page 11 once), 240 s",
        s.today_pages .. " pages " .. s.today_s .. " s")
    check(s.week_pages == 7 and s.week_s == 390, "last 7 days: 7 pages, 390 s (7 and 10 days ago excluded)",
        s.week_pages .. " pages " .. s.week_s .. " s")
    check(type(s.today_pages) == "number" and type(s.week_s) == "number", "plain Lua numbers (no int64 cdata)")
    check(s.days[os.date("%Y-%m-%d", NOW)] ~= nil, "per-day table keyed by local date")

    -- Without the start_time index (fast path fails): same numbers through the page_stat view
    local noindex = tmp .. "/noindex.sqlite3"
    os.execute(string.format("cp '%s' '%s'", KO_DB, noindex))
    sql(noindex, "DROP INDEX page_stat_data_start_time;")
    Readingstats.koreader_db = noindex
    local v = Readingstats:koreaderStats(NOW)
    check(v.ok and v.today_pages == 4 and v.week_pages == 7 and v.week_s == 390,
        "no start_time index: same result through the page_stat view")
    sql(noindex, "DROP VIEW page_stat;")
    local raw = Readingstats:koreaderStats(NOW)
    check(raw.ok and raw.today_pages == 4 and raw.week_s == 390, "no view either: raw page_stat_data")

    Readingstats.koreader_db = tmp .. "/nope.sqlite3"
    local m = Readingstats:koreaderStats(NOW)
    check(not m.ok and m.today_pages == 0 and m.week_s == 0 and m.error == "missing", "missing DB: zeros, no error raised")
    check(io.open(tmp .. "/nope.sqlite3") == nil, "missing DB is not created (read-only open)")
    local empty = tmp .. "/empty.sqlite3"
    sql(empty, "CREATE TABLE something (x INTEGER);")
    Readingstats.koreader_db = empty
    local e = Readingstats:koreaderStats(NOW)
    check(not e.ok and e.today_pages == 0, "DB without statistics tables: zeros, no error raised")
    writeFile(tmp .. "/garbage.sqlite3", string.rep("not a database ", 100))
    Readingstats.koreader_db = tmp .. "/garbage.sqlite3"
    local g = Readingstats:koreaderStats(NOW)
    check(not g.ok and g.week_pages == 0, "corrupt DB: zeros, no error raised")
    Readingstats.koreader_db = KO_DB

    -- last KOReader book: lastfile + sidecar
    local book_path = tmp .. "/Dune.epub"
    writeFile(book_path, "epub")
    Extra.gsettings.lastfile = book_path
    Extra.sidecars[book_path] = { percent_finished = 0.4, doc_props = { title = "Dune", authors = "Frank Herbert" },
                                  summary = { status = "reading" } }
    package.loaded["readhistory"].hist = { { file = book_path, time = NOW - 7200 } }
    local b = Readingstats:koreaderBook()
    check(b and b.title == "Dune" and b.author == "Frank Herbert" and b.percent == 0.4 and b.last_read == NOW - 7200,
        "last KOReader book from lastfile + DocSettings + history", b and (b.title .. " " .. tostring(b.percent)))
    Extra.sidecars[book_path] = nil
    local b2 = Readingstats:koreaderBook()
    check(b2 and b2.title == "Dune" and b2.percent == nil, "no sidecar: file name as title, no percent")
    -- open in the reader: live values
    package.loaded["apps/reader/readerui"].instance = {
        document = { file = book_path },
        doc_props = { display_title = "Dune (live)", authors = "Frank Herbert\nBrian Herbert" },
        view = { footer = { percent_finished = 0.5 } },
    }
    local b3 = Readingstats:koreaderBook()
    check(b3 and b3.title == "Dune (live)" and b3.percent == 0.5 and b3.author == "Frank Herbert, Brian Herbert",
        "book open in the reader: live title / percent / authors")
    package.loaded["apps/reader/readerui"].instance = nil
    Extra.gsettings.lastfile = tmp .. "/deleted.epub"
    check(Readingstats:koreaderBook() == nil, "lastfile deleted: no book")
    Extra.gsettings.lastfile = book_path
    Extra.sidecars[book_path] = { percent_finished = 0.4, doc_props = { title = "Dune", authors = "Frank Herbert" } }

    local inserted = 0
    Readingstats.flushKOReader({ insertDB = function() inserted = inserted + 1 end })
    Readingstats.flushKOReader({ insertDB = function() error("db locked") end })
    Readingstats.flushKOReader(nil)
    check(inserted == 1, "flushKOReader calls insertDB and swallows errors")
end

section("readingstats: Nickel KoboReader.sqlite")
do
    local data, err = Readingstats:readNickel(KOBO_DB)
    check(data ~= nil, "read ok", err)
    local trial = data and data.books[TRIAL]
    check(trial and trial.t == 32709 and trial.p == 812 and trial.percent == 0.65 and trial.title == "The Trial"
        and trial.author == "Franz Kafka" and trial.last_read == 1793492884,
        "The Trial: 32709 s, 812 page turns, 65 %, DateLastRead parsed")
    check(trial and type(trial.t) == "number" and type(trial.p) == "number", "plain Lua numbers")
    check(data and data.books[TRIAL .. "#ch1"] == nil, "chapters (ContentType 9) ignored")
    check(data and data.current and data.current.title == "The Trial" and data.current.source == "kobo",
        "current book = latest DateLastRead")
    local m = data and data.books[MIDDLE]
    check(m and m.p == 120 and m.t == 5000, "store book with page turns")
    local missing = Readingstats:readNickel(tmp .. "/none.sqlite")
    check(missing == nil, "missing Kobo DB -> nil")

    -- A firmware storing '' instead of NULL in BookID for books: retried on ContentType alone
    local odd = tmp .. "/odd_kobo.sqlite"
    sql(odd, [[
CREATE TABLE content (ContentID TEXT, ContentType TEXT, BookID TEXT, Title TEXT, Attribution TEXT, DateLastRead TEXT,
    ___PercentRead INTEGER, TimeSpentReading INTEGER);
INSERT INTO content VALUES ('b1', '6', '', 'Odd Book', 'X', '2026-10-30T10:00:00Z', 50, 600);
]])
    local o = Readingstats:readNickel(odd)
    check(o and o.books.b1 and o.books.b1.t == 600 and o.current.title == "Odd Book",
        "book rows with a non-NULL BookID still found; no Event table is fine")
end

section("readingstats: Nickel snapshot deltas")
do
    local T0 = NOW - 2 * 86400
    local today_key = Tracking.dateKey(NOW)
    local r = Readingstats:snapshotNickel{ now = T0 }
    check(r.status == "baseline" and r.added_s == 0 and r.added_pages == 0, "first run: baseline only", r.status)
    local snap = Tracking:get("nickel_snapshot")
    check(snap and snap.books[TRIAL] and snap.books[TRIAL].t == 32709 and snap.books[TRIAL].p == 812,
        "snapshot stored with per-book totals")
    check(snap and snap.books["file:///mnt/onboard/Books/Unread.epub"] == nil, "unread books not stored")
    local clean, where = noCdata(snap)
    check(clean, "snapshot holds only plain values (LuaSettings can serialise it)", where)
    check(Tracking:totals(7, NOW).read_nickel_s == 0, "baseline adds nothing to the day counters")
    check(r.current and r.current.title == "The Trial", "snapshot returns the current Nickel book")
    check(Readingstats:nickelSnapshotDone(), "marked done for this process")

    local u = Readingstats:snapshotNickel{ now = T0 + 10 }
    check(u.status == "unchanged", "same DB file (mtime + size): not read again", u.status)

    -- Read 30 min / 40 pages of The Trial yesterday evening
    local yesterday21 = localMidnight(NOW, 1) + 21 * 3600
    local T1 = NOW - 3600
    sql(KOBO_DB, string.format([[
UPDATE content SET TimeSpentReading = TimeSpentReading + 1800, ___PercentRead = 70, DateLastRead = '%s' WHERE ContentID = '%s';
UPDATE Event SET EventCount = EventCount + 40 WHERE EventType = 46 AND ContentID = '%s';
]], isoUtc(yesterday21), TRIAL, TRIAL))
    local d = Readingstats:snapshotNickel{ now = T1, force = true }
    local yday = Tracking:day(yesterday21)
    check(d.status == "delta" and d.added_s == 1800 and d.added_pages == 40 and d.books_changed == 1,
        "delta: +1800 s, +40 pages", d.status .. " " .. d.added_s .. " " .. d.added_pages)
    check(yday.read_nickel_s == 1800 and yday.read_nickel_pages == 40,
        "attributed to the local day of DateLastRead (yesterday)", yday.date .. " " .. yday.read_nickel_s)
    check(Tracking:day(NOW).read_nickel_s == 0 or Tracking.dateKey(yesterday21) == today_key,
        "nothing booked on other days")
    check(d.current and d.current.percent == 0.70, "current book percent updated")

    -- Middlemarch read again but its DateLastRead is older than the previous snapshot: clamp
    local T2 = NOW
    sql(KOBO_DB, string.format([[
UPDATE content SET TimeSpentReading = TimeSpentReading + 600, DateLastRead = '%s' WHERE ContentID = '%s';
]], isoUtc(NOW - 5 * 86400), MIDDLE))
    local before = Tracking:day(T1).read_nickel_s
    local c = Readingstats:snapshotNickel{ now = T2, force = true }
    check(c.added_s == 600 and Tracking:day(T1).read_nickel_s == before + 600,
        "DateLastRead before the previous snapshot: booked on the previous snapshot's day")

    -- Huge jump (e.g. totals synced from the Kobo cloud): capped at the time since the last snapshot
    local T3 = T2 + 1800
    sql(KOBO_DB, string.format([[
UPDATE content SET TimeSpentReading = TimeSpentReading + 100000, DateLastRead = '%s' WHERE ContentID = '%s';
]], isoUtc(T2 + 600), TRIAL))
    local cap = Readingstats:snapshotNickel{ now = T3, force = true }
    check(cap.added_s == 1800, "time difference capped at the time since the previous snapshot", cap.added_s)

    -- Book reset in Nickel (totals go down): ignored, then counted from the new value
    sql(KOBO_DB, string.format("UPDATE content SET TimeSpentReading = 100 WHERE ContentID = '%s';", TRIAL))
    local T4 = T3 + 3600
    local reset = Readingstats:snapshotNickel{ now = T4, force = true }
    check(reset.added_s == 0, "negative difference ignored", reset.added_s)
    sql(KOBO_DB, string.format("UPDATE content SET TimeSpentReading = 150, DateLastRead = '%s' WHERE ContentID = '%s';",
        isoUtc(T4 + 100), TRIAL))
    local T5 = T4 + 3600
    local after = Readingstats:snapshotNickel{ now = T5, force = true }
    check(after.added_s == 50, "then counted from the new total", after.added_s)

    -- A book that wasn't in the snapshot: everything counts (still capped)
    sql(KOBO_DB, string.format([[
INSERT INTO content VALUES ('new-book', '6', NULL, NULL, NULL, 'New Book', 'Someone', '%s', 3, 1, 700, NULL);
INSERT INTO Event VALUES (46, NULL, NULL, 30, 'new-book', NULL, NULL);
]], isoUtc(T5 + 60)))
    local nb = Readingstats:snapshotNickel{ now = T5 + 3600, force = true }
    check(nb.added_s == 700 and nb.added_pages == 30, "new book: whole total counted", nb.added_s .. "/" .. nb.added_pages)
    check(nb.current and nb.current.title == "New Book", "current book follows DateLastRead")

    -- Errors never raise and keep the stored snapshot
    local stored = Tracking:get("nickel_snapshot")
    local nodb = Readingstats:snapshotNickel{ path = tmp .. "/missing.sqlite", now = T5 + 7200 }
    check(nodb.status == "no_db", "no Kobo DB: status no_db")
    writeFile(tmp .. "/broken.sqlite", string.rep("garbage", 500))
    local broken = Readingstats:snapshotNickel{ path = tmp .. "/broken.sqlite", now = T5 + 7200, force = true }
    check(broken.status == "error" and Tracking:get("nickel_snapshot") == stored,
        "corrupt Kobo DB: status error, snapshot kept", broken.status)
    check(Readingstats:nickelCurrent() and Readingstats:nickelCurrent().title == "New Book",
        "nickelCurrent() from memory / stored snapshot")

    -- The snapshot keeps the books read last (for the screen); one from an older plugin version
    -- (no book list) is read once more although the DB is unchanged, without counting anything twice.
    local snap2 = Tracking:get("nickel_snapshot")
    check(snap2.meta == Readingstats.SNAPSHOT_META and type(snap2.recent) == "table" and #snap2.recent == 3
        and snap2.recent[1].title == "New Book" and snap2.recent[2].title == "The Trial",
        "snapshot keeps the 3 books read last, most recent first")
    check(snap2.recent[2].image_id == Readingstats.imageIdFromContentId(TRIAL)
        and snap2.recent[2].image_id == "file____mnt_onboard_Books_The_Trial_epub",
        "no ImageId column on this firmware: derived from the ContentID like calibre does")
    snap2.meta, snap2.recent = nil, nil
    Readingstats._nickel_recent = nil
    local before_s = Tracking:totals(14, NOW).read_nickel_s
    local up = Readingstats:snapshotNickel{ now = T5 + 7200 }
    check(up.status == "delta" and up.added_s == 0 and up.added_pages == 0 and Tracking:totals(14, NOW).read_nickel_s == before_s,
        "older snapshot format: DB read again, nothing counted twice", up.status)
    check(type(Tracking:get("nickel_snapshot").recent) == "table" and #Readingstats:nickelRecent() == 3,
        "book list added to the snapshot")
    check(Readingstats:snapshotNickel{ now = T5 + 7300 }.status == "unchanged", "then unchanged again")
    Readingstats._nickel_recent = nil
    check(#Readingstats:nickelRecent() == 3 and Readingstats:nickelRecent()[1].title == "New Book",
        "nickelRecent() from the stored snapshot")
end

section("readingstats: recent books, ImageId, finished (full Nickel schema)")
local TRIAL_UUID = "ee5c3570-76cf-4f21-9b41-9b68352cdf9d"
local ORWELL_ID = "file____mnt_onboard_books_Nineteen_Eighty-Four_(1)_epub"
do
    local full = tmp .. "/KoboReader-full.sqlite"
    sql(full, string.format([[
CREATE TABLE content (ContentID TEXT NOT NULL, ContentType TEXT NOT NULL, BookID TEXT, Title TEXT, Attribution TEXT,
    DateLastRead TEXT, ___PercentRead INTEGER, ReadStatus INTEGER, TimeSpentReading INTEGER DEFAULT 0, ImageId TEXT,
    PRIMARY KEY (ContentID));
CREATE TABLE Event (EventType INTEGER NOT NULL, EventCount INTEGER DEFAULT 0, ContentID TEXT, PRIMARY KEY (EventType, ContentID));
INSERT INTO content VALUES ('%s', '6', NULL, 'The Trial', 'Franz Kafka', '%s', 65, 1, 32709, '%s');
INSERT INTO content VALUES ('file:///mnt/onboard/books/Nineteen Eighty-Four (1).epub', '6', NULL, 'Nineteen Eighty-Four',
    'George Orwell', '%s', 32, 1, 9000, '');
INSERT INTO content VALUES ('done-book', '6', NULL, 'Finished Book', 'Someone', '%s', 100, 2, 20000, 'done-book');
INSERT INTO content VALUES ('old-book', '6', NULL, 'Old Book', 'X', '%s', 10, 1, 100, 'old-book');
INSERT INTO content VALUES ('unread', '6', NULL, 'Unread', 'Y', NULL, 0, 0, 0, 'unread');
]], TRIAL_UUID, isoUtc(NOW - 3600), TRIAL_UUID, isoUtc(NOW - 86400), isoUtc(NOW - 2 * 86400), isoUtc(NOW - 30 * 86400)))
    local d = Readingstats:readNickel(full)
    check(d and #d.recent == 3 and d.recent[1].title == "The Trial" and d.recent[2].title == "Nineteen Eighty-Four"
        and d.recent[3].title == "Finished Book", "the 3 books read last, most recent first (unread ones never)")
    check(d and d.current == d.recent[1] and d.recent[1].image_id == TRIAL_UUID and d.recent[1].percent == 0.65,
        "store book: ImageId from the column")
    check(d and d.recent[2].image_id == ORWELL_ID, "empty ImageId: derived from the ContentID", d and d.recent[2].image_id)
    check(d and d.recent[3].finished == true and d.recent[1].finished == false, "ReadStatus 2 = finished")
    check(d and noCdata(d.recent), "plain values only")
end

section("readingstats: reading per day (14 days)")
do
    local ko14 = Readingstats:koreaderStats(NOW, 14)
    check(ko14.ok and ko14.today_pages == 4 and ko14.today_s == 240 and ko14.week_pages == 7 and ko14.week_s == 390,
        "14-day query: today and the last 7 days as before")
    local d7, d10 = os.date("%Y-%m-%d", localMidnight(NOW, 7) + 120), os.date("%Y-%m-%d", localMidnight(NOW, 10) + 50)
    check(ko14.days[d7] and ko14.days[d7].s == 999 and ko14.days[d10] and ko14.days[d10].s == 500,
        "7 and 10 days ago are inside the 14 days")
    local days = Readingstats:readingDays(14, NOW, ko14)
    check(#days == 14 and days[14].date == Tracking.dateKey(NOW) and days[14].day == 0 and days[1].day == -13,
        "14 days, oldest first, today last")
    local sums_ok, kobo_ok = true, true
    for _, d in ipairs(days) do
        if d.s ~= d.kobo_s + d.koreader_s or d.pages ~= d.kobo_pages + d.koreader_pages then sums_ok = false end
        local rec = Tracking:day(os.time{ year = tonumber(d.date:sub(1, 4)), month = tonumber(d.date:sub(6, 7)),
                                          day = tonumber(d.date:sub(9, 10)), hour = 12 })
        if d.kobo_s ~= rec.read_nickel_s or d.kobo_pages ~= rec.read_nickel_pages then kobo_ok = false end
    end
    check(sums_ok, "each day = Kobo + KOReader")
    check(kobo_ok, "Kobo part = Tracking's read_nickel_s / read_nickel_pages of that day")
    check(days[14].koreader_s == 240 and days[14].koreader_pages == 4 and days[7].koreader_s == 999
        and days[4].koreader_s == 500, "KOReader part per day (today, 7 and 10 days ago)")
    local yday = Tracking.dateKey(localMidnight(NOW, 1) + 21 * 3600)
    check(days[13].date == yday and days[13].kobo_s >= 1800, "yesterday's Kobo reading", days[13].kobo_s)
    check(noCdata(days), "plain values only")
    local own = Readingstats:readingDays(14, NOW)
    check(own[14].s == days[14].s and own[7].s == days[7].s, "queries KOReader's statistics itself when not given")
    Readingstats.koreader_db = tmp .. "/nope.sqlite3"
    local kobo_only = Readingstats:readingDays(14, NOW)
    Readingstats.koreader_db = KO_DB
    check(kobo_only[14].koreader_s == 0 and kobo_only[13].s == days[13].kobo_s, "no KOReader statistics: Kobo only")
end

section("stats: Anki cache and rollover")
local Client = require("kanki/client")
local Stats = require("kanki/stats")
do
    Tracking:set("anki_stats_cache", nil)
    check(Stats:anki(NOW) == nil, "no cache -> nil")

    local probe, fetched = "refused", 0
    local body
    Client.probe = function() return probe end
    Client.stats = function(_, opts)
        fetched = fetched + 1
        assert(opts and opts.timeout and opts.timeout <= 5, "short timeout")
        return body
    end
    local res, why = Stats:refreshAnki()
    check(res == nil and why == "server_not_running" and fetched == 0, "server not running: no request, nothing cached")
    check(Tracking:get("anki_stats_cache") == nil, "cache untouched")

    local next_day_at = NOW + 3 * 3600
    body = {
        today = { answered = 128, seconds = 1380, correct = 117, learn = 10, review = 118, relearn = 0,
                  mature_correct = 60, mature_total = 64 },
        days = {},
        streak = 12, due_tomorrow = 87, due_today = { new = 20, learning = 3, review = 21 },
        retention = { today = 0.91, week = 0.94, month = 0.93 },
        cards = { new = 543, learn = 0, relearn = 1, young = 90, mature = 3525, suspended = 987, buried = 0 },
        studied_text = "Studied 128 cards in 23 minutes today.",
        next_day_at = next_day_at, generated_at = NOW - 120,
        weird = function() end, -- must not reach the tracking file
    }
    for d = -13, 0 do
        table.insert(body.days, { day = d, count = (d == 0) and 128 or (d % 3 == 0 and 0 or 40 + d * 2), seconds = 600 })
    end
    probe = "open"
    local flushed = 0
    local orig_flush = Tracking.flush
    Tracking.flush = function(t) flushed = flushed + 1 return orig_flush(t) end
    res = Stats:refreshAnki()
    Tracking.flush = orig_flush
    check(res and fetched == 1 and Tracking:get("anki_stats_cache") ~= nil, "server running: fetched and cached")
    check(flushed >= 1, "cache flushed to disk")
    local cache = Tracking:get("anki_stats_cache")
    check(cache.weird == nil and noCdata(cache), "cached body sanitised (no functions)")

    probe, body = "open", nil
    local res2 = Stats:refreshAnki()
    check(res2 == nil and Tracking:get("anki_stats_cache") == cache, "failed fetch keeps the previous cache")

    local a = Stats:anki(NOW)
    check(a and a.today.answered == 128 and a.rolled_over_days == 0, "same Anki day: today as cached")
    check(a and a.left_today == 24 and a.due_tomorrow == 87 and a.streak == 12, "left today = review + learning")
    check(a and a.as_of == NOW - 120, "as-of timestamp = generated_at")
    check(a and #a.days == 14 and a.days[14].day == 0 and a.days[14].count == 128 and a.days[1].day == -13,
        "14 days, oldest first, today last")
    check(a and a.days[14].start == next_day_at - 86400, "each day knows when it started")

    local b = Stats:anki(next_day_at + 60)
    check(b and b.rolled_over_days == 1 and b.today.answered == 0 and b.today.seconds == 0,
        "after next_day_at: today zeroed")
    check(b and b.days[13].count == 128 and b.days[14].count == 0, "days shifted: yesterday = cached today")
    check(b and b.streak == 12, "streak kept for one rollover (cached day had reviews)")
    check(b and b.left_today == 87 and b.due_tomorrow == nil, "due today = cached due tomorrow")
    check(b and b.next_day_at == next_day_at + 86400, "next rollover moved on")
    check(Tracking:get("anki_stats_cache").today.answered == 128, "cache itself not modified")

    local c = Stats:anki(next_day_at + 2 * 86400 + 60)
    check(c and c.rolled_over_days == 3 and c.streak == 0 and c.left_today == nil, "3 days later: streak 0, due unknown")
    check(c and c.days[11].count == 128 and c.days[12].count == 0, "days shifted by 3")

    cache.today.answered = 0
    cache.days[14].count = 0
    local d = Stats:anki(next_day_at + 60)
    check(d and d.streak == 0, "streak broken when the cached day had no reviews")
    cache.today.answered = 128
    cache.days[14].count = 128
end

section("stats: collect()")
local DATA
do
    Tracking:add({ study_s = 2520, cards = 128, sessions = 2, pomodoros = 3, focus_s = 4500 }, NOW)
    Tracking:add({ study_s = 3600, cards = 200, pomodoros = 4, focus_s = 6000 }, NOW - 86400)
    DATA = Stats:collect{ now = NOW }
    check(DATA.anki and DATA.study and DATA.reading and DATA.battery, "all sections present")
    check(DATA.study.today.pomodoros == 3 and DATA.study.week.pomodoros >= 7, "study: today and 7 days")
    local r = DATA.reading
    check(r.today.koreader_pages == 4 and r.today.pages == r.today.kobo_pages + 4 and r.today.s == r.today.kobo_s + 240,
        "reading today = Kobo + KOReader", r.today.pages)
    check(r.week.koreader_pages == 7 and r.week.kobo_s >= 1800, "reading 7 days includes yesterday's Kobo reading")
    check(r.has_kobo and r.has_koreader, "both sources known")
    check(#r.books == 2 and r.books[1].last_read >= r.books[2].last_read, "books sorted, most recent first")
    check(DATA.battery.level == 83 and DATA.battery.charging == false, "battery")

    local broken = Readingstats.koreaderStats
    Readingstats.koreaderStats = function() error("boom") end
    local partial = Stats:collect{ now = NOW }
    Readingstats.koreaderStats = broken
    check(partial.reading == nil and partial.anki ~= nil and partial.study ~= nil, "a failing section is nil, the rest is built")
    check(type(r.days) == "table" and #r.days == 14 and r.days[14].koreader_s == 240, "14 days of reading for the chart")
    check(r.books[1].title == "New Book" and r.books[2].title == "The Trial",
        "current book = read last anywhere (Nickel here); second = the next one", r.books[1].title)
end

section("stats: current and second book")
do
    local saved = Readingstats._nickel_recent
    Readingstats._nickel_recent = {
        { source = "kobo", title = "The Trial", author = "Franz Kafka", percent = 0.65, last_read = NOW - 3600,
          image_id = TRIAL_UUID },
        { source = "kobo", title = "Finished Book", percent = 1, last_read = NOW - 5000, finished = true },
        { source = "kobo", title = "DUNE ", percent = 0.1, last_read = NOW - 9000 },
        { source = "kobo", title = "Nineteen Eighty-Four", percent = 0.32, last_read = NOW - 86400, image_id = ORWELL_ID },
    }
    local books = Stats:books()
    local titles = {}
    for _, b in ipairs(books) do table.insert(titles, b.title) end
    check(#books == 4 and books[1].title == "The Trial" and books[2].title == "Finished Book" and books[3].title == "Dune"
        and books[4].title == "Nineteen Eighty-Four", "KOReader and Nickel books by last read; same title once",
        table.concat(titles, ", "))
    check(books[1].image_id == TRIAL_UUID and books[3].source == "koreader" and books[3].file ~= nil,
        "what the covers need: ImageId (Kobo), file (KOReader)")
    local r = Stats:reading(NOW)
    check(#r.books == 2 and r.books[1].title == "The Trial" and r.books[2].title == "Dune",
        "second book: the next one not finished")
    Readingstats._nickel_recent = { { source = "kobo", title = "Only", last_read = NOW - 60 } }
    Extra.gsettings.lastfile = nil
    local r1 = Stats:reading(NOW)
    check(#r1.books == 1 and r1.books[1].title == "Only", "one book: no second line")
    Readingstats._nickel_recent = {}
    check(#Stats:reading(NOW).books == 0, "no book at all")
    Extra.gsettings.lastfile = tmp .. "/Dune.epub"
    Readingstats._nickel_recent = saved
end

section("readingstats: Nickel cover files (.kobo-images)")
local IMG = tmp .. "/kobo-images"
local WEIRD_ID = "weird%id[1].(x)+-"
local cover_paths = {
    full = IMG .. "/244/233/" .. TRIAL_UUID .. " - N3_FULL.parsed",
    libfull = IMG .. "/244/233/" .. TRIAL_UUID .. " - N3_LIBRARY_FULL.parsed",
    grid = IMG .. "/244/233/" .. TRIAL_UUID .. " - N3_LIBRARY_GRID.parsed",
    orwell_lib = IMG .. "/12/7/" .. ORWELL_ID .. " - N3_LIBRARY_FULL.parsed",
    weird_grid = IMG .. "/5/250/" .. WEIRD_ID .. " - N3_LIBRARY_GRID.parsed",
}
local walks = 0
do
    for _, d in ipairs({ "244/233", "12/7", "5/250", "99/1", "0" }) do os.execute("mkdir -p '" .. IMG .. "/" .. d .. "'") end
    Extra.writeSyntheticCover(cover_paths.full, 600, 900)
    Extra.writeSyntheticCover(cover_paths.libfull, 300, 450, { top = { 0x6A, 0x1B, 0x4D }, bottom = { 0xC2, 0x41, 0x0C } })
    Extra.writeSyntheticCover(cover_paths.grid, 100, 150)
    Extra.writeSyntheticCover(cover_paths.orwell_lib, 240, 360, { top = { 0x33, 0x33, 0x33 }, bottom = { 0xAA, 0x22, 0x22 } })
    Extra.writeSyntheticCover(IMG .. "/12/7/" .. ORWELL_ID .. " - N3_LIBRARY_GRID.parsed", 80, 120)
    Extra.writeSyntheticCover(cover_paths.weird_grid, 90, 135)
    -- decoys: an id that merely starts with another one, a prefix of one, other files
    writeFile(IMG .. "/12/7/" .. ORWELL_ID .. "_extra - N3_FULL.parsed", "decoy")
    writeFile(IMG .. "/99/1/ee5c3570 - N3_FULL.parsed", "decoy")
    writeFile(IMG .. "/99/1/other-id - N3_FULL.parsed", "decoy")
    writeFile(IMG .. "/99/1/notes.txt", "x")
    writeFile(IMG .. "/README.txt", "x")
    Readingstats.KOBO_IMAGES = IMG
    Readingstats._walked = {}
    Tracking:set("nickel_cover_paths", nil)

    local orig_find = Readingstats._findNickelCovers
    Readingstats._findNickelCovers = function(self, ids)
        walks = walks + 1
        return orig_find(self, ids)
    end
    check(Readingstats:nickelCoverPath(TRIAL_UUID) == nil and walks == 0, "nothing known yet; a lookup never walks")
    local n = Readingstats:resolveNickelCovers({ TRIAL_UUID, ORWELL_ID, WEIRD_ID, "missing-id", TRIAL_UUID })
    check(n == 3 and walks == 1, "one walk for all the ids", n .. " found, " .. walks .. " walks")
    check(Readingstats:nickelCoverPath(TRIAL_UUID) == cover_paths.full, "N3_FULL preferred")
    check(Readingstats:nickelCoverPath(ORWELL_ID) == cover_paths.orwell_lib,
        "no N3_FULL: N3_LIBRARY_FULL; an id that only starts with it is a different book")
    check(Readingstats:nickelCoverPath(WEIRD_ID) == cover_paths.weird_grid,
        "only N3_LIBRARY_GRID; Lua pattern characters in an ImageId are matched literally")
    check(Readingstats:nickelCoverPath("missing-id") == nil, "no cover file: nil")
    local stored = Tracking:get("nickel_cover_paths")
    check(type(stored) == "table" and stored[TRIAL_UUID] == cover_paths.full and stored["missing-id"] == nil
        and noCdata(stored), "ImageId -> path kept in Tracking")

    Readingstats:resolveNickelCovers({ TRIAL_UUID, ORWELL_ID, WEIRD_ID, "missing-id" })
    check(walks == 1, "known paths and ids already searched for: no walk")
    os.remove(cover_paths.full)
    check(Readingstats:nickelCoverPath(TRIAL_UUID) == nil, "cached file gone: no path")
    Readingstats._walked = {} -- a new KOReader process
    Readingstats:resolveNickelCovers({ TRIAL_UUID })
    check(walks == 2 and Readingstats:nickelCoverPath(TRIAL_UUID) == cover_paths.libfull,
        "vanished: searched again, next best file")
    Readingstats._walked = {}
    Readingstats.WALK_MAX_ENTRIES = 2
    local found, entries = orig_find(Readingstats, { "missing-id" })
    Readingstats.WALK_MAX_ENTRIES = 20000
    check(next(found) == nil and entries <= 2, "the walk stops after WALK_MAX_ENTRIES entries", entries)
    Readingstats.KOBO_IMAGES = tmp .. "/no-such-dir"
    check(Readingstats:resolveNickelCovers({ "another-id" }) == 0, "no .kobo-images: nothing found, no error")
    Readingstats.KOBO_IMAGES = IMG
    Readingstats._walked = {}

    local src = Readingstats:coverSource({ source = "kobo", image_id = TRIAL_UUID })
    check(src and src.kind == "image" and src.path == cover_paths.libfull and src.key:find(cover_paths.libfull, 1, true),
        "cover source of a Kobo book: the cover file, keyed by path, mtime and size")
    check(Readingstats:coverSource({ source = "kobo" }) == nil and Readingstats:coverSource(nil) == nil,
        "no ImageId: no cover")
end

section("readingstats: pre-scaled cover cache")
local RI = Extra.RenderImage
do
    Readingstats.cover_cache_dir = tmp .. "/cache/kanki-covers"
    local cache_dir = Readingstats.cover_cache_dir
    local book = { source = "kobo", title = "The Trial", image_id = TRIAL_UUID }
    local live0 = Extra.live_images
    local d0 = RI.decodes
    local bb = Readingstats:coverBB(book, 200, 320)
    check(bb and bb:getWidth() == 200 and bb:getHeight() == 300 and RI.decodes == d0 + 1,
        "first time: decoded and scaled to fit 200x320 (aspect kept)", bb and (bb:getWidth() .. "x" .. bb:getHeight()))
    check(#listDir(cache_dir, ".kcover") == 1 and #listDir(cache_dir, ".tmp") == 0, "stored in the cache dir (no temp file left)")
    local bb2 = Readingstats:coverBB(book, 200, 320)
    check(bb2 and RI.decodes == d0 + 1 and bb2:getWidth() == 200 and bytesOf(bb2) == bytesOf(bb),
        "second time: loaded from the cache, no decoding, same pixels")
    local again = Readingstats:coverBB(book, 200, 320, { cached_only = true })
    check(again and RI.decodes == d0 + 1, "cached_only: from the cache")
    bb:free()
    bb2:free()
    again:free()
    check(Readingstats:coverBB(book, 120, 200, { cached_only = true }) == nil and RI.decodes == d0 + 1,
        "cached_only and nothing cached for that box: nil, no decoding")
    local small = Readingstats:coverBB(book, 1000, 1600)
    check(small and small:getWidth() == 300 and small:getHeight() == 450, "never upscaled")
    small:free()
    check(#listDir(cache_dir, ".kcover") == 2, "one cache entry per box")

    -- a new version of the source: new key, rebuilt
    Extra.writeSyntheticCover(cover_paths.libfull, 320, 480)
    local d1 = RI.decodes
    local nb = Readingstats:coverBB(book, 200, 320)
    check(nb and RI.decodes == d1 + 1 and nb:getHeight() == 300, "source changed (size/mtime): rebuilt")
    nb:free()
    -- a broken cache file is dropped and rebuilt
    local src = Readingstats:coverSource(book)
    local file = Readingstats:_coverCacheFile(src, 200, 320)
    local f = assert(io.open(file, "rb"))
    local content = f:read("*a")
    f:close()
    check(content:match("^KANKICOVER 1 200 300 4 600 raw %d+\n"), "header: size, type, stride, format", content:sub(1, 40))
    writeFile(file, content:sub(1, 500))
    local rb = Readingstats:coverBB(book, 200, 320)
    check(rb and RI.decodes == d1 + 2 and rb:getWidth() == 200, "truncated cache file: dropped and rebuilt")
    rb:free()
    writeFile(file, "garbage")
    rb = Readingstats:coverBB(book, 200, 320)
    check(rb and RI.decodes == d1 + 3, "garbage cache file: dropped and rebuilt")
    rb:free()

    -- zstd (KOReader has it): compressed on write, uncompressed on read
    Extra.setZstd(true)
    Readingstats._zstd = nil
    os.remove(file)
    local zb = Readingstats:coverBB(book, 200, 320)
    local zf = assert(io.open(file, "rb"))
    local zhead = zf:read("*l")
    zf:close()
    check(zb and zhead:find(" zstd ", 1, true) and Extra.zstd_calls.compress == 1, "zstd available: stored compressed", zhead)
    local zb2 = Readingstats:coverBB(book, 200, 320)
    check(zb2 and Extra.zstd_calls.uncompress == 1 and bytesOf(zb2) == bytesOf(zb) and RI.decodes == d1 + 4,
        "and loaded back without decoding")
    zb:free()
    zb2:free()
    Extra.setZstd(false)
    Readingstats._zstd = nil
    local rz = Readingstats:coverBB(book, 200, 320)
    check(rz and RI.decodes == d1 + 5, "zstd file but no zstd now: rebuilt (raw)")
    rz:free()

    -- failures never raise
    RI.fail = "decoder exploded"
    os.remove(file)
    local ok_fail, res_fail = pcall(Readingstats.coverBB, Readingstats, book, 200, 320)
    RI.fail = nil
    check(ok_fail and res_fail == nil, "decoder raising: nil, no error")
    writeFile(tmp .. "/not-an-image.parsed", "not an image")
    local orig_path = Readingstats.nickelCoverPath
    Readingstats.nickelCoverPath = function() return tmp .. "/not-an-image.parsed" end
    check(Readingstats:coverBB(book, 200, 320) == nil, "undecodable source: nil")
    Readingstats.COVER_SOURCE_MAX_BYTES = 10
    Readingstats.nickelCoverPath = function() return cover_paths.libfull end
    local d2 = RI.decodes
    os.remove(file)
    check(Readingstats:coverBB(book, 200, 320) == nil and RI.decodes == d2, "oversized source: not decoded")
    Readingstats.COVER_SOURCE_MAX_BYTES = 8 * 1024 * 1024
    Readingstats.nickelCoverPath = orig_path

    -- background preparation: builds once, then only checks
    os.remove(file)
    local d3 = RI.decodes
    check(Readingstats:prepareCover(book, 200, 320) == "built" and RI.decodes == d3 + 1, "prepareCover builds a missing cover")
    check(Readingstats:prepareCover(book, 200, 320) == "cached" and RI.decodes == d3 + 1, "then only checks it exists")
    check(Readingstats:prepareCover({ source = "kobo", image_id = "missing-id" }, 200, 320) == "none", "no cover: none")

    -- pruning keeps the newest COVER_CACHE_FILES
    Readingstats.COVER_CACHE_FILES = 3
    for i = 1, 4 do
        local c = Readingstats:coverBB(book, 100 + i, 200)
        if c then c:free() end
    end
    check(#listDir(cache_dir, ".kcover") <= 3, "old cache entries removed", #listDir(cache_dir, ".kcover"))
    check(exists(Readingstats:_coverCacheFile(src, 104, 200)), "the newest kept")
    Readingstats.COVER_CACHE_FILES = 12
    check(Extra.live_images == live0, "every bitmap freed", Extra.live_images - live0)
end

section("readingstats: KOReader covers (CoverBrowser's cache)")
do
    local book_path = tmp .. "/Dune.epub"
    local kbook = { source = "koreader", title = "Dune", file = book_path }
    local bim_db = tmp .. "/bookinfo_cache.sqlite3"
    writeFile(bim_db, "db")
    local calls, mode = 0, "cover"
    package.loaded["bookinfomanager"] = {
        db_location = bim_db,
        getBookInfo = function(_, file, get_cover)
            calls = calls + 1
            assert(file == book_path and get_cover == true)
            if mode == "none" then return { has_cover = nil } end
            local bb = RI:renderImageFile(cover_paths.orwell_lib)
            return { has_cover = "Y", ignore_cover = mode == "ignored" and "Y" or nil, cover_bb = bb }
        end,
    }
    local live0 = Extra.live_images
    local kb = Readingstats:coverBB(kbook, 200, 320)
    check(kb and calls == 1 and kb:getWidth() == 200 and kb:getHeight() == 300,
        "KOReader book: CoverBrowser's cover blitbuffer, pre-scaled and cached")
    kb:free()
    local kb2 = Readingstats:coverBB(kbook, 200, 320)
    check(kb2 and calls == 1, "then from our cache (CoverBrowser not asked again)")
    kb2:free()
    for _, name in ipairs(listDir(Readingstats.cover_cache_dir, ".kcover")) do
        os.remove(Readingstats.cover_cache_dir .. "/" .. name)
    end
    mode = "ignored"
    check(Readingstats:coverBB(kbook, 200, 320) == nil and calls == 2, "cover hidden in CoverBrowser: none")
    mode = "none"
    check(Readingstats:coverBB(kbook, 200, 320) == nil and calls == 3, "no cover in CoverBrowser's cache: none")
    mode = "cover"
    check(Readingstats:coverBB({ source = "koreader", title = "Dune", file = book_path, exclude_cover = true }, 200, 320) == nil
        and calls == 3, "book excluded from the sleep screen in KOReader: no cover, CoverBrowser not asked")
    os.remove(bim_db)
    check(Readingstats:coverBB(kbook, 200, 320) == nil and calls == 3, "CoverBrowser DB missing: not asked (it would create it)")
    package.loaded["bookinfomanager"] = nil
    writeFile(bim_db, "db")
    check(Readingstats:coverBB(kbook, 200, 320) == nil, "CoverBrowser not loaded: no cover, documents never opened")
    check(Extra.live_images == live0, "every bitmap freed", Extra.live_images - live0)
    Extra.sidecars[book_path].exclude_screensaver = true
    local excluded = Readingstats:koreaderBook()
    Extra.sidecars[book_path].exclude_screensaver = nil
    check(excluded and excluded.exclude_cover == true and Readingstats:koreaderBook().exclude_cover == false,
        "KOReader's 'exclude from sleep screen' read from the book's settings")
end

section("statsview: build and paint")
local StatsView = require("kanki/statsview")
do
    local function render(w, h, color, data, opts)
        Extra.setScreen(w, h, color)
        opts = opts or {}
        local view = StatsView:new{ data = data, sleep = opts.sleep ~= false, footer_text = opts.footer,
                                    interactive = opts.interactive }
        local rec = Extra.newRecorder(w, h)
        view[1]:paintTo(rec, 0, 0)
        return view, rec
    end
    local cases = {
        { 1264, 1680, true, "portrait colour" }, { 1264, 1680, false, "portrait grey" },
        { 1680, 1264, true, "landscape colour" }, { 1680, 1264, false, "landscape grey" },
    }
    for _, cs in ipairs(cases) do
        local view, rec = render(cs[1], cs[2], cs[3], DATA, { footer = "Sleeping" })
        check(#rec.out_of_bounds == 0, cs[4] .. ": everything painted on screen", rec.out_of_bounds[1])
        check(view.scale >= 1, cs[4] .. ": fits without shrinking fonts", view.scale)
        check(rec.rgb_used == cs[3], cs[4] .. ": " .. (cs[3] and "colour marks used" or "greys only"))
        check(rec:hasText("^READING$") and rec:hasText("^ANKI$") and rec:hasText("^128$") and rec:hasText("^Today$")
            and rec:hasText("^New Book$") and rec:hasText("^The Trial$") and rec:hasText("^Sleeping$")
            and rec:hasText("^STUDY ON THIS KOBO$") and rec:hasText("^Minutes read, last 14 days$")
            and rec:hasText("^Reviews, last 14 days$") and rec:hasText("^Last 7 days$"),
            cs[4] .. ": key texts present", table.concat(rec:texts(), " | "))
        local rd, an, st = rec:hasText("^READING$"), rec:hasText("^ANKI$"), rec:hasText("^STUDY ON THIS KOBO$")
        local reading_first
        if cs[1] > cs[2] then
            reading_first = rd and an and st and rd.y == an.y and rd.x < an.x and an.y < st.y
        else
            reading_first = rd and an and st and rd.y < an.y and an.y < st.y
        end
        check(reading_first, cs[4] .. ": reading first (portrait: on top; landscape: left column), then Anki, then study")
        local size = view:getSize()
        check(size.w == cs[1] and size.h == cs[2], cs[4] .. ": full-screen size")
    end

    local _, rec = render(1264, 1680, true, { now = NOW })
    check(#rec.out_of_bounds == 0 and rec:hasText("No Anki statistics yet"), "empty data: placeholders, on screen")
    local _, rec2 = render(1680, 1264, true, { now = NOW, anki = Stats:anki(NOW + 10 * 86400) })
    check(#rec2.out_of_bounds == 0 and rec2:hasText("^Due today$"), "stale cache after rollover renders")

    -- crowded: long titles, huge numbers, many Pomodoros, low battery
    local crowded = Stats:collect{ now = NOW }
    crowded.anki.today.answered = 12345
    crowded.anki.today.seconds = 99999
    crowded.study.today.pomodoros = 40
    crowded.reading.books[1].title = string.rep("A very long book title ", 10)
    crowded.reading.today.pages = 123456
    crowded.battery = { level = 9, charging = false }
    for _, cs in ipairs(cases) do
        local _, r = render(cs[1], cs[2], cs[3], crowded)
        check(#r.out_of_bounds == 0, cs[4] .. ": crowded data stays on screen", r.out_of_bounds[1])
    end

    -- default data (collect() itself)
    Extra.setScreen(1264, 1680, true)
    local v = StatsView:new{ sleep = true }
    check(v.data and v.data.now, "data collected when none given")
    check(next(v.key_events) == nil and next(v.ges_events) == nil, "sleep widget: no input handling")
    check(v.dithered == true, "flagged dithered")
    check(v:onTap() == false, "sleep widget ignores taps")
end

section("statsview: current book with and without a cover")
do
    local function cdata()
        local d = Stats:collect{ now = NOW }
        d.reading.books = {
            { source = "kobo", title = "The Trial", author = "Franz Kafka", percent = 0.65, last_read = NOW - 3600,
              image_id = TRIAL_UUID },
            { source = "kobo", title = "Nineteen Eighty-Four", author = "George Orwell", percent = 0.32,
              last_read = NOW - 86400, image_id = ORWELL_ID },
        }
        return d
    end
    local cases = {
        { 1264, 1680, true, "portrait colour" }, { 1264, 1680, false, "portrait grey" },
        { 1680, 1264, true, "landscape colour" }, { 1680, 1264, false, "landscape grey" },
    }
    local data = cdata()
    for _, cs in ipairs(cases) do
        Extra.setScreen(cs[1], cs[2], cs[3])
        local live0 = Extra.live_images
        local view = StatsView:new{ data = data, sleep = true, footer_text = "Sleeping" }
        local rec = Extra.newRecorder(cs[1], cs[2])
        view[1]:paintTo(rec, 0, 0)
        local imgs = rec:images()
        local img = imgs[1]
        check(#imgs == 1 and #rec.out_of_bounds == 0, cs[4] .. ": cover painted, everything on screen", rec.out_of_bounds[1])
        check(view.scale >= 1, cs[4] .. ": fits without shrinking fonts", view.scale)
        check(img and img.grey == not cs[3], cs[4] .. ": cover " .. (cs[3] and "in colour" or "converted to grey"))
        check(rec.rgb_used == cs[3], cs[4] .. ": " .. (cs[3] and "colour marks" or "no colour at all"))
        local title = rec:hasText("^The Trial$")
        check(img and title and img.x + img.w <= title.x and img.y <= title.y and img.w < cs[1] / 3,
            cs[4] .. ": cover on the left of the title, about a third of the column")
        local clash
        for _, op in ipairs(rec.ops) do
            if op.op == "text" and img and overlaps(op, img) then clash = op.text end
        end
        check(img and not clash, cs[4] .. ": no text over the cover", clash)
        check(rec:hasText("^65$") and rec:hasText("^Nineteen Eighty%-Four$") and rec:hasText("^32%%$")
            and rec:hasText("^Franz Kafka$") and rec:hasText("^Kobo · last read "), cs[4] .. ": book texts")
        local border
        for _, op in ipairs(rec.ops) do
            if op.op == "border" and img and op.x == img.x and op.y == img.y and op.w == img.w then border = op end
        end
        check(border ~= nil, cs[4] .. ": hairline around the cover")
        if cs[1] < cs[2] then
            local today = rec:hasText("^Last 7 days$")
            check(today and today.x > img.x + img.w and today.y < img.y + img.h,
                cs[4] .. ": today / last 7 days beside the cover")
        end
        view:onCloseWidget()
        check(Extra.live_images == live0, cs[4] .. ": cover bitmaps freed with the view", Extra.live_images - live0)
    end

    -- the sleep path with a warm cache: no decoding, no walking
    Extra.setScreen(1264, 1680, true)
    local d0, w0 = RI.decodes, walks
    local v = StatsView:new{ data = cdata(), sleep = true }
    check(v._cover and RI.decodes == d0 and walks == w0, "cached cover: no decoding, no walk")
    v:onCloseWidget()

    -- text-only: no cover known, or covers off, or the loader failing
    for _, cs in ipairs(cases) do
        Extra.setScreen(cs[1], cs[2], cs[3])
        local nd = cdata()
        nd.reading.books[1].image_id = "no-such-cover"
        local view = StatsView:new{ data = nd, sleep = true, footer_text = "Sleeping" }
        local rec = Extra.newRecorder(cs[1], cs[2])
        view[1]:paintTo(rec, 0, 0)
        check(#rec:images() == 0 and #rec.out_of_bounds == 0 and view.scale >= 1 and rec:hasText("^The Trial$")
            and rec:hasText("^Last 7 days$"), cs[4] .. ": no cover: text-only layout", view.scale)
        view:onCloseWidget()
    end
    Extra.setScreen(1264, 1680, true)
    local off = StatsView:new{ data = cdata(), sleep = true, covers = false }
    check(off._cover == false, "covers = false: none loaded")
    local boom = StatsView:new{ data = cdata(), sleep = true, cover_loader = function() error("loader exploded") end }
    local rec = Extra.newRecorder(1264, 1680)
    boom[1]:paintTo(rec, 0, 0)
    check(not boom.layout_failed and #rec:images() == 0 and rec:hasText("^The Trial$"),
        "cover loader raising: text-only, no error")
    -- a very wide and a very tall image stay inside the cover column
    local col_w = math.floor(1264 * StatsView.LAYOUT.cover_ratio)
    for _, size in ipairs({ { 900, 300 }, { 200, 900 } }) do
        local probe = StatsView:new{ data = cdata(), sleep = true, cover_loader = function()
            return require("ffi/blitbuffer").new(size[1], size[2], 4)
        end }
        local r2 = Extra.newRecorder(1264, 1680)
        probe[1]:paintTo(r2, 0, 0)
        local im = r2:images()[1]
        local t = r2:hasText("^The Trial$")
        check(im and t and im.x + im.w <= t.x and im.w <= col_w and im.h <= col_w * StatsView.LAYOUT.cover_max_aspect
            and math.abs(im.w / im.h - size[1] / size[2]) < 0.05,
            string.format("%dx%d image: fits the cover box, aspect kept", size[1], size[2]),
            im and (im.w .. "x" .. im.h))
        probe:onCloseWidget()
    end
    -- a broken bitmap (paint-time failure) never breaks the page
    local bad = StatsView:new{ data = cdata(), sleep = true, cover_loader = function()
        return { getWidth = function() return 400 end, getHeight = function() return 600 end,
                 getType = function() return 4 end, free = function() end }
    end }
    local r3 = Extra.newRecorder(1264, 1680)
    local ok_paint = pcall(bad[1].paintTo, bad[1], r3, 0, 0)
    check(ok_paint and r3:hasText("^The Trial$") and #r3:images() == 0, "unusable cover bitmap: the rest is painted")
    bad:onCloseWidget()
end

section("statsview: in-app view")
do
    Extra.setScreen(1264, 1680, true)
    local probes = 0
    Client.probe = function() probes = probes + 1 return "refused" end
    local view = StatsView.show()
    check(probes == 1, "opening refreshes Anki (probe only, server not running)")
    check(UIManager:isShown(view), "shown")
    check(Extra.last_show.mode == "full" and Extra.last_show.dither == true, "full refresh with dithering")
    check(view.key_events.KankiStatsClose and #view.key_events.KankiStatsClose == 3, "Back / PgFwd / PgBack close it")
    check(view.ges_events.Tap ~= nil, "tap closes it")
    check(view[1] and view[1].root, "laid out")
    view:onKankiStatsClose()
    check(not UIManager:isShown(view) and Extra.last_close.mode == "flashui", "closed with a flashing refresh")

    -- rotation: the widget below rotates, we come back in the new orientation
    local base = { handleEvent = function(self, ev)
        if ev.handler == "onSetRotationMode" then
            require("device").screen:setRotationMode(ev.args[1])
            self.rotated = true
            return true
        end
    end }
    UIManager:show(base)
    local v2 = StatsView.show{ refresh = false, data = DATA }
    check(v2:onSetRotationMode(1) == true and base.rotated, "rotation passed to the view below")
    local top = UIManager._stack[#UIManager._stack]
    check(top ~= v2 and top.width == 1680 and top.height == 1264 and not UIManager:isShown(v2),
        "re-shown in landscape")
    UIManager:close(top)
    UIManager:close(base)
    Extra.setScreen(1264, 1680, true)
end

section("sleepscreen: KOReader Screensaver hook")
do
    -- Stand-in for frontend/ui/screensaver.lua: the parts of setup()/show() our hook relies on.
    local real_statistics = { name = "statistics", inserted = 0 }
    function real_statistics:insertDB() self.inserted = self.inserted + 1 end
    function real_statistics:onShowReaderProgress() return "koreader-readingprogress-widget" end
    local ui = { statistics = real_statistics,
                 bookinfo = { expandString = function(_, s) return (s:gsub("%%T", "Dune")) end } }
    local SS = { default_screensaver_message = "Sleeping" }
    function SS:setup(event, event_message)
        self.ui = ui
        self.show_message = Extra.gsettings.screensaver_show_message == true
        self.screensaver_type = Extra.gsettings.screensaver_type
        self.prefix = event and event .. "_" or ""
        self.event_message = event_message
        self.overlay_message = nil
        if Extra.gsettings[self.prefix .. "screensaver_type"] ~= nil then
            self.screensaver_type = Extra.gsettings[self.prefix .. "screensaver_type"]
        elseif event then
            self.overlay_message = event_message
        end
        if self.screensaver_type == "cover" then
            self.image = { freed = false, free = function(img) img.freed = true end }
        end
        if self.screensaver_type == "readingprogress" and self.ui.statistics == nil then
            self.screensaver_type = "random_image"
        end
        self.screensaver_background = (self.screensaver_type == "cover" or self.screensaver_type == "random_image")
            and "black" or (Extra.gsettings.screensaver_msg_background or "none")
    end
    function SS:show()
        local widget
        if self.screensaver_type == "readingprogress" then
            widget = self.ui.statistics:onShowReaderProgress(true)
        elseif self.screensaver_type == "cover" then
            widget = "cover-widget"
        end
        self.shown = { type = self.screensaver_type, widget = widget, show_message = self.show_message,
                       overlay = self.overlay_message, background = self.screensaver_background,
                       statistics_during_show = self.ui.statistics }
        if self.fail_show then error("show failed") end
        return "shown"
    end
    package.loaded["ui/screensaver"] = SS
    local orig_setup, orig_show = SS.setup, SS.show

    local SleepScreen = require("kanki/sleepscreen")
    check(SleepScreen:install() == true, "install")
    local hooked_setup = SS.setup
    check(SS.setup ~= orig_setup and SS.show ~= orig_show, "Screensaver.setup / show wrapped")
    SleepScreen:install()
    check(SS.setup == hooked_setup, "install is idempotent")

    local function sleep(event, event_message)
        SS.shown = nil
        SS:setup(event, event_message)
        return SS:show()
    end

    -- setting on, cover mode
    Settings:set("sleep_screen_stats", true)
    Extra.gsettings.screensaver_type = "cover"
    Extra.gsettings.screensaver_show_message = false
    local flushed = 0
    local orig_flush = Tracking.flush
    Tracking.flush = function(t) flushed = flushed + 1 return orig_flush(t) end
    local inserted_before = real_statistics.inserted
    local ret = sleep()
    Tracking.flush = orig_flush
    local shown = SS.shown
    check(shown.type == "readingprogress", "setting on: KOReader mode switched to readingprogress")
    check(type(shown.widget) == "table" and getmetatable(shown.widget) ~= nil and shown.widget.sleep == true
        and shown.widget[1] ~= nil, "our StatsView is the sleep-screen widget")
    check(shown.statistics_during_show ~= real_statistics, "statistics shimmed during show()")
    check(ui.statistics == real_statistics, "real statistics plugin restored after show()")
    check(ret == "shown", "show() return value passed through")
    check(flushed >= 1, "Tracking flushed before sleeping")
    check(real_statistics.inserted == inserted_before + 1, "KOReader's statistics saved first (insertDB)")
    check(shown.show_message == false and shown.overlay == nil, "KOReader's message box not drawn over the stats")
    check(shown.background == "none", "message-mode background, as KOReader uses for readingprogress")
    check(next(shown.widget.key_events) == nil and next(shown.widget.ges_events) == nil,
        "sleep widget handles no input (ScreenSaverWidget does)")

    -- sleep message moves into our footer
    Extra.gsettings.screensaver_show_message = true
    Extra.gsettings.screensaver_message = "Reading %T"
    sleep()
    check(SS.shown.widget.footer_text == "Reading Dune", "custom sleep message (expanded) shown in our footer",
        SS.shown.widget.footer_text)
    Extra.gsettings.screensaver_message = nil
    sleep()
    check(SS.shown.widget.footer_text == "Sleeping", "default message in the footer")
    Extra.gsettings.screensaver_show_message = false

    -- power off without a dedicated power-off screen: ours, with KOReader's notice in the footer
    sleep("poweroff", "Powered off")
    check(SS.shown.type == "readingprogress" and SS.shown.widget.footer_text == "Powered off" and SS.shown.overlay == nil,
        "power off: stats + 'Powered off' in the footer")
    Extra.gsettings.poweroff_screensaver_type = "random_image"
    sleep("poweroff", "Powered off")
    check(SS.shown.type == "random_image", "explicit power-off screen left alone")
    Extra.gsettings.poweroff_screensaver_type = nil

    -- statistics plugin disabled
    ui.statistics = nil
    sleep()
    check(SS.shown.type == "readingprogress" and type(SS.shown.widget) == "table" and ui.statistics == nil,
        "statistics plugin disabled: works, and stays nil")
    ui.statistics = real_statistics

    -- show() raising: statistics restored, error propagated
    SS.fail_show = true
    local ok_show, err_show = pcall(sleep)
    SS.fail_show = nil
    check(not ok_show and tostring(err_show):find("show failed") and ui.statistics == real_statistics,
        "show() error: statistics restored and error propagated")

    -- building our widget fails: KOReader's own sleep screen, untouched
    local orig_collect = Stats.collect
    local orig_new = StatsView.new
    StatsView.new = function() error("layout exploded") end
    sleep()
    StatsView.new = orig_new
    Stats.collect = orig_collect
    check(SS.shown.type == "cover" and SS.shown.widget == "cover-widget", "widget build fails: KOReader's cover shown")
    local orig_page = StatsView.Builder.page
    StatsView.Builder.page = function() error("layout bug") end
    sleep()
    local inapp = StatsView:new{ data = DATA, interactive = true }
    StatsView.Builder.page = orig_page
    check(SS.shown.type == "cover" and SS.shown.widget == "cover-widget", "layout fails: KOReader's cover shown")
    check(inapp.layout_failed and inapp[1] ~= nil, "layout fails in-app: minimal page instead of a crash")

    -- setting off: untouched
    Settings:set("sleep_screen_stats", false)
    local off_flushes, off_inserts = 0, real_statistics.inserted
    local flush0 = Tracking.flush
    Tracking.flush = function(t) off_flushes = off_flushes + 1 return flush0(t) end
    sleep()
    Tracking.flush = flush0
    check(SS.shown.type == "cover" and SS.shown.widget == "cover-widget" and SS.shown.statistics_during_show == real_statistics,
        "setting off: KOReader's sleep screen untouched")
    check(SS.image and SS.image.freed == false and real_statistics.inserted == off_inserts,
        "setting off: cover not freed, statistics plugin not called")
    check(off_flushes == 1, "setting off: our own tracking file still flushed before sleeping")
    Extra.gsettings.screensaver_type = "readingprogress"
    sleep()
    check(SS.shown.widget == "koreader-readingprogress-widget", "setting off: KOReader's own readingprogress untouched")
    Settings:set("sleep_screen_stats", true)
    sleep()
    check(type(SS.shown.widget) == "table", "setting back on: ours again (no reinstall needed)")

    -- menu items
    local items = SleepScreen.settingsMenuItems()
    check(#items == 2 and items[1].checked_func() == true, "menu: toggle shows the setting")
    items[1].callback()
    check(Settings:get("sleep_screen_stats") == false and items[1].checked_func() == false, "menu: toggle turns it off")
    items[1].callback()
    local before = #UIManager._stack
    items[2].callback()
    UIManager:runTasks(0.2)
    local top = UIManager._stack[#UIManager._stack]
    check(#UIManager._stack == before + 1 and top.interactive and top.sleep, "menu: preview opens the sleep variant in-app")
    UIManager:close(top)

    -- Going to sleep with a Kobo book whose cover file isn't known yet: no walk (text-only), and
    -- with a known one: the cover (built once if the background didn't prepare it).
    local saved_recent = Readingstats._nickel_recent
    local now0 = os.time()
    Readingstats._nickel_recent = {
        { source = "kobo", title = "Nineteen Eighty-Four", author = "George Orwell", percent = 0.32,
          last_read = now0 + 60, image_id = ORWELL_ID },
        { source = "kobo", title = "The Trial", author = "Franz Kafka", percent = 0.65, last_read = now0 - 60,
          image_id = TRIAL_UUID },
        { source = "kobo", title = "Unknown Cover", percent = 0.5, last_read = now0 - 200, image_id = "never-seen" },
    }
    Readingstats._walked = {}
    local w0 = walks
    sleep()
    check(walks == w0 and type(SS.shown.widget) == "table" and type(SS.shown.widget._cover) == "table",
        "sleep: the current book's cover, from cached paths only (never a walk)")
    Readingstats._nickel_recent[3].last_read = now0 + 120
    sleep()
    check(walks == w0 and SS.shown.widget._cover == false, "sleep: current book's cover file unknown -> text-only, no walk")
    Readingstats._nickel_recent[3].last_read = now0 - 200

    -- Background preparation (after the snapshot / when a book is opened): one walk for unknown
    -- files, the missing pre-scaled covers built one per tick, then only checks.
    for _, name in ipairs(listDir(Readingstats.cover_cache_dir, ".kcover")) do
        os.remove(Readingstats.cover_cache_dir .. "/" .. name)
    end
    local d0 = RI.decodes
    local tasks0 = #UIManager._tasks
    SleepScreen.prepareCovers()
    check(walks == w0 + 1, "prepareCovers: one walk for the unknown cover file")
    check(RI.decodes == d0 + 1 and #UIManager._tasks == tasks0 + 1, "one cover built now, the next one on a later tick")
    UIManager:runTasks(SleepScreen.COVER_STEP_S + 0.3)
    check(RI.decodes == d0 + 2 and #listDir(Readingstats.cover_cache_dir, ".kcover") == 2,
        "the second one built on the next tick", RI.decodes - d0)
    SleepScreen.prepareCovers()
    check(RI.decodes == d0 + 2 and walks == w0 + 1, "all cached: no decoding, no walk")
    local d_sleep = RI.decodes
    sleep()
    check(RI.decodes == d_sleep and type(SS.shown.widget._cover) == "table", "then going to sleep decodes nothing")
    Settings:set("sleep_screen_stats", false)
    for _, name in ipairs(listDir(Readingstats.cover_cache_dir, ".kcover")) do
        os.remove(Readingstats.cover_cache_dir .. "/" .. name)
    end
    SleepScreen.prepareCovers()
    check(RI.decodes == d0 + 2, "sleep screen off: no cover work")
    Settings:set("sleep_screen_stats", true)
    Readingstats._nickel_recent = saved_recent

    -- Nickel snapshot scheduling: once per process, skipped when already done
    Readingstats._snapshot_done = false
    local n_tasks = #UIManager._tasks
    SleepScreen.scheduleNickelSnapshot(0)
    SleepScreen.scheduleNickelSnapshot(0)
    check(#UIManager._tasks == n_tasks + 1, "snapshot scheduled once")
    UIManager:runTasks(0.2)
    check(Readingstats:nickelSnapshotDone(), "scheduled snapshot ran")
    local after = #UIManager._tasks
    check(after >= 1 and SleepScreen._covers_scheduled, "covers prepared after the snapshot")
    SleepScreen.scheduleNickelSnapshot()
    SleepScreen.scheduleNickelSnapshot()
    check(#UIManager._tasks == after, "later calls (a book opened): cover preparation scheduled once")
end

print(string.format("\n[stats] %d passed, %d failed", passed, failed))
os.execute("rm -rf '" .. tmp .. "'")
os.exit(failed == 0 and 0 or 1)

--[[--
KOReader's sleep screen shows the stats view when the `sleep_screen_stats` setting is on.

We reuse Screensaver:show() so KOReader still handles everything around the picture: background,
lock gesture / delayed close, extra anti-ghosting flashes, rotation, the power-off/reboot cases and
the "dithered" Kaleido colour refresh. Two small wrappers do it:

* Screensaver.setup: after KOReader's own setup (which picks the mode and its fallbacks), when the
  setting is on, build our widget (caches only: no network, no server start), and only if that
  worked switch the mode to "readingprogress" (KOReader's full-screen statistics mode). Pending
  Tracking counters are flushed on every sleep (setting on or off: it's our own file).
  KOReader's sleep message and "Powered off"/"Rebooting…" overlay move into our footer instead of a
  box over the stats. If building fails, KOReader's own sleep screen is left exactly as set up.
* Screensaver.show: for that one call, `ui.statistics` is replaced by a shim whose
  onShowReaderProgress(true) returns our widget; the real plugin is restored as soon as show()
  returns, also when it raises.

A power-off or reboot screen the user configured explicitly ("poweroff_screensaver_type" etc.) is
left alone. With the setting off both wrappers just call through: KOReader's behaviour is untouched.
install() is idempotent (the wrappers are installed once per process, flagged on Screensaver).

Covers: the current book's cover is prepared in the background (scheduleNickelSnapshot ->
prepareCovers: find Nickel's cover file, pre-scale it into kanki/readingstats' cover cache), so going
to sleep normally only reads a small cached file. Going to sleep never walks .kobo-images; a cover
missing from the cache is decoded once then (one-time cost), any failure means a text-only layout.
]]

local Readingstats = require("kanki/readingstats")
local Settings = require("kanki/settings")
local Stats = require("kanki/stats")
local StatsView = require("kanki/statsview")
local Tracking = require("kanki/tracking")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local SleepScreen = {
    MODE = "readingprogress",   -- KOReader mode whose widget comes from ui.statistics
    SNAPSHOT_DELAY_S = 5,
    COVER_DELAY_S = 8,          -- cover preparation after a later call (e.g. a book was opened)
    COVER_STEP_S = 1,           -- between two cover decodes (one per tick: the UI never stalls long)
    COVER_BOOKS = 2,            -- covers prepared: the current book's and the next one's
    _snapshot_scheduled = false,
    _covers_scheduled = false,
}

local function packn(...)
    return { n = select("#", ...), ... }
end

function SleepScreen.isEnabled()
    return Settings:get("sleep_screen_stats") and true or false
end

local function gsetting(key)
    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        return G_reader_settings:readSetting(key)
    end
    return nil
end

--[[--
The text KOReader would have put in its message box / overlay, for our footer: the sleep message
(when "show message" is on, expanded like KOReader does) and the power-off / reboot notice.
]]
function SleepScreen.footerText(ss)
    local parts = {}
    local used_event = false
    if ss.show_message then
        local prefix = ss.prefix or ""
        local msg = gsetting(prefix .. "screensaver_message") or gsetting("screensaver_message")
            or ss.default_screensaver_message
        if msg == ss.default_screensaver_message and ss.event_message then
            msg = ss.event_message
            used_event = true
        end
        local bookinfo = ss.ui and ss.ui.bookinfo
        if type(msg) == "string" and bookinfo and type(bookinfo.expandString) == "function" then
            local ok, expanded = pcall(bookinfo.expandString, bookinfo, msg)
            if ok and type(expanded) == "string" then msg = expanded end
        end
        if type(msg) == "string" and msg ~= "" then table.insert(parts, msg) end
    end
    if type(ss.overlay_message) == "string" and ss.overlay_message ~= "" and not used_event then
        table.insert(parts, 1, ss.overlay_message)
    end
    if #parts == 0 then return nil end
    return (table.concat(parts, " · "):gsub("%s*\n%s*", " "))
end

--- Called right after KOReader's Screensaver:setup(). Builds our widget and switches the mode.
function SleepScreen:_takeOver(ss, event)
    if not self.isEnabled() then return end
    if not ss.ui or not ss.screensaver_type then return end -- setup bailed out (no UI)
    -- An explicitly configured power-off / reboot screen wins over ours.
    if event and gsetting((ss.prefix or (event .. "_")) .. "screensaver_type") ~= nil then return end

    -- Let KOReader's statistics plugin save the current reading session first (it does the same
    -- before its own reading-progress sleep screen), so "today" includes it.
    Readingstats.flushKOReader(ss.ui.statistics)
    local widget = StatsView:new{
        data = Stats:collect(),
        sleep = true,
        footer_text = self.footerText(ss),
    }
    if widget.layout_failed then
        widget:free()
        logger.warn("kanki sleep screen: layout failed, keeping KOReader's sleep screen")
        return
    end

    -- From here on the sleep screen is ours.
    if ss.image and type(ss.image.free) == "function" then
        pcall(ss.image.free, ss.image) -- a cover KOReader extracted for a cover mode
    end
    ss.image = nil
    ss.image_file = nil
    ss.screensaver_type = self.MODE
    -- What KOReader's setup uses for non-image modes (our page is opaque anyway).
    ss.screensaver_background = gsetting("screensaver_msg_background") or "none"
    ss.show_message = false
    ss.overlay_message = nil
    ss._kanki_widget = widget
end

--- Hook KOReader's Screensaver. Safe to call any number of times.
function SleepScreen:install()
    local ok, Screensaver = pcall(require, "ui/screensaver")
    if not ok or type(Screensaver) ~= "table" or type(Screensaver.setup) ~= "function"
            or type(Screensaver.show) ~= "function" then
        logger.warn("kanki sleep screen: KOReader's Screensaver not available:",
            (tostring(Screensaver):match("^[^\n]*")))
        return false
    end
    if Screensaver._kanki_sleep_hooked then return true end
    Screensaver._kanki_sleep_hooked = true

    local orig_setup, orig_show = Screensaver.setup, Screensaver.show

    Screensaver.setup = function(ss, event, ...)
        ss._kanki_widget = nil
        local res = packn(orig_setup(ss, event, ...))
        local ok_take, err = pcall(SleepScreen._takeOver, SleepScreen, ss, event)
        if not ok_take then
            -- Nothing was changed before the widget existed: KOReader's own sleep screen stays.
            ss._kanki_widget = nil
            logger.warn("kanki sleep screen: could not build the stats screen:", err)
        end
        -- About to sleep (or power off): write pending study/reading counters (no-op if none).
        local ok_flush, flush_err = pcall(Tracking.flush, Tracking)
        if not ok_flush then logger.warn("kanki sleep screen: tracking flush failed:", flush_err) end
        return unpack(res, 1, res.n)
    end

    Screensaver.show = function(ss, ...)
        local widget = ss._kanki_widget
        ss._kanki_widget = nil
        if not widget or ss.screensaver_type ~= SleepScreen.MODE or not ss.ui then
            return orig_show(ss, ...)
        end
        local ui = ss.ui
        local real = ui.statistics
        local shim = { onShowReaderProgress = function() return widget end }
        if real ~= nil then setmetatable(shim, { __index = real }) end
        ui.statistics = shim
        local res = packn(pcall(orig_show, ss, ...))
        ui.statistics = real
        if not res[1] then
            logger.err("kanki sleep screen: Screensaver.show failed:", res[2])
            error(res[2], 0)
        end
        return unpack(res, 2, res.n)
    end

    logger.info("kanki sleep screen: installed")
    return true
end

--[[--
Prepare the sleep screen's covers (background work, so going to sleep only loads a small cached
file): find Nickel's cover files of the books read last (one walk of .kobo-images, only for books
whose file isn't known yet), then make sure the pre-scaled covers of the first COVER_BOOKS books that
have a cover (among the first COVER_BOOKS + 1) are cached, decoding at most one per tick. Only when
the sleep screen setting is on. Never raises.
]]
function SleepScreen.prepareCovers()
    SleepScreen._covers_scheduled = false
    if not SleepScreen.isEnabled() then return end
    local ok, books = pcall(Stats.books, Stats)
    if not ok or type(books) ~= "table" then return end
    local ids = {}
    for i = 1, math.min(#books, Readingstats.RECENT_BOOKS + 1) do
        if books[i].source == "kobo" and books[i].image_id then table.insert(ids, books[i].image_id) end
    end
    Readingstats:resolveNickelCovers(ids)
    local max_w, max_h = Readingstats.coverMaxSize()
    -- the first COVER_BOOKS books that have a cover, among the first COVER_BOOKS + 1
    local i, ready = 0, 0
    local step
    step = function()
        while ready < SleepScreen.COVER_BOOKS and i < math.min(#books, SleepScreen.COVER_BOOKS + 1) do
            i = i + 1
            local res = Readingstats:prepareCover(books[i], max_w, max_h)
            if res == "built" or res == "cached" then ready = ready + 1 end
            if res == "built" then -- next decode on a later tick
                UIManager:scheduleIn(SleepScreen.COVER_STEP_S, function()
                    local ok_step, err = pcall(step)
                    if not ok_step then logger.warn("kanki sleep screen: preparing covers failed:", err) end
                end)
                return
            end
        end
    end
    step()
end

function SleepScreen.scheduleCovers(delay_s)
    if SleepScreen._covers_scheduled then return end
    SleepScreen._covers_scheduled = true
    UIManager:scheduleIn(delay_s or SleepScreen.COVER_DELAY_S, function()
        local ok, err = pcall(SleepScreen.prepareCovers)
        if not ok then
            SleepScreen._covers_scheduled = false
            logger.warn("kanki sleep screen: preparing covers failed:", err)
        end
    end)
end

--[[--
Read Nickel's totals once per KOReader process, a few seconds after start (Nickel can't change them
while KOReader runs; cheap when the Kobo's DB is unchanged since the last snapshot), then prepare the
covers. Called again later (the plugin is re-created whenever a book is opened or closed), it only
schedules the cover preparation (cheap when the covers are cached).
]]
function SleepScreen.scheduleNickelSnapshot(delay_s)
    if Readingstats:nickelSnapshotDone() then
        SleepScreen.scheduleCovers()
        return
    end
    if SleepScreen._snapshot_scheduled then return end -- pending; covers follow it
    SleepScreen._snapshot_scheduled = true
    UIManager:scheduleIn(delay_s or SleepScreen.SNAPSHOT_DELAY_S, function()
        if not Readingstats:nickelSnapshotDone() then
            local ok, err = pcall(Readingstats.snapshotNickel, Readingstats)
            if not ok then logger.warn("kanki sleep screen: Nickel snapshot failed:", err) end
        end
        SleepScreen.scheduleCovers(SleepScreen.COVER_STEP_S)
    end)
end

--- Show the sleep screen as it would look now (caches only), in-app; tap or a key closes it.
function SleepScreen.preview()
    local text = _("Preview · tap to close")
    if gsetting("screensaver_show_message") then
        local msg = gsetting("screensaver_message")
        if type(msg) == "string" and msg ~= "" and not msg:find("%%") then
            text = msg:gsub("%s*\n%s*", " ") .. " · " .. text
        end
    end
    return StatsView.show{ refresh = false, sleep = true, footer_text = text }
end

--- Menu entries for the plugin's settings.
function SleepScreen.settingsMenuItems()
    return {
        {
            text = _("Show Anki & reading stats on the sleep screen"),
            help_text = _("When the Kobo goes to sleep, show today's Anki reviews, study time and reading instead of KOReader's own sleep screen. KOReader's sleep screen options (lock, extra flashes, message) still apply. Turn this off to get KOReader's sleep screen back."),
            checked_func = function() return SleepScreen.isEnabled() end,
            callback = function() Settings:toggle("sleep_screen_stats") end,
        },
        {
            text = _("Preview sleep screen"),
            keep_menu_open = true,
            callback = function()
                UIManager:nextTick(function() SleepScreen.preview() end)
            end,
        },
    }
end

return SleepScreen

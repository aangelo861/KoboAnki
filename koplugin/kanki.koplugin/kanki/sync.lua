--[[--
Sync controller: starts a server-side sync job and polls GET /sync about once a second with
UIManager:scheduleIn, so the UI stays usable (reviews may continue during the media phase).

Listeners (the deck list, the reviewer) get `fn(event, st)` calls:
  "progress"            st = latest GET /sync body (state running)
  "collection_done"     the collection stage finished and media is still syncing: decks/cards are usable
  "done"                sync finished (st.state == "done")
  "error"               st.message explains
  "full_sync_required"  waiting for the user's decision
  "offline"             auto-sync skipped because the device is offline
  "cancelled"           user declined the full download

Wi-Fi power saving (setting wifi_off_after_sync): a sync may have to switch Wi-Fi on
(NetworkMgr:runWhenOnline, depending on KOReader's "action when Wi-Fi is off"). If Wi-Fi was off
when the sync was requested, it is switched off again once the sync is over (done, error, the user
declining a full download), like KOReader's own "turn off Wi-Fi after action". Not after
full_sync_required: the full download the user may confirm next needs the connection, and joins
the same snapshot. Never while another sync runs or is starting: it joins the snapshot, and its own
end restores Wi-Fi.
]]

local Client = require("kanki/client")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Login = require("kanki/login")
local NetworkMgr = require("ui/network/manager")
local Server = require("kanki/server")
local Settings = require("kanki/settings")
local UI = require("kanki/uihelpers")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Sync = {
    POLL_S = 1,
    AUTO_MIN_GAP_S = 60, -- automatic syncs never start sooner than this after the previous one
    -- A Wi-Fi snapshot nobody finished for this long (e.g. the user said no to KOReader's "turn on
    -- Wi-Fi?" prompt, so the sync never started) no longer speaks for the next sync.
    WIFI_SNAPSHOT_MAX_AGE_S = 10 * 60,
    last_finished_at = nil,
    active = false,     -- we're polling a job we started (or found running)
    last = nil,         -- last GET /sync body
    listeners = {},
    _job = nil,
    _wifi = nil,        -- Wi-Fi snapshot of the current sync(s), see _rememberWifi
}

-- Events after which no sync is running any more (see _wifiAfterSync).
local SYNC_OVER = { done = true, error = true, cancelled = true, offline = true }

function Sync:addListener(fn)
    self.listeners[fn] = true
end

function Sync:removeListener(fn)
    self.listeners[fn] = nil
end

function Sync:_emit(event, st)
    if SYNC_OVER[event] or event == "full_sync_required" then
        -- Before the listeners: a sync one of them starts must count as joining this round.
        self:_wifiAfterSync(event)
    end
    for fn in pairs(self.listeners) do
        local ok, err = pcall(fn, event, st)
        if not ok then logger.err("kanki sync listener failed:", err) end
    end
end

---------------------------------------------------------------------------------------------------
-- Wi-Fi power saving (see the top of this file)

-- true/false, or nil where NetworkMgr can't tell (no Wi-Fi toggle: the emulator says "on").
local function wifiOn()
    if type(NetworkMgr.isWifiOn) ~= "function" then return nil end
    local ok, on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
    if not ok then return nil end
    return on and true or false
end

--- A sync is being requested: remember whether Wi-Fi is off now, before it may be switched on.
function Sync:_rememberWifi()
    local snap = self._wifi
    local now = os.time()
    if snap and (snap.hold or now - snap.at < self.WIFI_SNAPSHOT_MAX_AGE_S) then
        -- A sync of the same round (full download after full_sync_required, or one requested
        -- while the previous one was finishing): keep the earliest state, cancel a pending restore.
        snap.at = now
        snap.gen = snap.gen + 1
        return
    end
    self._wifi = {
        at = now,
        gen = 0,
        off_before = wifiOn() == false,
        -- NetworkMgr's "restore Wi-Fi on resume" flag, so turning it off restores that too.
        was_on = NetworkMgr.wifi_was_on and true or false,
    }
end

function Sync:_wifiAfterSync(event)
    local snap = self._wifi
    if not snap then return end
    snap.at = os.time() -- the age that matters is since the last sync of the round
    if event == "full_sync_required" then
        snap.hold = true -- waiting for the user's decision (confirmFullDownload)
        return
    end
    snap.hold = nil
    local gen = snap.gen
    -- Next tick: listeners and the ConfirmBox above may start another sync right away.
    UIManager:nextTick(function()
        if self._wifi ~= snap or snap.gen ~= gen or self.active then
            return -- another sync joined this round; it restores Wi-Fi when it ends
        end
        self._wifi = nil
        if not (snap.off_before and Settings:get("wifi_off_after_sync")) then return end
        if wifiOn() and type(NetworkMgr.disableWifi) == "function" then
            logger.info("kanki: Wi-Fi was off before the sync, turning it off again")
            -- interactive = not was_on: if KOReader wasn't going to restore Wi-Fi on resume
            -- before the sync, clear the wifi_was_on flag the connection set (NetworkMgr:disableWifi).
            NetworkMgr:disableWifi(nil, not snap.was_on)
        end
    end)
end

function Sync:isActive()
    return self.active
end

local function fmtNum(n)
    n = tonumber(n) or 0
    local s = tostring(math.floor(n))
    -- 4500 -> 4,500
    local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (formatted:gsub("^,", ""))
end

--- One-line human description of a GET /sync body, for status lines.
function Sync.describe(st)
    if not st then return "" end
    local state = st.state
    if state == "running" then
        local parts = {}
        if st.stage == "media" then
            table.insert(parts, _("Syncing media"))
        elseif st.stage == "collection" then
            table.insert(parts, _("Syncing collection"))
        else
            table.insert(parts, _("Syncing"))
        end
        if st.message and st.message ~= "" then
            table.insert(parts, st.message)
        end
        local m = st.media
        if st.stage == "media" and type(m) == "table" then
            local counts = {}
            if (m.downloaded or 0) > 0 then table.insert(counts, T(_("%1 downloaded"), fmtNum(m.downloaded))) end
            if (m.uploaded or 0) > 0 then table.insert(counts, T(_("%1 uploaded"), fmtNum(m.uploaded))) end
            if (m.deleted or 0) > 0 then table.insert(counts, T(_("%1 deleted"), fmtNum(m.deleted))) end
            if (m.checked or 0) > 0 then table.insert(counts, T(_("%1 checked"), fmtNum(m.checked))) end
            if #counts > 0 then
                table.insert(parts, table.concat(counts, ", "))
            end
        end
        return table.concat(parts, " · ")
    elseif state == "error" then
        return T(_("Sync failed: %1"), st.message or "")
    elseif state == "full_sync_required" then
        return _("Sync needs a full download from AnkiWeb.")
    elseif st.last_success then
        return T(_("Last sync: %1"), Sync.ago(st.last_success))
    end
    return _("Not synced yet")
end

function Sync.ago(unix_secs)
    local delta = os.time() - (tonumber(unix_secs) or 0)
    if delta < 60 then
        return _("just now")
    elseif delta < 3600 then
        return T(_("%1 min ago"), math.floor(delta / 60))
    elseif delta < 86400 then
        return T(_("%1 h ago"), math.floor(delta / 3600))
    end
    return os.date("%Y-%m-%d %H:%M", unix_secs)
end

--[[--
Start a sync.
@string kind "normal" (default) or "full_download"
@tparam[opt] table opts
  auto = true: automatic sync (deck list opening / after a session): never prompts for Wi-Fi
         unless KOReader is set to turn Wi-Fi on by itself, never shows the login dialog,
         and only shows errors in status lines.
]]
function Sync:start(kind, opts)
    kind = kind or "normal"
    opts = opts or {}
    if self.active then
        if not opts.auto then UI.notify(_("Sync already in progress.")) end
        return
    end
    -- Backstop against sync loops: automatic syncs never start within a minute of the last one,
    -- except the one after a review session (it carries new reviews, and needs a user action).
    if opts.auto and not opts.after_reviews and self.last_finished_at and os.time() - self.last_finished_at < self.AUTO_MIN_GAP_S then
        logger.info("kanki: skipping automatic sync, last one finished", os.time() - self.last_finished_at, "s ago")
        return
    end
    self:_rememberWifi()
    local function go()
        Server:ensure(function(ok, err)
            if not ok then
                if not opts.auto then UI.showError(err) end
                self:_emit("error", { state = "error", message = UI.errorText(err) })
                return
            end
            self:_post(kind, opts)
        end)
    end
    if opts.auto then
        if NetworkMgr:isConnected() and NetworkMgr:isOnline() then
            go()
        elseif G_reader_settings:readSetting("wifi_enable_action") == "turn_on" then
            NetworkMgr:runWhenOnline(go)
        else
            self:_emit("offline", { state = "idle" })
        end
    else
        NetworkMgr:runWhenOnline(go)
    end
end

function Sync:_post(kind, opts)
    local res, err = Client:startSync(kind)
    if not res then
        if err.kind == "busy" then
            -- A job is already running server-side (e.g. started before a KOReader restart): follow it.
            logger.info("kanki: sync already running server-side, following it")
        elseif err.kind == "need_login" then
            if opts.auto then
                self:_emit("error", { state = "error", message = UI.errorText(err) })
            else
                Login:show(function() self:start(kind, opts) end)
            end
            return
        else
            if not opts.auto then UI.showError(err, { prefix = _("Could not start sync.") }) end
            self:_emit("error", { state = "error", message = UI.errorText(err) })
            return
        end
    end
    self.active = true
    self._job = {
        kind = kind,
        opts = opts,
        polls = 0,
        seen_running = false,
        collection_done = false,
        prev_last_success = self.last and self.last.last_success,
        failures = 0,
    }
    self:_emit("progress", { state = "running", stage = "collection",
        message = kind == "full_download" and _("Downloading from AnkiWeb…") or "" })
    self._poll_fn = self._poll_fn or function() self:_poll() end
    UIManager:scheduleIn(self.POLL_S, self._poll_fn)
end

function Sync:_poll()
    local job = self._job
    if not self.active or not job then return end
    job.polls = job.polls + 1
    local st, err = Client:syncStatus({ quiet = true, timeout = 5 })
    if not st then
        job.failures = job.failures + 1
        if err.kind == "server_down" or job.failures >= 5 then
            Server:markDown()
            self:_finish("error", { state = "error", message = UI.errorText(err) })
            return
        end
        UIManager:scheduleIn(self.POLL_S, self._poll_fn)
        return
    end
    job.failures = 0
    self.last = st

    if st.state == "running" then
        job.seen_running = true
        if st.stage == "media" and not job.collection_done then
            job.collection_done = true
            self:_emit("collection_done", st)
        end
        self:_emit("progress", st)
        UIManager:scheduleIn(self.POLL_S, self._poll_fn)
    elseif st.state == "done" then
        -- Guard against reading a stale "done" from the previous job before ours flips to running.
        if not job.seen_running and st.last_success == job.prev_last_success and job.polls < 3 then
            UIManager:scheduleIn(self.POLL_S, self._poll_fn)
            return
        end
        self:_finish("done", st)
    elseif st.state == "error" then
        self:_finish("error", st)
    elseif st.state == "full_sync_required" then
        self:_finish("full_sync_required", st)
    else -- "idle" or unknown
        if job.polls < 3 then
            UIManager:scheduleIn(self.POLL_S, self._poll_fn)
        else
            self:_finish("done", st)
        end
    end
end

function Sync:_finish(event, st)
    local job = self._job or { opts = {} }
    self.active = false
    self._job = nil
    self.last_finished_at = os.time()
    if self._poll_fn then UIManager:unschedule(self._poll_fn) end

    if st and st.server_message and st.server_message ~= "" then
        UIManager:show(InfoMessage:new{
            text = T(_("Message from AnkiWeb:\n\n%1"), st.server_message),
        })
    end

    if event == "full_sync_required" then
        self:_emit("full_sync_required", st)
        self:confirmFullDownload()
        return
    end
    if event == "error" then
        logger.warn("kanki: sync failed:", st and st.message)
        if not job.opts.auto then
            UI.warn(T(_("Sync failed.\n\n%1"), st and st.message or ""))
        end
    end
    self:_emit(event, st)
end

function Sync:confirmFullDownload()
    UIManager:show(ConfirmBox:new{
        text = _("AnkiWeb and this Kobo have changes that cannot be merged, so a one-way sync is needed.\n\nDownload the collection from AnkiWeb?\n\nAny reviews or changes made on this Kobo since the last successful sync will be lost. (This Kobo never uploads over AnkiWeb.)"),
        ok_text = _("Download from AnkiWeb"),
        cancel_text = _("Not now"),
        ok_callback = function()
            self:start("full_download", { auto = false })
        end,
        cancel_callback = function()
            self:_emit("cancelled", self.last)
        end,
    })
end

--- Stop polling (e.g. KOReader exiting). The server-side job is not cancelled.
function Sync:stopPolling()
    if self._poll_fn then UIManager:unschedule(self._poll_fn) end
    self.active = false
    self._job = nil
end

return Sync

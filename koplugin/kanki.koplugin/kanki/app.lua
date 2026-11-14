--[[--
App controller (one per KOReader process): opens the deck list and reviewer, drives the
first-run flows (log in, first download), auto-sync, settings menus and exit-to-Kobo.
]]

local Client = require("kanki/client")
local ConfirmBox = require("ui/widget/confirmbox")
local DeckList = require("kanki/decklist")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local Login = require("kanki/login")
local Pomodoro = require("kanki/pomodoro")
local SleepScreen = require("kanki/sleepscreen")
local Stats = require("kanki/stats")
local StatsView = require("kanki/statsview")
local Reviewer = require("kanki/reviewer")
local Server = require("kanki/server")
local Settings = require("kanki/settings")
local SpinWidget = require("ui/widget/spinwidget")
local Sync = require("kanki/sync")
local UI = require("kanki/uihelpers")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local App = {
    autostarted = false,   -- started by launch.sh (KANKI_AUTOSTART=1)
    decklist = nil,
    reviewer = nil,
    status = nil,          -- last GET /status body
    login_prompted = false,
    -- Opening the deck list auto-syncs unless the last successful sync is more recent than this.
    AUTO_SYNC_MIN_AGE_S = 5 * 60,
    _sync_listener = nil,
}

---------------------------------------------------------------------------------------------------
-- Deck list

function App:openDeckList()
    if self.decklist then
        -- Already open (possibly under the reviewer): nothing to do.
        return
    end
    self.decklist = DeckList:new{ app = self }
    UIManager:show(self.decklist, "flashui")
    if not self._sync_listener then
        self._sync_listener = function(event, st) self:_onSync(event, st) end
        Sync:addListener(self._sync_listener)
    end
    self.decklist:setStatus(_("Starting Anki…"))
    UIManager:nextTick(function() self:_startSession() end)
end

function App:_startSession()
    if not self.decklist then return end
    Server:ensure(function(ok, res)
        if not self.decklist then return end
        if not ok then
            self.decklist:setStatus(_("The Anki server is not running."))
            self.decklist:showPlaceholder(_("Could not start Anki. Tap to try again."), function()
                self.decklist:showPlaceholder(_("Starting Anki…"))
                self:_startSession()
            end)
            UI.showError(res)
            return
        end
        self:refresh({ auto_sync = true })
    end)
end

local function statusLine(st)
    if not st then return "" end
    local parts = {}
    if Sync:isActive() and Sync.last then
        table.insert(parts, Sync.describe(Sync.last))
    elseif type(st.sync) == "table" then
        table.insert(parts, Sync.describe(st.sync))
    end
    if st.username and st.username ~= "" then
        table.insert(parts, st.username)
    end
    return table.concat(parts, " · ")
end

--[[--
Reload server status and the deck list, running the first-run flows when needed.
@tparam table opts { auto_sync = bool: run the automatic sync if enabled }
]]
function App:refresh(opts)
    opts = opts or {}
    local decklist = self.decklist
    if not decklist then return end
    local st, err = Client:status()
    if not st then
        if err.kind == "server_down" then
            Server:markDown()
            return self:_startSession()
        end
        decklist:setStatus(UI.errorText(err))
        return
    end
    self.status = st
    Server:noteStatus(st)

    if not st.logged_in then
        decklist:setStatus(_("Not logged in to AnkiWeb"))
        decklist:showPlaceholder(_("Log in to AnkiWeb to download your decks"), function()
            self:login()
        end)
        if not self.login_prompted then
            self.login_prompted = true
            self:login()
        end
        return
    end

    -- Unknown card_count (nil) is NOT "empty": only an explicit 0 means the first download is due.
    if not st.has_collection or tonumber(st.card_count) == 0 then
        if Sync:isActive() then
            -- (Menu rows are single-line: keep placeholder texts short, details go in the status line.)
            decklist:showPlaceholder(_("Downloading your collection from AnkiWeb…"))
            decklist:setStatus(statusLine(st))
        elseif not self.first_download_started then
            -- Start the first download automatically once per session; with no local cards the
            -- server turns a normal sync into a full download.
            self.first_download_started = true
            decklist:showPlaceholder(_("Downloading your collection from AnkiWeb…"))
            decklist:setStatus(_("First sync: downloading the collection from AnkiWeb."))
            Sync:start("normal")
        else
            -- A sync already ran and there are still no cards (e.g. nothing on AnkiWeb yet).
            -- Never loop: let the user decide.
            decklist:showPlaceholder(_("No cards downloaded. Tap to sync again."), function()
                decklist:showPlaceholder(_("Downloading your collection from AnkiWeb…"))
                self:syncNow()
            end)
            decklist:setStatus(statusLine(st))
        end
        return
    end

    self:loadDecks()
    decklist:setStatus(statusLine(st))

    if opts.auto_sync and Settings:get("auto_sync") and not Sync:isActive() then
        local last = type(st.sync) == "table" and tonumber(st.sync.last_success)
        if not last or os.time() - last > self.AUTO_SYNC_MIN_AGE_S then
            Sync:start("normal", { auto = true })
        end
    end
end

function App:loadDecks(keep_page)
    if not self.decklist then return end
    local res, err = Client:decks()
    if not res then
        if err.kind == "busy" then
            self.decklist:showPlaceholder(_("Syncing… decks will appear shortly."))
        elseif err.kind == "need_login" then
            self.decklist:showPlaceholder(_("Log in to AnkiWeb to download your decks"), function() self:login() end)
        elseif err.kind == "no_collection" then
            self.decklist:showPlaceholder(_("No collection yet. Tap to sync with AnkiWeb."), function() self:syncNow() end)
        else
            self.decklist:showPlaceholder(UI.errorText(err))
        end
        return
    end
    self.decklist:setDecks(res, keep_page)
end

function App:_onSync(event, st)
    local decklist = self.decklist
    if not decklist then return end
    if event == "progress" then
        decklist:setStatus(Sync.describe(st))
    elseif event == "collection_done" then
        decklist:setStatus(Sync.describe(st))
        -- Collection is ready even though media is still coming: show the decks now.
        if not self.reviewer then self:loadDecks(true) end
    elseif event == "done" then
        if not self.reviewer then
            self:refresh({})
        else
            decklist:setStatus(Sync.describe(st))
        end
        self:_refreshStatsSoon()
    elseif event == "error" then
        decklist:setStatus(Sync.describe(st))
        if not self.reviewer and self.status and not self.status.has_collection then
            decklist:showPlaceholder(_("Download failed. Tap to try again."), function()
                decklist:showPlaceholder(_("Downloading your collection from AnkiWeb…"))
                self:syncNow()
            end)
        end
    elseif event == "offline" then
        local base = self.status and type(self.status.sync) == "table" and Sync.describe(self.status.sync) or ""
        decklist:setStatus(base ~= "" and (base .. " · " .. _("offline")) or _("Offline — not synced"))
    elseif event == "full_sync_required" then
        decklist:setStatus(Sync.describe(st))
    elseif event == "cancelled" then
        decklist:setStatus(_("Full download postponed. Tap Sync to decide again."))
    end
end

function App:openDeck(deck)
    if self.reviewer then return end
    local res, err = Client:selectDeck(deck.id)
    if not res then
        UI.showError(err, { on_need_login = function() self:login() end })
        return
    end
    local reviewer
    reviewer = Reviewer:new{
        deck_name = deck.name,
        on_detach = function()
            if self.reviewer == reviewer then self.reviewer = nil end
        end,
        on_close = function(answered)
            self:_onReviewerClosed(answered)
        end,
    }
    self.reviewer = reviewer
    UIManager:show(reviewer, "ui")
end

--- Refresh the cached Anki numbers for the stats/sleep screens, after the deck list has repainted.
function App:_refreshStatsSoon()
    UIManager:scheduleIn(1, function()
        local ok, err = pcall(Stats.refreshAnki, Stats)
        if not ok then logger.warn("kanki: stats refresh failed:", err) end
    end)
end

function App:_onReviewerClosed(answered)
    if not self.decklist then return end
    self:refresh({})
    self:_refreshStatsSoon()
    if (answered or 0) > 0 and Settings:get("auto_sync") and not Sync:isActive() then
        -- New reviews to upload: exempt from the minimum gap between automatic syncs.
        Sync:start("normal", { auto = true, after_reviews = true })
    end
end

function App:onDeckListClose()
    local decklist = self.decklist
    if not decklist then return end
    local exit = self.autostarted and Settings:get("exit_when_autostarted")
    if exit and Sync:isActive() then
        UIManager:show(ConfirmBox:new{
            text = _("A sync is still running. Exit anyway?\n\nThe sync will be stopped. Reviews already done are saved on this Kobo and will be uploaded next time."),
            ok_text = _("Exit"),
            ok_callback = function() self:exitToKobo() end,
        })
        return
    end
    decklist:closeWidget()
    if exit then
        self:exitToKobo()
    end
end

function App:showDeckListMenu()
    local ButtonDialog = require("ui/widget/buttondialog")
    local logged_in = self.status and self.status.logged_in
    local dialog
    local function close() UIManager:close(dialog) end
    local exit_row
    if self.autostarted then
        exit_row = {
            {
                text = _("Exit to Kobo home"),
                callback = function()
                    close()
                    if self.decklist then self.decklist:closeWidget() end
                    self:exitToKobo()
                end,
            },
        }
    else
        exit_row = {
            {
                text = _("Close Anki"),
                callback = function()
                    close()
                    if self.decklist then self.decklist:closeWidget() end
                end,
            },
        }
    end
    dialog = ButtonDialog:new{
        title = _("Anki"),
        buttons = {
            {
                { text = _("Sync now"), callback = function() close(); self:syncNow() end },
            },
            {
                { text = _("Today's stats"), callback = function() close(); StatsView.show() end },
            },
            {
                {
                    text = _("Brightness & warmth"),
                    enabled = type(Device.hasFrontlight) == "function" and Device:hasFrontlight() or false,
                    callback = function()
                        close()
                        if type(Device.showLightDialog) == "function" then Device:showLightDialog() end
                    end,
                },
            },
            {
                {
                    text = logged_in and T(_("Log out (%1)"), self.status.username or "") or _("Log in to AnkiWeb"),
                    callback = function()
                        close()
                        if logged_in then self:confirmLogout() else self:login() end
                    end,
                },
            },
            {
                { text = _("Settings"), callback = function() close(); self:showSettingsMenu() end },
            },
            exit_row,
        },
    }
    UIManager:show(dialog)
end

---------------------------------------------------------------------------------------------------
-- Account & sync actions

function App:syncNow()
    Sync:start("normal")
end

function App:login()
    Login:show(function()
        self.login_prompted = true
        if self.decklist then
            self:refresh({ auto_sync = true })
        else
            Sync:start("normal")
        end
    end)
end

function App:confirmLogout()
    UIManager:show(ConfirmBox:new{
        text = _("Log out of AnkiWeb?\n\nThe collection stays on this Kobo; you'll need to log in again to sync."),
        ok_text = _("Log out"),
        ok_callback = function()
            Server:ensure(function(ok, err)
                if not ok then return UI.showError(err) end
                local res, logout_err = Client:logout()
                if not res then return UI.showError(logout_err) end
                UI.notify(_("Logged out of AnkiWeb."))
                if self.status then self.status.logged_in = false end
                if self.decklist then self:refresh({}) end
            end)
        end,
    })
end

-- Log in if we know we're logged out, otherwise offer to log out (asks the server when unsure).
function App:loginOrLogout(after)
    Server:ensure(function(ok, st)
        if not ok then return UI.showError(st) end
        self.status = st
        if st.logged_in then
            self:confirmLogout()
        else
            self:login()
        end
        if after then after() end
    end)
end

function App:loginMenuText()
    local st = self.status
    if st and st.logged_in then
        return T(_("Log out of AnkiWeb (%1)"), st.username or "")
    elseif st then
        return _("Log in to AnkiWeb")
    end
    return _("AnkiWeb account")
end

---------------------------------------------------------------------------------------------------
-- Settings

function App:onSettingsChanged()
    -- The reviewer reads settings when it opens; nothing to rebuild live.
end

function App:settingsMenuItems()
    return {
        {
            text_func = function()
                return T(_("Card text size: %1"), Settings:get("font_size"))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    title_text = _("Card text size"),
                    info_text = _("Anki's default 20px card text is shown at this size; the card's own styles are scaled to match. Applies from the next card you open."),
                    value = Settings:get("font_size"),
                    value_min = 12,
                    value_max = 48,
                    value_step = 1,
                    value_hold_step = 4,
                    default_value = Settings.DEFAULTS.font_size,
                    callback = function(spin)
                        Settings:set("font_size", spin.value)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                        self:onSettingsChanged()
                    end,
                })
            end,
        },
        {
            text = _("Page buttons"),
            sub_item_table = {
                {
                    text = _("Forward = Good, Back = Again"),
                    radio = true,
                    checked_func = function() return not Settings:get("swap_page_keys") end,
                    callback = function() Settings:set("swap_page_keys", false) end,
                },
                {
                    text = _("Forward = Again, Back = Good"),
                    radio = true,
                    checked_func = function() return Settings:get("swap_page_keys") == true end,
                    callback = function() Settings:set("swap_page_keys", true) end,
                    separator = true,
                },
                {
                    text = _("About the page buttons"),
                    keep_menu_open = true,
                    callback = function()
                        UI.info(_("Question side: either page button shows the answer.\nAnswer side: the buttons rate the card as chosen above.\n\nKOReader's own \"Invert page-turn buttons\" setting is applied before Anki sees the buttons, so it swaps them here too."))
                    end,
                },
            },
        },
        {
            text_func = function()
                local n = tonumber(Settings:get("full_refresh_every")) or 0
                if n > 0 then
                    return T(_("Full screen refresh every %1 cards"), n)
                end
                return _("Full screen refresh: never")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    title_text = _("Full screen refresh"),
                    info_text = _("Flash the screen every N cards to clear ghosting on the colour screen (0 = never)."),
                    value = tonumber(Settings:get("full_refresh_every")) or 0,
                    value_min = 0,
                    value_max = 50,
                    value_step = 1,
                    value_hold_step = 5,
                    default_value = Settings.DEFAULTS.full_refresh_every,
                    callback = function(spin)
                        Settings:set("full_refresh_every", spin.value)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        },
        {
            text = _("Study timer & Pomodoro"),
            sub_item_table = Pomodoro.settingsMenuItems(),
        },
        {
            text = _("Sleep screen"),
            sub_item_table = SleepScreen.settingsMenuItems(),
        },
        {
            text = _("Sync automatically"),
            help_text = _("Sync with AnkiWeb when the deck list opens and after each review session (only when logged in; Wi-Fi is only switched on if KOReader is set to do that by itself)."),
            checked_func = function() return Settings:get("auto_sync") end,
            callback = function() Settings:toggle("auto_sync") end,
        },
        {
            text = _("Edge swipes change the light"),
            help_text = _("While reviewing, swipe up or down along the left edge of the screen to change brightness, along the right edge to change warmth. The ☼ button in the top bar opens the full light settings."),
            checked_func = function() return Settings:get("edge_swipe_light") end,
            callback = function() Settings:toggle("edge_swipe_light") end,
        },
        {
            text = _("Turn Wi-Fi off after syncing"),
            help_text = _("If Wi-Fi was off before a sync started, switch it off again when the sync is done. Saves battery; Wi-Fi is only needed while syncing."),
            checked_func = function() return Settings:get("wifi_off_after_sync") end,
            callback = function() Settings:toggle("wifi_off_after_sync") end,
        },
        {
            text = _("Exit to Kobo when closing the deck list"),
            help_text = _("Only when KOReader was started from the Anki entry in the Kobo menu (launch.sh): closing the deck list then quits KOReader and returns to the Kobo home screen."),
            checked_func = function() return Settings:get("exit_when_autostarted") end,
            callback = function() Settings:toggle("exit_when_autostarted") end,
        },
        {
            text = _("Restart the Kobo instead of exiting"),
            help_text = _("On this Kobo, going back to the Kobo home screen after KOReader can crash the device and remove NickelMenu (a known Kobo firmware problem on MediaTek models). With this on, leaving KOReader restarts the Kobo cleanly instead. Only applies to MediaTek Kobos (Libra Colour, Clara Colour/BW)."),
            enabled_func = function() return self:isMTKKobo() end,
            checked_func = function() return Settings:get("restart_instead_of_exit") end,
            callback = function() Settings:toggle("restart_instead_of_exit") end,
            separator = true,
        },
        {
            text = _("Log out of AnkiWeb"),
            keep_menu_open = true,
            callback = function()
                Server:ensure(function(ok, st)
                    if not ok then return UI.showError(st) end
                    self.status = st
                    if st.logged_in then
                        self:confirmLogout()
                    else
                        UI.info(_("You are not logged in to AnkiWeb."))
                    end
                end)
            end,
        },
        {
            text_func = function()
                return T(_("Data folder: %1"), Settings:dataDir())
            end,
            keep_menu_open = true,
            callback = function()
                UI.info(T(_("Collection, media and log are in:\n%1\n\nLog file:\n%2"),
                    Settings:dataDir(), Settings:logPath()))
            end,
        },
    }
end

--- Settings as a standalone one-tab TouchMenu (reachable from the deck list when KOReader's
--- own menu isn't, e.g. when started from the Kobo menu).
function App:showSettingsMenu()
    local CenterContainer = require("ui/widget/container/centercontainer")
    local TouchMenu = require("ui/widget/touchmenu")
    local container = CenterContainer:new{
        ignore = "height",
        dimen = Screen:getSize(),
    }
    local tab = self:settingsMenuItems()
    tab.icon = "appbar.settings"
    local menu = TouchMenu:new{
        width = Screen:getWidth(),
        tab_item_table = { tab },
        show_parent = container,
    }
    menu.close_callback = function()
        UIManager:close(container)
    end
    container[1] = menu
    UIManager:show(container)
end

--- The "Anki" entry of KOReader's main menu.
function App:mainMenuTable()
    return {
        text = _("Anki"),
        sorting_hint = "main", -- fallback if a user menu order hides our slot
        sub_item_table = {
            {
                text = _("Decks"),
                callback = function()
                    UIManager:nextTick(function() self:openDeckList() end)
                end,
            },
            {
                text = _("Today's stats"),
                callback = function()
                    UIManager:nextTick(function() StatsView.show() end)
                end,
            },
            {
                text = _("Sync now"),
                callback = function() self:syncNow() end,
                separator = true,
            },
            {
                text_func = function() return self:loginMenuText() end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:loginOrLogout(function()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end)
                end,
            },
            {
                text = _("Settings"),
                sub_item_table = self:settingsMenuItems(),
            },
        },
    }
end

---------------------------------------------------------------------------------------------------
-- Lifecycle

--[[--
On MediaTek Kobos (Libra Colour, Clara Colour/BW), going back to Nickel after KOReader can crash
the kernel: the MTK Wi-Fi/Bluetooth driver doesn't survive Nickel starting a second time, so the
device reboots while Nickel is still starting, which trips NickelMenu's failsafe and removes it
(koreader/koreader#12739, pgaskin/NickelMenu#220). Using Wi-Fi for sync makes it more likely.
Restarting the Kobo cleanly instead is the workaround with reported success.
]]
function App:isMTKKobo()
    return type(Device.isKobo) == "function" and Device:isKobo()
        and type(Device.isMTK) == "function" and Device:isMTK() and true or false
end

function App:restartInsteadOfExit()
    return self:isMTKKobo() and Settings:get("restart_instead_of_exit") and true or false
end

--- Leave KOReader and go back to Nickel (koreader.sh restarts Nickel when KOReader exits), or,
--- where that is unsafe (see restartInsteadOfExit), restart the Kobo.
function App:exitToKobo()
    logger.info("kanki: exiting KOReader")
    Sync:stopPolling()
    if self.reviewer then
        self.reviewer:onExit()
        self.reviewer = nil
    end
    if self.decklist then
        self.decklist:closeWidget()
        self.decklist = nil
    end
    -- Blocking: the server closes the collection (stopping a running sync) before it exits.
    local info = InfoMessage:new{ text = _("Closing Anki…") }
    UIManager:show(info)
    UIManager:forceRePaint()
    Server:stop("exit to Kobo")
    UIManager:close(info)
    if self:restartInsteadOfExit() and type(UIManager.reboot_action) == "function" then
        -- KOReader's own "Reboot the device": "Rebooting…" screen, settings saved, clean reboot,
        -- and exit code 88 so koreader.sh doesn't start Nickel first.
        logger.info("kanki: restarting the Kobo instead of returning to Nickel")
        UIManager:nextTick(function() UIManager.reboot_action() end)
        return
    end
    -- Same as KOReader's own Exit menu entry (ui/elements/common_exit_menu_table.lua).
    -- (On MTK Kobos the quit hook in main.lua still turns this into a restart.)
    UIManager:nextTick(function()
        UIManager:broadcastEvent(Event:new("Exit"))
    end)
end

--- KOReader is exiting / restarting / powering off / rebooting / entering USB mass storage.
--- Blocks until the server is gone (see Server:stop). Cheap when nothing is running, so it is
--- fine that several of these hooks fire for one exit.
function App:onKOReaderTeardown(reason)
    Sync:stopPolling()
    Server:stop(reason)
end

return App

--[[--
Persistent settings for the Anki plugin.

Stored in KOReader's settings dir as `kanki.lua` (a LuaSettings file), separate from
G_reader_settings so that removing the plugin leaves nothing behind in KOReader's own settings.

Never store the AnkiWeb password here (or anywhere): the server keeps only the hkey in auth.json.
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Settings = {
    DEFAULTS = {
        -- Card text size, in KOReader "font size" units (Screen:scaleBySize() is applied).
        font_size = 22,
        -- false: PgFwd = Good, PgBack = Again.  true: PgFwd = Again, PgBack = Good.
        swap_page_keys = false,
        -- Flashing full refresh every N cards (0 = never), to clear colour ghosting.
        full_refresh_every = 6,
        -- Sync automatically when the deck list opens and after a review session.
        auto_sync = true,
        -- When started through launch.sh (KANKI_AUTOSTART=1), closing the deck list exits KOReader.
        exit_when_autostarted = true,
        -- MediaTek Kobos only (see App:restartInsteadOfExit): leave KOReader by restarting the Kobo
        -- instead of returning to Nickel, which can crash the kernel and remove NickelMenu.
        restart_instead_of_exit = true,

        -- Study timer: elapsed time of the current review session in the reviewer's top bar.
        show_session_timer = true,
        -- Pomodoro focus blocks while reviewing (minutes).
        pomodoro_enabled = true,
        pomodoro_focus_min = 25,
        pomodoro_short_break_min = 5,
        pomodoro_long_break_min = 15,
        pomodoro_long_break_every = 4,
        -- Start a focus block automatically when a review session starts.
        pomodoro_autostart = true,

        -- Show study & reading statistics as KOReader's sleep screen.
        sleep_screen_stats = true,

        -- Turn Wi-Fi off again after a sync, if it was off before the sync started (saves battery).
        wifi_off_after_sync = true,

        -- In the reviewer, vertical swipes along the left edge change brightness, along the right edge
        -- warmth (KOReader's own frontlight logic). The top bar's ☼ button opens the light dialog.
        edge_swipe_light = true,
        -- Server data dir (collection, media, auth.json, kanki.log). Absolute on purpose:
        -- DataStorage:getDataDir() is "." on Kobo.
        data_dir = "/mnt/onboard/.adds/kanki",
        -- Last AnkiWeb username typed in the login dialog (convenience only; not a secret).
        last_username = nil,
    },
    store = nil,
}

function Settings:_open()
    if not self.store then
        self.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/kanki.lua")
    end
    return self.store
end

function Settings:get(key)
    -- NOTE: LuaSettings:readSetting(key, default) would *save* the default, which we don't want.
    local value = self:_open():readSetting(key)
    if value == nil then
        value = self.DEFAULTS[key]
    end
    return value
end

function Settings:set(key, value)
    local store = self:_open()
    if value == nil then
        store:delSetting(key)
    else
        store:saveSetting(key, value)
    end
    store:flush()
end

function Settings:toggle(key)
    self:set(key, not self:get(key))
    return self:get(key)
end

--- Data dir without a trailing slash.
function Settings:dataDir()
    local dir = self:get("data_dir") or self.DEFAULTS.data_dir
    return (dir:gsub("/+$", ""))
end

function Settings:mediaDir()
    return self:dataDir() .. "/collection.media"
end

function Settings:logPath()
    return self:dataDir() .. "/kanki.log"
end

return Settings

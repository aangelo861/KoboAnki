--[[--
Anki for KOReader ("kanki"): a thin UI over the local `kanki serve` process (see DESIGN.md).

* Main menu: an "Anki" entry at the top of KOReader's main (☰) menu, in both the file manager
  and the reader: Decks / Sync now / Log in|out / Settings.
* KANKI_AUTOSTART=1 (set by launch.sh, used from the NickelMenu entry): the deck list opens as
  soon as KOReader's UI is up, and closing it exits KOReader back to Nickel (setting, default on).
* The server is stopped, and we wait until the process is gone (Server:stop), whenever KOReader
  quits: exit, restart, power off, reboot, USB mass storage (/mnt/onboard must unmount). The
  reliable hook for that is UIManager:quit(), which every one of those paths calls; the Exit/
  PowerOff/... event handlers below just do it earlier. (A broadcast "Close", the only event USB
  mass storage sends, never reaches plugins in the file manager: its file chooser, a Menu, consumes
  it.) It is NOT stopped on suspend. Its --parent-pid watchdog covers crashes.

Our modules live in kanki/ and are required as "kanki/<name>" so they can't collide with any other
module on KOReader's package.path (PluginLoader appends plugin dirs to it).
]]

local Device = require("device")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

-- Load our modules now, while PluginLoader has this plugin's dir at the front of package.path.
local App = require("kanki/app")
local SleepScreen = require("kanki/sleepscreen")
local Server = require("kanki/server")

local MENU_ID = "kanki"

-- Put "Anki" first in the main (☰) menu of both the file manager and the reader.
-- These order tables are cached by require(), and FileManagerMenu/ReaderMenu read them each
-- time they build the menu (the same mechanism ui/plugin/insert_menu.lua uses).
-- If the user has a custom menu order that drops it, `sorting_hint = "main"` still appends it there.
local function insertIntoMainMenuOrder()
    for _, module_name in ipairs({ "ui/elements/filemanager_menu_order", "ui/elements/reader_menu_order" }) do
        local ok, order = pcall(require, module_name)
        if ok and type(order) == "table" and type(order.main) == "table" then
            if not util.arrayContains(order.main, MENU_ID) then
                table.insert(order.main, 1, MENU_ID)
                table.insert(order.main, 2, "----------------------------")
            end
        else
            logger.warn("kanki: could not patch menu order", module_name)
        end
    end
end
insertIntoMainMenuOrder()

-- Stop the server (and wait for it to be gone) before KOReader's UI loop quits.
local function installQuitHook()
    if UIManager._kanki_quit_hook or type(UIManager.quit) ~= "function" then
        return
    end
    UIManager._kanki_quit_hook = true
    local orig_quit = UIManager.quit
    UIManager.quit = function(uimanager, exit_code, ...)
        local ok, err = pcall(App.onKOReaderTeardown, App, "quit")
        if not ok then
            logger.err("kanki: teardown failed:", err)
        end
        -- A plain exit (KOReader's own Exit menu included) would hand back to Nickel, which can
        -- crash MediaTek Kobos and remove NickelMenu (see App:restartInsteadOfExit). Restart the
        -- Kobo instead, exactly like KOReader's reboot action: save, reboot, exit 88 (= don't
        -- start Nickel). Restart (85), USB mass storage (86) and power off/reboot (88) pass through.
        -- Judge by the *effective* code: KOReader calls quit() a second time with no code
        -- (UIManager:_gated_quit -> quit(nil, true), "No dialogs left to show") after
        -- quit(85) for Restart KOReader. Its own quit() keeps the earlier _exit_code then, so
        -- that call is not a plain exit and must not reboot the Kobo (it did, 2026-11-07).
        local effective = exit_code
        if effective == nil then effective = uimanager._exit_code end
        local ok_check, restart = pcall(App.restartInsteadOfExit, App)
        if (effective == nil or effective == 0) and ok_check and restart then
            logger.info("kanki: exit would return to Nickel; restarting the Kobo instead")
            pcall(function() Device:saveSettings() end)
            Device:reboot()
            return orig_quit(uimanager, 88, ...)
        end
        return orig_quit(uimanager, exit_code, ...)
    end
end
installQuitHook()

-- Stats on KOReader's sleep screen (when enabled in Anki settings; KOReader's own sleep screen otherwise).
SleepScreen:install()

-- Process-wide: KANKI_AUTOSTART is only acted upon once per KOReader process (the plugin is
-- re-instantiated every time KOReader switches between file manager and reader).
local autostart_checked = false

local Kanki = WidgetContainer:extend{
    name = "kanki",
    is_doc_only = false,
}

function Kanki:init()
    Server:setPluginDir(self.path)
    -- Baseline/deltas of the Kobo's own reading totals, once per KOReader process, a few seconds in.
    SleepScreen.scheduleNickelSnapshot()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    if not autostart_checked then
        autostart_checked = true
        if os.getenv("KANKI_AUTOSTART") == "1" then
            logger.info("kanki: KANKI_AUTOSTART=1, opening the deck list")
            App.autostarted = true
            -- nextTick: runs from the UI loop, i.e. after the file manager/reader has been shown,
            -- and before its first paint (so it doesn't flash on screen first).
            UIManager:nextTick(function()
                App:openDeckList()
            end)
        end
    end
end

function Kanki:onDispatcherRegisterActions()
    Dispatcher:registerAction("kanki_show_decks", {
        category = "none",
        event = "KankiShowDecks",
        title = _("Anki: deck list"),
        general = true,
    })
end

function Kanki:onKankiShowDecks()
    App:openDeckList()
    return true
end

function Kanki:addToMainMenu(menu_items)
    menu_items[MENU_ID] = App:mainMenuTable()
end

-- Teardown. None of these return true: they are broadcasts that KOReader itself must also handle.
function Kanki:onExit()
    App:onKOReaderTeardown("exit")
end

function Kanki:onRestart()
    App:onKOReaderTeardown("restart")
end

function Kanki:onPowerOff()
    App:onKOReaderTeardown("poweroff")
end

function Kanki:onReboot()
    App:onKOReaderTeardown("reboot")
end

-- "Close" is broadcast at power off, reboot and before USB mass storage. In the reader it does
-- reach us (in the file manager it doesn't, see the top of this file; the quit hook covers that).
-- It can also be sent when back-to-exit closes a document; stopping the server then is harmless,
-- it is restarted on demand the next time Anki is opened.
function Kanki:onClose()
    App:onKOReaderTeardown("close")
end

return Kanki

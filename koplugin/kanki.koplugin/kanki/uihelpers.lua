--[[--
Shared UI helpers: consistent error display for KankiError values.
]]

local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local UI = {}

--- Short, non-blocking toast at the top of the screen (always shown, whatever the user's
--- notification preferences are).
function UI.notify(text)
    Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
end

function UI.info(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

function UI.warn(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, icon = "notice-warning", timeout = timeout })
end

--- Human text for an error, with the special kinds the UI cares about.
function UI.errorText(err)
    if type(err) ~= "table" then
        return tostring(err)
    end
    if err.kind == "busy" then
        return _("Sync in progress. Please wait a moment.")
    elseif err.kind == "need_login" then
        return _("Please log in to AnkiWeb first.")
    elseif err.kind == "no_collection" then
        return _("There is no collection on this device yet. Sync with AnkiWeb to download it.")
    end
    return err.message or err.kind or _("Unknown error")
end

--[[--
Show an error the standard way.
* busy -> toast "Sync in progress"
* need_login -> calls opts.on_need_login() if given (normally opens the login dialog)
* anything else -> InfoMessage
]]
function UI.showError(err, opts)
    opts = opts or {}
    if type(err) == "table" then
        if err.kind == "busy" then
            UI.notify(UI.errorText(err))
            return
        elseif err.kind == "need_login" and opts.on_need_login then
            opts.on_need_login()
            return
        end
    end
    local text = UI.errorText(err)
    if opts.prefix then
        text = opts.prefix .. "\n\n" .. text
    end
    UI.warn(text)
end

return UI

--[[--
AnkiWeb login dialog.

The password only ever lives in the dialog's input field and in the local variable used for the
single POST /login request to 127.0.0.1; it is never saved, logged, or kept after the request.
The server stores only AnkiWeb's session key (hkey) in auth.json.
]]

local Client = require("kanki/client")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Server = require("kanki/server")
local Settings = require("kanki/settings")
local UI = require("kanki/uihelpers")
local UIManager = require("ui/uimanager")
local util = require("util")
local _ = require("gettext")

local Login = {
    dialog = nil,
}

--[[--
Show the login dialog.
@func on_success called (with the username) after a successful login
@string[opt] message extra explanation shown above the fields (e.g. after a failed attempt)
]]
function Login:show(on_success, message)
    if self.dialog then
        return -- already showing
    end
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Log in to AnkiWeb"),
        fields = {
            {
                description = message,
                text = Settings:get("last_username") or "",
                hint = _("AnkiWeb email"),
            },
            {
                text = "",
                hint = _("Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                        self.dialog = nil
                    end,
                },
                {
                    text = _("Log in"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local username = util.trim(fields[1] or "")
                        local password = fields[2] or ""
                        fields = nil -- luacheck: ignore
                        if username == "" or password == "" then
                            UI.notify(_("Enter your AnkiWeb email and password."))
                            return
                        end
                        UIManager:close(dialog)
                        self.dialog = nil
                        Settings:set("last_username", username)
                        self:_doLogin(username, password, on_success)
                        password = nil -- luacheck: ignore
                    end,
                },
            },
        },
    }
    self.dialog = dialog
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Login:_doLogin(username, password, on_success)
    NetworkMgr:runWhenOnline(function()
        Server:ensure(function(ok, err)
            if not ok then
                password = nil
                UI.showError(err)
                return
            end
            local info = InfoMessage:new{ text = _("Logging in to AnkiWeb…") }
            UIManager:show(info)
            UIManager:forceRePaint()
            local res, login_err = Client:login(username, password)
            password = nil
            UIManager:close(info)
            if res then
                UI.notify(_("Logged in to AnkiWeb."))
                if on_success then on_success(username) end
            elseif login_err.kind == "auth" then
                self:show(on_success, _("AnkiWeb did not accept that email and password. Please try again."))
            else
                UI.showError(login_err, { prefix = _("Login failed.") })
            end
        end)
    end)
end

return Login

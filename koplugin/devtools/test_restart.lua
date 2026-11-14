--[[
On MediaTek Kobos, leaving KOReader back to Nickel can crash the kernel and remove NickelMenu
(koreader/koreader#12739). The plugin turns plain exits into a clean restart. Checks the quit hook:
  * plain exit (nil/0) on an MTK Kobo  -> Device:reboot() + exit code 88 (koreader.sh won't start Nickel)
  * restart (85), USB mass storage (86), power off/reboot (88) pass through unchanged
  * setting off, or a non-MTK device -> plain exit passes through unchanged

  KANKI_TEST_QUIET=1 luajit test_restart.lua      (LUA_PATH/LUA_CPATH as in README.md)
]]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local abs_here = io.popen("cd '" .. here .. "' && pwd"):read("*l")
package.path = table.concat({
    abs_here .. "/stubs/?.lua",
    abs_here .. "/../kanki.koplugin/?.lua",
    package.path,
}, ";")

local Stubs = require("koreader_stubs")
Stubs.settings_dir = os.getenv("TMPDIR") or "/tmp"
local UIManager = Stubs.UIManager
local Device = require("device")
local Settings = require("kanki/settings")

local rebooted, mtk = 0, true
function Device:isKobo() return true end
function Device:isMTK() return mtk end
function Device:reboot() rebooted = rebooted + 1 end
function Device:saveSettings() end

require("main") -- installs the quit hook

local passed, failed = 0, 0
local function check(cond, what)
    if cond then passed = passed + 1; print("ok   " .. what)
    else failed = failed + 1; print("FAIL " .. what) end
end
local function quit(code)
    rebooted = 0
    UIManager._quit_code = nil
    UIManager:quit(code)
    return UIManager._quit_code, rebooted
end

Settings:set("restart_instead_of_exit", nil) -- default (on)
local code, r = quit(nil)
check(code == 88 and r == 1, "MTK Kobo: plain exit becomes a clean restart (code 88, reboot called)")
code, r = quit(0)
check(code == 88 and r == 1, "MTK Kobo: exit code 0 becomes a clean restart")
for _, c in ipairs({ 85, 86, 88 }) do
    code, r = quit(c)
    check(code == c and r == 0, "exit code " .. c .. " passes through unchanged")
end
-- KOReader v2026.07: Restart = quit(85), then UIManager:_gated_quit() -> quit(nil, true) with
-- _exit_code still 85. That second call must not reboot the Kobo.
for _, c in ipairs({ 85, 86 }) do
    rebooted = 0
    UIManager._exit_code = c
    UIManager:quit(nil, true)
    check(rebooted == 0, "implicit quit after exit code " .. c .. " does not reboot")
end
UIManager._exit_code = nil
code, r = quit(nil)
check(code == 88 and r == 1, "plain exit still restarts the Kobo after that")

Settings:set("restart_instead_of_exit", false)
code, r = quit(0)
check(code == 0 and r == 0, "setting off: plain exit goes back to Nickel")
Settings:set("restart_instead_of_exit", nil)

mtk = false
code, r = quit(0)
check(code == 0 and r == 0, "non-MTK Kobo: plain exit goes back to Nickel")

print(string.format("\n[restart] %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

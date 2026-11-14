--[[
Regression test for the first real-device run: on a Kobo with the loopback interface down, TCP
connects to the server neither succeeded nor got refused, they hung. Closing Anki then took ~90 s.

Simulates that by pointing the client at a non-routable address (connects hang), and checks that
stopping is fast (a) when no server process exists and (b) when a process exists but never answers,
and that repeated stop() calls in one exit return at once.

  KANKI_TEST_QUIET=1 luajit test_hang.lua      (LUA_PATH/LUA_CPATH as in README.md)
]]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local abs_here = io.popen("cd '" .. here .. "' && pwd"):read("*l")
package.path = table.concat({
    abs_here .. "/stubs/?.lua",
    abs_here .. "/../kanki.koplugin/?.lua",
    package.path,
}, ";")

require("koreader_stubs")
local socket = require("socket")
local Client = require("kanki/client")
local Server = require("kanki/server")

local passed, failed = 0, 0
local function check(cond, what)
    if cond then passed = passed + 1; print("ok   " .. what)
    else failed = failed + 1; print("FAIL " .. what) end
end
local function timed(f)
    local t0 = socket.gettime()
    local r = f()
    return r, socket.gettime() - t0
end

Client.host = "10.255.255.1" -- non-routable: connect() hangs instead of being refused

local p, dt = timed(function() return Client:probe(1) end)
check(p ~= "open" and dt < 1.6, string.format("probe on a hanging address gives up in %.2fs (%s)", dt, p))

-- (a) nothing running
Server._findPids = function() return {} end
local ok
ok, dt = timed(function() return Server:stop("test-a") end)
check(ok and dt < 2, string.format("stop with no server process returns in %.2fs", dt))

-- (b) a process that exists but never answers (stands in for a hung server)
local pid = tonumber(io.popen("sleep 60 >/dev/null 2>&1 & echo $!"):read("*l"))
Server._findPids = function() return { pid } end
Server._pidAlive = function(_, q) return os.execute("kill -0 " .. q .. " 2>/dev/null") == 0 end
ok, dt = timed(function() return Server:stop("test-b") end)
check(ok and dt < 5, string.format("stop kills a non-answering server in %.2fs", dt))
check(not Server:_pidAlive(pid), "the process is gone")

-- (c) re-entrant calls during one exit (exit to Kobo -> Exit -> quit)
Server._findPids = function() return {} end
Server._stopping = true
ok, dt = timed(function() return Server:stop("nested") end)
Server._stopping = false
check(ok and dt < 0.1, string.format("nested stop returns immediately (%.3fs)", dt))

print(string.format("\n[hang] %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

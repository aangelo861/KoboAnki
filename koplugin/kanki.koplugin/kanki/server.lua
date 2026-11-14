--[[--
Lifecycle of the local `kanki serve` process.

* ensure(callback): make sure a healthy server answers GET /status, starting it if needed, without
  blocking the UI (startup is polled with UIManager:scheduleIn). callback(ok, status_or_err).
  Whenever we start talking to a server we didn't see come up in this KOReader process (left over
  from a previous session, or our own spawn exited with code 3 because the port was already taken),
  we POST /adopt {"parent_pid": <KOReader pid>} so its --parent-pid watchdog follows this KOReader.

* Spawning: `cd / && exec <bin> serve ... >><data>/kanki.log 2>&1 </dev/null &` — cwd is "/" so the
  process doesn't pin /mnt/onboard as its cwd, the shell doesn't linger, and stdout/stderr (the
  server's only log output; it never opens kanki.log itself) are appended to the log instead of
  pointing at a pipe that may be closed. The server closes inherited fds > 2 at startup.

* stop(reason): BLOCKING, on purpose. USB mass storage needs /mnt/onboard unmounted right after
  KOReader quits, and the binary, the collection and the log all live there. So:
    1. POST /shutdown. The server closes the collection (aborting a running sync, up to ~15 s)
       *before* it replies, then exits within ~1 s.
    2. Wait until the port refuses connections and, where /proc exists, no
       `... serve --data-dir <our data dir>` process is left (up to EXIT_WAIT_S).
    3. Last resort, only for processes positively identified in /proc: SIGTERM, then SIGKILL.
  It is not stopped on suspend. Its --parent-pid watchdog (5 s) covers KOReader crashes.

Process state is module-level (one per KOReader process), so it survives the plugin being
re-instantiated when KOReader switches between the file manager and the reader.
]]

local Client = require("kanki/client")
local Settings = require("kanki/settings")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socket = require("socket")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Server = {
    PORT = 47321,
    START_TIMEOUT_S = 10,
    POLL_INTERVAL_S = 0.25,
    SHUTDOWN_TIMEOUT_S = 20, -- POST /shutdown replies only after the collection is closed
    EXIT_WAIT_S = 5,         -- then the port must stop answering / the process must be gone
    DEAD_AFTER_S = 1.5,      -- during startup: no process and no port after this long = it died
    KILL_WAIT_S = 2,         -- per signal, last resort
    -- "stopped" | "starting" | "running"
    state = "stopped",
    plugin_dir = nil, -- absolute path of kanki.koplugin, set by main.lua
    media_dir = nil,  -- from GET /status "media_dir"
    _waiters = {},
    _start_deadline = nil,
    _spawn_times = nil,
}

Client:setPort(Server.PORT)

local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function koreaderPid()
    local ok, pid = pcall(function()
        local ffi = require("ffi")
        require("ffi/posix_h") -- declares pid_t getpid(void)
        return tonumber(ffi.C.getpid())
    end)
    if ok then return pid end
    logger.warn("kanki: could not get KOReader pid:", pid)
    return nil
end
Server.koreaderPid = koreaderPid

function Server:setPluginDir(dir)
    -- PluginLoader gives a path relative to KOReader's cwd ("plugins/kanki.koplugin"); make it
    -- absolute, since the server is started from "/".
    if dir and dir:sub(1, 1) ~= "/" then
        local cwd = lfs.currentdir()
        if cwd then
            dir = cwd .. "/" .. dir:gsub("^%./", "")
        end
    end
    self.plugin_dir = dir
end

function Server:binaryPath()
    return (self.plugin_dir or ".") .. "/bin/kanki"
end

function Server:isRunning()
    return self.state == "running"
end

--- Remember what the server tells us about itself (GET /status body).
function Server:noteStatus(st)
    if type(st) == "table" and type(st.media_dir) == "string" and st.media_dir ~= "" then
        self.media_dir = st.media_dir
    end
end

--- Media directory to use as the HTML resource directory.
function Server:mediaDir()
    return self.media_dir or Settings:mediaDir()
end

local function finish(self, ok, result)
    local waiters = self._waiters
    self._waiters = {}
    for _, cb in ipairs(waiters) do
        local cb_ok, cb_err = pcall(cb, ok, result)
        if not cb_ok then
            logger.err("kanki: server ensure() callback failed:", cb_err)
        end
    end
end

function Server:_adopt()
    local pid = koreaderPid()
    if not pid then return end
    local res, err = Client:adopt(pid)
    if res then
        logger.info("kanki: server now watches KOReader pid", pid)
    else
        logger.warn("kanki: POST /adopt failed:", err and err.message)
    end
end

function Server:_becameRunning(status, adopt)
    self.state = "running"
    self:noteStatus(status)
    if adopt then
        self:_adopt()
    end
    finish(self, true, status)
end

--- Make sure the server is up. callback(true, status) or callback(false, KankiError).
function Server:ensure(callback)
    if callback then
        table.insert(self._waiters, callback)
    end
    if self.state == "starting" then
        return -- the running start sequence will call us back
    end
    local status = Client:probe(1) == "open" and Client:status({ timeout = 2, quiet = true })
    if status then
        -- Not "running" yet from our point of view => a server we didn't see start: adopt it.
        self:_becameRunning(status, self.state ~= "running")
        return
    end
    self:_spawn()
end

function Server:_spawn()
    -- Don't respawn forever if the server keeps dying right after starting.
    local now = os.time()
    local recent = {}
    for _, t in ipairs(self._spawn_times or {}) do
        if now - t < 60 then table.insert(recent, t) end
    end
    if #recent >= 3 then
        self._spawn_times = recent
        self.state = "stopped"
        finish(self, false, Client.newError("server_down",
            T(_("The Anki server keeps stopping.\n\nSee the log file:\n%1"), Settings:logPath())))
        return
    end
    table.insert(recent, now)
    self._spawn_times = recent

    local bin = self:binaryPath()
    if lfs.attributes(bin, "mode") ~= "file" then
        self.state = "stopped"
        finish(self, false, Client.newError("server_missing",
            T(_("The Anki server program is missing:\n%1"), bin)))
        return
    end
    local data_dir = Settings:dataDir()
    if lfs.attributes(data_dir, "mode") ~= "directory" then
        local ok, err = util.makePath(data_dir)
        if not ok then
            self.state = "stopped"
            finish(self, false, Client.newError("server_missing",
                T(_("Cannot create the Anki data folder %1: %2"), data_dir, tostring(err))))
            return
        end
    end

    local pid = koreaderPid()
    local serve = string.format("%s serve --data-dir %s --port %d%s",
        shellQuote(bin), shellQuote(data_dir), self.PORT,
        pid and (" --parent-pid " .. pid) or "")
    -- Kobo firmware leaves the loopback interface down; the server brings it up itself too, this is
    -- just belt and braces (KOReader runs as root on Kobo; harmless elsewhere).
    local cmd = string.format("ifconfig lo up >/dev/null 2>&1; chmod 755 %s 2>/dev/null; cd / && exec %s >>%s 2>&1 </dev/null &",
        shellQuote(bin), serve, shellQuote(Settings:logPath()))
    logger.info("kanki: starting server:", serve)
    local rc = os.execute(cmd)
    if rc ~= 0 and rc ~= true then
        logger.warn("kanki: spawn shell returned", rc)
    end

    self.state = "starting"
    self._spawned_at = socket.gettime()
    self._start_deadline = os.time() + self.START_TIMEOUT_S
    self._poll = self._poll or function() self:_pollStartup() end
    UIManager:scheduleIn(self.POLL_INTERVAL_S, self._poll)
end

--- Last few lines of kanki.log, for error messages.
local function logTail(n)
    local f = io.open(Settings:logPath(), "rb")
    if not f then return "" end
    local size = f:seek("end")
    f:seek("set", math.max(0, size - 2000))
    local text = f:read("*a") or ""
    f:close()
    local lines = {}
    for line in text:gmatch("[^\n]+") do table.insert(lines, line) end
    return table.concat(lines, "\n", math.max(1, #lines - n + 1))
end

function Server:_pollStartup()
    if self.state ~= "starting" then return end
    local status = Client:probe(1) == "open" and Client:status({ timeout = 2, quiet = true })
    if not status and socket.gettime() - (self._spawned_at or 0) >= self.DEAD_AFTER_S then
        local pids = self:_findPids()
        if pids and #pids == 0 then
            -- The process is gone without ever answering: don't sit out the full start timeout.
            self.state = "stopped"
            local tail = logTail(3)
            logger.warn("kanki: server exited during startup:", tail)
            finish(self, false, Client.newError("server_down",
                T(_("The Anki server could not start.\n\n%1\n\nLog: %2"), tail, Settings:logPath())))
            return
        end
    end
    if status then
        logger.info("kanki: server is up, version", status.version, "anki", status.anki_version)
        -- It may be an older server that made ours exit with code 3: always adopt (harmless if
        -- it's our own child, which already watches our pid).
        self:_becameRunning(status, true)
        return
    end
    if os.time() >= self._start_deadline then
        self.state = "stopped"
        logger.warn("kanki: server did not come up within", self.START_TIMEOUT_S, "s")
        finish(self, false, Client.newError("server_down",
            T(_("The Anki server did not start.\n\nSee the log file:\n%1"), Settings:logPath())))
        return
    end
    UIManager:scheduleIn(self.POLL_INTERVAL_S, self._poll)
end

---------------------------------------------------------------------------------------------------
-- Stopping

--- Is this process alive? (Overridable for desktop tests, which have no /proc.)
function Server:_pidAlive(pid)
    return lfs.attributes("/proc/" .. pid, "mode") ~= nil
end

function Server:_anyAlive(pids)
    if not pids then return false end
    for _, pid in ipairs(pids) do
        if self:_pidAlive(pid) then return true end
    end
    return false
end

local function cmdlineArgs(pid)
    local f = io.open("/proc/" .. pid .. "/cmdline", "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    if not s or s == "" then return nil end
    if s:sub(-1) ~= "\0" then s = s .. "\0" end
    local args = {}
    for a in s:gmatch("(%Z*)%z") do
        args[#args + 1] = a
    end
    return args
end

--- PIDs of `... serve --data-dir <our data dir> ...` processes, or nil when /proc isn't available.
function Server:_findPids()
    local ok_dir, iter, dir_obj = pcall(lfs.dir, "/proc")
    if not ok_dir or lfs.attributes("/proc/self", "mode") == nil then
        return nil
    end
    local data_dir = Settings:dataDir()
    local me = koreaderPid()
    local pids = {}
    for entry in iter, dir_obj do
        local pid = entry:match("^%d+$") and tonumber(entry)
        if pid and pid ~= me then
            local args = cmdlineArgs(entry)
            if args then
                local serve, ours = false, false
                for i, a in ipairs(args) do
                    if a == "serve" then serve = true end
                    if a == "--data-dir" and args[i + 1] and (args[i + 1]:gsub("/+$", "")) == data_dir then
                        ours = true
                    elseif a == "--data-dir=" .. data_dir then
                        ours = true
                    end
                end
                if serve and ours then
                    table.insert(pids, pid)
                end
            end
        end
    end
    return pids
end

--- Wait until the port refuses connections and no known pid is alive. True when gone.
function Server:_waitGone(seconds, pids)
    local deadline = socket.gettime() + seconds
    local last_ask = socket.gettime()
    repeat
        local open = Client:probe(0.5) == "open"
        if not open and not self:_anyAlive(pids) then
            return true
        end
        if open and socket.gettime() - last_ask >= 2 then
            -- Still serving (e.g. it was still starting up when we first asked): ask again, briefly.
            last_ask = socket.gettime()
            Client:shutdown(3)
        end
        socket.sleep(0.1)
    until socket.gettime() >= deadline
    return false
end

function Server:_kill(pids)
    for _, sig in ipairs({ "TERM", "KILL" }) do
        local alive = {}
        for _, pid in ipairs(pids) do
            if self:_pidAlive(pid) then table.insert(alive, pid) end
        end
        if #alive == 0 then return true end
        logger.warn("kanki: server did not exit, sending SIG" .. sig .. " to", table.concat(alive, " "))
        os.execute(string.format("kill -%s %s >/dev/null 2>&1", sig, table.concat(alive, " ")))
        local deadline = socket.gettime() + self.KILL_WAIT_S
        while socket.gettime() < deadline and self:_anyAlive(alive) do
            socket.sleep(0.1)
        end
    end
    local gone = not self:_anyAlive(pids)
    if not gone then
        logger.err("kanki: could not stop the server process")
    end
    return gone
end

--[[--
Ask the server to exit and wait until it is really gone (see the module comment). Blocking.
Safe and fast (one refused connection + a /proc scan) when nothing is running.
@treturn bool true when no server is left running
]]
function Server:stop(reason)
    -- KOReader's exit path can call this several times in a row (exit to Kobo → Exit → quit).
    if self._stopping then return true end
    self._stopping = true
    local ok = self:_stop(reason)
    self._stopping = false
    return ok
end

function Server:_stop(reason)
    if self._poll then
        UIManager:unschedule(self._poll)
    end
    local was = self.state
    self.state = "stopped"
    if was == "starting" then
        finish(self, false, Client.newError("server_down", _("The Anki server was stopped.")))
    end

    local pids = self:_findPids()
    local probe = Client:probe(1)
    if probe ~= "open" then
        -- Nothing is answering on the port (≤ 1 s to find out, even if connects hang).
        if not self:_anyAlive(pids) then
            return true -- nothing was running
        end
        -- A process exists but isn't serving (hung, or still starting): don't wait on it.
        logger.info("kanki: stopping server (" .. tostring(reason) .. "): process not answering (" .. probe .. ")")
        return self:_kill(pids)
    end

    local res, err = Client:shutdown(self.SHUTDOWN_TIMEOUT_S)
    logger.info("kanki: stopping server (" .. tostring(reason) .. "):",
        res and "shutdown acknowledged" or ("shutdown request failed: " .. tostring(err)))

    if self:_waitGone(self.EXIT_WAIT_S, pids) then
        logger.info("kanki: server has exited")
        return true
    end
    -- A process we couldn't see before (e.g. it was still starting) may have appeared.
    local now_pids = self:_findPids()
    if now_pids and #now_pids > 0 then
        return self:_kill(now_pids)
    end
    logger.warn("kanki: server still answering", self.EXIT_WAIT_S, "s after /shutdown")
    return false
end

--- Mark the server as gone (e.g. after a refused connection) so the next ensure() restarts it.
function Server:markDown()
    if self.state == "running" then
        self.state = "stopped"
    end
end

return Server

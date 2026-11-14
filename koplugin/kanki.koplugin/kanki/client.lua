--[[--
Small synchronous JSON-over-HTTP client for the local kanki server (127.0.0.1 only).

Every call returns `data` on success, or `nil, err` where `err` is a KankiError table:

    err.kind     machine kind from the server's {"error","kind"} body ("need_login", "no_collection",
                 "busy", "bad_request", "network", "auth", "internal"), or one of our own transport
                 kinds: "server_down" (connection refused: nothing listening), "timeout",
                 "transport" (any other socket error), "bad_response" (non-JSON / unexpected body).
    err.message  human readable text, safe to show in the UI.
    err.status   HTTP status code (number) when we got one.

`tostring(err)` gives the message, so `error(err)` / pcall also work if a caller prefers that style.

Requests block the UI thread (LuaSocket is synchronous). That's fine for localhost calls, which are
fast; the only slow one is POST /login (AnkiWeb round trip), for which callers show a message first.
Request bodies are never logged (POST /login carries the AnkiWeb password).
]]

local JSON = require("kanki/json")
local logger = require("logger")
local _ = require("gettext")

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local has_socketutil, socketutil = pcall(require, "socketutil")
if not has_socketutil then socketutil = nil end

local KankiError = {}
KankiError.__index = KankiError
KankiError.__tostring = function(e) return e.message or e.kind or "error" end

local function newError(kind, message, status)
    return setmetatable({ kind = kind, message = message, status = status }, KankiError)
end

local Client = {
    host = "127.0.0.1",
    port = 47321,
    -- Seconds. Per-socket-operation (block) timeout and whole-request (total) timeout.
    default_timeout = 15,
    KankiError = KankiError,
    newError = newError,
}

function Client:setPort(port)
    self.port = port
end

function Client:baseUrl()
    return string.format("http://%s:%d", self.host, self.port)
end

--[[--
Quick TCP check of the server port, bounded by `timeout` seconds (default 1). Used for every
"is it alive?" decision, because a full HTTP request can hang for its whole timeout when nothing
answers (seen on a Kobo whose loopback interface was down: connects neither succeed nor get refused).
@treturn string "open", "refused", "timeout" or "error"
]]
function Client:probe(timeout)
    local sock = socket.tcp()
    if not sock then return "error" end
    sock:settimeout(timeout or 1)
    local ok, err = sock:connect(self.host, self.port)
    sock:close()
    if ok then return "open" end
    local lower = tostring(err or ""):lower()
    if lower:find("refused", 1, true) then return "refused" end
    if lower:find("timeout", 1, true) or lower:find("timed out", 1, true) then return "timeout" end
    return "error"
end

local function classifyTransportError(msg)
    msg = tostring(msg or "")
    local lower = msg:lower()
    if lower:find("refused", 1, true) then
        return newError("server_down", _("The Anki server is not running."))
    elseif lower:find("timeout", 1, true) or lower:find("timed out", 1, true) then
        return newError("timeout", _("The Anki server did not answer in time."))
    end
    return newError("transport", _("Could not talk to the Anki server:") .. " " .. msg)
end

--[[--
Perform a request.

@string method "GET" or "POST"
@string path e.g. "/next?img_max_px=1200"
@param body Lua table to JSON-encode (POST), or nil
@tparam[opt] table opts { timeout = seconds, quiet = bool (don't log failures) }
@return decoded JSON table, or nil + KankiError
]]
function Client:request(method, path, body, opts)
    opts = opts or {}
    local timeout = opts.timeout or self.default_timeout
    local url = self:baseUrl() .. path

    local payload
    if body ~= nil then
        local ok, encoded = pcall(JSON.encode, body)
        if not ok then
            return nil, newError("bad_request", "Could not encode request: " .. tostring(encoded))
        end
        payload = encoded
    elseif method == "POST" then
        payload = "{}"
    end

    local headers = { ["Accept"] = "application/json" }
    if payload then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#payload)
    end

    local sink = {}
    local request = {
        url = url,
        method = method,
        headers = headers,
        source = payload and ltn12.source.string(payload) or nil,
        sink = ltn12.sink.table(sink),
    }

    -- KOReader's global HTTP proxy setting (NetworkMgr:setHTTPProxy sets http.PROXY) must not apply
    -- to 127.0.0.1. LuaSocket uses `reqt.proxy or http.PROXY`, so clear the global for this call.
    local saved_proxy = http.PROXY
    http.PROXY = nil
    local saved_timeout = http.TIMEOUT
    if socketutil then
        -- socketutil also patches socket.tcp() so the total timeout applies.
        socketutil:set_timeout(timeout, timeout * 2)
    else
        http.TIMEOUT = timeout
    end

    local ok, code, resp_headers, status_line = pcall(function()
        return socket.skip(1, http.request(request))
    end)

    if socketutil then
        socketutil:reset_timeout()
    else
        http.TIMEOUT = saved_timeout
    end
    http.PROXY = saved_proxy

    if not ok then
        -- Lua error inside LuaSocket (shouldn't happen, but never crash the UI on it)
        if not opts.quiet then logger.warn("kanki client:", method, path, "raised", code) end
        return nil, classifyTransportError(code)
    end
    if resp_headers == nil then
        -- On failure, http.request returns nil, err; after socket.skip(1) `code` is the error string.
        if not opts.quiet then logger.warn("kanki client:", method, path, "failed:", code) end
        return nil, classifyTransportError(code)
    end

    local text = table.concat(sink)
    local status = tonumber(code)
    local data, decode_err = JSON.decode(text)

    if status and status >= 200 and status < 300 then
        if data == nil then
            if text == "" then
                return {} -- e.g. 204
            end
            if not opts.quiet then logger.warn("kanki client:", method, path, "bad JSON:", decode_err) end
            return nil, newError("bad_response", _("The Anki server sent an unreadable answer."), status)
        end
        return data
    end

    -- Error status: map {"error": "...", "kind": "..."} bodies.
    local kind, message
    if type(data) == "table" then
        kind = data.kind
        message = data.error
    end
    if not kind then
        if status == 409 then kind = "busy"
        elseif status == 401 then kind = "auth"
        elseif status == 400 then kind = "bad_request"
        else kind = "internal" end
    end
    if not message or message == "" then
        message = string.format("%s (HTTP %s)", tostring(status_line or "error"), tostring(status))
    end
    if not opts.quiet then
        logger.info("kanki client:", method, path, "->", status, kind, message)
    end
    return nil, newError(kind, message, status)
end

function Client:get(path, opts)
    return self:request("GET", path, nil, opts)
end

function Client:post(path, body, opts)
    return self:request("POST", path, body, opts)
end

-- Convenience wrappers for the API in DESIGN.md -------------------------------------------------

local function withImgMax(path, img_max_px)
    if img_max_px then
        local sep = path:find("?", 1, true) and "&" or "?"
        return string.format("%s%simg_max_px=%d", path, sep, img_max_px)
    end
    return path
end

function Client:status(opts) return self:get("/status", opts) end
function Client:login(username, password)
    -- AnkiWeb round trip: allow plenty of time.
    return self:post("/login", { username = username, password = password }, { timeout = 60 })
end
function Client:logout() return self:post("/logout") end
function Client:startSync(kind) return self:post("/sync", { kind = kind or "normal" }) end
function Client:syncStatus(opts) return self:get("/sync", opts) end
function Client:decks() return self:get("/decks") end
function Client:selectDeck(id) return self:post("/deck/select", { id = id }) end
function Client:nextCard(img_max_px) return self:get(withImgMax("/next", img_max_px)) end
function Client:answer(card_id, rating, ms_taken, img_max_px)
    return self:post(withImgMax("/answer", img_max_px),
        { card_id = card_id, rating = rating, ms_taken = ms_taken })
end
function Client:undo(img_max_px) return self:post(withImgMax("/undo", img_max_px)) end
function Client:bury(card_id, img_max_px)
    return self:post(withImgMax("/bury", img_max_px), { card_id = card_id })
end
function Client:suspend(card_id, img_max_px)
    return self:post(withImgMax("/suspend", img_max_px), { card_id = card_id })
end
--- The server closes the collection (aborting a running sync, up to ~15 s) before it replies.
function Client:shutdown(timeout)
    return self:post("/shutdown", nil, { timeout = timeout or 20, quiet = true })
end
--- Make an already-running server watch this KOReader's pid.
function Client:adopt(pid)
    return self:post("/adopt", { parent_pid = pid }, { timeout = 5 })
end
--- Render any card without touching the queue (testing/diagnostics).
function Client:card(card_id, img_max_px)
    return self:get(withImgMax(string.format("/card?id=%d", card_id), img_max_px))
end
--- {cards, notes, media_files}
function Client:verify()
    return self:get("/verify", { timeout = 30 })
end

--- Study statistics (see DESIGN.md "GET /stats"). Takes a few hundred ms on the Kobo: cache it.
function Client:stats(opts)
    opts = opts or {}
    opts.timeout = opts.timeout or 15
    return self:get("/stats", opts)
end

--- Flag a card: 0 clears, 1-7 = red, orange, green, blue, pink, turquoise, purple.
function Client:flag(card_id, flag)
    return self:post("/flag", { card_id = card_id, flag = flag })
end

return Client

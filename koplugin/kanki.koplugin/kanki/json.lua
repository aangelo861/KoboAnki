--[[--
JSON helpers for the kanki client.

* Decoding uses KOReader's bundled rapidjson (C, fast enough for card HTML payloads); outside
  KOReader (devtools tests on a desktop) it falls back to the pure-Lua dkjson.
  JSON `null` is removed from objects (so `undo: null` simply reads as nil).

* Encoding is done here in Lua on purpose. On 32-bit ARM (the Kobo) LuaJIT's lua_Integer is 32-bit,
  so lua-rapidjson encodes integral doubles beyond 2^31 (Anki card ids are ~1.7e12) as
  "1690000000000.0", which a Rust/serde server rejects for an i64 field. We format integral
  numbers with "%d" (LuaJIT formats through int64), which is exact up to 2^53.
]]

local JSON = {}

local ok_rj, rapidjson = pcall(require, "rapidjson")
local dkjson
if not ok_rj then
    rapidjson = nil
    dkjson = require("dkjson")
end

-- Sentinel used by the fallback decoder for JSON null.
local DK_NULL = setmetatable({}, { __tostring = function() return "null" end })

local function isNull(v)
    if rapidjson and v == rapidjson.null then return true end
    return v == DK_NULL
end

-- Recursively drop nulls from objects; nulls inside arrays become false (our API has none).
local function stripNulls(v)
    if type(v) ~= "table" then
        return v
    end
    local n = #v
    if n > 0 then
        for i = 1, n do
            local item = v[i]
            if isNull(item) then
                v[i] = false
            else
                v[i] = stripNulls(item)
            end
        end
    else
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        for _, k in ipairs(keys) do
            local item = v[k]
            if isNull(item) then
                v[k] = nil
            else
                v[k] = stripNulls(item)
            end
        end
    end
    return v
end

--- Decode a JSON string. Returns value, or nil + error string.
function JSON.decode(str)
    if type(str) ~= "string" or str == "" then
        return nil, "empty response"
    end
    local value, err
    if rapidjson then
        local ok
        ok, value, err = pcall(rapidjson.decode, str)
        if not ok then
            return nil, tostring(value)
        end
    else
        local _
        value, _, err = dkjson.decode(str, 1, DK_NULL)
    end
    if value == nil then
        return nil, err or "invalid JSON"
    end
    return stripNulls(value)
end

local escapes = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local MAX_EXACT_INT = 2^53

local function encodeValue(v, depth)
    if depth > 32 then
        error("JSON: nesting too deep")
    end
    local t = type(v)
    if v == nil then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            error("JSON: cannot encode non-finite number")
        end
        if v == math.floor(v) and math.abs(v) < MAX_EXACT_INT then
            return string.format("%d", v)
        end
        return string.format("%.17g", v)
    elseif t == "string" then
        return encodeString(v)
    elseif t == "table" then
        local n = #v
        if n > 0 or next(v) == nil and getmetatable(v) == JSON.array_mt then
            local parts = {}
            for i = 1, n do
                parts[i] = encodeValue(v[i], depth + 1)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do
            if type(k) ~= "string" then
                error("JSON: object keys must be strings")
            end
            keys[#keys + 1] = k
        end
        table.sort(keys)
        local parts = {}
        for i, k in ipairs(keys) do
            parts[i] = encodeString(k) .. ":" .. encodeValue(v[k], depth + 1)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("JSON: cannot encode " .. t)
end

JSON.array_mt = {}

--- Mark an (possibly empty) table as a JSON array.
function JSON.array(t)
    return setmetatable(t or {}, JSON.array_mt)
end

--- Encode a Lua value. Raises on unsupported values.
function JSON.encode(v)
    return encodeValue(v, 0)
end

return JSON

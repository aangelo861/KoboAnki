--[[--
Per-day study tracking for the plugin (study timer, Pomodoro, reading done in Nickel), kept in
KOReader's settings dir as `kanki_tracking.lua` (a LuaSettings file).

Days are local calendar dates ("YYYY-MM-DD"). Anki's own review numbers are NOT stored here: they
come from the server (GET /stats), which counts reviews from every device after a sync.

Writes are deferred: add() only changes memory, flush() writes the file. Callers flush at natural
points (end of a review session, a finished Pomodoro, suspend, exit) so answering a card never
costs a write to the FAT partition.

Record fields (all numbers, missing = 0):
  study_s            seconds spent in the reviewer (paused while asleep or on a break)
  cards              cards answered in the reviewer on this device
  sessions           reviewer sessions opened
  pomodoros          focus blocks completed
  focus_s            seconds of completed focus blocks
  read_nickel_s      reading time in the Kobo's own reader (from snapshot deltas, see readingstats)
  read_nickel_pages  page turns in the Kobo's own reader (idem)
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Tracking = {
    RETAIN_DAYS = 400, -- enough for a year of history (streaks, weekly/monthly totals)
    FIELDS = { "study_s", "cards", "sessions", "pomodoros", "focus_s", "read_nickel_s", "read_nickel_pages" },
    store = nil,
    dirty = false,
}

function Tracking:_open()
    if not self.store then
        self.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/kanki_tracking.lua")
    end
    return self.store
end

--- "YYYY-MM-DD" for a unix time (default now), in local time.
function Tracking.dateKey(t)
    return os.date("%Y-%m-%d", t or os.time())
end

function Tracking:_days()
    local store = self:_open()
    local days = store:readSetting("days")
    if type(days) ~= "table" then
        days = {}
        store:saveSetting("days", days)
    end
    return days
end

--- Add to one day's counters (in memory). fields: { study_s = 12, cards = 1, ... }.
function Tracking:add(fields, t)
    local days = self:_days()
    local key = self.dateKey(t)
    local rec = days[key]
    if type(rec) ~= "table" then
        rec = {}
        days[key] = rec
    end
    for k, v in pairs(fields) do
        if type(v) == "number" and v ~= 0 then
            rec[k] = (tonumber(rec[k]) or 0) + v
        end
    end
    self.dirty = true
end

--- A copy of one day's record with every field present (zeros where nothing was recorded).
function Tracking:day(t)
    local rec = self:_days()[self.dateKey(t)] or {}
    local out = { date = self.dateKey(t) }
    for _, f in ipairs(self.FIELDS) do
        out[f] = tonumber(rec[f]) or 0
    end
    return out
end

--- The last n days (oldest first, ending with the day of `t`, default today).
function Tracking:lastDays(n, t)
    t = t or os.time()
    local out = {}
    for i = n - 1, 0, -1 do
        -- step back by whole days at local noon, so DST changes never skip or repeat a date
        local noon = os.time(os.date("*t", t)) -- normalise
        local d = os.date("*t", noon)
        d.hour, d.min, d.sec = 12, 0, 0
        d.day = d.day - i
        table.insert(out, self:day(os.time(d)))
    end
    return out
end

--- Sum of each field over the last n days (including today).
function Tracking:totals(n, t)
    local sum = {}
    for _, f in ipairs(self.FIELDS) do sum[f] = 0 end
    for _, rec in ipairs(self:lastDays(n, t)) do
        for _, f in ipairs(self.FIELDS) do
            sum[f] = sum[f] + rec[f]
        end
    end
    return sum
end

--- Arbitrary persistent values (e.g. cached Anki stats, the Nickel reading snapshot).
function Tracking:get(key)
    return self:_open():readSetting(key)
end

function Tracking:set(key, value)
    local store = self:_open()
    if value == nil then
        store:delSetting(key)
    else
        store:saveSetting(key, value)
    end
    self.dirty = true
end

--- Write to disk if anything changed. Drops days older than RETAIN_DAYS.
function Tracking:flush()
    if not self.dirty or not self.store then return end
    local days = self:_days()
    local cutoff = self.dateKey(os.time() - self.RETAIN_DAYS * 86400)
    for key in pairs(days) do
        if key < cutoff then days[key] = nil end
    end
    self.store:flush()
    self.dirty = false
end

return Tracking

-- Desktop stub of KOReader's logger (devtools tests only).
local logger = {}
local quiet = os.getenv("KANKI_TEST_QUIET") == "1"
for _, level in ipairs({ "dbg", "info", "warn", "err" }) do
    logger[level] = function(...)
        if quiet and (level == "dbg" or level == "info") then return end
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        io.stderr:write("[" .. level .. "] " .. table.concat(parts, " ") .. "\n")
    end
end
return logger

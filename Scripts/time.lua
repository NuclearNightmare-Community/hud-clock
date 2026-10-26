-- The in-game time (clock story 2): read it from the live Ultra Dynamic Sky, format it like the Journal map.
--
--   time.read()            -> hour, minute | nil, reason   game thread; re-finds the sky on every call
--   time.format(h, m, n)   -> "HH:MM"                       minute rounded down to a multiple of n
--   time.boundary(h, m, n) -> integer                       changes exactly when format's text changes
--   time.forget()                                           drop the remembered sky path (after a map change)
--
-- The sky (Ultra_Dynamic_Sky_C) keeps `Time of Day` as a double, 0..2400, 100 units per hour; its own
-- `Time Of Day to H/M/S` turns that into hour/minute/second (Time % 2400, so hours are 0..23). The Journal map
-- (MapWidget_C.GetText_0) formats the same conversion (via the sky's Get DateTime) as zero-padded HH:MM.
-- Clients read their own replicated copy; nothing here sends anything or reads anything from another player.
--
-- No UObject is kept between calls (AGENTS.md): only the sky's path, re-found with StaticFindObject (a cheap
-- lookup), and FindFirstOf (a scan) only when the path no longer resolves.
local M = {}

local SKY_CLASS = "Ultra_Dynamic_Sky_C"
local TOD = "Time of Day"
local TO_HMS = "Time Of Day to H/M/S"

local skyPath -- full path of the last live sky (a string, never the object)

-- ---------------------------------------------------------------- pure logic

local function checkArgs(fn, h, m, n)
    if type(h) ~= "number" or h ~= h or h == math.huge or h == -math.huge then error("time." .. fn .. ": hour must be a finite number, got " .. tostring(h), 3) end
    if type(m) ~= "number" or m ~= m or m == math.huge or m == -math.huge then error("time." .. fn .. ": minute must be a finite number, got " .. tostring(m), 3) end
    if math.type(n) ~= "integer" or n < 1 or n > 60 then error("time." .. fn .. ": n must be an integer from 1 to 60, got " .. tostring(n), 3) end
end

-- Minute of the day, 0..1439: hours of 24 or more (and negative ones) wrap; a minute of 60 carries into the hour.
local function minuteOfDay(h, m)
    local total = math.floor(h) * 60 + math.floor(m)
    return total % 1440
end

-- The shown minute of the day: the minute rounded down to a multiple of n within its hour (10:07 with n = 5 is 10:05;
-- n = 60 gives whole hours). Rounding is always down, like a clock face.
local function shownMinuteOfDay(h, m, n)
    local t = minuteOfDay(h, m)
    local hh, mm = t // 60, t % 60
    return hh * 60 + mm - mm % n
end

function M.format(h, m, n)
    checkArgs("format", h, m, n)
    local t = shownMinuteOfDay(h, m, n)
    return string.format("%02d:%02d", t // 60, t % 60)
end

-- The key of the shown text: equal for two times exactly when format gives the same text. For every n that divides
-- 60 (1, 5, 15, ...) it changes at the same moments as (h*60 + m) // n.
function M.boundary(h, m, n)
    checkArgs("boundary", h, m, n)
    return shownMinuteOfDay(h, m, n)
end

-- ---------------------------------------------------------------- the one game call

local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local function pathOf(o)
    return (o:GetFullName():gsub("^%S+ ", ""))
end

-- The first number UE4SS wrote into an out-parameter table (it stores it under the parameter's name).
local function outNumber(t)
    for _, v in pairs(t) do
        if type(v) == "number" then return v end
    end
    return nil
end

local function findSky()
    if skyPath then
        local s = StaticFindObject(skyPath)
        if valid(s) then return s end
        skyPath = nil
    end
    local s = FindFirstOf(SKY_CLASS)
    if not valid(s) then return nil end
    local p = pathOf(s)
    if p:find("Default__", 1, true) then return nil end
    skyPath = p
    return s
end

local function readRaw()
    local sky = findSky()
    if not sky then return nil, "no sky" end
    local tod = sky[TOD]
    if type(tod) ~= "number" then return nil, "'" .. TOD .. "' is not a number (" .. type(tod) .. ")" end
    local fn = sky[TO_HMS]
    if fn == nil then return nil, "'" .. TO_HMS .. "' is missing on " .. SKY_CLASS end
    local oh, om, os_, of = {}, {}, {}, {}
    fn(sky, tod, oh, om, os_, of)
    local h, m = outNumber(oh), outNumber(om)
    if h == nil or m == nil then
        return nil, string.format("'%s' returned no hour/minute (hour=%s minute=%s)", TO_HMS, tostring(h), tostring(m))
    end
    return math.floor(h), math.floor(m)
end

-- read() -> hour, minute | nil, reason. Never raises: an engine error comes back as nil, "read failed: ...".
-- reason is "no sky" when no Ultra_Dynamic_Sky_C is live (loading; the main menu has its own sky).
function M.read()
    local ok, h, m = pcall(readRaw)
    if not ok then
        skyPath = nil
        return nil, "read failed: " .. tostring(h):match("^[^\n]*")
    end
    return h, m
end

function M.forget() skyPath = nil end

-- Diagnostics (tests, debug lines): the remembered sky path or nil.
function M.skyPath() return skyPath end

return M

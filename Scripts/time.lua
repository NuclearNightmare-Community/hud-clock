-- The in-game time (clock story 2): read it from the live Ultra Dynamic Sky, format it like the Journal map.
--
--   time.read()            -> hour, minute | nil, reason   game thread; re-finds the sky on every call
--   time.format(h, m, n)   -> "HH:MM"                       minute rounded down to a multiple of n
--   time.boundary(h, m, n) -> integer                       changes exactly when format's text changes
--   time.slot(h, m, n)     -> slot, perDay                  the boundary's position in the day, 0..perDay-1
--   time.shouldShow(last, slot, perDay) -> boolean          show this slot? (holds back a 1-2 slot step back)
--   time.forget()                                           drop the remembered sky path (after a map change)
--   time.takeNote()        -> message, level | nil          the once-per-sky conversion check's result, to log
--   time.useHandles(ref, deref, free)                       keep the sky as a core weak handle instead of a path
--
-- The sky (Ultra_Dynamic_Sky_C) keeps `Time of Day` as a double, 0..2400, 100 units per hour; its own
-- `Time Of Day to H/M/S` turns that into hour/minute/second (Time % 2400, so hours are 0..23); hmFromTod below does
-- the same in Lua, checked against the function once per sky. The Journal map
-- (MapWidget_C.GetText_0) formats the same conversion (via the sky's Get DateTime) as zero-padded HH:MM.
-- Clients read their own replicated copy; nothing here sends anything or reads anything from another player.
--
-- No UObject is kept between calls (AGENTS.md): only the sky's path and, with core, a weak handle to it, re-found
-- each call; FindFirstOf (a scan, about 120 us) only when that no longer resolves or after a map change.
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

-- The boundary's position in the day: 0, 1, 2, ... in steps of one shown value, and how many there are a day
-- (perDay). For an n that divides 60 the slot is the minute of the day // n and perDay is 1440 // n; for any other n
-- each hour has ceil(60 / n) values (n = 7: :00, :07, ... :56), so the slots stay consecutive across the hour.
function M.slot(h, m, n)
    checkArgs("slot", h, m, n)
    local t = shownMinuteOfDay(h, m, n)
    local perHour = (60 + n - 1) // n
    return (t // 60) * perHour + (t % 60) // n, 24 * perHour
end

-- How far back a new slot may be and still be held back (clock story 5): on a client the sky's once-a-second
-- replication snaps Time of Day to the host's value with no smoothing, which can step it back by well under a game
-- minute, so a 1 or 2 slot step back would show a time that goes backwards for a moment. A larger step back (the
-- 23:59 -> 00:00 wrap is a step forward; the host setting the time back) shows at once.
local HOLD_BACK = 2

-- shouldShow(last, slot, perDay) -> boolean: true when nothing is shown yet (last nil), or the slot is ahead of last
-- (counted around the day, so the midnight wrap is ahead), or it is more than HOLD_BACK slots behind; false for the
-- same slot and for a step back of 1 or 2 slots.
function M.shouldShow(last, slot, perDay)
    if math.type(perDay) ~= "integer" or perDay <= 2 * HOLD_BACK then error("time.shouldShow: perDay must be an integer above " .. 2 * HOLD_BACK .. ", got " .. tostring(perDay), 2) end
    if math.type(slot) ~= "integer" or slot < 0 or slot >= perDay then error("time.shouldShow: slot must be an integer from 0 to perDay - 1, got " .. tostring(slot), 2) end
    if last == nil then return true end
    if math.type(last) ~= "integer" or last < 0 or last >= perDay then error("time.shouldShow: last must be nil or an integer from 0 to perDay - 1, got " .. tostring(last), 2) end
    local ahead = (slot - last) % perDay
    if ahead == 0 then return false end
    return perDay - ahead > HOLD_BACK
end

-- ---------------------------------------------------------------- the one game call

local function isValidOf(o) return o:IsValid() end -- no closure per call: a tick allocates as little as possible
local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(isValidOf, o)
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

-- With core's weak handles (useHandles), the sky is kept as a handle and re-found with one native Deref (about
-- 5 us on V8.1.2) instead of StaticFindObject by path plus IsValid; without them (unit tests), by path.
local H -- { ref, deref, free } from core, or nil
local skyHandle

local function dropHandle()
    if skyHandle and H then pcall(H.free, skyHandle) end
    skyHandle = nil
end

local function findSky()
    if H and skyHandle then
        local okD, s = pcall(H.deref, skyHandle)
        if okD and s ~= nil then return s end
        dropHandle()
        skyPath = nil
    elseif skyPath and not H then
        local s = StaticFindObject(skyPath)
        if valid(s) then return s end
        skyPath = nil
    end
    local s = FindFirstOf(SKY_CLASS)
    if not valid(s) then return nil end
    local p = pathOf(s)
    if p:find("Default__", 1, true) then return nil end
    skyPath = p
    if H then
        local okR, h = pcall(H.ref, s)
        if okR then skyHandle = h end
    end
    return s
end

-- useHandles(ref, deref, free): core's weak-handle functions (core.ref, core.deref, core.free).
function M.useHandles(ref, deref, free)
    dropHandle()
    H = { ref = ref, deref = deref, free = free }
end

-- The sky's own conversion, done in Lua: the decompiled `Time Of Day to H/M/S` is Time % 2400, / 100, floor for the
-- hour, the fraction * 60, floor for the minute; the same IEEE double operations give the same result. Calling the
-- Blueprint function costs about 100 us a second (measured on V8.1.2: looking it up by name dominates), reading the
-- property about 9 us, so the clock converts in Lua and checks that against the function once per sky.
function M.hmFromTod(tod)
    local x = (tod % 2400) / 100
    local h = math.floor(x)
    return h, math.floor((x - h) * 60)
end

local function viaFunction(sky, tod)
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

local verifiedPath        -- the sky whose Lua conversion was checked against its function
local useFunction = false -- set for the rest of the session once the two ever disagree
local note, noteLevel     -- what the last check found, for the caller to log once (takeNote)

local function readRaw()
    local sky = findSky()
    if not sky then return nil, "no sky" end
    local tod = sky[TOD]
    if type(tod) ~= "number" then return nil, "'" .. TOD .. "' is not a number (" .. type(tod) .. ")" end
    if useFunction then return viaFunction(sky, tod) end
    local h, m = M.hmFromTod(tod)
    if verifiedPath ~= skyPath then
        verifiedPath = skyPath
        local okF, fh, fm = pcall(viaFunction, sky, tod)
        if not okF or fh == nil then
            note, noteLevel = string.format("could not check the conversion against '%s' (%s); using Lua's", TO_HMS,
                tostring(okF and fm or fh):match("^[^\n]*")), "warn"
        elseif fh ~= h or fm ~= m then
            useFunction = true
            note, noteLevel = string.format("Lua's conversion of %.4f gave %d:%02d, '%s' %d:%02d; using the sky's function from now on",
                tod, h, m, TO_HMS, fh, fm), "warn"
            return fh, fm
        else
            note, noteLevel = string.format("VERIFY %.4f -> %02d:%02d, the same as '%s'", tod, h, m, TO_HMS), "info"
        end
    end
    return h, m
end

-- takeNote() -> message, level ("info" | "warn") | nil: what the last conversion check found, once.
function M.takeNote()
    local n, l = note, noteLevel
    note, noteLevel = nil, nil
    return n, l
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

function M.forget() dropHandle(); skyPath, verifiedPath = nil, nil end -- a new world: find its sky and check it again

-- Diagnostics (tests, debug lines): the remembered sky path or nil.
function M.skyPath() return skyPath end

return M

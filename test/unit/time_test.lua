-- Unit tests for Scripts/time.lua outside the game (clock story 2, acceptance 2 and the robustness of read()).
-- The sky and UE4SS's globals are stubbed with plain Lua tables, so this checks the clock's own logic, not the engine.
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  texlua test/unit/time_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/Scripts/?.lua;" .. package.path

local passed, failed = 0, 0
local function ok(cond, name, detail)
    if cond then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or "")) end
end
local function eq(got, want, name) ok(got == want, name, "got " .. tostring(got) .. ", want " .. tostring(want)) end
local function raises(fn, text, name)
    local okP, err = pcall(fn)
    ok(not okP and tostring(err):find(text, 1, true) ~= nil, name, okP and "did not raise" or err)
end

-- ---------------------------------------------------------------- fake engine
local objects, calls = {}, { find = 0, static = 0, hms = 0 }
local function newSky(path, tod)
    local s = { path = path, alive = true }
    s["Time of Day"] = tod
    function s:IsValid() return self.alive end
    function s:GetFullName() return "Ultra_Dynamic_Sky_C " .. self.path end
    -- UE4SS stores each out parameter in the table passed at its position, under the parameter's name.
    s["Time Of Day to H/M/S"] = function(self, t, oh, om, os_, of)
        calls.hms = calls.hms + 1
        local x = (t % 2400) / 100
        local hour = math.floor(x)
        local mf = (x - hour) * 60
        local minute = math.floor(mf)
        oh.Hour, om.Minute, os_.Second, of["Second Fraction"] = hour, minute, math.floor((mf - minute) * 60), 0.0
    end
    objects[path] = s
    return s
end
local INVALID = { IsValid = function() return false end }
local firstSky -- what FindFirstOf("Ultra_Dynamic_Sky_C") returns
function FindFirstOf(cls)
    calls.find = calls.find + 1
    assert(cls == "Ultra_Dynamic_Sky_C", cls)
    return firstSky or INVALID
end
function StaticFindObject(path)
    calls.static = calls.static + 1
    local o = objects[path]
    return (o and o.alive) and o or INVALID
end

local time = require("time")

-- ---------------------------------------------------------------- format (story 2, AC 2)
eq(time.format(0, 0, 1), "00:00", "format 00:00")
eq(time.format(9, 5, 1), "09:05", "format 09:05")
eq(time.format(23, 59, 1), "23:59", "format 23:59")
eq(time.format(24, 0, 1), "00:00", "format 24:00 wraps to 00:00")
eq(time.format(25, 10, 1), "01:10", "format 25:10 wraps to 01:10")
eq(time.format(48, 30, 1), "00:30", "format 48:30 wraps to 00:30")
eq(time.format(-1, 15, 1), "23:15", "format a negative hour wraps backwards")
eq(time.format(10, 60, 1), "11:00", "format minute 60 carries into the hour")
eq(time.format(23, 60, 1), "00:00", "format 23:60 carries and wraps")
eq(time.format(10.9, 7.99, 1), "10:07", "format floors fractional inputs")

-- Rounding is down, never up.
eq(time.format(10, 7, 5), "10:05", "n=5: 10:07 shows 10:05")
eq(time.format(10, 4, 5), "10:00", "n=5: 10:04 shows 10:00")
eq(time.format(10, 5, 5), "10:05", "n=5: 10:05 shows 10:05")
eq(time.format(10, 59, 5), "10:55", "n=5: 10:59 shows 10:55")
eq(time.format(10, 7, 1), "10:07", "n=1: exact")
eq(time.format(10, 59, 60), "10:00", "n=60: whole hours")
eq(time.format(0, 0, 60), "00:00", "n=60: midnight")
eq(time.format(10, 13, 7), "10:07", "n=7: rounded within the hour")
eq(time.format(10, 59, 7), "10:56", "n=7: last step of the hour")

-- Every minute of the day matches the Journal map's own formatting for n = 1 (MapWidget_C.GetText_0: hour > 9 ?
-- str : "0" .. str, the same for the minute).
local function mapText(h, m)
    local hs = h > 9 and tostring(h) or ("0" .. h)
    local ms = m > 9 and tostring(m) or ("0" .. m)
    return hs .. ":" .. ms
end
do
    local bad = 0
    for h = 0, 23 do for m = 0, 59 do if time.format(h, m, 1) ~= mapText(h, m) then bad = bad + 1 end end end
    eq(bad, 0, "n=1: all 1440 minutes match the map's formatting")
end

-- ---------------------------------------------------------------- boundary (story 2, AC 2)
-- Over a whole day, for each n: the boundary changes exactly when the shown text changes, which is exactly at the
-- minutes that are multiples of n within their hour; for n dividing 60 that's the same as (h*60 + m) // n.
for _, n in ipairs({ 1, 2, 5, 10, 15, 30, 60, 7, 13, 59 }) do
    local mismatched, offMultiple, formulaDiff = 0, 0, 0
    local prevB, prevText, prevF = time.boundary(23, 59, n), time.format(23, 59, n), (23 * 60 + 59) // n
    for t = 0, 1439 do
        local h, m = t // 60, t % 60
        local b, text, f = time.boundary(h, m, n), time.format(h, m, n), t // n
        local changed, textChanged = b ~= prevB, text ~= prevText
        if changed ~= textChanged then mismatched = mismatched + 1 end
        if changed ~= (m % n == 0) then offMultiple = offMultiple + 1 end
        if 60 % n == 0 and t > 0 and (changed ~= (f ~= prevF)) then formulaDiff = formulaDiff + 1 end
        prevB, prevText, prevF = b, text, f
    end
    eq(mismatched, 0, "n=" .. n .. ": boundary changes exactly when the text changes")
    eq(offMultiple, 0, "n=" .. n .. ": boundary changes exactly at multiples of n")
    if 60 % n == 0 then eq(formulaDiff, 0, "n=" .. n .. ": same change points as (h*60 + m) // n") end
end
ok(math.type(time.boundary(10, 7, 5)) == "integer", "boundary is an integer")
eq(time.boundary(24, 0, 1), time.boundary(0, 0, 1), "boundary wraps like format")

-- Bad arguments raise a clean error naming the function.
raises(function() time.format("10", 0, 1) end, "time.format: hour must be a finite number", "format: string hour")
raises(function() time.format(10, nil, 1) end, "time.format: minute must be a finite number", "format: nil minute")
raises(function() time.format(0 / 0, 0, 1) end, "time.format: hour must be a finite number", "format: NaN hour")
raises(function() time.format(math.huge, 0, 1) end, "time.format: hour must be a finite number", "format: inf hour")
raises(function() time.format(10, 0, 0) end, "time.format: n must be an integer from 1 to 60", "format: n=0")
raises(function() time.format(10, 0, 61) end, "n must be an integer from 1 to 60", "format: n=61")
raises(function() time.format(10, 0, 1.5) end, "n must be an integer from 1 to 60", "format: n=1.5")
raises(function() time.boundary(10, 0, "5") end, "time.boundary: n must be an integer", "boundary: string n")

-- ---------------------------------------------------------------- read (story 2, AC 4 and 5)
do
    firstSky = nil
    local h, why = time.read()
    ok(h == nil and why == "no sky", "read: no sky -> nil, 'no sky'", tostring(h) .. " " .. tostring(why))
end
do
    local sky = newSky("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap:PersistentLevel.Ultra_Dynamic_Sky_C_0", 1037.5)
    firstSky = sky
    local h, m = time.read()
    ok(h == 10 and m == 22, "read: 1037.5 -> 10:22", tostring(h) .. ":" .. tostring(m))
    ok(math.type(h) == "integer" and math.type(m) == "integer", "read: integers")
    eq(time.skyPath(), sky.path, "read: remembers the sky's path, not the object")
    local f0, s0 = calls.find, calls.static
    sky["Time of Day"] = 2399.99
    h, m = time.read()
    ok(h == 23 and m == 59, "read: 2399.99 -> 23:59 (100 units per hour)", tostring(h) .. ":" .. tostring(m))
    ok(calls.find == f0 and calls.static == s0 + 1, "read: second call re-finds by path (StaticFindObject), no FindFirstOf scan",
        ("find +%d static +%d"):format(calls.find - f0, calls.static - s0))
    sky["Time of Day"] = 2400.0
    h, m = time.read()
    ok(h == 0 and m == 0, "read: 2400 -> 00:00 (the sky wraps Time % 2400)", tostring(h) .. ":" .. tostring(m))

    -- The sky goes away (map change): path no longer resolves, FindFirstOf finds nothing.
    sky.alive = false; firstSky = nil
    h, m = time.read()
    ok(h == nil and m == "no sky" and time.skyPath() == nil, "read: dead sky -> no sky, path forgotten", tostring(m))

    -- A new sky in the next match is found by FindFirstOf.
    local sky2 = newSky("/Game/Maps/Forest.Forest:PersistentLevel.Ultra_Dynamic_Sky_C_0", 600)
    firstSky = sky2
    h, m = time.read()
    ok(h == 6 and m == 0 and time.skyPath() == sky2.path, "read: new sky found", tostring(h) .. ":" .. tostring(m))

    -- forget(): the next read scans again.
    time.forget()
    local f1 = calls.find
    time.read()
    eq(calls.find, f1 + 1, "forget: next read uses FindFirstOf")

    -- The conversion is done in Lua and checked against the sky's function once per sky (and after forget()).
    local hms0 = calls.hms
    time.forget(); time.takeNote()
    h, m = time.read()
    local note, level = time.takeNote()
    ok(h == 6 and m == 0 and level == "info" and tostring(note):find("^VERIFY 600%.0000 %-> 06:00, the same as 'Time Of Day to H/M/S'"),
        "check: once per sky, logged as VERIFY", tostring(note))
    eq(calls.hms, hms0 + 1, "check: one call of the sky's function")
    time.read(); time.read()
    eq(calls.hms, hms0 + 1, "check: later reads don't call the function")
    ok(time.takeNote() == nil, "check: the note is given once")

    -- The function is missing after a patch: the Lua conversion goes on, with one WARN note.
    local saved = sky2["Time Of Day to H/M/S"]
    sky2["Time Of Day to H/M/S"] = nil
    time.forget()
    h, m = time.read()
    note, level = time.takeNote()
    ok(h == 6 and m == 0 and level == "warn" and tostring(note):find("could not check the conversion", 1, true) and tostring(note):find("is missing", 1, true),
        "check: function missing -> Lua's time and a WARN note", tostring(note))
    -- It throws: same, one line.
    sky2["Time Of Day to H/M/S"] = function() error("boom\nsecond line") end
    time.forget()
    h, m = time.read()
    note, level = time.takeNote()
    ok(h == 6 and level == "warn" and tostring(note):find("boom", 1, true) and not tostring(note):find("\n", 1, true), "check: function throws -> one-line WARN note", tostring(note))
    -- No out values.
    sky2["Time Of Day to H/M/S"] = function() end
    time.forget()
    h, m = time.read()
    note, level = time.takeNote()
    ok(h == 6 and level == "warn" and tostring(note):find("returned no hour/minute", 1, true), "check: no out values -> WARN note", tostring(note))
    -- The function disagrees: its answer wins, now and for the rest of the session.
    sky2["Time Of Day to H/M/S"] = function(self, t, oh, om) oh.Hour = 7; om.Minute = 1 end
    time.forget()
    h, m = time.read()
    note, level = time.takeNote()
    ok(h == 7 and m == 1 and level == "warn" and tostring(note):find("using the sky's function from now on", 1, true), "check: disagreement -> the function's answer, WARN", tostring(note))
    local hms1 = calls.hms
    sky2["Time Of Day to H/M/S"] = function(self, t, oh, om) calls.hms = calls.hms + 1; oh.Hour = 7; om.Minute = 2 end
    h, m = time.read()
    ok(h == 7 and m == 2 and calls.hms == hms1 + 1, "check: after a disagreement every read uses the function", tostring(h) .. ":" .. tostring(m))
    -- From here on the function is in use: a missing one is now a read error.
    sky2["Time Of Day to H/M/S"] = nil
    h, m = time.read()
    ok(h == nil and tostring(m):find("'Time Of Day to H/M/S' is missing", 1, true), "function in use and missing -> nil, reason", tostring(m))
    sky2["Time Of Day to H/M/S"] = function() error("boom\nsecond line") end
    h, m = time.read()
    ok(h == nil and tostring(m):find("read failed: ", 1, true) and not tostring(m):find("\n", 1, true), "function in use and throws -> nil, one-line reason", tostring(m))
    sky2["Time Of Day to H/M/S"] = saved
    -- Time of Day isn't a number.
    sky2["Time of Day"] = nil
    h, m = time.read()
    ok(h == nil and tostring(m):find("is not a number", 1, true), "read: Time of Day not a number -> nil, reason", tostring(m))
    sky2["Time of Day"] = 1205
    h, m = time.read()
    ok(h == 12 and m == 3, "read: recovers once the sky reads again", tostring(h) .. ":" .. tostring(m))
    -- IsValid throwing is treated as not valid.
    sky2.IsValid = function() error("freed") end
    firstSky = nil
    h, m = time.read()
    ok(h == nil and m == "no sky", "read: IsValid throwing -> no sky", tostring(m))
    -- A class default object is never taken for the live sky.
    local cdo = newSky("/Game/UltraDynamicSky/Blueprints/Ultra_Dynamic_Sky.Default__Ultra_Dynamic_Sky_C", 1000)
    firstSky = cdo
    h, m = time.read()
    ok(h == nil and m == "no sky", "read: CDO ignored", tostring(m))
end

-- hmFromTod is the decompiled formula: compare with it over a dense sweep of Time of Day.
do
    local bad = 0
    for i = 0, 240000 do
        local t = i * 0.01 + (i % 7) * 1e-4
        local x = (t % 2400) / 100
        local hh = math.floor(x)
        local mf = (x - hh) * 60
        local h2, m2 = time.hmFromTod(t)
        if h2 ~= hh or m2 ~= math.floor(mf) then bad = bad + 1 end
    end
    eq(bad, 0, "hmFromTod: same as the sky's formula over 240001 values")
    local h, m = time.hmFromTod(2400.0); ok(h == 0 and m == 0, "hmFromTod: 2400 -> 0:00")
    h, m = time.hmFromTod(659.06); ok(h == 6 and m == 35, "hmFromTod: 659.06 -> 6:35 (logged in game as 6:35:26)")
end

print(("time_test: %d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)

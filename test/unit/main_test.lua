-- Unit tests for Scripts/main.lua outside the game: the bootstrap, settings, and the glue between time.lua and core's
-- UI helpers (clock stories 1 and 3), against a fake core (client.connect, core.ui.text, core.log, core.clock), a
-- fake sky and stubbed UE4SS globals. The in-game proof is run.ps1 (story 4).
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  texlua test/unit/main_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
local MAIN = ROOT .. "/Scripts/main.lua"

local passed, failed = 0, 0
local function ok(cond, name, detail)
    if cond then passed = passed + 1 else failed = failed + 1; io.stdout:write("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or "") .. "\n") end
end
local function eq(got, want, name) ok(got == want, name, "got " .. tostring(got) .. ", want " .. tostring(want)) end

-- ---------------------------------------------------------------- fakes
local W -- the world of one test: printed lines, ui calls, loops, hooks, sky
local realLoadfile, realLoad = loadfile, load

local function newSky(path, tod)
    local s = { path = path, alive = true }
    s["Time of Day"] = tod
    function s:IsValid() return self.alive end
    function s:GetFullName() return "Ultra_Dynamic_Sky_C " .. self.path end
    s["Time Of Day to H/M/S"] = function(self, t, oh, om)
        local x = (t % 2400) / 100
        oh.Hour = math.floor(x)
        om.Minute = math.floor((x - math.floor(x)) * 60 + 1e-9)
    end
    W.objects[path] = s
    return s
end
local function tod(h, m) return h * 100 + m * 100 / 60 end

local INVALID = { IsValid = function() return false end }
function FindFirstOf() W.finds = W.finds + 1; return W.sky or INVALID end
function StaticFindObject(p) local o = W.objects[p] return (o and o.alive) and o or INVALID end
function LoopInGameThreadWithDelay(ms, fn) W.loops[#W.loops + 1] = { ms = ms, fn = fn }; return #W.loops end
function RegisterLoadMapPostHook(fn) W.loadMapHooks[#W.loadMapHooks + 1] = fn end
function LoopAsync() W.async = W.async + 1 end
function ExecuteInGameThread() W.async = W.async + 1 end
print = function(s) W.printed[#W.printed + 1] = (tostring(s):gsub("\n$", "")) end

-- core's logger shape (nucleus.log): one line per call, "[Clock] LEVEL msg".
local function newLog(tag)
    local L = { debugEnabled = false }
    local function emit(level, fmt, ...) print("[" .. tag .. "] " .. level .. string.format(fmt, ...) .. "\n") end
    function L.info(f, ...) emit("", f, ...) end
    function L.warn(f, ...) emit("WARN ", f, ...) end
    function L.error(f, ...) emit("ERROR ", f, ...) end
    function L.debug(f, ...) if L.debugEnabled then emit("DEBUG ", f, ...) end end
    return L
end

local function newUi()
    local U = { calls = {}, els = {} }
    local function rec(...) U.calls[#U.calls + 1] = table.pack(...) end
    U.text = {
        create = function(spec)
            rec("create", spec)
            if U.failCreate then error("nucleus.ui.text.create: boom") end
            local h = setmetatable({}, { __index = { id = spec.id }, __newindex = function() error("read-only") end })
            U.els[h] = { text = spec.text, visible = true, place = spec.place }
            return h
        end,
        set = function(h, t)
            rec("set", t)
            if U.failSet then error("nucleus.ui.text.set: boom") end
            U.els[h].text = t
        end,
        setVisible = function(h, v)
            assert(type(v) == "boolean")
            rec("setVisible", v)
            U.els[h].visible = v
        end,
        isShown = function(h) return U.els[h].visible end,
    }
    return U
end

-- Loads main.lua fresh. opts: client = false (core not installed) | nil; settings = text of settings.lua | false.
local function boot(opts)
    opts = opts or {}
    W = { printed = {}, loops = {}, loadMapHooks = {}, objects = {}, finds = 0, async = 0, connects = {} }
    package.loaded["time"] = nil
    package.loaded["nucleus.client"] = nil
    package.preload["nucleus.client"] = nil
    if opts.client ~= false then
        package.preload["nucleus.client"] = function()
            return { connect = function(o) W.connects[#W.connects + 1] = o end }
        end
    end
    loadfile = function(path, mode, env)
        if path:match("[/\\]settings%.lua$") then
            if opts.settings == false then return nil, "cannot open " .. path end
            return realLoad(opts.settings or "return { updateEvery = 1 }", "=settings.lua", "t", env)
        end
        return realLoadfile(path, mode, env)
    end
    local chunk = assert(realLoadfile(MAIN))
    chunk()
    loadfile = realLoadfile
end

local function connect(core)
    local c = W.connects[1]
    c.onReady(core)
end
local function newCore(o)
    o = o or {}
    local now = 0
    local core = { name = "Nucleus", version = "0.2.0", log = newLog("Clock") }
    if o.ui ~= false then core.ui = newUi() end
    if o.clock ~= false then core.clock = { micros = function() now = now + 25 return now end } end
    return core
end
local function tick(n) for _ = 1, (n or 1) do W.loops[1].fn() end end
local function lines(pat) local r = {} for _, l in ipairs(W.printed) do if l:find(pat) then r[#r + 1] = l end end return r end
local function callsSince(U, i, name) local r = {} for k = i + 1, #U.calls do if U.calls[k][1] == name then r[#r + 1] = U.calls[k][2] end end return r end

-- ---------------------------------------------------------------- bootstrap (story 1)
do -- Core not installed: exactly one [Clock] line, the bootstrap's own; nothing else happens.
    boot{ client = false }
    eq(#W.printed, 1, "no core: exactly one line")
    eq(W.printed[1], "[Clock] Nucleus is not installed. Clock will not run.", "no core: the line names the cause")
    eq(#W.connects, 0, "no core: no connect")
    eq(#W.loops, 0, "no core: no loop")
end

do -- Core installed: connect{ mod = "Clock", need = "0.2.0" }, and nothing logged before it answers.
    boot()
    eq(#W.connects, 1, "connect called once")
    local c = W.connects[1]
    ok(c.mod == "Clock" and c.need == "0.2.0", "connect{ mod = 'Clock', need = '0.2.0' }", tostring(c.mod) .. " " .. tostring(c.need))
    ok(type(c.onReady) == "function" and type(c.onFail) == "function", "connect gets onReady and onFail")
    eq(#W.printed, 0, "nothing printed during main.lua")
    -- onFail: connect has already logged its one line; the clock adds nothing (CAP-3).
    c.onFail("Nucleus 0.1.0 is not compatible; Clock needs 0.2.0 (^ rules). Update Nucleus.")
    eq(#W.printed, 0, "onFail adds no line")
    eq(#W.loops, 0, "onFail starts nothing")
end

do -- A settings problem is logged only after connect (so a missing core still gives one line).
    boot{ settings = false }
    eq(#W.printed, 0, "settings missing: nothing before connect")
    connect(newCore())
    eq(#lines("^%[Clock%] WARN settings%.lua could not be read"), 1, "settings missing: one WARN after connect")
    ok(#lines("^%[Clock%] READY updateEvery=1 element=clock%.time$") == 1, "settings missing: runs with updateEvery = 1")
end
do
    for _, bad in ipairs({ "return { updateEvery = 0 }", "return { updateEvery = 61 }", "return { updateEvery = 2.5 }", "return { updateEvery = '5' }" }) do
        boot{ settings = bad }
        connect(newCore())
        ok(#lines("WARN updateEvery must be an integer from 1 to 60") == 1 and #lines("READY updateEvery=1 ") == 1, "bad setting falls back to 1: " .. bad)
    end
    boot{ settings = "error('broken')" }
    connect(newCore())
    ok(#lines("WARN settings%.lua did not return a table") == 1, "settings.lua that throws: WARN and defaults")
    boot{ settings = "return os.exit(3)" } -- sandboxed: settings.lua sees no globals
    connect(newCore())
    ok(#lines("WARN settings%.lua did not return a table") == 1, "settings.lua runs with an empty environment")
end

do -- No UI helpers on the api: one ERROR line, no element, no loop.
    boot()
    connect(newCore{ ui = false })
    eq(#lines("^%[Clock%] ERROR Nucleus's UI helpers are not available%. Clock will not run%.$"), 1, "no core.ui: one ERROR line")
    eq(#W.loops, 0, "no core.ui: no loop")
end

do -- create fails: one ERROR line, no loop.
    boot()
    local core = newCore()
    core.ui.failCreate = true
    connect(core)
    eq(#lines("ERROR could not create the clock element"), 1, "create fails: one ERROR line")
    eq(#W.loops, 0, "create fails: no loop")
end

-- ---------------------------------------------------------------- the glue (story 3)
do
    boot()
    local core = newCore()
    local U = core.ui
    connect(core)
    -- Created once, hidden, top-right, id clock.time, then READY and one 1000 ms game-thread loop.
    eq(#U.calls >= 2 and U.calls[1][1], "create", "first ui call is create")
    local spec = U.calls[1][2]
    ok(spec.id == "clock.time" and spec.text == "" and spec.place.host == "hud" and spec.place.corner == "top-right"
        and spec.place.absolute == nil and spec.place.offset == nil, "create{ id = 'clock.time', text = '', place = { host = 'hud', corner = 'top-right' } }")
    ok(U.calls[2][1] == "setVisible" and U.calls[2][2] == false, "then setVisible(el, false)")
    eq(#U.calls, 2, "nothing else before the first tick")
    eq(#W.loops, 1, "one loop")
    eq(W.loops[1].ms, 1000, "the loop runs every 1000 ms")
    eq(W.async, 0, "never LoopAsync or ExecuteInGameThread")
    eq(#W.loadMapHooks, 1, "one LoadMap post-hook")
    eq(#lines("^%[Clock%] READY updateEvery=1 element=clock%.time$"), 1, "READY logged")

    -- No sky (loading): stays hidden, no text set.
    local i = #U.calls
    tick(3)
    eq(#callsSince(U, i, "set"), 0, "no sky: no set")
    local vis = callsSince(U, i, "setVisible")
    ok(#vis == 3 and vis[1] == false and vis[3] == false, "no sky: setVisible(false) each tick")
    eq(#lines("HIDDEN"), 0, "no sky from the start: no HIDDEN line")

    -- A sky appears at 10:07: text set first, then shown, on the same tick.
    W.sky = newSky("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap:PersistentLevel.Ultra_Dynamic_Sky_C_0", tod(10, 7))
    i = #U.calls
    tick()
    ok(U.calls[i + 1][1] == "set" and U.calls[i + 1][2] == "10:07", "first value: set('10:07') first", U.calls[i + 1] and (U.calls[i + 1][1] .. " " .. tostring(U.calls[i + 1][2])))
    ok(U.calls[i + 2][1] == "setVisible" and U.calls[i + 2][2] == true, "first value: then setVisible(true)")
    eq(#lines("^%[Clock%] VISIBLE 10:07 %(updateEvery=1%)$"), 1, "VISIBLE line")

    -- Same minute: no set, setVisible(true) again (core makes that a no-op).
    i = #U.calls
    tick(2)
    eq(#callsSince(U, i, "set"), 0, "same minute: no set")
    eq(#callsSince(U, i, "setVisible"), 2, "same minute: setVisible(true) each tick")

    -- The next minute: one set.
    W.sky["Time of Day"] = tod(10, 8)
    i = #U.calls
    tick()
    local sets = callsSince(U, i, "set")
    ok(#sets == 1 and sets[1] == "10:08", "next minute: set('10:08')", sets[1])
    eq(#lines("VISIBLE"), 1, "no second VISIBLE line while shown")

    -- The sky goes away (back to loading): hidden, one HIDDEN line, last reset.
    W.sky.alive = false; W.sky = nil
    i = #U.calls
    tick()
    local v = callsSince(U, i, "setVisible")
    ok(#v == 1 and v[1] == false, "sky gone: setVisible(false)")
    eq(#lines("^%[Clock%] HIDDEN no sky$"), 1, "sky gone: one HIDDEN line")
    tick(2)
    eq(#lines("HIDDEN"), 1, "still gone: no more HIDDEN lines")
    eq(#lines("WARN"), 0, "no sky is normal: no WARN")

    -- A new match at the same minute as before: shown immediately (last was reset), text set before showing.
    W.sky = newSky("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap:PersistentLevel.Ultra_Dynamic_Sky_C_1", tod(10, 8))
    i = #U.calls
    tick()
    ok(U.calls[i + 1][1] == "set" and U.calls[i + 1][2] == "10:08" and U.calls[i + 2][1] == "setVisible" and U.calls[i + 2][2] == true,
        "new match: set then show at once, even at the same boundary")

    -- A map change runs the LoadMap hook: the sky path is forgotten, so the next read scans again.
    local f0 = W.finds
    i = #U.calls
    W.loadMapHooks[1]()
    ok(#U.calls == i + 1 and U.calls[i + 1][1] == "setVisible" and U.calls[i + 1][2] == false, "LoadMap: hides at once")
    tick()
    eq(W.finds, f0 + 1, "after LoadMap: one FindFirstOf")
    ok(U.calls[i + 2][1] == "set" and U.calls[i + 3][1] == "setVisible" and U.calls[i + 3][2] == true,
        "after LoadMap: the next tick sets the time, then shows it (no stale flash)")
    tick()
    eq(W.finds, f0 + 1, "then by path again")

    -- A read error (the conversion function gone after a patch): hidden, one WARN, however many ticks.
    W.sky["Time Of Day to H/M/S"] = nil
    i = #U.calls
    tick(5)
    v = callsSince(U, i, "setVisible")
    ok(#v == 5 and v[1] == false, "read error: hidden")
    eq(#lines("WARN time unreadable %('Time Of Day to H/M/S' is missing"), 1, "read error: logged once")
    eq(#callsSince(U, i, "set"), 0, "read error: never a wrong time")
    -- It reads again: shown again.
    W.sky["Time Of Day to H/M/S"] = function(self, t, oh, om) oh.Hour = 11; om.Minute = 0 end
    i = #U.calls
    tick()
    sets = callsSince(U, i, "set")
    ok(#sets == 1 and sets[1] == "11:00", "recovers: shows the time again", sets[1])

    -- A tick that throws inside core (set raising): caught, one WARN, hidden, no error escapes the loop.
    U.failSet = true
    W.sky["Time Of Day to H/M/S"] = function(self, t, oh, om) oh.Hour = 11; om.Minute = 1 end
    local okT = pcall(tick, 3)
    ok(okT, "a throwing tick never escapes the loop callback")
    eq(#lines("WARN tick failed: "), 1, "a throwing tick: one WARN")
    eq(U.calls[#U.calls][1] == "setVisible" and U.calls[#U.calls][2], false, "a throwing tick: hidden")
    U.failSet = false
    tick()
    eq(U.els[next(U.els)].text, "11:01", "after the throw: shows again")
end

do -- updateEvery = 5: multiples of 5, changes only at multiples.
    boot{ settings = "return { updateEvery = 5 }" }
    local core = newCore()
    local U = core.ui
    connect(core)
    eq(#lines("READY updateEvery=5 "), 1, "READY with updateEvery=5")
    W.sky = newSky("/Game/Maps/X.X:PersistentLevel.Ultra_Dynamic_Sky_C_0", tod(10, 7))
    local shown = {}
    local i = #U.calls
    for m = 7, 31 do W.sky["Time of Day"] = tod(10, m); tick() end
    for _, t in ipairs(callsSince(U, i, "set")) do shown[#shown + 1] = t end
    eq(table.concat(shown, " "), "10:05 10:10 10:15 10:20 10:25 10:30", "n=5: shows 10:05, then each multiple of 5 once")
end

do -- Debug lines: SHOW per change and a TICK cost line every 60 ticks, only with debug = true.
    boot{ settings = "return { updateEvery = 1, debug = true }" }
    local core = newCore()
    connect(core)
    W.sky = newSky("/Game/Maps/X.X:PersistentLevel.Ultra_Dynamic_Sky_C_0", tod(9, 5))
    tick(60)
    eq(#lines("^%[Clock%] DEBUG SHOW 09:05$"), 1, "debug: one SHOW line per shown value")
    local cost = lines("^%[Clock%] DEBUG TICK n=60 avg [%d%.]+ max %d+ us$")
    eq(#cost, 1, "debug: one TICK cost line per 60 ticks")
    boot()
    connect(newCore())
    W.sky = newSky("/Game/Maps/X.X:PersistentLevel.Ultra_Dynamic_Sky_C_0", tod(9, 5))
    tick(60)
    eq(#lines("DEBUG"), 0, "no debug lines by default")
    boot{ settings = "return { updateEvery = 1, debug = true }" }
    connect(newCore{ clock = false })
    W.sky = newSky("/Game/Maps/X.X:PersistentLevel.Ultra_Dynamic_Sky_C_0", tod(9, 5))
    ok(pcall(tick, 60), "no core.clock: ticks still run")
    eq(#lines("DEBUG TICK"), 0, "no core.clock: no cost line")
end

do -- The clock never keeps a UObject: after ticks, its upvalues hold no sky.
    boot()
    local core = newCore()
    connect(core)
    W.sky = newSky("/Game/Maps/X.X:PersistentLevel.Ultra_Dynamic_Sky_C_0", tod(12, 0))
    tick(2)
    local held = false
    local fn = W.loops[1].fn
    local seen = {}
    local function scan(f, depth)
        if depth > 4 or seen[f] then return end
        seen[f] = true
        for k = 1, 64 do
            local name, val = debug.getupvalue(f, k)
            if not name then break end
            if val == W.sky then held = true end
            if type(val) == "function" then scan(val, depth + 1) end
            if type(val) == "table" and val ~= W and val ~= core and val ~= core.ui then
                for _, x in pairs(val) do if x == W.sky then held = true end end
            end
        end
    end
    scan(fn, 0)
    ok(not held, "no upvalue holds the sky object")
end

loadfile = realLoadfile
io.stdout:write(("main_test: %d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)

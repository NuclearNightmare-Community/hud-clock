-- Unit tests for Scripts/main.lua outside the game: the bootstrap, settings, and the glue between time.lua and core's
-- UI helpers (clock stories 1 and 3), against a fake core (client.connect, core.ui.text, core.settings, core.log,
-- core.clock), a fake sky and stubbed UE4SS globals. The in-game proof is run.ps1 (story 4).
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
local realLoadfile, realOpen = loadfile, io.open

local function newSky(path, tod)
    local s = { path = path, alive = true }
    s["Time of Day"] = tod
    function s:IsValid() return self.alive end
    function s:GetFullName() return "Ultra_Dynamic_Sky_C " .. self.path end
    s["Time Of Day to H/M/S"] = function(self, t, oh, om)
        local x = (t % 2400) / 100
        oh.Hour = math.floor(x)
        om.Minute = math.floor((x - math.floor(x)) * 60)
    end
    W.objects[path] = s
    return s
end
local function tod(h, m) return h * 100 + (m + 0.5) * 100 / 60 end -- mid-minute, as a live sky almost always is

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

-- Loads main.lua fresh. opts: client = false (core not installed) | nil; dev = text of Scripts/dev.lua (nil: none).
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
    loadfile = function(path, ...)
        W.loadfiles = (W.loadfiles or 0) + (path:match("[/\\]dev%.lua$") and 1 or 0)
        return realLoadfile(path, ...)
    end
    io.open = function(path, mode)
        if path:match("[/\\]dev%.lua$") then
            if not opts.dev then return nil, "cannot open " .. path end
            local text = opts.dev
            return { read = function() local t = text; text = nil; return t end, close = function() end }
        end
        return realOpen(path, mode)
    end
    local chunk = assert(realLoadfile(MAIN))
    chunk()
    loadfile = realLoadfile
    io.open = realOpen
end

local function connect(core)
    local c = W.connects[1]
    c.onReady(core)
end
-- o.every: what core.settings.get("updateEvery") returns (default 1); o.getErr: get raises it; o.settings = false: no
-- core.settings at all.
local function newCore(o)
    o = o or {}
    local now = 0
    local core = { name = "Nucleus", version = "0.9.0", log = newLog("Clock") }
    if o.ui ~= false then core.ui = newUi() end
    if o.settings ~= false then
        W.watchers = {}
        core.settings = {
            get = function(k)
                W.gets = (W.gets or 0) + 1
                if o.getErr then error(o.getErr, 0) end
                assert(k == "updateEvery", "unexpected key " .. tostring(k))
                if o.every == nil then return 1 end
                return o.every
            end,
            watch = function(fn) W.watchers[#W.watchers + 1] = fn return #W.watchers end,
        }
    end
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

do -- Core installed: connect{ mod = "Clock", need = ">=0.9.0" }, and nothing logged before it answers.
    boot()
    eq(#W.connects, 1, "connect called once")
    local c = W.connects[1]
    ok(c.mod == "Clock" and c.need == ">=0.9.0", "connect{ mod = 'Clock', need = '>=0.9.0' } (core.settings)", tostring(c.mod) .. " " .. tostring(c.need))
    ok(type(c.onReady) == "function" and type(c.onFail) == "function", "connect gets onReady and onFail")
    eq(#W.printed, 0, "nothing printed during main.lua")
    -- onFail: connect has already logged its one line; the clock adds nothing (CAP-3).
    c.onFail("Nucleus 0.1.0 is older than Clock needs (>=0.9.0). Update Nucleus.")
    eq(#W.printed, 0, "onFail adds no line")
    eq(#W.loops, 0, "onFail starts nothing")
end

do -- updateEvery from core.settings, read in onReady; a problem is one WARN after connect and N = 1.
    boot()
    eq(#W.printed, 0, "nothing before connect")
    connect(newCore{ every = 7 })
    eq(W.gets, 1, "core.settings.get('updateEvery') once in onReady")
    eq(#lines("^%[Clock%] READY updateEvery=7 element=clock%.time$"), 1, "READY shows the stored value")
    eq(#lines("WARN"), 0, "no WARN")
    eq(#W.watchers, 1, "one settings watcher")
    boot()
    connect(newCore{ getErr = "nucleus.settings.get: call-failed channel class not loaded" })
    eq(#lines("^%[Clock%] WARN updateEvery could not be read from Nucleus's settings %(nucleus%.settings%.get: call%-failed"), 1, "get raises: one WARN")
    ok(#lines("^%[Clock%] READY updateEvery=1 element=clock%.time$") == 1, "get raises: runs with updateEvery = 1")
    boot()
    connect(newCore{ settings = false })
    ok(#lines("WARN updateEvery could not be read") == 1 and #lines("WARN could not watch Nucleus's settings") == 1 and #lines("READY updateEvery=1 ") == 1,
        "no core.settings: WARNs, N = 1, still runs")
    for _, bad in ipairs({ 0, 61, 2.5, "5", false }) do
        boot()
        connect(newCore{ every = bad })
        ok(#lines("WARN updateEvery could not be read from Nucleus's settings %(got " .. tostring(bad):gsub("%.", "%%.") .. "%); using 1") == 1
            and #lines("READY updateEvery=1 ") == 1, "a bad stored value falls back to 1: " .. tostring(bad))
    end
end

do -- dev.lua: read as text, never run
    boot{ dev = "return { debug = true }" }
    eq(W.loadfiles or 0, 0, "dev.lua is never loaded as code")
    boot{ dev = "os.exit(3) -- profile = true" }
    eq(W.loadfiles or 0, 0, "dev.lua with code in it: still only text")
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
    -- Created once, hidden, top-right, id clock.time, then READY and one 250 ms game-thread loop.
    eq(#U.calls >= 2 and U.calls[1][1], "create", "first ui call is create")
    local spec = U.calls[1][2]
    ok(spec.id == "clock.time" and spec.text == "" and spec.place.host == "hud" and spec.place.corner == "top-right"
        and spec.place.absolute == nil and spec.place.offset == nil, "create{ id = 'clock.time', text = '', place = { host = 'hud', corner = 'top-right' } }")
    ok(U.calls[2][1] == "setVisible" and U.calls[2][2] == false, "then setVisible(el, false)")
    eq(#U.calls, 2, "nothing else before the first tick")
    eq(#W.loops, 1, "one loop")
    eq(W.loops[1].ms, 250, "the loop runs every 250 ms (clock story 5)")
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
    eq(#callsSince(U, i, "setVisible"), 0, "same minute: no repeated setVisible(true)")

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

    -- The conversion is checked against the sky's function once per sky: one VERIFY line per match.
    eq(#lines("^%[Clock%] VERIFY "), 3, "one VERIFY line per sky and per map change (two skies, one LoadMap)")

    -- A read error (Time of Day gone after a patch): hidden, one WARN, however many ticks.
    W.sky["Time of Day"] = nil
    i = #U.calls
    tick(5)
    v = callsSince(U, i, "setVisible")
    ok(#v == 5 and v[1] == false, "read error: hidden")
    eq(#lines("WARN time unreadable %('Time of Day' is not a number"), 1, "read error: logged once")
    eq(#callsSince(U, i, "set"), 0, "read error: never a wrong time")
    -- It reads again: shown again.
    W.sky["Time of Day"] = tod(11, 0)
    i = #U.calls
    tick()
    sets = callsSince(U, i, "set")
    ok(#sets == 1 and sets[1] == "11:00", "recovers: shows the time again", sets[1])

    -- The sky's function disagrees with Lua's conversion on a new sky: one WARN, and its answer is shown.
    W.loadMapHooks[1]()
    W.sky["Time Of Day to H/M/S"] = function(self, t, oh, om) oh.Hour = 11; om.Minute = 2 end
    i = #U.calls
    tick()
    sets = callsSince(U, i, "set")
    ok(#sets == 1 and sets[1] == "11:02", "disagreement: the function's answer", sets[1])
    eq(#lines("WARN Lua's conversion of .* using the sky's function from now on"), 1, "disagreement: one WARN")
    W.sky["Time Of Day to H/M/S"] = function(self, t, oh, om) oh.Hour = 11; om.Minute = 0 end

    -- A tick that throws inside core (set raising): caught, one WARN, hidden, no error escapes the loop.
    U.failSet = true
    -- 11:03, ahead of the shown 11:02 (a step back of 1 or 2 is held back and would never reach set).
    W.sky["Time Of Day to H/M/S"] = function(self, t, oh, om) oh.Hour = 11; om.Minute = 3 end
    local okT = pcall(tick, 3)
    ok(okT, "a throwing tick never escapes the loop callback")
    eq(#lines("WARN tick failed: "), 1, "a throwing tick: one WARN")
    eq(U.calls[#U.calls][1] == "setVisible" and U.calls[#U.calls][2], false, "a throwing tick: hidden")
    U.failSet = false
    tick()
    eq(U.els[next(U.els)].text, "11:03", "after the throw: shows again")
end

do -- With core's weak handles: the sky is kept as a handle, re-found by Deref; freed and re-found on a map change.
    boot()
    local core = newCore()
    local handles, nextH, refs, derefs, freed = {}, 0, 0, 0, 0
    core.ref = function(o) refs = refs + 1; nextH = nextH + 1; handles[nextH] = o; return nextH end
    core.deref = function(h) derefs = derefs + 1; local o = handles[h]; return (o and o.alive) and o or nil end
    core.free = function(h) freed = freed + 1; handles[h] = nil end
    connect(core)
    W.sky = newSky("/Game/Maps/X.X:PersistentLevel.Ultra_Dynamic_Sky_C_0", tod(8, 0))
    local static0 = 0
    local realSFO = StaticFindObject
    StaticFindObject = function(p) static0 = static0 + 1; return realSFO(p) end
    tick(); tick(); tick()
    ok(refs == 1 and derefs == 2 and static0 == 0 and W.finds == 1, "handles: one FindFirstOf and Ref, then Deref; no StaticFindObject",
        ("refs=%d derefs=%d static=%d finds=%d"):format(refs, derefs, static0, W.finds))
    W.loadMapHooks[1]()
    ok(freed == 1, "handles: a map change frees the handle")
    W.sky.alive = false
    W.sky = newSky("/Game/Maps/Y.Y:PersistentLevel.Ultra_Dynamic_Sky_C_0", tod(9, 0))
    tick()
    ok(refs == 2 and W.finds == 2 and core.ui.els[next(core.ui.els)].text == "09:00", "handles: the new world's sky is found and shown")
    W.sky.alive = false; W.sky = nil
    tick()
    ok(freed == 2 and #lines("HIDDEN no sky") == 1, "handles: a dead sky's handle is freed and the clock hides")
    StaticFindObject = realSFO
end

do -- updateEvery = 5: multiples of 5, changes only at multiples.
    boot()
    local core = newCore{ every = 5 }
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

do -- Clock story 5: a step back of 1 or 2 shown values is held back (a client's replication snap); 3 or more shows.
    boot()
    local core = newCore()
    local U = core.ui
    connect(core)
    W.sky = newSky("/Game/Maps/X.X:PersistentLevel.Ultra_Dynamic_Sky_C_0", tod(10, 8))
    tick()
    local function setsAfter(h, m)
        W.sky["Time of Day"] = tod(h, m)
        local i = #U.calls
        tick()
        return callsSince(U, i, "set")
    end
    eq(#setsAfter(10, 7), 0, "hold-back: 10:08 -> 10:07 keeps 10:08")
    eq(#setsAfter(10, 6), 0, "hold-back: 10:08 -> 10:06 keeps 10:08")
    eq(#setsAfter(10, 8), 0, "hold-back: back at 10:08, nothing to change")
    local s = setsAfter(10, 9)
    ok(#s == 1 and s[1] == "10:09", "hold-back: then forward to 10:09 as usual", s[1])
    s = setsAfter(10, 6)
    ok(#s == 1 and s[1] == "10:06", "hold-back: 3 back (10:09 -> 10:06) shows at once", s[1])
    s = setsAfter(12, 6)
    ok(#s == 1 and s[1] == "12:06", "forward jump +120 shows at once", s[1])
    s = setsAfter(23, 59)
    ok(#s == 1 and s[1] == "23:59", "a big step (12:06 -> 23:59) shows at once", s[1])
    s = setsAfter(24, 0)
    ok(#s == 1 and s[1] == "00:00", "the midnight wrap 23:59 -> 00:00 shows at once", s[1])
    eq(#setsAfter(23, 59), 0, "hold-back across midnight: 00:00 -> 23:59 keeps 00:00")
    -- After a hide (no sky) last is cleared: the next value shows at once, even one behind.
    W.sky.alive = false; W.sky = nil
    tick()
    W.sky = newSky("/Game/Maps/X.X:PersistentLevel.Ultra_Dynamic_Sky_C_1", tod(23, 59))
    local i = #U.calls
    tick()
    s = callsSince(U, i, "set")
    ok(#s == 1 and s[1] == "23:59", "after a hide the next value shows at once, even one behind", s[1])
    -- And after a map change (LoadMap hook).
    W.loadMapHooks[1]()
    W.sky["Time of Day"] = tod(23, 58)
    i = #U.calls
    tick()
    s = callsSince(U, i, "set")
    ok(#s == 1 and s[1] == "23:58", "after LoadMap the next value shows at once, even one behind", s[1])
end

-- Fast: 3.0 Time of Day units a real second, read every 0.25 s (0.75 units a tick). Every change is +n.
for _, n in ipairs({ 1, 5 }) do
    boot()
    local core = newCore{ every = n }
    local U = core.ui
    connect(core)
    local t = tod(10, 0)
    W.sky = newSky("/Game/Maps/X.X:PersistentLevel.Ultra_Dynamic_Sky_C_0", t)
    local i = #U.calls
    for _ = 1, 400 do t = t + 0.75; W.sky["Time of Day"] = t; tick() end
    local shown = callsSince(U, i, "set")
    local bad = 0
    for k = 2, #shown do
        local a, b = shown[k - 1], shown[k]
        local ma = tonumber(a:sub(1, 2)) * 60 + tonumber(a:sub(4, 5))
        local mb = tonumber(b:sub(1, 2)) * 60 + tonumber(b:sub(4, 5))
        if (mb - ma) % 1440 ~= n then bad = bad + 1 end
    end
    ok(#shown >= 180 // n and bad == 0, "n=" .. n .. " at Fast, 250 ms reads: every change is +" .. n, ("%d changes, %d not +%d"):format(#shown, bad, n))
end

do -- A watched change applies at the next tick (changeable "anytime"): one SETTING line, the new rounding at once.
    boot()
    local core = newCore()
    local U = core.ui
    connect(core)
    W.sky = newSky("/Game/Maps/X.X:PersistentLevel.Ultra_Dynamic_Sky_C_0", tod(10, 7))
    tick()
    local i = #U.calls
    W.watchers[1]("other.key", 3)
    eq(#lines("SETTING"), 0, "another key: ignored")
    W.watchers[1]("updateEvery", 5)
    eq(#lines("^%[Clock%] SETTING updateEvery=5$"), 1, "SETTING line")
    tick()
    local sets = callsSince(U, i, "set")
    ok(#sets == 1 and sets[1] == "10:05", "next tick shows the new rounding (10:07 -> 10:05)", sets[1])
    W.watchers[1]("updateEvery", 5)
    eq(#lines("SETTING"), 1, "the same value again: nothing")
    W.watchers[1]("updateEvery", 0)
    eq(#lines("WARN updateEvery changed to 0, which isn't an integer from 1 to 60; keeping 5"), 1, "a bad value: one WARN, kept")
    W.watchers[1]("updateEvery", 1)
    i = #U.calls
    tick()
    sets = callsSince(U, i, "set")
    ok(#sets == 1 and sets[1] == "10:07", "back to 1: 10:07 at the next tick", sets[1])
    eq(#lines("VISIBLE"), 1, "no new VISIBLE line while shown")
end

do -- Debug lines: SHOW per change and a TICK cost line every 240 ticks (a minute), only with debug = true.
    boot{ dev = "return { debug = true }" }
    local core = newCore()
    connect(core)
    W.sky = newSky("/Game/Maps/X.X:PersistentLevel.Ultra_Dynamic_Sky_C_0", tod(9, 5))
    tick(240)
    eq(#lines("^%[Clock%] DEBUG SHOW 09:05$"), 1, "debug: one SHOW line per shown value")
    local cost = lines("^%[Clock%] DEBUG TICK n=240 avg [%d%.]+ max %d+ us %(read [%d%.]+, set [%d%.]+ over 1 changes, log [%d%.]+%)$")
    eq(#cost, 1, "debug: one TICK cost line per 240 ticks")
    boot()
    connect(newCore())
    W.sky = newSky("/Game/Maps/X.X:PersistentLevel.Ultra_Dynamic_Sky_C_0", tod(9, 5))
    tick(240)
    eq(#lines("DEBUG"), 0, "no debug lines by default")
    boot{ dev = "return { profile = true }" }
    connect(newCore())
    W.sky = newSky("/Game/Maps/X.X:PersistentLevel.Ultra_Dynamic_Sky_C_0", tod(9, 5))
    tick(240)
    eq(#lines("^%[Clock%] TICK n=240 avg [%d%.]+ max %d+ us %(read 0%.0, set 0%.0 over 1 changes, log 0%.0%)$"), 1, "profile: one info TICK line, whole tick only")
    eq(#lines("DEBUG"), 0, "profile: no DEBUG lines")
    boot{ dev = "return { debug = true }" }
    connect(newCore{ clock = false })
    W.sky = newSky("/Game/Maps/X.X:PersistentLevel.Ultra_Dynamic_Sky_C_0", tod(9, 5))
    ok(pcall(tick, 240), "no core.clock: ticks still run")
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
            if type(val) == "table" and val ~= W and val ~= core and val ~= core.ui and val ~= core.settings then
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

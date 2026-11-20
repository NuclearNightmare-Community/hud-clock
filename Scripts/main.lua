-- HudClock (spec-clock-v1): the in-game time as HH:MM in the HUD's top-right corner during a match.
-- Runs on Nucleus (core) through the dependent bootstrap (core's api-contract.md); uses only core's public API
-- (connect, core.ui.text, core.settings, core.log). Holds no UObject between ticks: the element handle, the last shown
-- boundary and the setting (AGENTS.md). Reads the time every 250 ms on the game thread (clock story 5: a game minute
-- lasts 0.55 real s at Fast, so a once-a-second read skipped minutes); changes the text only when the time crosses an
-- updateEvery boundary, and holds back a 1-2 boundary step back (a client's replication snap).
local CORE, NEED, ME = "Nucleus", ">=0.9.0", "HudClock"
local ELEMENT = "clock.time"
local PLACE = { host = "hud", corner = "top-right" }
local TICK_MS = 250 -- under half the shortest game minute (0.55 s at Fast): every minute is read at every speed
local COST_EVERY = 240 -- ticks per DEBUG cost line: one a minute

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local scriptDir = source:match("^(.*)[/\\]") or "."

-- ---------------------------------------------------------------- the dependent bootstrap (core's api-contract.md)
local mods = source:match("^(.*)[/\\][^/\\]+[/\\][Ss]cripts[/\\]") or "."
package.path = scriptDir .. "/?.lua;" .. package.path .. ";" .. mods .. "/" .. CORE .. "/Scripts/?.lua"
local ok, client = pcall(require, CORE:lower() .. ".client")
if not ok then print(("[%s] %s is not installed. %s will not run.\n"):format(ME, CORE, ME)) return end

local time = require("time")

-- ---------------------------------------------------------------- settings
-- updateEvery comes from Nucleus's settings service (core.settings, Nucleus 0.9.0): declared in mod.json, its value
-- kept by Nucleus in Mods/HudClock/settings.json (written by deploy.ps1 -UpdateEvery, later by the Mod Manager), read in
-- onReady and watched, so a change shows at the next tick (changeable "anytime").
local UPDATE_DEFAULT = 1
local function validEvery(n) return math.type(n) == "integer" and n >= 1 and n <= 60 end
-- Test-only flags from Scripts/dev.lua, which only deploy.ps1 -Test writes (git-ignored, never shipped). Read as text,
-- never run: "debug = true" turns on the DEBUG lines (SHOW per value, TICK cost), "profile = true" only the TICK cost
-- lines at info level (deploy.ps1 -Test -Scenario cost).
local function devFlags()
    local d = { debug = false, profile = false }
    local f = io.open(scriptDir .. "/dev.lua", "r")
    if not f then return d end
    local okR, text = pcall(f.read, f, 4096)
    pcall(f.close, f)
    text = okR and type(text) == "string" and text or ""
    d.debug = text:find("debug%s*=%s*true") ~= nil
    d.profile = text:find("profile%s*=%s*true") ~= nil
    return d
end
local settings = devFlags()

-- ---------------------------------------------------------------- the clock (clock story 3)
local function start(core)
    local log = core.log
    log.debugEnabled = settings.debug
    local ui = type(core.ui) == "table" and core.ui.text or nil
    if type(ui) ~= "table" then
        log.error("%s's UI helpers are not available. %s will not run.", CORE, ME)
        return
    end
    local cs = type(core.settings) == "table" and core.settings or nil
    local n = UPDATE_DEFAULT
    do
        local okS, v = pcall(function() return cs.get("updateEvery") end)
        if okS and validEvery(v) then n = v
        else log.warn("updateEvery could not be read from %s's settings (%s); using %d", CORE, okS and ("got " .. tostring(v)) or tostring(v), UPDATE_DEFAULT) end
    end
    if core.ref and core.deref and core.free then time.useHandles(core.ref, core.deref, core.free) end

    local okC, el = pcall(ui.create, { id = ELEMENT, text = "", place = PLACE })
    if not okC then log.error("could not create the clock element: %s. %s will not run.", tostring(el), ME) return end
    ui.setVisible(el, false) -- hidden until there's a time to show

    local last         -- the slot (time.slot) last shown; nil after a hide, so the next value shows at once
    local visible = false
    local warned, nWarned = {}, 0 -- reasons already logged: each read error once, at most 8 different ones
    local cost = { n = 0, sum = 0, max = 0, read = 0, set = 0, sets = 0, log = 0 } -- DEBUG timing, per COST_EVERY ticks
    local micros = type(core.clock) == "table" and core.clock.micros or nil

    local function hide(reason)
        ui.setVisible(el, false)
        last = nil -- so the next match shows its time immediately
        if visible then log.info("HIDDEN %s", reason) end
        visible = false
        if reason ~= "no sky" and not warned[reason] and nWarned < 8 then
            warned[reason], nWarned = true, nWarned + 1
            log.warn("time unreadable (%s); the clock is hidden until it reads again", reason)
        end
    end

    -- Timings only when they're logged: the whole tick with debug or profile, the split (read/set/log, four more
    -- clock reads a tick) only with debug, so profile measures the tick about as a normal install runs it.
    local total = micros and (settings.debug or settings.profile)
    local timing = micros and settings.debug
    local function tick()
        local t0 = timing and micros()
        local h, m = time.read()
        if timing then cost.read = cost.read + (micros() - t0) end
        local note, level = time.takeNote()
        if note then log[level == "warn" and "warn" or "info"]("%s", note) end
        if not h then hide(m) return end
        local b, perDay = time.slot(h, m, n)
        -- A new slot shows, except one or two behind the shown one: on a client the sky's once-a-second replication
        -- snap can step the time back briefly (time.shouldShow).
        if time.shouldShow(last, b, perDay) then
            local text = time.format(h, m, n)
            local t1 = timing and micros()
            ui.set(el, text)
            if timing then cost.set = cost.set + (micros() - t1) end
            cost.sets = cost.sets + 1
            last = b
            local t2 = timing and micros()
            log.debug("SHOW %s", text)
            if timing then cost.log = cost.log + (micros() - t2) end
            if not visible then log.info("VISIBLE %s (updateEvery=%d)", text, n) end
        end
        -- Shown once per appearance: core makes a repeated setVisible a no-op, but even a no-op call costs a few
        -- tens of microseconds a tick (its game-thread check and lookup), so it isn't repeated.
        if not visible then ui.setVisible(el, true) end
        visible = true
    end

    local function timedTick()
        local t0 = total and micros()
        local okT, err = pcall(tick)
        if not okT then
            if not warned.tick then warned.tick = true; log.warn("tick failed: %s", tostring(err)) end
            pcall(ui.setVisible, el, false)
            last, visible = nil, false
        end
        if t0 then
            local dt = micros() - t0
            cost.n, cost.sum = cost.n + 1, cost.sum + dt
            if dt > cost.max then cost.max = dt end
            if cost.n >= COST_EVERY then
                -- avg/max cover the whole tick; read is time.read, set is core's ui.text.set (n of them changed the
                -- text), log is the DEBUG SHOW line itself (0 without debug), all averaged over the ticks.
                log[settings.profile and "info" or "debug"]("TICK n=%d avg %.1f max %d us (read %.1f, set %.1f over %d changes, log %.1f)", cost.n, cost.sum / cost.n,
                    cost.max, cost.read / cost.n, cost.set / cost.n, cost.sets, cost.log / cost.n)
                cost.n, cost.sum, cost.max, cost.read, cost.set, cost.sets, cost.log = 0, 0, 0, 0, 0, 0, 0
            end
        end
    end

    -- A map change: the remembered sky path belongs to the old world, and the shown time to the old match (the main
    -- menu has a sky too, so a travel need not pass through "no sky"). Hide now; the next tick sets the new world's
    -- time before showing it, so the old time never flashes on the new HUD.
    pcall(RegisterLoadMapPostHook, function()
        pcall(time.forget)
        pcall(ui.setVisible, el, false)
        last, visible = nil, false
    end)

    -- A changed updateEvery (the Mod Manager, or anyone through core.settings) applies at the next tick: last is
    -- forgotten, so the next tick sets the text with the new rounding.
    local okW, errW = pcall(function()
        return cs.watch(function(key, value)
            if key ~= "updateEvery" then return end
            if not validEvery(value) then log.warn("updateEvery changed to %s, which isn't an integer from 1 to 60; keeping %d", tostring(value), n) return end
            if value == n then return end
            n, last = value, nil
            log.info("SETTING updateEvery=%d", n)
        end)
    end)
    if not okW then log.warn("could not watch %s's settings (%s); a changed updateEvery applies after a restart", CORE, tostring(errW)) end

    -- A game-thread loop registered from the game thread (onReady runs there). Never LoopAsync + ExecuteInGameThread:
    -- in the pinned UE4SS those can lose their callback (core's ui/hud.lua).
    local okL, res = pcall(LoopInGameThreadWithDelay, TICK_MS, timedTick)
    if not okL then log.error("could not start the clock's loop: %s. %s will not run.", tostring(res), ME) return end
    log.info("READY updateEvery=%d element=%s", n, ELEMENT)
end

client.connect{
    mod = ME, need = NEED,
    onReady = function(core)
        local okR, err = pcall(start, core)
        if not okR then print(("[%s] ERROR start failed: %s\n"):format(ME, tostring(err))) end
    end,
    -- connect has already logged the one line naming the cause (CAP-3: exactly one [HudClock] line). Nothing to add.
    onFail = function() end,
}

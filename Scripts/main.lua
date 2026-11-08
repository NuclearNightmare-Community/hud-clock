-- Clock (spec-clock-v1): the in-game time as HH:MM in the HUD's top-right corner during a match.
-- Runs on Nucleus (core) through the dependent bootstrap (core's api-contract.md); uses only core's public API
-- (connect, core.ui.text, core.log). Holds no UObject between ticks: the element handle, the last shown boundary and
-- the setting (AGENTS.md). Reads the time once a second on the game thread; changes the text only when the time
-- crosses an updateEvery boundary.
local CORE, NEED, ME = "Nucleus", ">=0.2.0", "Clock"
local ELEMENT = "clock.time"
local PLACE = { host = "hud", corner = "top-right" }
local TICK_MS = 1000
local COST_EVERY = 60 -- ticks per DEBUG cost line

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local scriptDir = source:match("^(.*)[/\\]") or "."

-- ---------------------------------------------------------------- the dependent bootstrap (core's api-contract.md)
local mods = source:match("^(.*)[/\\][^/\\]+[/\\][Ss]cripts[/\\]") or "."
package.path = scriptDir .. "/?.lua;" .. package.path .. ";" .. mods .. "/" .. CORE .. "/Scripts/?.lua"
local ok, client = pcall(require, CORE:lower() .. ".client")
if not ok then print(("[%s] %s is not installed. %s will not run.\n"):format(ME, CORE, ME)) return end

local time = require("time")

-- ---------------------------------------------------------------- settings
-- deploy.ps1 generates Scripts/settings.lua from mod.json's defaults (clock story 1, decision 1). Problems are only
-- remembered here and logged once connected, so a missing core still leaves exactly one [Clock] line.
local SETTINGS_DEFAULT = { updateEvery = 1 }
local function loadSettings()
    local s = { updateEvery = SETTINGS_DEFAULT.updateEvery, debug = false, profile = false }
    local chunk, err = loadfile(scriptDir .. "/settings.lua", "t", {})
    if not chunk then return s, "settings.lua could not be read (" .. tostring(err) .. "); run deploy.ps1. Using updateEvery = 1" end
    local okS, t = pcall(chunk)
    if not okS or type(t) ~= "table" then return s, "settings.lua did not return a table (" .. tostring(t) .. "); using updateEvery = 1" end
    local problem
    local n = t.updateEvery
    if math.type(n) == "integer" and n >= 1 and n <= 60 then s.updateEvery = n
    elseif n ~= nil then problem = "updateEvery must be an integer from 1 to 60, got " .. tostring(n) .. "; using 1" end
    s.debug = t.debug == true     -- DEBUG lines (SHOW per value, TICK cost): deploy.ps1 -Test
    s.profile = t.profile == true -- only the TICK cost lines, at info level: deploy.ps1 -Test -Scenario cost
    return s, problem
end
local settings, settingsProblem = loadSettings()

-- ---------------------------------------------------------------- the clock (clock story 3)
local function start(core)
    local log = core.log
    log.debugEnabled = settings.debug
    if settingsProblem then log.warn("%s", settingsProblem) end
    local ui = type(core.ui) == "table" and core.ui.text or nil
    if type(ui) ~= "table" then
        log.error("%s's UI helpers are not available. %s will not run.", CORE, ME)
        return
    end
    local n = settings.updateEvery
    if core.ref and core.deref and core.free then time.useHandles(core.ref, core.deref, core.free) end

    local okC, el = pcall(ui.create, { id = ELEMENT, text = "", place = PLACE })
    if not okC then log.error("could not create the clock element: %s. %s will not run.", tostring(el), ME) return end
    ui.setVisible(el, false) -- hidden until there's a time to show

    local last         -- the boundary last shown; nil after a hide, so the next value shows at once
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
        local b = time.boundary(h, m, n)
        if b ~= last then
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
    -- connect has already logged the one line naming the cause (CAP-3: exactly one [Clock] line). Nothing to add.
    onFail = function() end,
}

-- ClockDriver: the clock's test driver (clock story 4). Installed only by deploy.ps1 -Test, never shipped; the clock
-- itself carries no test code. Plain UE4SS Lua: it doesn't connect to core (no-core runs without it), and it can't
-- reach the clock's Lua state, so it judges the clock by what is on the HUD: the clock's widget, found in the live
-- InventoryUI_C canvas by core's tag (ToolTipText "<core>:Clock:clock.time"), its text, its visibility and the HUD's.
--
-- mods.txt order (deploy.ps1): <Core>, ClockDriver, Clock. The driver's main.lua runs before the clock's, which
-- old-core needs.
--
-- Scenarios (Scripts/scenario.txt, written by deploy.ps1):
--   match:    menu -> SmallMap?listen -> touchdown -> clock drawn top-right, HH:MM, matching the sky; time forced
--             forward on the host (the sky's Time of Day) -> the text follows; menu -> not drawn; match 2 -> again.
--   step5:    (deploy -UpdateEvery 5) in a match, time frozen and set to chosen minutes: the clock shows each
--             minute rounded down to 5 and changes only at multiples of 5.
--   rebuild:  in a match, RemoveAllWidgets and re-add the HUD: the clock is drawn again, one widget.
--   no-core:  (run.ps1 moves core aside) in a match: no clock widget; the [Clock] line is judged by check.ps1.
--   old-core: (run.ps1 sets core's installed mod.json to 0.1.0) publishes that version as <core>.version before the
--             clock connects, as an old core would; in a match: no clock widget.
--   measure:  story 2 part A, as host: Time of Day once a second for 2 min at each Time Speed (1.5, 1.0, 0.5),
--             UDS's minute event (Check for Time Event Dispatchers / Event Minute), the map's text against the sky's
--             H/M/S, the wrap at 2400, and which skies FindAllOf sees after each travel.
--   speed:    story 5, as host: Time of Day and the shown text every 50 ms for 30 s at Fast, then Normal; one
--             SPEEDSUM line per speed counts the text's changes by step size (check.ps1 judges them).
--   pair-client: story 5, B in a pair run (test/pair/clock-scenarios.ps1): never travels or presses keys; once in the
--             host's match it samples the clock's text and its own (replicated) sky every 50 ms for 120 s and logs
--             one PAIRSUM line: the text's steps (none may go back) and how often the sky stepped back.
-- Keys it can't press itself (Enter for touchdown) go to run.ps1 through request.txt / done.txt next to this file.
-- Never keeps a UObject across steps: only paths, re-found with StaticFindObject.
local CORE = "Nucleus"   -- core's name: the one place the driver spells it
local CLOCK = "Clock"    -- the clock's connect name (its log tag and its tag's mod part)
local ELEMENT = "clock.time"
local scriptDir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]")
local ME = "ClockDriver"

local function say(fmt, ...) print("[" .. ME .. "] " .. string.format(fmt, ...) .. "\n") end

local SCENARIO = "match"
do
    local f = io.open(scriptDir .. "\\scenario.txt", "r")
    if f then SCENARIO = (f:read("*a") or ""):match("^%s*([%w%-]+)") or SCENARIO; f:close() end
end
say("SCENARIO %s", SCENARIO)

-- old-core: an old core publishes its own version. The installed core's mod.json says what version to pretend.
if SCENARIO == "old-core" then
    local modsDir = scriptDir:match("^(.*)[/\\][^/\\]+[/\\][Ss]cripts$")
    local f = io.open(modsDir .. "\\" .. CORE .. "\\mod.json", "r")
    local claimed = f and (f:read("*a") or ""):match('"version"%s*:%s*"([^"]+)"')
    if f then f:close() end
    if claimed then
        ModRef:SetSharedVariable(CORE:lower() .. ".version", claimed)
        say("OLDCORE published %s.version=%s (from %s's installed mod.json)", CORE:lower(), claimed, CORE)
    else
        say("FAIL OLDCORE could not read the version from %s's installed mod.json", CORE)
    end
end

local REQ, DONE = scriptDir .. "\\request.txt", scriptDir .. "\\done.txt"
os.remove(REQ); os.remove(DONE)

local MENU_MAP = "/Game/Maps/NewMainMenu"
local MATCH_MAP = "/Game/Maps/SmallLoweIsland/SmallMap"
local TEXT_SHORT = "WBP_" .. CORE .. "Text_C"
local TAG = CORE:lower() .. ":" .. CLOCK .. ":" .. ELEMENT
local GAP = 16 -- core's "normal" gap: the clock's corner inset in canvas units
local TO_HMS = "Time Of Day to H/M/S"

local S = { failures = 0, checks = 0 }

local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
local function found(path) local o = path and StaticFindObject(path) return valid(o) and o or nil end
local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end
local function check(cond, fmt, ...)
    S.checks = S.checks + 1
    if not cond then S.failures = S.failures + 1 end
    say("%s " .. fmt, cond and "OK" or "FAIL", ...)
    return cond
end
local function pc() return FindFirstOf("PlayerController") end
local function worldName() local p = pc() return valid(p) and p:GetWorld():GetFullName() or "" end
local function GS() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end
local function WLL() return StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end

local function liveHud()
    for _, w in ipairs(FindAllOf("InventoryUI_C") or {}) do
        if valid(w) and w:IsInViewport() then return w end
    end
    return nil
end

-- ---------------------------------------------------------------- the sky (host side; test only)
local function sky()
    local s = FindFirstOf("Ultra_Dynamic_Sky_C")
    return valid(s) and s or nil
end
local function outNumber(t) for _, v in pairs(t) do if type(v) == "number" then return v end end end
-- hour, minute, second of the live sky, through its own conversion; nil when there's none.
local function skyHms(s)
    s = s or sky()
    if not s then return nil end
    local tod = s["Time of Day"]
    local oh, om, os_, of = {}, {}, {}, {}
    s[TO_HMS](s, tod, oh, om, os_, of)
    return outNumber(oh), outNumber(om), outNumber(os_), tod
end
local function hhmm(h, m, n)
    n = n or 1
    local t = (math.floor(h) * 60 + math.floor(m)) % 1440
    local hh, mm = t // 60, t % 60
    mm = mm - mm % n
    return string.format("%02d:%02d", hh, mm)
end
-- The clock reads every 250 ms (story 5) and a game minute lasts 0.55 to 1.67 real s (Day Length 10 + Night Length
-- 10 min at Time Speed 1.5 to 0.5; measure scenario), so the text may trail the sky by up to LAG game minutes.
local LAG = 1
-- lead: on a client the clock may also be up to 2 minutes ahead of its sky for a moment (it holds back the sky's
-- replication snap; clock story 5), so a client check passes lead = 2.
local function lagging(text, h, m, n, lead)
    if not (text and h) then return false end
    for d = -(lead or 0), LAG do if text == hhmm(h, m - d, n) then return true end end
    return false
end
-- Time of Day for hour:minute, a fifth of the way into the minute (so a frozen sky never sits on a boundary).
local function todOf(h, m) return h * 100 + (m + 0.2) * 100 / 60 end

-- ---------------------------------------------------------------- the clock as drawn
-- The clock's widgets in the live HUD's canvas (by tag), the first one, and the HUD.
local function clockWidgets()
    local hud = liveHud()
    if not hud then return nil, 0, nil end
    local okC, canvas = pcall(function() return hud.OwningCanvas end)
    if not okC or not valid(canvas) then return nil, 0, hud end
    local first, n = nil, 0
    for i = 0, canvas:GetChildrenCount() - 1 do
        local c = canvas:GetChildAt(i)
        if valid(c) and c:GetClass():GetFName():ToString() == TEXT_SHORT then
            local ok, t = pcall(function() return c.ToolTipText:ToString() end)
            if ok and t == TAG then n = n + 1; first = first or c end
        end
    end
    return first, n, hud
end
local function textOf(w) local ok, t = pcall(function() return w.Text:GetText():ToString() end) return ok and t or nil end
local function hiddenVis(v) return v == 1 or v == 2 end -- ESlateVisibility Collapsed, Hidden

-- One snapshot: { widgets, text, collapsed, hudVisible, drawn }.
local function state()
    local w, n, hud = clockWidgets()
    local st = { widgets = n, hud = hud ~= nil }
    if hud then st.hudVisible = not hiddenVis(tonumber(hud:GetVisibility())) end
    if w then
        st.text = textOf(w)
        st.collapsed = hiddenVis(tonumber(w:GetVisibility()))
        st.path = pathOf(w)
    end
    st.drawn = n >= 1 and st.collapsed == false and st.hudVisible == true
    return st, w, hud
end
local function stateText(st)
    return string.format("widgets=%d text=%s collapsed=%s hudVisible=%s drawn=%s", st.widgets, tostring(st.text),
        tostring(st.collapsed), tostring(st.hudVisible), tostring(st.drawn))
end

-- The widget sits in the canvas's top-right corner, GAP from both edges, inside the canvas.
local function checkCorner(phase, w, hud)
    pcall(function() w:ForceLayoutPrepass() end)
    local slot = w.Slot
    local an, al, pos = slot:GetAnchors(), slot:GetAlignment(), slot:GetPosition()
    local ds = w:GetDesiredSize()
    local world = hud:GetWorld()
    local vp, scale = WLL():GetViewportSize(world), WLL():GetViewportScale(world)
    local cw, ch = vp.X / scale, vp.Y / scale
    local left = an.Minimum.X * cw + pos.X - al.X * ds.X
    local top = an.Minimum.Y * ch + pos.Y - al.Y * ds.Y
    local right, bottom = left + ds.X, top + ds.Y
    local near = function(a, b) return math.abs(a - b) <= 0.5 end
    local inside = left >= 0 and top >= 0 and right <= cw and bottom <= ch and ds.X > 0 and ds.Y > 0
    check(near(cw - right, GAP) and near(top, GAP) and inside and left > cw / 2 and bottom < ch / 2,
        "CORNER %s clock in the top-right corner: rect=(%.0f,%.0f)-(%.0f,%.0f) gapRight=%.1f gapTop=%.1f canvas=(%.0fx%.0f) inside=%s",
        phase, left, top, right, bottom, cw - right, top, cw, ch, tostring(inside))
end

-- ---------------------------------------------------------------- steps and key requests
local seq = 0
local function request(cmd)
    seq = seq + 1
    local f = io.open(REQ, "w"); f:write(seq .. " " .. cmd); f:close()
    local mine = seq
    return function()
        local d = io.open(DONE, "r")
        if not d then return false end
        local s = d:read("*a"); d:close()
        return tonumber(s) == mine
    end
end
local function after(sec) local t = os.clock() + sec return function() return os.clock() >= t end end

local steps = {}
local function step(name, fn) steps[#steps + 1] = { name = name, fn = fn } end

local function waitWorld(phase, mapPart, timeout)
    step(phase .. ": world", function()
        return function()
            if worldName():find(mapPart, 1, true) then say("WORLD %s %s", phase, worldName():match("/Game/[^ ]+") or "?") return true end
            return false
        end, timeout, phase .. " world " .. mapPart
    end)
end
local function waitHud(phase, timeout)
    step(phase .. ": hud", function()
        local since
        return function()
            local hud = liveHud()
            if hud then
                since = since or os.clock()
                if os.clock() - since >= 3 then S.hudPath = pathOf(hud) say("HUD %s %s", phase, S.hudPath) return true end
            end
            return false
        end, timeout, phase .. " live HUD"
    end)
end
local function travel(phase, map, options)
    step(phase .. ": travel", function()
        say("TRAVEL %s OpenLevel %s%s", phase, map, options ~= "" and ("?" .. options) or "")
        GS():OpenLevel(pc(), FName(map), true, options)
        return after(3), 5, "travel start"
    end)
end
local function touchdown(phase)
    step(phase .. ": touchdown", function()
        say("TOUCHDOWN %s requesting Enter", phase)
        return request("key ENTER"), 20, "touchdown key"
    end)
end
local function enterMatch(phase)
    travel(phase, MATCH_MAP, "listen")
    waitWorld(phase, "SmallMap", 150)
    touchdown(phase)
    waitHud(phase, 90)
end
local function toMenu(phase)
    travel(phase, MENU_MAP, "")
    waitWorld(phase, "NewMainMenu", 150)
    waitHud(phase, 60)
end

-- Which skies exist right after a travel (risk: FindFirstOf returning the previous world's sky).
local function skies(phase)
    step(phase .. ": skies", function()
        local list = {}
        for _, s in ipairs(FindAllOf("Ultra_Dynamic_Sky_C") or {}) do if valid(s) then list[#list + 1] = pathOf(s) end end
        local first = sky()
        say("SKIES %s n=%d first=%s all=%s", phase, #list, first and pathOf(first) or "none", table.concat(list, ", "))
        local w = worldName():match("/Game/[^ :]+") or "?"
        if first then
            check(pathOf(first):find((w:gsub("%.[^.]*$", "")), 1, true) ~= nil, "SKYWORLD %s FindFirstOf's sky belongs to the current world %s (%s)", phase, w, pathOf(first))
        end
    end)
end

-- ---------------------------------------------------------------- clock checks
-- Waits until the clock is drawn, then checks it: one widget, HH:MM matching the sky, top-right.
local function clockShown(phase, n, lead)
    step(phase .. ": clock drawn", function()
        return function() return state().drawn end, 15, phase .. " clock drawn"
    end)
    step(phase .. ": clock check", function()
        local st, w, hud = state()
        say("STATE %s %s", phase, stateText(st))
        check(st.widgets == 1, "ONE %s exactly one clock widget (found %d)", phase, st.widgets)
        check(type(st.text) == "string" and st.text:match("^%d%d:%d%d$") ~= nil, "FORMAT %s text is HH:MM (%s)", phase, tostring(st.text))
        local h, m = skyHms()
        local want = h and hhmm(h, m, n)
        -- The clock reads every 250 ms: the sky may have moved on since (LAG).
        check(want ~= nil and lagging(st.text, h, m, n, lead), "MATCHES %s text %s matches the sky's %s (H/M/S %s:%s)", phase, tostring(st.text), tostring(want), tostring(h), tostring(m))
        if w and hud then checkCorner(phase, w, hud) end
        S.lastText = st.text
    end)
end

-- Host only (listen server): moves the sky's Time of Day forward by `minutes` and waits for the text to follow.
local function forceForward(phase, minutes)
    step(phase .. ": force time forward", function()
        local s = sky()
        if not check(s ~= nil, "SKY %s live sky found", phase) then return end
        local tod = s["Time of Day"]
        local new = (tod + minutes * 100 / 60) % 2400
        s["Time of Day"] = new
        say("FORCE %s Time of Day %.2f -> %.2f (+%d game minutes); clock showed %s", phase, tod, new, minutes, tostring(S.lastText))
        S.forcedFrom = S.lastText
        -- The time also moves on by itself, so wait for the text to reach the forced time, not just to change.
        return function()
            local st = state()
            local h, m = skyHms()
            return st.drawn and st.text ~= S.forcedFrom and lagging(st.text, h, m)
        end, 5, phase .. " clock followed the forced time"
    end)
    step(phase .. ": changed", function()
        local st = state()
        local h, m = skyHms()
        local want = h and hhmm(h, m)
        check(st.text ~= S.forcedFrom and lagging(st.text, h, m),
            "CHANGED %s %s -> %s within 5 s, the sky says %s", phase, tostring(S.forcedFrom), tostring(st.text), tostring(want))
        S.lastText = st.text
    end)
end

local function notDrawn(phase)
    step(phase .. ": clock not drawn", function()
        local since = os.clock()
        return function() return os.clock() - since >= 3 end, 10, phase .. " settle"
    end)
    step(phase .. ": not drawn check", function()
        local st = state()
        say("STATE %s %s", phase, stateText(st))
        check(not st.drawn, "NOTDRAWN %s the clock is not drawn (%s)", phase, stateText(st))
        check(st.widgets <= 1, "ONE %s at most one clock widget (found %d)", phase, st.widgets)
    end)
end

local function noClock(phase, seconds)
    step(phase .. ": watch for a clock", function()
        local since = os.clock()
        S.maxWidgets = 0
        return function()
            local _, n = clockWidgets()
            if n > S.maxWidgets then S.maxWidgets = n end
            return os.clock() - since >= seconds
        end, seconds + 5, phase .. " watch"
    end)
    step(phase .. ": no clock", function()
        check(S.maxWidgets == 0, "NOCLOCK %s no clock widget on the HUD for %d s (max seen %d)", phase, seconds, S.maxWidgets)
    end)
end

-- A few minutes in a match with nothing else going on, so the clock logs several read-tick cost lines (one per 60
-- ticks) and the text keeps following the sky. Checked once at the end.
local IDLE_S = 200
local function idle(phase, seconds)
    step(phase .. ": idle", function()
        say("IDLE %s %d s in the match from here", phase, seconds)
        local since = os.clock()
        return function() return os.clock() - since >= seconds end, seconds + 10, phase .. " idle"
    end)
    clockShown(phase .. "-idle")
end

-- ---------------------------------------------------------------- scenarios
local function buildMatch()
    waitWorld("menu1", "NewMainMenu", 120)
    waitHud("menu1", 60)
    notDrawn("menu1")
    enterMatch("match1")
    skies("match1")
    clockShown("match1")
    forceForward("match1", 120)
    forceForward("match1", 61)
    toMenu("menu2")
    skies("menu2")
    notDrawn("menu2")
    enterMatch("match2")
    skies("match2")
    clockShown("match2")
    forceForward("match2", 300)
    idle("match2", IDLE_S)
end

-- updateEvery = 5: the sky is frozen ('Animate Time of Day' off) and set to chosen minutes.
local STEP5 = { { 10, 2, "10:00" }, { 10, 4, "10:00" }, { 10, 5, "10:05" }, { 10, 7, "10:05" }, { 10, 9, "10:05" },
                { 10, 10, "10:10" }, { 10, 59, "10:55" }, { 11, 0, "11:00" }, { 23, 58, "23:55" }, { 0, 3, "00:00" } }
local function buildStep5()
    waitWorld("menu1", "NewMainMenu", 120)
    waitHud("menu1", 60)
    enterMatch("match1")
    clockShown("match1", 5)
    step("match1: freeze time", function()
        local s = sky()
        if not check(s ~= nil, "SKY match1 live sky found") then return end
        S.animate = s["Animate Time of Day"]
        s["Animate Time of Day"] = false
        say("FREEZE match1 Animate Time of Day %s -> false", tostring(S.animate))
    end)
    for i, c in ipairs(STEP5) do
        local h, m, want = c[1], c[2], c[3]
        step(("match1: set %02d:%02d"):format(h, m), function()
            local s = sky()
            if not s then return end
            S.beforeSet = state().text
            s["Time of Day"] = todOf(h, m)
            local since = os.clock()
            -- The clock reads every 250 ms; 2.2 s leaves room for a slow frame or two.
            return function() return os.clock() - since >= 2.2 end, 5, "step5 wait"
        end)
        step(("match1: shows %s"):format(want), function()
            local st = state()
            local sh, sm = skyHms()
            -- If the freeze didn't hold, judge against the sky's actual time, rounded down to 5.
            local actual = sh and hhmm(sh, sm, 5)
            check(st.text == want or (actual ~= nil and actual ~= hhmm(h, m, 5) and st.text == actual),
                "STEP5 %d set %02d:%02d -> shows %s (want %s; sky now %s:%s)", i, h, m, tostring(st.text), want, tostring(sh), tostring(sm))
            check(st.text ~= nil and tonumber(st.text:sub(4, 5)) % 5 == 0, "MULT5 %d %s is a multiple of 5 minutes", i, tostring(st.text))
        end)
    end
    step("match1: unfreeze", function()
        local s = sky()
        if s and S.animate ~= nil then s["Animate Time of Day"] = S.animate end
        say("UNFREEZE match1 Animate Time of Day -> %s", tostring(S.animate))
    end)
end

local function buildRebuild()
    waitWorld("menu1", "NewMainMenu", 120)
    waitHud("menu1", 60)
    enterMatch("match1")
    clockShown("match1")
    step("match1: RemoveAllWidgets", function()
        local hud = liveHud()
        if not check(hud ~= nil, "HUD match1 live before RemoveAllWidgets") then return end
        S.hudPath = pathOf(hud)
        WLL():RemoveAllWidgets(hud:GetWorld())
        say("REBUILD match1 RemoveAllWidgets (HUD %s)", S.hudPath)
        return after(2), 5, "after RemoveAllWidgets"
    end)
    step("match1: gone", function()
        local _, n = clockWidgets()
        say("REBUILD match1 after RemoveAllWidgets: live HUD=%s clock widgets=%d", tostring(liveHud() ~= nil), n)
    end)
    step("match1: re-add the HUD", function()
        local hud = found(S.hudPath)
        if not check(hud ~= nil, "HUD match1 still exists after RemoveAllWidgets (%s)", tostring(S.hudPath)) then return end
        hud:AddToViewport(0)
        say("REBUILD match1 AddToViewport(0)")
    end)
    clockShown("match1-rebuilt")
end

local function buildNoClock()
    waitWorld("menu1", "NewMainMenu", 120)
    waitHud("menu1", 60)
    enterMatch("match1")
    noClock("match1", 15)
end

-- ---------------------------------------------------------------- measure (story 2 part A)
local MEASURE_SPEEDS = { { "Fast", 1.5 }, { "Normal", 1.0 }, { "Long", 0.5 } }
local MEASURE_SECONDS = 120
-- The Journal map's own text (MapWidget_C.GetText_0), from a map widget whose cached DynamicSky is set (it's cached on
-- Construct, so a map never opened reads "00:00" from no sky): "n/a" without a map widget, "nosky" without a live one.
local function mapText()
    local any = false
    for _, m in ipairs(FindAllOf("MapWidget_C") or {}) do
        if valid(m) then
            any = true
            local okS, sk = pcall(function() return m.DynamicSky end)
            if okS and valid(sk) then
                local ok, t = pcall(function() return m:GetText_0():ToString() end)
                return ok and t or ("error: " .. tostring(t))
            end
        end
    end
    return any and "nosky" or "n/a"
end
local function buildMeasure()
    waitWorld("menu1", "NewMainMenu", 120)
    waitHud("menu1", 60)
    skies("menu1")
    enterMatch("match1")
    skies("match1")
    step("match1: minute hook", function()
        -- UDS broadcasts Every Minute from this timer function when Event Minute changes (decompiled sky).
        local fn = "/Game/UltraDynamicSky/Blueprints/Ultra_Dynamic_Sky.Ultra_Dynamic_Sky_C:Check for Time Event Dispatchers"
        local okH, err = pcall(RegisterHook, fn, function(ctx)
            pcall(function()
                local s = ctx:get()
                local em = s["Event Minute"]
                if em ~= S.eventMinute then
                    S.eventMinute = em
                    local h, m, sec, tod = skyHms(s)
                    say("MEASURE minute-event t=%.3f eventMinute=%s tod=%.3f hms=%s:%s:%s", os.clock(), tostring(em), tod or -1, tostring(h), tostring(m), tostring(sec))
                end
            end)
        end)
        say("MEASURE hook %s ok=%s %s", fn, tostring(okH), okH and "" or tostring(err))
        local s = sky()
        if s then
            say("MEASURE sky %s TimeSpeed=%s DayLength=%s NightLength=%s Animate=%s CheckPeriod=%s ReplicationPeriod=%s",
                pathOf(s), tostring(s["Time Speed"]), tostring(s["Day Length"]), tostring(s["Night Length"]),
                tostring(s["Animate Time of Day"]), tostring(s["Time Event Dispatcher Check Period"]), tostring(s["Time of Day Replication Period"]))
        end
    end)
    for _, sp in ipairs(MEASURE_SPEEDS) do
        local name, speed = sp[1], sp[2]
        step("match1: speed " .. name, function()
            local s = sky()
            if not s then return end
            s["Time Speed"] = speed
            say("MEASURE speed %s Time Speed=%s", name, tostring(s["Time Speed"]))
            local t0, nextAt = os.clock(), os.clock()
            return function()
                local now = os.clock()
                if now >= nextAt then
                    nextAt = nextAt + 1
                    local h, m, sec, tod = skyHms()
                    say("MEASURE sample speed=%s t=%.3f tod=%.4f hms=%s:%s:%s map=%s", name, now - t0, tod or -1, tostring(h), tostring(m), tostring(sec), mapText())
                end
                return now - t0 >= MEASURE_SECONDS
            end, MEASURE_SECONDS + 10, "measure " .. name
        end)
    end
    step("match1: wrap", function()
        local s = sky()
        if not s then return end
        s["Time Speed"] = 1.0
        s["Time of Day"] = 2399.0
        say("MEASURE wrap set Time of Day 2399.0")
        local t0, nextAt = os.clock(), os.clock()
        return function()
            local now = os.clock()
            if now >= nextAt then
                nextAt = nextAt + 1
                local h, m, sec, tod = skyHms()
                say("MEASURE wrap t=%.3f tod=%.4f hms=%s:%s:%s days=%s", now - t0, tod or -1, tostring(h), tostring(m), tostring(sec), tostring(sky() and sky()["Total Days Elapsed"]))
            end
            return now - t0 >= 30
        end, 40, "measure wrap"
    end)
    toMenu("menu2")
    skies("menu2")
    enterMatch("match2")
    skies("match2")
end

-- ---------------------------------------------------------------- cost: what each part of a clock read costs
-- Times, on the game thread in a match, each engine call the clock's tick makes, N times each, with core's monotonic
-- clock (its native is registered into every Lua state). Diagnostic only.
local function costProfile(phase, N)
    step(phase .. ": cost", function()
        local us = _G[CORE .. "_ClockMicros"]
        if not check(type(us) == "function", "COSTCLOCK %s %s_ClockMicros available", phase, CORE) then return end
        local s = sky()
        if not check(s ~= nil, "SKY %s live sky found", phase) then return end
        local path = pathOf(s)
        local function run(label, fn)
            local t0 = us()
            for _ = 1, N do fn() end
            say("COST %s %s avg %.1f us (n=%d)", phase, label, (us() - t0) / N, N)
        end
        local probe = StaticFindObject(path)
        say("COST %s StaticFindObject(%s) valid=%s", phase, path, tostring(valid(probe)))
        run("StaticFindObject+IsValid", function() local o = StaticFindObject(path); o:IsValid() end)
        -- The clock's own time.lua, loaded fresh into this state: the real read path, and whether it keeps its path.
        local modsDir = scriptDir:match("^(.*)[/\\][^/\\]+[/\\][Ss]cripts$")
        local okT, T = pcall(dofile, modsDir .. "\\" .. CLOCK .. "\\Scripts\\time.lua")
        if okT and type(T) == "table" then
            local h, m = T.read()
            say("COST %s time.read -> %s %s; remembered path %s", phase, tostring(h), tostring(m), tostring(T.skyPath()))
            run("time.read()", function() T.read() end)
            say("COST %s after the loop: remembered path %s", phase, tostring(T.skyPath()))
            S.costTime = T
        else
            say("COST %s could not load the clock's time.lua: %s", phase, tostring(T))
        end
        run("FindFirstOf", function() FindFirstOf("Ultra_Dynamic_Sky_C") end)
        local o = StaticFindObject(path)
        run("read Time of Day", function() return o["Time of Day"] end)
        run("index the function", function() return o[TO_HMS] end)
        local fn = o[TO_HMS]
        run("call Time Of Day to H/M/S", function() fn(o, 600.0, {}, {}, {}, {}) end)
        run("all of time.read's calls", function()
            local x = StaticFindObject(path); x:IsValid()
            local t = x["Time of Day"]; local f = x[TO_HMS]; f(x, t, {}, {}, {}, {})
        end)
        run("Lua H/M from Time of Day", function()
            local t = o["Time of Day"] % 2400 / 100
            local h = math.floor(t); local m = math.floor((t - h) * 60)
            return h, m
        end)
        run("print a log line", function() print("[" .. ME .. "] COST probe line\n") end)
    end)
end

-- ---------------------------------------------------------------- runner (game thread, every 250 ms)
local idx, waiting, busy, finished = 0, nil, false, false
local function finish()
    finished = true
    say("END result=%s checks=%d failures=%d", (S.failures == 0 and S.checks > 0) and "PASS" or "FAIL", S.checks, S.failures)
end
local function tick()
    if busy or finished then return end
    busy = true
    local ok, err = pcall(function()
        if waiting then
            if not waiting.pred() then
                if os.clock() <= waiting.deadline then return end
                check(false, "TIMEOUT %s", waiting.what)
            end
            waiting = nil
        end
        idx = idx + 1
        local s = steps[idx]
        if not s then finish() return end
        local pred, timeout, what = s.fn()
        if pred then waiting = { pred = pred, deadline = os.clock() + (timeout or 10), what = what or s.name } end
    end)
    if not ok then
        check(false, "STEP '%s' threw: %s", steps[idx] and steps[idx].name or "?", tostring(err))
        waiting = nil
    end
    busy = false
end

local function buildCost()
    waitWorld("menu1", "NewMainMenu", 120)
    waitHud("menu1", 60)
    enterMatch("match1")
    costProfile("match1", 200)
    -- The clock reads every 250 ms, not in a tight loop: the same calls, sampled one per second for 30 s.
    step("match1: cold cost", function()
        local us = _G[CORE .. "_ClockMicros"]
        local T = S.costTime
        if not (us and T) then return end
        local acc = { read = 0, prop = 0, n = 0, maxRead = 0 }
        local nextAt = os.clock()
        return function()
            if os.clock() < nextAt then return false end
            nextAt = nextAt + 1
            local t0 = us(); T.read(); local d = us() - t0
            acc.read = acc.read + d; if d > acc.maxRead then acc.maxRead = d end
            local t1 = us()
            local p = T.skyPath() and StaticFindObject(T.skyPath())
            if p and p:IsValid() then local x = p["Time of Day"] % 2400 / 100; local _ = math.floor(x) end
            acc.prop = acc.prop + (us() - t1)
            acc.n = acc.n + 1
            if acc.n >= 30 then
                say("COST match1 once a second: time.read avg %.1f max %d us; path+property+Lua math avg %.1f us (n=%d)",
                    acc.read / acc.n, acc.maxRead, acc.prop / acc.n, acc.n)
                return true
            end
            return false
        end, 45, "cold cost"
    end)
    idle("match1", IDLE_S)
end

-- ---------------------------------------------------------------- speed (clock story 5)
-- As host, Time of Day and the clock's shown text every 50 ms for SPEED_SECONDS at each Time Speed (the research run
-- that found the 1 s read skipping minutes), then one SPEEDSUM line per speed: how many times the text changed, and
-- by how many minutes (step1, step2, step3plus forward; back for any step backwards). check.ps1 judges it.
local SPEED_SECONDS = 30
-- Hour and minute of a Time of Day, by the sky's own formula (time.lua's hmFromTod).
local function hhOf(tod)
    local x = (tod % 2400) / 100
    local h = math.floor(x)
    return h, math.floor((x - h) * 60)
end
local function minuteOf(text)
    local h, m = tostring(text):match("^(%d%d):(%d%d)$")
    return h and tonumber(h) * 60 + tonumber(m) or nil
end
-- Counts one sampled text into acc; a change is the step from the previous sampled HH:MM (around midnight, a step
-- of more than 12 hours forward is a step back).
local function countStep(acc, text)
    local m = minuteOf(text)
    if m == nil then return end
    if acc.prev ~= nil and m ~= acc.prev then
        local d = (m - acc.prev) % 1440
        acc.changes = acc.changes + 1
        if d > 720 then acc.back = acc.back + 1
        elseif d == 1 then acc.step1 = acc.step1 + 1
        elseif d == 2 then acc.step2 = acc.step2 + 1
        else acc.step3plus = acc.step3plus + 1 end
        if d ~= 1 then say("SPEED step speed=%s %s -> %s", acc.name, acc.prevText, text) end
    end
    acc.prev, acc.prevText = m, text
end
local function buildSpeed()
    waitWorld("menu1", "NewMainMenu", 120)
    waitHud("menu1", 60)
    enterMatch("match1")
    clockShown("match1", 1)
    for _, sp in ipairs({ { "Fast", 1.5 }, { "Normal", 1.0 } }) do
        local name, speed = sp[1], sp[2]
        step("match1: fine " .. name, function()
            local s = sky()
            if not s then return end
            s["Time Speed"] = speed
            say("SPEED start %s Time Speed=%s", name, tostring(s["Time Speed"]))
            local t0, done, loop = os.clock(), false, nil
            local acc = { name = name, changes = 0, step1 = 0, step2 = 0, step3plus = 0, back = 0 }
            local okL, res = pcall(LoopInGameThreadWithDelay, 50, function()
                if done then return end
                pcall(function()
                    local sk = sky()
                    local tod = sk and sk["Time of Day"] or -1
                    local text = state().text
                    say("SPEED fine speed=%s t=%.3f tod=%.4f text=%s", name, os.clock() - t0, tod, tostring(text))
                    countStep(acc, text)
                end)
            end)
            if okL then loop = res end
            check(okL, "SPEEDLOOP %s 50 ms sample loop started (%s)", name, okL and "ok" or tostring(res))
            return function()
                if os.clock() - t0 < SPEED_SECONDS + 1.5 then return false end
                done = true
                if loop then pcall(CancelDelayedAction, loop) end
                say("SPEEDSUM speed=%s changes=%d step1=%d step2=%d step3plus=%d back=%d", name, acc.changes, acc.step1,
                    acc.step2, acc.step3plus, acc.back)
                return true
            end, SPEED_SECONDS + 15, "fine " .. name
        end)
    end
end

-- ---------------------------------------------------------------- pair-client (clock story 5, in a pair run)
-- B joins the host's friends-only lobby (pair.ps1); B's sky is a client copy: the host replicates Time of Day once a
-- second and OnRep snaps B's value to it, so B's time can step back a little. The clock holds back a step back of 1-2
-- minutes; this samples what B's HUD shows against B's sky. Nothing is sent; only this machine's own state is read.
local PAIR_SECONDS = 120
local function buildPairClient()
    step("pair: in a match", function()
        return function()
            -- The join passes through /Game/Maps/Startup/GraphicsWarmup first (pair run 2026-11-19): not a match.
            local w = worldName()
            if w ~= "" and not w:find("NewMainMenu", 1, true) and not w:find("GraphicsWarmup", 1, true) and sky() then
                say("WORLD pair %s", w:match("/Game/[^ ]+") or "?")
                return true
            end
            return false
        end, 900, "pair world (joined the host's match)"
    end)
    waitHud("pair", 120)
    -- The game hides the HUD during the lobby countdown: wait for it to be drawn (the countdown, then touchdown).
    step("pair: wait for the HUD to show", function()
        return function() return state().drawn end, 300, "pair clock drawn after the lobby"
    end)
    clockShown("pair", 1, 2)
    step("pair: sample", function()
        local s = sky()
        say("PAIR start Time Speed=%s replicated=%s", tostring(s and s["Time Speed"]), tostring(s and s["Replicated Time of Day"]))
        local t0, done, loop = os.clock(), false, nil
        local acc = { name = "client", changes = 0, step1 = 0, step2 = 0, step3plus = 0, back = 0 }
        local sk = { n = 0, back = 0, backMinute = 0, ahead = 0, maxBack = 0 }
        local okL, res = pcall(LoopInGameThreadWithDelay, 50, function()
            if done then return end
            pcall(function()
                local s2 = sky()
                local tod = s2 and s2["Time of Day"]
                local text = state().text
                if type(tod) ~= "number" then return end
                sk.n = sk.n + 1
                -- A step back of the sky between two samples (not the wrap at 2400): the replication snap.
                if sk.prev and tod < sk.prev and sk.prev - tod < 1200 then
                    sk.back = sk.back + 1
                    if sk.prev - tod > sk.maxBack then sk.maxBack = sk.prev - tod end
                    local h1, m1 = hhOf(sk.prev); local h2, m2 = hhOf(tod)
                    if h1 * 60 + m1 ~= h2 * 60 + m2 then
                        sk.backMinute = sk.backMinute + 1
                        say("PAIR sky back %.4f -> %.4f (%02d:%02d -> %02d:%02d), text %s", sk.prev, tod, h1, m1, h2, m2, tostring(text))
                    end
                end
                sk.prev = tod
                -- The text ahead of the sky: the clock holding a value the sky stepped back from.
                local tm = minuteOf(text)
                if tm then
                    local h, m = hhOf(tod)
                    local d = (tm - (h * 60 + m)) % 1440
                    if d >= 1 and d <= 2 then sk.ahead = sk.ahead + 1 end
                end
                countStep(acc, text)
            end)
        end)
        if okL then loop = res end
        check(okL, "PAIRLOOP 50 ms sample loop started (%s)", okL and "ok" or tostring(res))
        return function()
            if os.clock() - t0 < PAIR_SECONDS then return false end
            done = true
            if loop then pcall(CancelDelayedAction, loop) end
            say("PAIRSUM changes=%d step1=%d step2=%d step3plus=%d back=%d samples=%d skyBack=%d skyBackMinute=%d maxSkyBack=%.4f heldAhead=%d",
                acc.changes, acc.step1, acc.step2, acc.step3plus, acc.back, sk.n, sk.back, sk.backMinute, sk.maxBack, sk.ahead)
            return true
        end, PAIR_SECONDS + 15, "pair sample"
    end)
    clockShown("pair-end", 1, 2)
end

local build = ({ cost = buildCost, ["pair-client"] = buildPairClient, match = buildMatch, step5 = buildStep5, rebuild = buildRebuild, ["no-core"] = buildNoClock,
                 ["old-core"] = buildNoClock, measure = buildMeasure, speed = buildSpeed })[SCENARIO]
if not build then
    say("END result=FAIL checks=0 failures=1 reason=unknown-scenario %s", SCENARIO)
    return
end
build()
-- A game-thread loop (never LoopAsync + ExecuteInGameThread: the pinned UE4SS can lose those callbacks).
local runner
local okL, res = pcall(LoopInGameThreadWithDelay, 250, function()
    tick()
    if finished and runner then pcall(CancelDelayedAction, runner); runner = nil end
end)
if okL then runner = res else say("END result=FAIL checks=0 failures=1 reason=loop %s", tostring(res)) end
say("LOADED %d steps", #steps)

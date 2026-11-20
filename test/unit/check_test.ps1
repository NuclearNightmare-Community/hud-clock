<#
.SYNOPSIS
  Unit tests for check.ps1: synthetic UE4SS.log files, in the format the pinned UE4SS writes, for every scenario,
  each passing as written and failing after one targeted change. Proves the patterns, not the game.
.EXAMPLE
  pwsh -NoProfile -File test/unit/check_test.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
$check = Join-Path $repo 'check.ps1'
$script:passed = 0; $script:failed = 0
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("clock-check-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null

$script:t = 0
function L([string] $tag, [string] $msg) { $script:t++; "[2026-10-25 01:00:{0:D2}.{1:D7}] [Lua] [$tag] $msg" -f [int]($script:t / 1000 % 60), $script:t }
function U([string] $msg) { $script:t++; "[2026-10-25 01:00:00.{0:D7}] $msg" -f $script:t }

function Run([string[]] $log, [string] $scenario, [string] $target = 'host') {
    $p = Join-Path $tmp "$scenario-$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
    Set-Content $p $log
    $out = & pwsh -NoProfile -NonInteractive -File $check -Log $p -Scenario $scenario -Target $target 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}
function Expect([string[]] $log, [string] $scenario, [int] $code, [string] $name, [string] $mustSay, [string] $target = 'host') {
    $r = Run $log $scenario $target
    $ok = $r.Code -eq $code -and (-not $mustSay -or $r.Out -match $mustSay)
    if ($ok) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $name (exit $($r.Code), want $code)"; Write-Host ($r.Out -split "`n" | Where-Object { $_ -match 'FAIL|warn' } | Out-String) }
}

function Start-Log { @(
    (U "Starting Lua mod 'Nucleus'"), (L 'Nucleus' 'READY version=0.2.0 native=0.2.0 ue4ss=v3.0.1-1181-g83330635 boot=1'),
    (U "Starting Lua mod 'HudClockDriver'"), (U "Starting Lua mod 'HudClock'")) }
function Running([int] $n, [string] $scenario) {
    $l = @((L 'HudClockDriver' "SCENARIO $scenario"), (L 'HudClockDriver' 'LOADED 30 steps'),
        (L 'HudClock' 'CONNECT ok Nucleus 0.2.0 (pong 0.2.0 boot=1)'), (L 'HudClock' "READY updateEvery=$n element=clock.time"),
        (L 'HudClock' "ui attach 'clock.time' created /Engine/Transient.GameEngine_1:BP_GameInstance_C_1.WBP_NucleusText_C_1 (HUD appeared)"),
        (L 'HudClock' "VISIBLE 10:05 (updateEvery=$n)"))
    foreach ($s in '10:05', '10:10', '10:15') { $l += L 'HudClock' "DEBUG SHOW $s" }
    $l += L 'HudClock' "VERIFY 659.0600 -> 06:35, the same as 'Time Of Day to H/M/S'"
    $l += L 'HudClock' 'DEBUG TICK n=60 avg 131.5 max 210 us (read 10.2, set 20.1 over 40 changes, log 100.0)'
    $l += L 'HudClock' 'DEBUG TICK n=60 avg 28.0 max 180 us'
    $l += L 'HudClock' 'DEBUG hud tick n=120 poll avg 20 max 90'
    return $l
}
function End-Log { @((L 'HudClockDriver' 'END result=PASS checks=20 failures=0')) }

# ---------------------------------------------------------------- match
$match = (Start-Log) + (Running 1 'match') + @(
    (L 'HudClockDriver' 'OK NOTDRAWN menu1 the clock is not drawn (widgets=1 ...)'), (L 'HudClockDriver' 'OK NOTDRAWN menu2 the clock is not drawn (...)'))
foreach ($p in 'match1', 'match2') {
    $match += L 'HudClockDriver' "OK ONE $p exactly one clock widget (found 1)"
    $match += L 'HudClockDriver' "OK FORMAT $p text is HH:MM (10:05)"
    $match += L 'HudClockDriver' "OK MATCHES $p text 10:05 matches the sky's 10:05 (H/M/S 10:5)"
    $match += L 'HudClockDriver' "OK CORNER $p clock in the top-right corner: rect=(1800,16)-(1904,45) gapRight=16.0 gapTop=16.0"
    $match += L 'HudClockDriver' "OK SKYWORLD $p FindFirstOf's sky belongs to the current world"
    $match += L 'HudClockDriver' "OK CHANGED $p 10:05 -> 10:08 within 5 s, the sky says 10:08"
}
$match += L 'HudClockDriver' 'OK CHANGED match1 10:08 -> 11:09 within 5 s, the sky says 11:09'
$match += L 'HudClockDriver' 'IDLE match2 200 s in the match from here'
$match += L 'HudClockDriver' 'OK ONE match2-idle exactly one clock widget (found 1)'
$match += L 'HudClockDriver' "OK MATCHES match2-idle text 12:00 matches the sky's 12:01 (H/M/S 12:1)"
$match += End-Log
Expect $match 'match' 0 'match: passes' 'All checks passed'
Expect ($match | Where-Object { $_ -notmatch 'OK CORNER match2' }) 'match' 1 'match: missing CORNER match2 fails'
Expect ($match | Where-Object { $_ -notmatch 'match2-idle' }) 'match' 1 'match: missing idle check fails'
Expect ($match + (L 'HudClock' 'WARN tick failed: boom')) 'match' 1 'match: a clock WARN fails'
Expect ($match + (L 'HudClock' 'WARN hud slow tick 1.4 ms (attach); HUD event: attached')) 'match' 0 "match: core's slow tick on a HUD event is soft" 'soft check'
Expect ($match + (L 'HudClock' 'WARN hud slow tick 1.4 ms; steady state')) 'match' 1 'match: a steady-state slow tick fails'
# -Target vm (run.ps1 -Target vm): timing inside functional scenarios is soft, everything else as on the host.
Expect $match 'match' 0 'vm match: passes' 'All checks passed' 'vm'
Expect ($match + (L 'HudClock' 'WARN hud slow tick 1.4 ms (steady state)')) 'match' 0 'vm match: a steady-state slow tick is soft' 'warn: .*steady state' 'vm'
Expect ($match + (L 'HudClock' 'WARN tick failed: boom')) 'match' 1 'vm match: a clock WARN still fails' '' 'vm'
Expect ($match | Where-Object { $_ -notmatch 'OK CORNER match2' }) 'match' 1 'vm match: missing CORNER match2 still fails' '' 'vm'
Expect $match 'cost' 1 'vm cost: refused (host-only)' 'valid only on the host' 'vm'
Expect $match 'measure' 1 'vm measure: refused (host-only)' 'valid only on the host' 'vm'
Expect ($match + (U 'stack traceback:')) 'match' 1 'match: a traceback fails'
Expect ($match + (L 'HudClockDriver' 'FAIL MATCHES match1 text 10:05')) 'match' 1 'match: a driver FAIL fails'
Expect (($match | Where-Object { $_ -notmatch 'DEBUG TICK' }) + (L 'HudClock' 'DEBUG TICK n=60 avg 150.0 max 400 us')) 'match' 0 'match: a slow tick with DEBUG lines on is only a warning' 'judged in the cost scenario'
Expect ($match | Where-Object { $_ -notmatch 'VERIFY' }) 'match' 1 'match: no VERIFY fails'
Expect ($match + (L 'HudClock' 'DEBUG TICK n=60 avg 20.0 max 1500 us (read 5.0, set 5.0 over 1 changes, log 0.0)')) 'match' 0 'match: one slow tick is a warning' 'warn: a read tick took 1500 us'
Expect ($match | Where-Object { $_ -notmatch 'DEBUG TICK' }) 'match' 1 'match: no TICK line fails'
Expect ($match + (L 'HudClock' 'READY updateEvery=1 element=clock.time')) 'match' 1 'match: two READY lines fail'
# READY before CONNECT ok.
$swapped = [Collections.Generic.List[string]]::new([string[]]$match)
$ic = $swapped.FindIndex({ param($l) $l -match '\[HudClock\] CONNECT ok' }); $ir = $swapped.FindIndex({ param($l) $l -match '\[HudClock\] READY ' })
$tmpL = $swapped[$ic]; $swapped[$ic] = $swapped[$ir]; $swapped[$ir] = $tmpL
Expect $swapped.ToArray() 'match' 1 'match: READY before CONNECT ok fails' 'READY comes after CONNECT ok'
Expect ($match + (L 'HudClock' 'DEBUG SHOW 24:10')) 'match' 1 'match: an hour of 24 fails'

# ---------------------------------------------------------------- cost (the hard tick-cost check)
function Cost-Log([string[]] $ticks) {
    $l = (Start-Log) + @((L 'HudClockDriver' 'SCENARIO cost'), (L 'HudClock' 'CONNECT ok Nucleus 0.2.0 (pong 0.2.0 boot=1)'),
        (L 'HudClock' 'READY updateEvery=1 element=clock.time'), (L 'HudClock' "ui attach 'clock.time' created /Engine/Transient.WBP_NucleusText_C_1 (HUD appeared)"),
        (L 'HudClock' 'VISIBLE 06:30 (updateEvery=1)'), (L 'HudClockDriver' "COST match1 all of time.read's calls avg 17.4 us (n=200)"),
        (L 'HudClockDriver' 'IDLE match1 200 s in the match from here'))
    foreach ($t in $ticks) { $l += L 'HudClock' $t }
    return $l + (End-Log)
}
$first = 'TICK n=60 avg 900.0 max 3000 us (read 160.0, set 20.0 over 30 changes, log 0.0)' # menu and travel: skipped
Expect (Cost-Log @($first, 'TICK n=60 avg 80.0 max 300 us (read 30.0, set 45.0 over 60 changes, log 0.0)')) 'cost' 0 'cost: 0.08 ms passes, the first window skipped' 'avg 80.0 us without'
Expect (Cost-Log @($first, 'TICK n=60 avg 120.0 max 300 us (read 30.0, set 45.0 over 60 changes, log 0.0)')) 'cost' 1 'cost: 0.12 ms fails' 'FAIL: read tick cost'
Expect ((Cost-Log @($first, 'TICK n=60 avg 80.0 max 300 us (read 30.0, set 45.0 over 60 changes, log 0.0)')) + (L 'HudClock' 'DEBUG SHOW 06:31')) 'cost' 1 'cost: DEBUG lines present fails'
Expect (Cost-Log @()) 'cost' 1 'cost: no TICK line fails'
Expect ((Cost-Log @($first, 'TICK n=60 avg 80.0 max 300 us (read 0.0, set 0.0 over 60 changes, log 0.0)')) | Where-Object { $_ -notmatch 'ui attach' }) 'cost' 0 'cost: no attach line (DEBUG-only in core) is soft' 'warn: .*ui attach'
Expect ((Cost-Log @($first, 'TICK n=60 avg 80.0 max 300 us (read 0.0, set 0.0 over 60 changes, log 0.0)')) + (L 'HudClock' "ui attach left 'clock.time' pending, retried in 4 ticks (HUD appeared)")) 'cost' 1 'cost: the clock left pending fails'

# ---------------------------------------------------------------- step5
$step5 = (Start-Log) + (Running 5 'step5') + @((L 'HudClockDriver' 'FREEZE match1 Animate Time of Day true -> false'), (L 'HudClockDriver' 'OK CORNER match1 clock in the top-right corner'))
for ($i = 1; $i -le 10; $i++) { $step5 += L 'HudClockDriver' "OK STEP5 $i set 10:02 -> shows 10:00"; $step5 += L 'HudClockDriver' "OK MULT5 $i 10:00 is a multiple of 5 minutes" }
$step5 += End-Log
Expect $step5 'step5' 0 'step5: passes' 'All checks passed'
Expect ($step5 + (L 'HudClock' 'DEBUG SHOW 10:07')) 'step5' 1 'step5: a shown 10:07 fails' 'not 10:07'
Expect (($step5 | Where-Object { $_ -notmatch 'READY' }) + (L 'HudClock' 'READY updateEvery=1 element=clock.time')) 'step5' 1 'step5: READY updateEvery=1 fails'
Expect ($step5 | Where-Object { $_ -notmatch 'OK STEP5 10 ' }) 'step5' 1 'step5: nine STEP5 lines fail'

# ---------------------------------------------------------------- rebuild
$rebuild = (Start-Log) + (Running 1 'rebuild') + @(
    (L 'HudClockDriver' 'REBUILD match1 RemoveAllWidgets (HUD /Engine/Transient.InventoryUI_C_1)'), (L 'HudClockDriver' 'REBUILD match1 AddToViewport(0)'),
    (L 'HudClock' "DEBUG ui attach 'clock.time' reused /Engine/Transient.WBP_NucleusText_C_1 (HUD back in the viewport)"),
    (L 'HudClockDriver' 'OK ONE match1-rebuilt exactly one clock widget (found 1)'), (L 'HudClockDriver' 'OK CORNER match1-rebuilt clock in the top-right corner')) + (End-Log)
Expect $rebuild 'rebuild' 0 'rebuild: passes (DEBUG attach line, core ac57c5c)' 'All checks passed'
Expect ($rebuild -replace 'DEBUG ui attach', 'ui attach') 'rebuild' 0 'rebuild: an INFO attach line (older core) passes too' 'All checks passed'
Expect ($rebuild | Where-Object { $_ -notmatch "reused" }) 'rebuild' 1 'rebuild: no reuse fails'
Expect ($rebuild + (L 'HudClock' "WARN text 'clock.time': removed 1 duplicate widget(s) from the HUD canvas")) 'rebuild' 1 'rebuild: a duplicate fails'

# ---------------------------------------------------------------- no-core and old-core
$noCore = @((U "Starting Lua mod 'HudClockDriver'"), (L 'HudClockDriver' 'SCENARIO no-core'), (U "Starting Lua mod 'HudClock'"),
    (L 'HudClock' 'Nucleus is not installed. HudClock will not run.'), (L 'HudClockDriver' 'OK NOCLOCK match1 no clock widget on the HUD for 15 s (max seen 0)')) + (End-Log)
Expect $noCore 'no-core' 0 'no-core: passes' 'All checks passed'
Expect $noCore 'no-core' 0 'vm no-core: passes' 'All checks passed' 'vm'
Expect ($noCore + (L 'HudClock' 'READY updateEvery=1 element=clock.time')) 'no-core' 1 'no-core: a second [HudClock] line fails'
Expect ($noCore | Where-Object { $_ -notmatch 'NOCLOCK' }) 'no-core' 1 'no-core: no NOCLOCK fails'

$oldCore = (Start-Log) + @((L 'HudClockDriver' "OLDCORE published nucleus.version=0.1.0 (from Nucleus's installed mod.json)"),
    (L 'HudClock' 'ERROR Nucleus 0.1.0 is older than HudClock needs (>=0.9.0). Update Nucleus. HudClock will not run.'),
    (L 'HudClockDriver' 'OK NOCLOCK match1 no clock widget on the HUD for 15 s (max seen 0)')) + (End-Log)
Expect $oldCore 'old-core' 0 'old-core: passes' 'All checks passed'
Expect ($oldCore + (L 'HudClock' 'ERROR start failed: x')) 'old-core' 1 'old-core: a second [HudClock] line fails'
Expect ($oldCore -replace 'needs \(>=0\.9\.0\)', 'needs (>=0.1.0)') 'old-core' 1 'old-core: the wrong need fails'

# ---------------------------------------------------------------- measure
$measure = (Start-Log) + @((L 'HudClockDriver' 'SCENARIO measure'), (L 'HudClockDriver' 'SKIES match1 n=1 first=/Game/Maps/X'), (L 'HudClockDriver' 'SKIES match2 n=1 first=/Game/Maps/X'),
    (L 'HudClockDriver' 'MEASURE hook /Game/UltraDynamicSky/Blueprints/Ultra_Dynamic_Sky.Ultra_Dynamic_Sky_C:Check for Time Event Dispatchers ok=true '))
foreach ($sp in @(@('Fast', 1.5), @('Normal', 1.0), @('Long', 0.5))) {
    for ($s = 0; $s -lt 20; $s++) {
        $tod = 2390 + $s * 0.5 * $sp[1]
        if ($tod -ge 2400) { $tod -= 2400 }
        $h = [math]::Floor($tod / 100); $m = [math]::Floor(($tod / 100 - $h) * 60)
        $measure += L 'HudClockDriver' ("MEASURE sample speed={0} t={1:F3} tod={2:F4} hms={3}:{4}:0 map={5:D2}:{6:D2}" -f $sp[0], $s, $tod, $h, $m, [int]$h, [int]$m)
    }
}
$measure += L 'HudClockDriver' 'MEASURE minute-event t=1.000 eventMinute=5 tod=1000.000 hms=10:0:0'
$measure += L 'HudClockDriver' 'MEASURE wrap t=0.000 tod=2399.0000 hms=23:54:0 days=0'
$measure += End-Log
$r = Run $measure 'measure'
if ($r.Code -eq 0 -and $r.Out -match 'MEASURE Normal: 20 samples, 0\.5000 Time of Day units/s, 3\.33 real s per game minute, jumps=0, map samples=20 differing=0') { $script:passed++ }
else { $script:failed++; Write-Host "FAIL measure: summary"; Write-Host $r.Out }
Expect ($measure | Where-Object { $_ -notmatch 'speed=Long' }) 'measure' 1 'measure: no Long samples fails'

# ---------------------------------------------------------------- speed (story 5; allowed in the VM)
function Speed-Log([string] $fast, [string] $normal) {
    $l = (Start-Log) + (Running 1 'speed') + @(
        (L 'HudClockDriver' "OK MATCHES match1 text 10:05 matches the sky's 10:05 (H/M/S 10:5)"),
        (L 'HudClockDriver' 'OK SPEEDLOOP Fast 50 ms sample loop started (ok)'),
        (L 'HudClockDriver' 'SPEED fine speed=Fast t=0.050 tod=650.0000 text=06:30'),
        (L 'HudClockDriver' 'SPEED fine speed=Normal t=0.050 tod=750.0000 text=07:30'))
    if ($fast) { $l += L 'HudClockDriver' "SPEEDSUM speed=Fast $fast" }
    if ($normal) { $l += L 'HudClockDriver' "SPEEDSUM speed=Normal $normal" }
    return $l + (End-Log)
}
$fastOk = 'changes=54 step1=54 step2=0 step3plus=0 back=0'
$normalOk = 'changes=35 step1=34 step2=1 step3plus=0 back=0'
Expect (Speed-Log $fastOk $normalOk) 'speed' 0 'speed: passes' 'SPEED Fast: 54 changes, 54 by \+1'
Expect (Speed-Log $fastOk $normalOk) 'speed' 0 'vm speed: passes (not refused)' 'All checks passed' 'vm'
Expect (Speed-Log $fastOk 'changes=35 step1=31 step2=4 step3plus=0 back=0') 'speed' 1 'speed: under 90% +1 fails' 'FAIL: SPEED Normal'
Expect (Speed-Log $fastOk 'changes=35 step1=32 step2=3 step3plus=0 back=0') 'speed' 0 'speed: exactly 32 of 35 (91%) passes' 'All checks passed'
Expect (Speed-Log 'changes=54 step1=53 step2=0 step3plus=1 back=0' $normalOk) 'speed' 1 'speed: a step of 3 fails' 'FAIL: SPEED Fast'
Expect (Speed-Log 'changes=54 step1=53 step2=0 step3plus=0 back=1' $normalOk) 'speed' 1 'speed: a step back fails' 'FAIL: SPEED Fast'
Expect (Speed-Log 'changes=0 step1=0 step2=0 step3plus=0 back=0' $normalOk) 'speed' 1 'speed: no change fails' 'FAIL: SPEED Fast'
Expect (Speed-Log $fastOk '') 'speed' 1 'speed: no Normal summary fails' 'no SPEEDSUM line'
# The research run's 1 s reads (+2 x22, +1 x6, +3 x1 at Fast) fail.
Expect (Speed-Log 'changes=29 step1=6 step2=22 step3plus=1 back=0' $normalOk) 'speed' 1 'speed: the old 1 s read fails' 'FAIL: SPEED Fast'

# ---------------------------------------------------------------- pair-client (story 5, B's log from a pair run)
function Pair-Log([string] $sum) {
    $l = (Start-Log) + (Running 1 'pair-client') + @(
        (L 'HudClockDriver' 'WORLD pair /Game/Maps/SmallLoweIsland/SmallMap.SmallMap'),
        (L 'HudClockDriver' 'OK ONE pair exactly one clock widget (found 1)'),
        (L 'HudClockDriver' "OK MATCHES pair text 10:05 matches the sky's 10:05 (H/M/S 10:5)"),
        (L 'HudClockDriver' "OK MATCHES pair-end text 12:05 matches the sky's 12:05 (H/M/S 12:5)"))
    if ($sum) { $l += L 'HudClockDriver' "PAIRSUM $sum" }
    return $l + (End-Log)
}
$pairOk = 'changes=140 step1=140 step2=0 step3plus=0 back=0 samples=2400 skyBack=110 skyBackMinute=1 maxSkyBack=0.0420 heldAhead=3'
Expect (Pair-Log $pairOk) 'pair-client' 0 'pair-client: passes, sky summary printed' 'PAIR client sky: 2400 samples, 110 steps back'
Expect (Pair-Log $pairOk) 'pair-client' 0 'vm pair-client: passes' 'All checks passed' 'vm'
Expect (Pair-Log ($pairOk -replace 'back=0 samples', 'back=1 samples')) 'pair-client' 1 'pair-client: a text step back fails' 'FAIL: PAIR client text'
Expect (Pair-Log ($pairOk -replace 'step3plus=0', 'step3plus=1')) 'pair-client' 1 'pair-client: a step of 3 fails' 'FAIL: PAIR client text'
Expect (Pair-Log '') 'pair-client' 1 'pair-client: no PAIRSUM fails'
Expect ((Pair-Log $pairOk) | Where-Object { $_ -notmatch 'MATCHES pair-end' }) 'pair-client' 1 'pair-client: no end check fails'

# ---------------------------------------------------------------- hand
$hand = (Start-Log) + @((L 'HudClock' 'CONNECT ok Nucleus 0.2.0 (pong 0.2.0 boot=1)'), (L 'HudClock' 'READY updateEvery=1 element=clock.time'),
    (L 'HudClock' "ui attach 'clock.time' created /Engine/Transient.WBP_NucleusText_C_1 (HUD appeared)"), (L 'HudClock' 'VISIBLE 07:42 (updateEvery=1)'),
    (L 'HudClock' 'HIDDEN no sky'), (L 'HudClock' 'VISIBLE 06:00 (updateEvery=1)'))
Expect $hand 'hand' 0 'hand: passes' 'All checks passed'
Expect ($hand + (L 'HudClock' 'ERROR boom')) 'hand' 1 'hand: an ERROR fails'

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("check_test: {0} passed, {1} failed" -f $script:passed, $script:failed)
exit $(if ($script:failed) { 1 } else { 0 })

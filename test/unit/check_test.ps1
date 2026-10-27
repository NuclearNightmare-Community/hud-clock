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
    (U "Starting Lua mod 'ClockDriver'"), (U "Starting Lua mod 'Clock'")) }
function Running([int] $n, [string] $scenario) {
    $l = @((L 'ClockDriver' "SCENARIO $scenario"), (L 'ClockDriver' 'LOADED 30 steps'),
        (L 'Clock' 'CONNECT ok Nucleus 0.2.0 (pong 0.2.0 boot=1)'), (L 'Clock' "READY updateEvery=$n element=clock.time"),
        (L 'Clock' "ui attach 'clock.time' created /Engine/Transient.GameEngine_1:BP_GameInstance_C_1.WBP_NucleusText_C_1 (HUD appeared)"),
        (L 'Clock' "VISIBLE 10:05 (updateEvery=$n)"))
    foreach ($s in '10:05', '10:10', '10:15') { $l += L 'Clock' "DEBUG SHOW $s" }
    $l += L 'Clock' "VERIFY 659.0600 -> 06:35, the same as 'Time Of Day to H/M/S'"
    $l += L 'Clock' 'DEBUG TICK n=60 avg 131.5 max 210 us (read 10.2, set 20.1 over 40 changes, log 100.0)'
    $l += L 'Clock' 'DEBUG TICK n=60 avg 28.0 max 180 us'
    $l += L 'Clock' 'DEBUG hud tick n=120 poll avg 20 max 90'
    return $l
}
function End-Log { @((L 'ClockDriver' 'END result=PASS checks=20 failures=0')) }

# ---------------------------------------------------------------- match
$match = (Start-Log) + (Running 1 'match') + @(
    (L 'ClockDriver' 'OK NOTDRAWN menu1 the clock is not drawn (widgets=1 ...)'), (L 'ClockDriver' 'OK NOTDRAWN menu2 the clock is not drawn (...)'))
foreach ($p in 'match1', 'match2') {
    $match += L 'ClockDriver' "OK ONE $p exactly one clock widget (found 1)"
    $match += L 'ClockDriver' "OK FORMAT $p text is HH:MM (10:05)"
    $match += L 'ClockDriver' "OK MATCHES $p text 10:05 matches the sky's 10:05 (H/M/S 10:5)"
    $match += L 'ClockDriver' "OK CORNER $p clock in the top-right corner: rect=(1800,16)-(1904,45) gapRight=16.0 gapTop=16.0"
    $match += L 'ClockDriver' "OK SKYWORLD $p FindFirstOf's sky belongs to the current world"
    $match += L 'ClockDriver' "OK CHANGED $p 10:05 -> 10:08 within 5 s, the sky says 10:08"
}
$match += L 'ClockDriver' 'OK CHANGED match1 10:08 -> 11:09 within 5 s, the sky says 11:09'
$match += L 'ClockDriver' 'IDLE match2 200 s in the match from here'
$match += L 'ClockDriver' 'OK ONE match2-idle exactly one clock widget (found 1)'
$match += L 'ClockDriver' "OK MATCHES match2-idle text 12:00 matches the sky's 12:01 (H/M/S 12:1)"
$match += End-Log
Expect $match 'match' 0 'match: passes' 'All checks passed'
Expect ($match | Where-Object { $_ -notmatch 'OK CORNER match2' }) 'match' 1 'match: missing CORNER match2 fails'
Expect ($match | Where-Object { $_ -notmatch 'match2-idle' }) 'match' 1 'match: missing idle check fails'
Expect ($match + (L 'Clock' 'WARN tick failed: boom')) 'match' 1 'match: a clock WARN fails'
Expect ($match + (L 'Clock' 'WARN hud slow tick 1.4 ms (attach); HUD event: attached')) 'match' 0 "match: core's slow tick on a HUD event is soft" 'soft check'
Expect ($match + (L 'Clock' 'WARN hud slow tick 1.4 ms; steady state')) 'match' 1 'match: a steady-state slow tick fails'
# -Target vm (run.ps1 -Target vm): timing inside functional scenarios is soft, everything else as on the host.
Expect $match 'match' 0 'vm match: passes' 'All checks passed' 'vm'
Expect ($match + (L 'Clock' 'WARN hud slow tick 1.4 ms (steady state)')) 'match' 0 'vm match: a steady-state slow tick is soft' 'warn: .*steady state' 'vm'
Expect ($match + (L 'Clock' 'WARN tick failed: boom')) 'match' 1 'vm match: a clock WARN still fails' '' 'vm'
Expect ($match | Where-Object { $_ -notmatch 'OK CORNER match2' }) 'match' 1 'vm match: missing CORNER match2 still fails' '' 'vm'
Expect $match 'cost' 1 'vm cost: refused (host-only)' 'valid only on the host' 'vm'
Expect $match 'measure' 1 'vm measure: refused (host-only)' 'valid only on the host' 'vm'
Expect ($match + (U 'stack traceback:')) 'match' 1 'match: a traceback fails'
Expect ($match + (L 'ClockDriver' 'FAIL MATCHES match1 text 10:05')) 'match' 1 'match: a driver FAIL fails'
Expect (($match | Where-Object { $_ -notmatch 'DEBUG TICK' }) + (L 'Clock' 'DEBUG TICK n=60 avg 150.0 max 400 us')) 'match' 0 'match: a slow tick with DEBUG lines on is only a warning' 'judged in the cost scenario'
Expect ($match | Where-Object { $_ -notmatch 'VERIFY' }) 'match' 1 'match: no VERIFY fails'
Expect ($match + (L 'Clock' 'DEBUG TICK n=60 avg 20.0 max 1500 us (read 5.0, set 5.0 over 1 changes, log 0.0)')) 'match' 0 'match: one slow tick is a warning' 'warn: a read tick took 1500 us'
Expect ($match | Where-Object { $_ -notmatch 'DEBUG TICK' }) 'match' 1 'match: no TICK line fails'
Expect ($match + (L 'Clock' 'READY updateEvery=1 element=clock.time')) 'match' 1 'match: two READY lines fail'
# READY before CONNECT ok.
$swapped = [Collections.Generic.List[string]]::new([string[]]$match)
$ic = $swapped.FindIndex({ param($l) $l -match '\[Clock\] CONNECT ok' }); $ir = $swapped.FindIndex({ param($l) $l -match '\[Clock\] READY ' })
$tmpL = $swapped[$ic]; $swapped[$ic] = $swapped[$ir]; $swapped[$ir] = $tmpL
Expect $swapped.ToArray() 'match' 1 'match: READY before CONNECT ok fails' 'READY comes after CONNECT ok'
Expect ($match + (L 'Clock' 'DEBUG SHOW 24:10')) 'match' 1 'match: an hour of 24 fails'

# ---------------------------------------------------------------- cost (the hard tick-cost check)
function Cost-Log([string[]] $ticks) {
    $l = (Start-Log) + @((L 'ClockDriver' 'SCENARIO cost'), (L 'Clock' 'CONNECT ok Nucleus 0.2.0 (pong 0.2.0 boot=1)'),
        (L 'Clock' 'READY updateEvery=1 element=clock.time'), (L 'Clock' "ui attach 'clock.time' created /Engine/Transient.WBP_NucleusText_C_1 (HUD appeared)"),
        (L 'Clock' 'VISIBLE 06:30 (updateEvery=1)'), (L 'ClockDriver' "COST match1 all of time.read's calls avg 17.4 us (n=200)"),
        (L 'ClockDriver' 'IDLE match1 200 s in the match from here'))
    foreach ($t in $ticks) { $l += L 'Clock' $t }
    return $l + (End-Log)
}
$first = 'TICK n=60 avg 900.0 max 3000 us (read 160.0, set 20.0 over 30 changes, log 0.0)' # menu and travel: skipped
Expect (Cost-Log @($first, 'TICK n=60 avg 80.0 max 300 us (read 30.0, set 45.0 over 60 changes, log 0.0)')) 'cost' 0 'cost: 0.08 ms passes, the first window skipped' 'avg 80.0 us without'
Expect (Cost-Log @($first, 'TICK n=60 avg 120.0 max 300 us (read 30.0, set 45.0 over 60 changes, log 0.0)')) 'cost' 1 'cost: 0.12 ms fails' 'FAIL: read tick cost'
Expect ((Cost-Log @($first, 'TICK n=60 avg 80.0 max 300 us (read 30.0, set 45.0 over 60 changes, log 0.0)')) + (L 'Clock' 'DEBUG SHOW 06:31')) 'cost' 1 'cost: DEBUG lines present fails'
Expect (Cost-Log @()) 'cost' 1 'cost: no TICK line fails'
Expect ((Cost-Log @($first, 'TICK n=60 avg 80.0 max 300 us (read 0.0, set 0.0 over 60 changes, log 0.0)')) | Where-Object { $_ -notmatch 'ui attach' }) 'cost' 0 'cost: no attach line (DEBUG-only in core) is soft' 'warn: .*ui attach'
Expect ((Cost-Log @($first, 'TICK n=60 avg 80.0 max 300 us (read 0.0, set 0.0 over 60 changes, log 0.0)')) + (L 'Clock' "ui attach left 'clock.time' pending, retried in 4 ticks (HUD appeared)")) 'cost' 1 'cost: the clock left pending fails'

# ---------------------------------------------------------------- step5
$step5 = (Start-Log) + (Running 5 'step5') + @((L 'ClockDriver' 'FREEZE match1 Animate Time of Day true -> false'), (L 'ClockDriver' 'OK CORNER match1 clock in the top-right corner'))
for ($i = 1; $i -le 10; $i++) { $step5 += L 'ClockDriver' "OK STEP5 $i set 10:02 -> shows 10:00"; $step5 += L 'ClockDriver' "OK MULT5 $i 10:00 is a multiple of 5 minutes" }
$step5 += End-Log
Expect $step5 'step5' 0 'step5: passes' 'All checks passed'
Expect ($step5 + (L 'Clock' 'DEBUG SHOW 10:07')) 'step5' 1 'step5: a shown 10:07 fails' 'not 10:07'
Expect (($step5 | Where-Object { $_ -notmatch 'READY' }) + (L 'Clock' 'READY updateEvery=1 element=clock.time')) 'step5' 1 'step5: READY updateEvery=1 fails'
Expect ($step5 | Where-Object { $_ -notmatch 'OK STEP5 10 ' }) 'step5' 1 'step5: nine STEP5 lines fail'

# ---------------------------------------------------------------- rebuild
$rebuild = (Start-Log) + (Running 1 'rebuild') + @(
    (L 'ClockDriver' 'REBUILD match1 RemoveAllWidgets (HUD /Engine/Transient.InventoryUI_C_1)'), (L 'ClockDriver' 'REBUILD match1 AddToViewport(0)'),
    (L 'Clock' "DEBUG ui attach 'clock.time' reused /Engine/Transient.WBP_NucleusText_C_1 (HUD back in the viewport)"),
    (L 'ClockDriver' 'OK ONE match1-rebuilt exactly one clock widget (found 1)'), (L 'ClockDriver' 'OK CORNER match1-rebuilt clock in the top-right corner')) + (End-Log)
Expect $rebuild 'rebuild' 0 'rebuild: passes (DEBUG attach line, core cbbca96)' 'All checks passed'
Expect ($rebuild -replace 'DEBUG ui attach', 'ui attach') 'rebuild' 0 'rebuild: an INFO attach line (older core) passes too' 'All checks passed'
Expect ($rebuild | Where-Object { $_ -notmatch "reused" }) 'rebuild' 1 'rebuild: no reuse fails'
Expect ($rebuild + (L 'Clock' "WARN text 'clock.time': removed 1 duplicate widget(s) from the HUD canvas")) 'rebuild' 1 'rebuild: a duplicate fails'

# ---------------------------------------------------------------- no-core and old-core
$noCore = @((U "Starting Lua mod 'ClockDriver'"), (L 'ClockDriver' 'SCENARIO no-core'), (U "Starting Lua mod 'Clock'"),
    (L 'Clock' 'Nucleus is not installed. Clock will not run.'), (L 'ClockDriver' 'OK NOCLOCK match1 no clock widget on the HUD for 15 s (max seen 0)')) + (End-Log)
Expect $noCore 'no-core' 0 'no-core: passes' 'All checks passed'
Expect $noCore 'no-core' 0 'vm no-core: passes' 'All checks passed' 'vm'
Expect ($noCore + (L 'Clock' 'READY updateEvery=1 element=clock.time')) 'no-core' 1 'no-core: a second [Clock] line fails'
Expect ($noCore | Where-Object { $_ -notmatch 'NOCLOCK' }) 'no-core' 1 'no-core: no NOCLOCK fails'

$oldCore = (Start-Log) + @((L 'ClockDriver' "OLDCORE published nucleus.version=0.1.0 (from Nucleus's installed mod.json)"),
    (L 'Clock' 'ERROR Nucleus 0.1.0 is not compatible; Clock needs 0.2.0 (^ rules). Update Nucleus. Clock will not run.'),
    (L 'ClockDriver' 'OK NOCLOCK match1 no clock widget on the HUD for 15 s (max seen 0)')) + (End-Log)
Expect $oldCore 'old-core' 0 'old-core: passes' 'All checks passed'
Expect ($oldCore + (L 'Clock' 'ERROR start failed: x')) 'old-core' 1 'old-core: a second [Clock] line fails'
Expect ($oldCore -replace 'needs 0\.2\.0', 'needs 0.1.0') 'old-core' 1 'old-core: the wrong need fails'

# ---------------------------------------------------------------- measure
$measure = (Start-Log) + @((L 'ClockDriver' 'SCENARIO measure'), (L 'ClockDriver' 'SKIES match1 n=1 first=/Game/Maps/X'), (L 'ClockDriver' 'SKIES match2 n=1 first=/Game/Maps/X'),
    (L 'ClockDriver' 'MEASURE hook /Game/UltraDynamicSky/Blueprints/Ultra_Dynamic_Sky.Ultra_Dynamic_Sky_C:Check for Time Event Dispatchers ok=true '))
foreach ($sp in @(@('Fast', 1.5), @('Normal', 1.0), @('Long', 0.5))) {
    for ($s = 0; $s -lt 20; $s++) {
        $tod = 2390 + $s * 0.5 * $sp[1]
        if ($tod -ge 2400) { $tod -= 2400 }
        $h = [math]::Floor($tod / 100); $m = [math]::Floor(($tod / 100 - $h) * 60)
        $measure += L 'ClockDriver' ("MEASURE sample speed={0} t={1:F3} tod={2:F4} hms={3}:{4}:0 map={5:D2}:{6:D2}" -f $sp[0], $s, $tod, $h, $m, [int]$h, [int]$m)
    }
}
$measure += L 'ClockDriver' 'MEASURE minute-event t=1.000 eventMinute=5 tod=1000.000 hms=10:0:0'
$measure += L 'ClockDriver' 'MEASURE wrap t=0.000 tod=2399.0000 hms=23:54:0 days=0'
$measure += End-Log
$r = Run $measure 'measure'
if ($r.Code -eq 0 -and $r.Out -match 'MEASURE Normal: 20 samples, 0\.5000 Time of Day units/s, 3\.33 real s per game minute, jumps=0, map samples=20 differing=0') { $script:passed++ }
else { $script:failed++; Write-Host "FAIL measure: summary"; Write-Host $r.Out }
Expect ($measure | Where-Object { $_ -notmatch 'speed=Long' }) 'measure' 1 'measure: no Long samples fails'

# ---------------------------------------------------------------- hand
$hand = (Start-Log) + @((L 'Clock' 'CONNECT ok Nucleus 0.2.0 (pong 0.2.0 boot=1)'), (L 'Clock' 'READY updateEvery=1 element=clock.time'),
    (L 'Clock' "ui attach 'clock.time' created /Engine/Transient.WBP_NucleusText_C_1 (HUD appeared)"), (L 'Clock' 'VISIBLE 07:42 (updateEvery=1)'),
    (L 'Clock' 'HIDDEN no sky'), (L 'Clock' 'VISIBLE 06:00 (updateEvery=1)'))
Expect $hand 'hand' 0 'hand: passes' 'All checks passed'
Expect ($hand + (L 'Clock' 'ERROR boom')) 'hand' 1 'hand: an ERROR fails'

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("check_test: {0} passed, {1} failed" -f $script:passed, $script:failed)
exit $(if ($script:failed) { 1 } else { 0 })

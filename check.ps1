<#
.SYNOPSIS
  Judges one run of the clock from UE4SS.log.
.DESCRIPTION
  Prints the clock's, the driver's and UE4SS's relevant lines, then checks the patterns the scenario needs.
  A pattern must match somewhere; "!pattern" must match nowhere; "#N|pattern" must match exactly N lines;
  "?pattern" is a soft check (reported as "warn:", never failing); "?!pattern" is a soft check that it matches nowhere.
  Then the scenario's computed checks: READY after CONNECT ok, the read-tick cost (story 3 AC 5: average under
  0.1 ms per tick), every shown value a multiple of updateEvery, and for measure, a summary of story 2 part A.
  Exit code 1 when any check fails; otherwise prints "All checks passed."
  Scenarios: match, step5, rebuild, no-core, old-core, measure (run.ps1 drives them), and hand (a log from the
  README's hand check: only that the clock connected, showed a time and logged no error). unit needs no log: it runs
  test.ps1 (story 2 AC 2's pure tests and the rest of the unit tests).
  -Target vm judges a log from run.ps1 -Target vm. The VM's game shares the CPU with the host, so the one timing
  assertion inside the functional scenarios, "no hud slow tick in steady state" (core's WARN under the clock's tag),
  is a soft check there; the read-tick cost is already soft outside cost. measure and cost are refused (host-only).
.EXAMPLE
  ./check.ps1 -Log C:\...\nuclear-nightmare\dumps\v8.1.2-build26193463\clock\match.log -Scenario match
  ./check.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Scenario hand
  ./check.ps1 -Log C:\...\nuclear-nightmare\dumps\v8.1.2-build26193463\clock\match.vm.log -Scenario match -Target vm
#>
param(
    [string] $Instance,
    [string] $Log,
    [ValidateSet('match', 'step5', 'rebuild', 'no-core', 'old-core', 'measure', 'cost', 'hand', 'unit')]
    [string] $Scenario = 'match',
    [ValidateSet('host', 'vm')] [string] $Target = 'host'
)
if ($Target -eq 'vm' -and $Scenario -in 'measure', 'cost') { Write-Host "FAIL: $Scenario judges timing and is valid only on the host (run.ps1 without -Target vm)."; exit 1 }
if ($Scenario -eq 'unit') { & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'test.ps1'); exit $LASTEXITCODE }
$CoreName = 'Nucleus'
$CoreId = 'nuclearnightmare-community.nucleus'
$manifest = Get-Content (Join-Path $PSScriptRoot 'mod.json') -Raw | ConvertFrom-Json
$name = $manifest.name
$C = [regex]::Escape($name); $D = [regex]::Escape("${name}Driver"); $K = [regex]::Escape($CoreName)
$needVer = ($manifest.dependsOn | Where-Object id -eq $CoreId).version
$NeedRx = [regex]::Escape($needVer)
if (-not $Log) {
    if (-not $Instance) { Write-Host 'FAIL: pass -Log <file> or -Instance <copy>'; exit 1 }
    $Log = Join-Path (Resolve-Path $Instance) 'NuclearNightmare\Binaries\Win64\ue4ss\UE4SS.log'
}
if (-not (Test-Path $Log)) { Write-Host "FAIL: no log at $Log"; exit 1 }

$lines = @(Get-Content $Log)
Write-Host "--- $name lines ($Scenario) ---"
$lines | Where-Object {
    ($_ -match "\[$C\]|\[$D\]" -and $_ -notmatch "\[$D\] MEASURE sample|\[$C\] (DEBUG )?(SHOW|TICK|hud)") -or
    $_ -match 'Error executing script|threw an exception|removing hook|Unhandled Exception|stack traceback|\[script_hook\]'
} | ForEach-Object { $_ -replace '^\[[^\]]+\]\s*', '' -replace '^\[Lua\]\s*', '' }

$always = @(
    '!Unhandled Exception'
    '!Error executing script'
    '!removing hook'
    '!stack traceback'
    '!\[script_hook\]'
    '!A function requiring userdata as param #1 was called without userdata'
    "!\[$D\] FAIL "
    "!\[$D\] .*STEP '.*' threw"
)
$every = if ($Scenario -eq 'step5') { 5 } else { 1 }
$running = @(
    "\[$C\] CONNECT ok $K \d+\.\d+\.\d+ "
    "#1|\[$C\] READY updateEvery=$every element=clock\.time\s*$"
    "\[$C\] VISIBLE \d\d:\d\d \(updateEvery=$every\)"
    # Core logs attaches at DEBUG since Nucleus cbbca96 (INFO only for an element left pending), so the line shows only
    # with the clock's DEBUG lines on (deploy -Test); soft. A pending clock element would be an INFO line: never.
    "?\[$C\] (DEBUG )?ui attach (.*, )?'clock\.time' (created|reused) "
    "!\[$C\] ui attach left .*'clock\.time'"
    "!\[$C\] ERROR"
    # Core's UI helpers log with the clock's tag; a slow tick while handling a HUD event is core's to judge (soft).
    # In the VM (-Target vm) every slow tick is soft: the VM's game shares the CPU with the host.
    $(if ($Target -eq 'vm') { "!\[$C\] WARN (?!hud slow tick )" } else { "!\[$C\] WARN (?!hud slow tick .*(HUD event|steady state, a Lua GC step ran inside it))" })
    "?!\[$C\] WARN hud slow tick .*HUD event"
    "?!\[$C\] WARN hud slow tick .*steady state, a Lua GC step"
)
if ($Target -eq 'vm') { $running += "?!\[$C\] WARN hud slow tick .*steady state\)" }
$driven = $running + @(
    "\[$D\] SCENARIO $([regex]::Escape($Scenario))\s*$"
    "\[$D\] END result=PASS"
    "\[$C\] DEBUG SHOW \d\d:\d\d\s*$"
    # Lua's conversion checked against the sky's own Time Of Day to H/M/S, once per sky.
    "\[$C\] VERIFY \d+\.\d+ -> \d\d:\d\d, the same as 'Time Of Day to H/M/S'"
)
$expect = @{
    'match' = $driven + @(
        "\[$D\] OK NOTDRAWN menu1 ", "\[$D\] OK NOTDRAWN menu2 "
        "\[$D\] OK ONE match1 exactly one", "\[$D\] OK FORMAT match1 ", "\[$D\] OK MATCHES match1 ", "\[$D\] OK CORNER match1 "
        "#2|\[$D\] OK CHANGED match1 "
        "\[$D\] OK ONE match2 exactly one", "\[$D\] OK FORMAT match2 ", "\[$D\] OK MATCHES match2 ", "\[$D\] OK CORNER match2 "
        "\[$D\] OK CHANGED match2 "
        "\[$D\] OK SKYWORLD match1 ", "\[$D\] OK SKYWORLD match2 "
        # A few minutes idle in match 2 (read-tick cost, story 3 AC 5); the clock still follows the sky after it.
        "\[$D\] IDLE match2 ", "\[$D\] OK ONE match2-idle ", "\[$D\] OK MATCHES match2-idle "
        "\[$C\] DEBUG TICK n=\d+ avg "
    )
    'step5' = $driven + @(
        "\[$D\] FREEZE match1 "
        "#10|\[$D\] OK STEP5 \d+ "
        "#10|\[$D\] OK MULT5 \d+ "
        "\[$D\] OK CORNER match1 "
    )
    'rebuild' = $driven + @(
        "\[$D\] REBUILD match1 RemoveAllWidgets"
        "\[$D\] REBUILD match1 AddToViewport"
        "\[$D\] OK ONE match1-rebuilt exactly one clock widget \(found 1\)"
        "\[$D\] OK CORNER match1-rebuilt "
        "\[$C\] (DEBUG )?ui attach (.*, )?'clock\.time' reused .*\(HUD back in the viewport\)"
    )
    'no-core' = @(
        "#1|\[$C\] "
        "\[$C\] $K is not installed\. $C will not run\.\s*$"
        "\[$D\] OK NOCLOCK match1 "
        "\[$D\] END result=PASS"
    )
    'old-core' = @(
        "#1|\[$C\] "
        "\[$D\] OLDCORE published $($K.ToLowerInvariant())\.version=0\.1\.0 "
        "\[$C\] ERROR $K 0\.1\.0 is older than $C needs \($NeedRx\)\. Update $K\. $C will not run\.\s*$"
        "\[$D\] OK NOCLOCK match1 "
        "\[$D\] END result=PASS"
    )
    'measure' = @(
        "\[$D\] MEASURE hook .* ok=true"
        "\[$D\] MEASURE sample speed=Fast ", "\[$D\] MEASURE sample speed=Normal ", "\[$D\] MEASURE sample speed=Long "
        "\[$D\] MEASURE wrap "
        "\[$D\] SKIES match1 ", "\[$D\] SKIES match2 "
        "\[$D\] END result=PASS"
        "?\[$D\] MEASURE minute-event "
    )
    'hand' = $running
    # Diagnostic: what each engine call of a clock read costs (COST lines); only that the probe ran.
    # What each engine call of a clock read costs (COST lines), then the clock as a normal install runs it (no DEBUG
    # lines; dev.lua profile = true logs only the TICK cost lines) through a few idle minutes in a match.
    'cost' = $running + @(
        "\[$D\] COST match1 all of time.read's calls avg ", "\[$D\] IDLE match1 ", "\[$D\] END result=PASS"
        "\[$C\] TICK n=\d+ avg ", "!\[$C\] DEBUG SHOW "
    )
}

$failed = 0
$warned = 0
function Fail([string] $label) { Write-Host "FAIL: $label"; $script:failed++ }
function Pass([string] $label) { Write-Host "ok:   $label" }
Write-Host "--- checks ($Scenario) ---"
foreach ($pattern in ($always + $expect[$Scenario])) {
    if ($pattern.StartsWith('#')) {
        $count, $p = $pattern.Substring(1) -split '\|', 2
        $hits = @($lines | Where-Object { $_ -match $p }).Count
        if ($hits -eq [int]$count) { Pass "$pattern (found $hits)" } else { Fail "$pattern (found $hits)" }
    } elseif ($pattern.StartsWith('?!')) {
        if ($lines | Where-Object { $_ -match $pattern.Substring(2) }) { Write-Host "warn: $pattern"; $warned++ } else { Pass $pattern }
    } elseif ($pattern.StartsWith('?')) {
        if ($lines | Where-Object { $_ -match $pattern.Substring(1) }) { Pass $pattern } else { Write-Host "warn: $pattern"; $warned++ }
    } elseif ($pattern.StartsWith('!')) {
        if ($lines | Where-Object { $_ -match $pattern.Substring(1) }) { Fail $pattern } else { Pass $pattern }
    } else {
        if ($lines | Where-Object { $_ -match $pattern }) { Pass $pattern } else { Fail $pattern }
    }
}

function IndexOf([string] $p) { for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $p) { return $i } } return -1 }

if ($Scenario -in 'match', 'step5', 'rebuild', 'hand') {
    # Story 1 AC 1: READY after CONNECT ok.
    $ic, $ir = (IndexOf "\[$C\] CONNECT ok "), (IndexOf "\[$C\] READY ")
    if ($ic -ge 0 -and $ir -gt $ic) { Pass 'READY comes after CONNECT ok' } else { Fail "READY comes after CONNECT ok (CONNECT at line $ic, READY at line $ir)" }
}
if ($Scenario -in 'match', 'step5', 'rebuild', 'cost') {
    # Story 3 AC 5: a read tick averages under 0.1 ms. Each DEBUG TICK line covers n ticks; "log" is the time spent
    # writing the DEBUG SHOW lines themselves, which a normal install (no debug) doesn't do, so it's left out.
    $ticks = @($lines | Where-Object { $_ -match "\[$C\] (DEBUG )?TICK n=\d+ avg " } | ForEach-Object {
        [void]($_ -match "n=(\d+) avg ([\d.]+) max (\d+) us(?: \(read ([\d.]+), set ([\d.]+) over (\d+) changes, log ([\d.]+)\))?")
        [pscustomobject]@{ N = [int]$Matches[1]; Avg = [double]$Matches[2]; Max = [int]$Matches[3]
            Read = [double]$Matches[4]; Set = [double]$Matches[5]; Log = [double]$Matches[7] } })
    # The first window covers the menu, the travel and the first FindFirstOf scans: steady state starts after it.
    if ($ticks.Count -gt 1) { $ticks = @($ticks | Select-Object -Skip 1) }
    if ($ticks.Count) {
        $total = ($ticks | Measure-Object N -Sum).Sum
        $w = { param($f) (($ticks | ForEach-Object { $_.N * (& $f $_) }) | Measure-Object -Sum).Sum / $total }
        $avg = & $w { param($t) $t.Avg }; $log = & $w { param($t) $t.Log }
        $read = & $w { param($t) $t.Read }; $set = & $w { param($t) $t.Set }
        $max = ($ticks | Measure-Object Max -Maximum).Maximum
        $label = "read tick cost over $total ticks: avg {0:N1} us without the DEBUG lines (target < 100; read {1:N1}, set {2:N1}; with them {3:N1}), max $max us" -f ($avg - $log), $read, $set, $avg
        # Judged hard only in cost, which runs the clock as installed: elsewhere the DEBUG SHOW lines (about 300 us
        # each) run inside the same ticks and slow the rest of them down too.
        if ($avg - $log -lt 100) { Pass $label } elseif ($Scenario -eq 'cost') { Fail $label } else { Write-Host "warn: $label (judged in the cost scenario)"; $warned++ }
        if ($max -gt 1000) { Write-Host "warn: a read tick took $max us (over 1 ms; includes DEBUG lines and any Lua GC step)"; $warned++ }
    }
}
if ($Scenario -in 'match', 'step5', 'rebuild') {
    # Every shown value is a multiple of updateEvery minutes (step5: of 5).
    $shown = @($lines | Where-Object { $_ -match "\[$C\] DEBUG SHOW (\d\d):(\d\d)\s*$" } | ForEach-Object { [void]($_ -match 'SHOW (\d\d):(\d\d)\s*$'); "$($Matches[1]):$($Matches[2])" })
    $bad = @($shown | Where-Object { [int]$_.Substring(3) % $every -ne 0 -or [int]$_.Substring(0, 2) -gt 23 })
    $label = "every shown value ($($shown.Count)) is a valid HH:MM on a multiple of $every minutes$(if ($bad) { ': not ' + ($bad -join ', ') })"
    if ($shown.Count -and -not $bad) { Pass $label } else { Fail $label }
    # No value shown twice in a row: the text changes only when the boundary does.
    $repeats = 0
    for ($i = 1; $i -lt $shown.Count; $i++) { if ($shown[$i] -eq $shown[$i - 1]) { $repeats++ } }
    # A repeat is legitimate only right after a reset (no sky, or a new match at the same minute); report, don't fail.
    if ($repeats) { Write-Host "warn: $repeats SHOW value(s) repeated the previous one (expected only after a hide)"; $warned++ }
}
if ($Scenario -eq 'measure') {
    # Story 2 part A, question 1: real seconds per game minute at each speed, from a straight-line fit of Time of Day
    # (100 units per hour) over the samples' real time. Question 3: the map's text against the sky's H/M/S.
    foreach ($speed in 'Fast', 'Normal', 'Long') {
        $pts = @($lines | Where-Object { $_ -match "MEASURE sample speed=$speed t=([\d.]+) tod=([\d.\-]+) hms=(\d+):(\d+):\d+ map=(.*)$" } | ForEach-Object {
            [void]($_ -match "t=([\d.]+) tod=([\d.\-]+) hms=(\d+):(\d+):\d+ map=(.*)$")
            [pscustomobject]@{ T = [double]$Matches[1]; Tod = [double]$Matches[2]; H = [int]$Matches[3]; M = [int]$Matches[4]; Map = $Matches[5].Trim() } })
        if ($pts.Count -lt 10) { Fail "MEASURE $speed has only $($pts.Count) samples"; continue }
        # Unwrap across 2400 so the fit stays a line.
        $off = 0.0; $prev = $pts[0].Tod; $xs = @(); $ys = @()
        foreach ($p in $pts) { if ($p.Tod -lt $prev - 1200) { $off += 2400 }; $prev = $p.Tod; $xs += $p.T; $ys += ($p.Tod + $off) }
        $mx = ($xs | Measure-Object -Average).Average; $my = ($ys | Measure-Object -Average).Average
        $sxy = 0.0; $sxx = 0.0
        for ($i = 0; $i -lt $xs.Count; $i++) { $sxy += ($xs[$i] - $mx) * ($ys[$i] - $my); $sxx += ($xs[$i] - $mx) * ($xs[$i] - $mx) }
        $slope = if ($sxx) { $sxy / $sxx } else { 0 }            # Time of Day units per real second
        $secPerMin = if ($slope -gt 0) { (100 / 60) / $slope } else { [double]::PositiveInfinity }
        $jumps = 0
        for ($i = 1; $i -lt $ys.Count; $i++) { $delta = $ys[$i] - $ys[$i - 1]; if ($delta -lt 0 -or ($slope -gt 0 -and $delta -gt 5 * $slope * ($xs[$i] - $xs[$i - 1]) + 1)) { $jumps++ } }
        $withMap = @($pts | Where-Object { $_.Map -match '^\d\d:\d\d$' })
        $mapDiff = @($withMap | Where-Object { $_.Map -ne ('{0:D2}:{1:D2}' -f $_.H, $_.M) })
        Write-Host ("MEASURE {0}: {1} samples, {2:N4} Time of Day units/s, {3:N2} real s per game minute, jumps={4}, map samples={5} differing={6}" -f
            $speed, $pts.Count, $slope, $secPerMin, $jumps, $withMap.Count, $mapDiff.Count)
    }
    $events = @($lines | Where-Object { $_ -match 'MEASURE minute-event ' })
    Write-Host "MEASURE minute events: $($events.Count) (question 2: one per game minute, no bursts; compare with the samples above)"
    $wrap = @($lines | Where-Object { $_ -match 'MEASURE wrap t=' })
    if ($wrap) { Write-Host "MEASURE wrap: first $($wrap[0] -replace '^.*MEASURE wrap ', '') | last $($wrap[-1] -replace '^.*MEASURE wrap ', '')" }
}

if ($failed) { Write-Host "$failed check(s) failed."; exit 1 }
Write-Host ("All checks passed{0}." -f $(if ($warned) { " ($warned soft check(s) not met)" } else { '' }))

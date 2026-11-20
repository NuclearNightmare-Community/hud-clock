<#
.SYNOPSIS
  Installs the clock into a dev copy of Nuclear Nightmare, or removes it.
.DESCRIPTION
  Refuses (exit 1, one line) unless Nucleus (core) is installed in the copy, enabled in mods.txt, and its installed
  mod.json version satisfies the clock's dependsOn (a minimum, not below the installed core's compat.floor;
  deploy-lib.ps1). -Force installs anyway, for the failure scenarios
  (the clock's own runtime check then has to catch it).
  Installs ue4ss/Mods/HudClock/{mod.json, Scripts/main.lua, Scripts/time.lua}. The clock's setting lives in
  Mods/HudClock/settings.json, the values file Nucleus's settings service keeps (Nucleus 0.9.0): -UpdateEvery writes it
  ({"updateEvery":N}); without it an existing settings.json survives the redeploy untouched (it is the player's).
  Writes "HudClock : 1" into mods.txt right below Nucleus's line and above "Keybinds : 1", moving it there if it was
  elsewhere. Never writes outside Mods/HudClock, Mods/HudClockDriver and those mods.txt lines, and never bundles any of
  core's files.
  -Test also installs the test driver (test/HudClockDriver as Mods/HudClockDriver, between Nucleus and HudClock), writes the
  scenario to its Scripts/scenario.txt, and writes Scripts/dev.lua (test only) to turn on the clock's DEBUG lines
  (debug = true), which check.ps1 reads (cost: only the TICK cost lines, profile = true). With -Test, step5 implies
  -UpdateEvery 5 and every other scenario -UpdateEvery 1, so a run never inherits an earlier run's value.
  -Remove deletes Mods/HudClock, Mods/HudClockDriver and their mods.txt lines; nothing else changes (mods.txt keeps its
  bytes when it had no clock lines).
  -Staged: $Instance is the host-side staging folder of a VM run (run.ps1 -Target vm, tools/vm/vm-sp.ps1), not a game
  copy; only the running-game check is skipped (no game runs from it, and the host's game may be in use meanwhile).
  Pass the main checkout's instance path when running from a worktree.
.EXAMPLE
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -UpdateEvery 5
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Test -Scenario match
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Remove
#>
param(
    [Parameter(Mandatory)] [string] $Instance,
    [switch] $Test,
    [ValidateSet('match', 'step5', 'rebuild', 'no-core', 'old-core', 'measure', 'cost', 'speed', 'pair-client')]
    [string] $Scenario = 'match',
    [ValidateRange(0, 60)] [int] $UpdateEvery = 0,  # 0: mod.json's default
    [switch] $Force,
    [switch] $Remove,
    [switch] $Staged
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deploy-lib.ps1')

$CoreId   = 'nuclearnightmare-community.nucleus' # core's mod id (distribution story 13, mod-ids.md)
$CoreName = 'Nucleus' # core's folder and mods.txt name: the one place this script spells it
$here     = $PSScriptRoot
$manifest = Get-Content (Join-Path $here 'mod.json') -Raw | ConvertFrom-Json
$name     = $manifest.name
$driver   = "${name}Driver"
$inst     = (Resolve-Path $Instance).Path
$win64    = Join-Path $inst 'NuclearNightmare\Binaries\Win64'
$ue4ss    = Join-Path $win64 'ue4ss'
$modsDir  = Join-Path $ue4ss 'Mods'
$modsTxt  = Join-Path $modsDir 'mods.txt'

function Stop-Deploy([string] $why) { Write-Host "$name not deployed: $why"; exit 1 }

if (-not (Test-Path (Join-Path $win64 'NuclearNightmare-Win64-Shipping.exe'))) { Stop-Deploy "not a game instance: $inst" }
if (-not (Test-Path (Join-Path $ue4ss 'UE4SS.dll'))) { Stop-Deploy "UE4SS is not installed in $win64" }
if (-not (Test-Path $modsTxt)) { Stop-Deploy "no mods.txt in $modsDir" }
if (-not $Staged -and (Get-Process -Name 'NuclearNightmare*' -ErrorAction SilentlyContinue)) { Stop-Deploy 'Nuclear Nightmare is running; close it first.' }

$file  = Read-ModsTxt $modsTxt
$mine  = @($name, $driver)
$clean = Edit-ModsTxt -Lines $file.Lines -Remove $mine

if ($Remove) {
    foreach ($d in $mine) { Remove-Item (Join-Path $modsDir $d) -Recurse -Force -ErrorAction SilentlyContinue }
    if ($clean.Count -ne $file.Lines.Count) { Write-ModsTxt $modsTxt $file $clean }
    Write-Host "$name removed (and $driver, if it was installed)."
    return
}

# Core: installed, enabled, and a version the clock's dependsOn accepts.
$dep = @($manifest.dependsOn | Where-Object { $_.id -is [string] -and $_.id.ToLowerInvariant() -eq $CoreId })[0]
if (-not $dep) { throw "mod.json has no dependsOn entry for $CoreId" }
$coreJson = Join-Path $modsDir "$CoreName\mod.json"
$problem = $null
if (-not (Test-Path $coreJson)) {
    $problem = "$CoreName is not installed in $modsDir (no $CoreName\mod.json); install it first with its own deploy.ps1."
} else {
    $core = $null
    try { $core = Get-Content $coreJson -Raw | ConvertFrom-Json } catch { }
    $state = Get-ModsTxtState -Lines $clean -Name $CoreName
    $floor = $null
    try { $floor = $core.compat.floor } catch { }
    $fit = if ($core) { Test-VersionNeed -Version $core.version -Need $dep.version -Floor $floor }
    if (-not $core -or $core.id -ne $dep.id) {
        $problem = "$coreJson is not $CoreName's manifest (id '$($core.id)', expected '$($dep.id)')."
    } elseif ($fit -in 'core-too-old', 'bad-have') {
        $problem = "$CoreName $($core.version) is installed, but $name needs $($dep.version); update $CoreName."
    } elseif ($fit -eq 'mod-too-old') {
        $problem = "$name was made for $CoreName $($dep.version), which this $CoreName $($core.version) no longer supports (oldest: $floor); update $name."
    } elseif ($state -ne 'enabled') {
        $problem = "$CoreName is installed but $state in mods.txt; enable it ('$CoreName : 1', its first line)."
    }
}
if ($problem) {
    if (-not $Force) { Stop-Deploy $problem }
    Write-Warning "forced: $problem"
}

# The clock's files. Its setting: settings.json from -UpdateEvery, else the existing one kept as it was.
$override = @{}
if ($Test -and $UpdateEvery -eq 0) { $UpdateEvery = if ($Scenario -eq 'step5') { 5 } else { 1 } }
if ($UpdateEvery -gt 0) { $override.updateEvery = $UpdateEvery }
$settingsJson = ConvertTo-SettingsJson -Manifest $manifest -Override $override
# cost measures the clock as a normal install runs it: no DEBUG lines, only the TICK cost lines.
$dev = if ($Test) { ConvertTo-DevLua -DebugLog:($Scenario -ne 'cost') -Profile:($Scenario -eq 'cost') }
$valuesFile = Join-Path $modsDir "$name\settings.json"
$keptValues = if (-not $settingsJson -and (Test-Path -LiteralPath $valuesFile -PathType Leaf)) { [IO.File]::ReadAllBytes($valuesFile) }
foreach ($d in $mine) { Remove-Item (Join-Path $modsDir $d) -Recurse -Force -ErrorAction SilentlyContinue }
$dest = Join-Path $modsDir "$name\Scripts"
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $here 'mod.json') (Join-Path $modsDir $name) -Force
foreach ($f in $ModScripts) { Copy-Item (Join-Path $here "Scripts\$f") $dest -Force }
if ($dev) { [IO.File]::WriteAllText((Join-Path $dest 'dev.lua'), $dev, [Text.UTF8Encoding]::new($false)) }
if ($settingsJson) { [IO.File]::WriteAllText($valuesFile, $settingsJson, [Text.UTF8Encoding]::new($false)) }
elseif ($keptValues) { [IO.File]::WriteAllBytes($valuesFile, $keptValues) }

# mods.txt: below core, above Keybinds. The driver goes between core and the clock (its old-core mode must run
# before the clock's main.lua).
$add = @($name)
if ($Test) {
    Copy-Item (Join-Path $here 'test\HudClockDriver') (Join-Path $modsDir $driver) -Recurse -Force
    foreach ($f in 'scenario.txt', 'request.txt', 'done.txt') { Remove-Item (Join-Path $modsDir "$driver\Scripts\$f") -ErrorAction SilentlyContinue }
    [IO.File]::WriteAllText((Join-Path $modsDir "$driver\Scripts\scenario.txt"), $Scenario)
    $add = @($driver, $name)
}
$lines = Edit-ModsTxt -Lines $clean -Add $add -After $CoreName
Write-ModsTxt $modsTxt $file $lines

Write-Host "$name $($manifest.version) deployed$(if ($Test) { " with $driver (scenario $Scenario)" }):"
Get-ChildItem (Join-Path $modsDir $name) -Recurse -File | ForEach-Object { Write-Host "  Mods/$name/$($_.FullName.Substring((Join-Path $modsDir $name).Length + 1)) ($($_.Length) bytes)" }
Write-Host "  settings.json: $(if ($settingsJson) { "$settingsJson (written)" } elseif ($keptValues) { 'kept as it was' } else { "none (Nucleus uses mod.json's defaults)" })"
Write-Host "mods.txt: $(($lines | Where-Object { $_ -match '^\s*[\w-]+\s*:\s*1' }) -join ', ')"

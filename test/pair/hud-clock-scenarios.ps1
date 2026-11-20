<#
.SYNOPSIS
  HudClock's two-player scenario for tools/vm/pair.ps1 (the workspace's pair tooling): the clock on a client, whose sky
  is a replicated copy (clock story 5).
.DESCRIPTION
  A -ScenarioFile for pair.ps1: dot-sourced by it after its own pair-scenarios.ps1, in the same shape, and adds
  clock-client to its $PairScenarios (the last lines of this file).
    clock-client  B (VM, client) = Nucleus + HudClockDriver "pair-client" + HudClock: once in the host's match, B samples its
                  clock's text and its own sky every 50 ms for 120 s (PAIRSUM). The host replicates Time of Day once a
                  second and B's OnRep snaps to it with no smoothing, so B's sky can step back a little; the clock
                  holds back a step back of 1-2 minutes, so B's text must never go back.
                  A (host) = unmodded (PairDriver and JoinLog only, pair.ps1's own).
  Friends-only lobbies only (AGENTS.md "Networking"): pair.ps1's PairDriver creates them and stops the run if the
  flags ever say otherwise. The clock and its driver send nothing and read only B's own state.
  Judging: check.ps1 -Scenario pair-client -Target vm on the VM log.
.EXAMPLE
  # from the workspace's main checkout (Nucleus built: mods/Nucleus/build.ps1; no game running on the host; the VM lock taken):
  ./tools/vm/pair.ps1 -Scenario clock-client -ScenarioFile mods/hud-clock/test/pair/hud-clock-scenarios.ps1
  # after an aborted run: both games closed, host and VM copies put back
  ./tools/vm/pair.ps1 -Stop -Scenario clock-client -ScenarioFile mods/hud-clock/test/pair/hud-clock-scenarios.ps1
#>

$script:ClockRepo = Split-Path (Split-Path $PSScriptRoot)
$script:ClockNucleusPackage = Join-Path $MainCheckout 'mods\Nucleus\build\package'

# The clock and its driver (role in scenario.txt) staged by the clock's own deploy.ps1 -Test -Staged into a fake copy
# holding Nucleus's package, exactly what a deploy installs. Returns the staged folders: @{ HudClock; Driver; Core }.
function Get-ClockStage {
    if (-not (Test-Path (Join-Path $ClockNucleusPackage 'Mods\Nucleus\mod.json'))) { throw "No Nucleus package at $ClockNucleusPackage; build it with mods/Nucleus/build.ps1 (not while a game runs)." }
    $stage = Join-Path ([IO.Path]::GetTempPath()) 'nn-hud-clock-stage-pair-client'
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    $win64 = Join-Path $stage 'NuclearNightmare\Binaries\Win64'
    $mods = Join-Path $win64 'ue4ss\Mods'
    New-Item -ItemType Directory -Force $mods | Out-Null
    Set-Content (Join-Path $win64 'NuclearNightmare-Win64-Shipping.exe') 'stage'
    Set-Content (Join-Path $win64 'ue4ss\UE4SS.dll') 'stage'
    Copy-Item (Join-Path $ClockNucleusPackage 'Mods\Nucleus') $mods -Recurse
    [IO.File]::WriteAllText((Join-Path $mods 'mods.txt'), "Nucleus : 1`r`nKeybinds : 1`r`n")
    $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $ClockRepo 'deploy.ps1') -Instance $stage -Test -Scenario 'pair-client' -Staged 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "HudClock's deploy.ps1 failed in the stage: $out" }
    @{ HudClock = Join-Path $mods 'HudClock'; Driver = Join-Path $mods 'HudClockDriver'; Core = $ClockNucleusPackage }
}

$script:ClockPairScenarios = @{
    'clock-client' = @{
        Summary = 'HudClock on a client (story 5): B (VM, modded) samples its clock text and its replicated sky every 50 ms for 120 s; the text must never step back (the 1-2 minute hold-back), A (host) unmodded'
        VMSetup = {
            $s = Get-ClockStage
            Restore-VMBaseline
            Invoke-VMDeploy -UE4SS On
            # Order matters: Nucleus first, then the driver, then the clock (vm-deploy adds each above Keybinds in turn).
            & (Join-Path $Workspace "tools/vm/vm-deploy.ps1") -Path $s.Core -First
            Invoke-VMDeploy -Path $s.Driver, $s.HudClock
        }
        VMRestore = {
            # The baseline (UE4SS off, no mods) is restored even if staging or the removal fails.
            try {
                $s = Get-ClockStage
                Invoke-VMDeploy -Remove -Path $s.HudClock, $s.Driver, $s.Core
            } finally { Restore-VMBaseline }
        }
        AfterJoin = {
            Save-ShotAt -Seconds 60 -Name 'clock' -Expect 'B in the match with the clock (HH:MM) in the HUD''s top-right corner'
        }
        PlaySec = 240; LobbyMinutes = 1
        Check = {
            if ($result -and -not $result.Joined) { return [ordered]@{ Verdict = 'FAIL'; Note = "not judged: B never joined (pair outcome: $($result.Outcome))" } }
            if (-not ($vmLogPath -and (Test-Path $vmLogPath))) { return [ordered]@{ Verdict = 'FAIL'; Note = "no VM log ($vmLogPath)" } }
            $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $ClockRepo 'check.ps1') -Log $vmLogPath -Scenario 'pair-client' -Target vm 2>&1 | Out-String
            [ordered]@{
                Verdict = $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' })
                Pair = @($out -split "`r?`n" | Where-Object { $_ -match 'PAIR|PAIRSUM' })
                Failures = @($out -split "`r?`n" | Where-Object { $_ -match '^FAIL' })
            }
        }
    }
}

# Into pair.ps1's table (it checks that no built-in scenario is replaced); a test may dot-source this file without it.
if ($script:PairScenarios -is [hashtable]) { foreach ($k in $ClockPairScenarios.Keys) { $script:PairScenarios[$k] = $ClockPairScenarios[$k] } }

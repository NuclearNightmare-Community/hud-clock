# HUD Clock

A Nuclear Nightmare mod that shows the in-game time as `HH:MM` (24-hour, the Journal map's format) in the HUD's top-right corner during a match, so you don't have to open the Journal to see it. It's the first mod built on **Nucleus** (core): it connects to core and puts its text on the HUD through core's UI helpers. Spec: `_bmad-output/specs/spec-clock-v1/` in the workspace.

- Scope `client`: each player runs it for themselves. It reads the time from the game's own sky (the replicated copy on a client), sends nothing over the network and reads nothing from other players.
- Version 0.3.0, built for game V8.2.3 (build 26601774) and UE4SS `v3.0.1-1181-g83330635`. Needs Nucleus `>=0.9.0` (0.9.0, the first core with the settings service, or newer). The `>=` form is read by Nucleus 0.5.0 and newer (core story 18); an older core refuses it.
- License: MIT (`LICENSE`); changes: `CHANGELOG.md`; `build.ps1` stages the release package for the workspace's `tools/release/release.ps1`.

## Install

Nucleus must be installed in the dev copy first (its own `deploy.ps1`). Then, from this repo (from a worktree, pass the main checkout's instance path):

```powershell
./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2.3-build26601774
./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2.3-build26601774 -UpdateEvery 5
./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2.3-build26601774 -Remove
```

`deploy.ps1` refuses, with one line and exit code 1, when Nucleus isn't installed in the copy, is disabled in `mods.txt`, or its installed `mod.json` version doesn't satisfy `dependsOn` (`>=0.9.0`: a minimum, and not below the installed core's `compat.floor`). Otherwise it copies `mod.json` and `Scripts/` to `Mods/HudClock/`, writes `Mods/HudClock/settings.json` when `-UpdateEvery` is given (otherwise an existing `settings.json` survives the redeploy untouched), and puts `HudClock : 1` in `mods.txt` right below Nucleus's line and above `Keybinds : 1` (it moves the line there if it was elsewhere). It never bundles core's files and never writes outside `Mods/HudClock`, `Mods/HudClockDriver` and those `mods.txt` lines. `-Remove` takes all of that out again; `mods.txt` keeps its exact bytes otherwise.

Launch only with the workspace's `tools/launch.ps1 -Instance <copy>`.

## Settings

| Setting | Type | Default | Range | Changeable | Label |
|---|---|---|---|---|---|
| `updateEvery` | int | 1 | 1–60 | anytime | Update every N game minutes |

The clock shows the minute rounded down to a multiple of N (10:07 shows 10:05 with N = 5; N = 60 shows whole hours) and changes the text only when that value changes. The setting is declared in `mod.json` and kept by Nucleus's settings service (Nucleus 0.9.0) in `Mods/HudClock/settings.json` (the Mod Manager edits it later; `deploy.ps1 -UpdateEvery N` writes it for tests). The clock reads it with `core.settings.get("updateEvery")` when it starts and watches it: a change shows at the next tick, with one `SETTING updateEvery=<n>` line. If it can't be read, one `WARN` and N = 1. A release ships no settings file; Nucleus uses the default until a value is changed. Test-only flags (`debug`, `profile`) are in `Scripts/dev.lua`, which only `deploy.ps1 -Test` writes (git-ignored, never shipped); the clock reads it as text and never runs it.

## How it works

- `Scripts/main.lua`: the dependent bootstrap from core's `api-contract.md`, then `connect{ mod = "HudClock", need = ">=0.9.0" }`. In `onReady` it reads `updateEvery` and watches it (`core.settings`), creates one text element, `clock.time`, at `{ host = "hud", corner = "top-right" }`, hidden, and starts a 250 ms game-thread loop (`LoopInGameThreadWithDelay`). Each tick reads the time; when the shown value changes it sets the text, then shows the element. 250 ms is under half the shortest game minute (0.55 real s at Fast), so every minute is read at every lobby speed and the text steps by one minute (a once-a-second read skipped minutes at Fast and Normal; clock story 5). A step back of one or two shown values is held back (`time.shouldShow`): on a client the sky's once-a-second replication snap can step the time back briefly. A bigger step back (the host setting the time back) and the midnight wrap show at once. With no sky it hides the element and forgets the last value, so a new match shows its time at once. Core keeps the element attached through every HUD rebuild.
- `Scripts/time.lua`: `read()` finds the live `Ultra_Dynamic_Sky_C`, reads `Time of Day` and converts it in Lua with the sky's own formula (the decompiled `Time Of Day to H/M/S`: `Time % 2400`, `/ 100`, floor for the hour, the fraction × 60, floor for the minute), the conversion the Journal map uses too. Once per sky (each match) it checks that against the Blueprint function itself and logs `VERIFY`; if they ever disagree it uses the function from then on, with one `WARN`. (Calling the function every second cost about 100 µs a tick on V8.1.2; reading the property costs a few.) Between calls it keeps only a core weak handle to the sky and its path; `FindFirstOf` (about 120 µs) runs only when the handle no longer resolves or after a map change. `format`, `boundary`, `slot` and `shouldShow` are pure: zero-padded `HH:MM`, hours past 23 wrap to 00; `slot` numbers the shown values of a day 0, 1, 2, ... so `shouldShow` can tell a step forward (around midnight too) from a small step back.
- If core is missing, disabled, failed or too old, the log has exactly one `[HudClock]` line naming the cause (core's `connect` composes it; the bootstrap writes the "not installed" one) and the clock does nothing else.

Log lines (`UE4SS.log`): `[HudClock] CONNECT ok ...`, `[HudClock] READY updateEvery=<n> element=clock.time`, `[HudClock] VERIFY <Time of Day> -> HH:MM, the same as 'Time Of Day to H/M/S'` once per match, `[HudClock] VISIBLE <HH:MM>` when the clock appears, `[HudClock] HIDDEN no sky` when it goes away, and one `WARN` per distinct read error (the clock hides rather than show a wrong time). `[HudClock] SETTING updateEvery=<n>` when the setting changes while the game runs. With `deploy.ps1 -Test`, `Scripts/dev.lua` also turns on DEBUG lines: `DEBUG SHOW <HH:MM>` for every shown value and `DEBUG TICK n=240 avg <us> max <us> (read, set over <changes>, log)` for the read-tick cost (one line a minute). The `cost` scenario uses `profile = true` instead: only the whole-tick `TICK` line, at info level, as a normal install runs.

## Tests

### Unit tests (no game)

```powershell
./test.ps1                      # or: ./check.ps1 -Scenario unit
```

Lua tests run with any Lua 5.3/5.4 on PATH (MiKTeX's `texlua.exe` is one): `test/unit/time_test.lua` (formatting, rounding, boundaries and slots over every minute of the day for several N, `shouldShow` (same, ahead, the 1-2 step hold-back, 3 back, the midnight wrap, a forced jump), `read()` against a fake sky), `test/unit/main_test.lua` (the bootstrap, `core.settings` (read, watched change, failures; `dev.lua` never run) and the glue against a fake core and sky: create hidden, set before show, reset outside a match, one log line per failure), `test/unit/driver_test.lua` (the driver loads and ticks in every scenario). PowerShell tests: `test/unit/deploy_test.ps1` (version needs, `mods.txt` editing, `settings.json` and `dev.lua`, and `deploy.ps1` end to end against a fake instance in a temp folder) and `test/unit/check_test.ps1` (each scenario's patterns against synthetic logs, passing and failing).

### Scenarios (in game, unattended)

`run.ps1` deploys with the test driver, launches through `tools/launch.ps1`, presses Enter at touchdown (posted to the game window only), waits for the driver's `END` line (or a crash or the time limit), closes only the game under that instance, keeps the log as `dumps/<copy>/hud-clock/<scenario>.log` and runs `check.ps1` on it. Nucleus must be installed in the copy. Steam must be running, and nothing else may be running the game.

```powershell
$copy = 'C:\...\nuclear-nightmare\game-instances\v8.2.3-build26601774'
./run.ps1 -Instance $copy -Scenario match      # two matches with the menu between; time forced forward on the host
./run.ps1 -Instance $copy -Scenario step5      # updateEvery = 5; frozen sky set to chosen minutes
./run.ps1 -Instance $copy -Scenario rebuild    # RemoveAllWidgets and re-add the HUD mid-match
./run.ps1 -Instance $copy -Scenario no-core    # Nucleus moved aside: deploy refuses; forced, one [HudClock] line, no widget
./run.ps1 -Instance $copy -Scenario old-core   # Nucleus mod.json set to 0.1.0: deploy refuses; forced, one [HudClock] line
./run.ps1 -Instance $copy -Scenario cost       # cost of each engine call, then 200 s idle as installed (story 3 AC 5)
./run.ps1 -Instance $copy -Scenario speed      # text and sky every 50 ms at Fast, then Normal: steps of one minute (story 5)
./check.ps1 -Log <a kept log> -Scenario match  # judge a kept log again
```

| Scenario | What it proves |
|---|---|
| `match` | Drawn in match 1, one widget, `HH:MM` equal to the sky's own conversion, top-right with the 16-unit gap; follows the host moving `Time of Day` forward (+120 and +61 minutes; +300 in match 2); not drawn at the menu; the same again in match 2. Every shown value is valid; each match's sky belongs to its own world; 200 s idle in match 2, still matching the sky |
| `step5` | With `updateEvery = 5` and the sky frozen (`Animate Time of Day` off): 10 chosen times each show the value rounded down to 5; every logged value is a multiple of 5 |
| `rebuild` | After `RemoveAllWidgets` and `AddToViewport`, the clock is drawn again, reused, one widget |
| `cost` | The cost of each engine call a read makes (`COST` lines), then 200 s idle in a match with the clock as installed (no DEBUG lines): the read tick averages under 0.1 ms, leaving out the first minute (menu and travel) |
| `speed` | As host, the sky's `Time of Day` and the clock's text every 50 ms for 30 s at Fast (1.5), then Normal (1.0); one `SPEEDSUM` line per speed counts the text's changes by step. Passes when, at each speed, at least 90% of the changes are +1 minute, none is 3 or more and none goes backwards (a 2-minute step needs a frame stalled over about 0.3 s) |
| `no-core` | `deploy.ps1` refuses in one line; forced, the log has exactly one `[HudClock]` line ("Nucleus is not installed. HudClock will not run.") and no clock widget |
| `old-core` | `deploy.ps1` refuses naming both versions; forced, exactly one `[HudClock]` line: "Nucleus 0.1.0 is older than HudClock needs (>=0.9.0). Update Nucleus. HudClock will not run." |

`no-core` and `old-core` put Nucleus back afterwards (also after a crash or Ctrl+C, and at the start of the next run if one was killed); the backup lives in `ue4ss/_hud-clock-test-backup/` meanwhile. For `old-core` the driver publishes the claimed version as core's runtime version (`nucleus.version`), because a real 0.1.0 core has no UI helpers and can't be built from today's source.

The driver (`test/HudClockDriver/`, installed as `Mods/HudClockDriver` between Nucleus and HudClock, only with `deploy.ps1 -Test`) is plain UE4SS Lua and never ships. It can't reach the clock's Lua state, so it judges what's on the HUD: the clock's widget found in the live `InventoryUI_C` canvas by core's tag (`nucleus:HudClock:clock.time`), its text and visibility, and the HUD's visibility.

### Scenarios in the VM

`run.ps1 -Target vm` runs a scenario in the Hyper-V VM `NNB` (account B; workspace `tools/vm/README.md`, "Single-player tests in the VM") instead of on the host, so it can run while you play on the host with your own account:

```powershell
./run.ps1 -Instance $copy -Scenario match -Target vm
./run.ps1 -Instance $copy -Scenario no-core -Target vm
./check.ps1 -Log <workspace>\dumps\v8.2.3-build26601774\hud-clock\match.vm.log -Scenario match -Target vm
```

- `-Instance` is still the host's copy (absolute, also from a worktree): it names the build and finds the workspace's `tools/` and `mods/Nucleus/`. The VM's copy (`C:\nn\<same name>`) must be the same build; the run refuses otherwise. Nothing of the host copy is read except its exe size, and no host game is started, stopped or checked. Nucleus doesn't have to be installed anywhere first.
- What goes into the VM copy: Nucleus from the workspace's `mods/Nucleus/build/package`, installed by Nucleus's own `deploy.ps1 -Staged`, then the clock and the driver by this repo's `deploy.ps1 -Test -Scenario <s> -Staged`, all into a host-side staging folder that `tools/vm/vm-sp.ps1` copies into the VM. `no-core` and `old-core` break core in the stage and check `deploy.ps1`'s refusal there, exactly as on the host. Nothing is built. UE4SS is switched on for the run; afterwards the VM copy is put back exactly as it was (UE4SS off, no mods), also after a crash or a time limit. An interrupted run is undone by the next one, or by `tools/vm/vm-sp-restore.ps1`.
- Enter at touchdown: the driver's `request.txt`/`done.txt` are polled in the VM copy over PowerShell Direct, and the key is posted with `tools/vm/vm-key.ps1`.
- Time limits are the host's times 1.5 (the VM's game is slower), unless `-TimeoutSec` is given. The log is kept as `dumps/<copy>/hud-clock/<scenario>.vm.log`.
- In the VM: `match`, `step5`, `rebuild`, `no-core`, `old-core`, `speed` (it judges step sizes, not cost). Host only: `cost` and `measure` (they judge tick costs and real time; refused with `-Target vm`). `check.ps1 -Target vm` makes the one timing assertion inside the functional scenarios soft: core's `WARN hud slow tick ... steady state` under the clock's tag shows as `warn:` instead of failing. The read-tick cost is soft outside `cost` anyway.
- Builds still happen on the host (Nucleus's `build.ps1` is CPU-heavy: the game you're playing may stutter meanwhile), and the VM's game itself shares the host's CPU and GPU.

### Two players: the clock on a client (story 5)

`test/pair/hud-clock-scenarios.ps1` adds `clock-client` to the workspace's pair tooling (`tools/vm/pair.ps1`; `tools/vm/README.md`). The host (this PC) makes a friends-only lobby and stays unmodded; B (the VM, a client) has Nucleus, HUD Clock and the driver in role `pair-client`. Once B is in the match and its HUD shows, the driver samples B's clock text and B's own (replicated) sky every 50 ms for 120 s and logs one `PAIRSUM` line; `check.ps1 -Scenario pair-client -Target vm` passes when no text change goes backwards, none is 3 minutes or more, and at least 90% are +1, and it prints how often B's sky stepped back. From the main checkout, with Nucleus built, the VM lock taken and no game running on the host:

```powershell
./tools/vm/pair.ps1 -Scenario clock-client -ScenarioFile mods/hud-clock/test/pair/hud-clock-scenarios.ps1
./tools/vm/pair.ps1 -Stop -Scenario clock-client -ScenarioFile mods/hud-clock/test/pair/hud-clock-scenarios.ps1   # after an aborted run
```

Run on 2026-11-19 (V8.2.3, Normal speed): 144 changes, all +1, none back. B's sky stepped back 5 times in 2,042 samples (the once-a-second replication snap; at most 0.062 `Time of Day` units, about 2 game seconds), and none of those crossed a minute, so the 1-2 minute hold-back had nothing to hold back on a LAN; its logic is covered by the unit tests.

### Measuring how the game advances time (story 2, part A)

`./run.ps1 -Instance $copy -Scenario measure` (about 10 minutes, as host). The driver logs, once a second for 2 real minutes at each `Time Speed` (Fast 1.5, Normal 1.0, Long 0.5), `Time of Day`, the sky's H/M/S and the Journal map's own text (`MapWidget_C.GetText_0`, when the widget exists); every change of the sky's `Event Minute` (what UDS's `Every Minute` broadcasts, from `Check for Time Event Dispatchers`); 30 s across the wrap at 2400; and which skies exist after each travel. `check.ps1 -Scenario measure` prints real seconds per game minute per speed, jumps, and how many map samples differed from H/M/S. To answer the four questions:

1. **Seconds per game minute** at each speed: the `MEASURE <speed>:` summary lines.
2. **Does `Every Minute` fire once per game minute?** Compare the `MEASURE minute-event` lines with the samples: one per minute, no bursts. (Host only; a client needs a second machine.)
3. **Map text vs H/M/S:** `differing=0` in the summaries. If the map widget doesn't exist until the Journal is opened (`map=n/a`), open the Journal by hand during a hand run and compare with `[HudClock] DEBUG SHOW`.
4. **Jumps and the wrap:** `jumps=` in the summaries and the `MEASURE wrap` first/last lines. Sleeping or skipping (if the game has them) needs a hand run.

Answered on V8.1.2 (2026-10-26, `docs/game-internals.md`, "In-game time"): a game minute takes 0.56 / 0.83 / 1.67 real s at Fast / Normal / Long (Day Length and Night Length 10 min each); UDS checks for a new minute on a 1 s timer, so `Every Minute` fires at most once a real second and skips minutes at Fast and Normal; the map uses the same conversion (decompiled `Get DateTime`), but its widget caches the sky only once the Journal is opened, so the unattended run can't read it (`map=nosky`: compare by hand); no jumps, and `Time of Day` wraps from 2400 to 0 with `Total Days Elapsed` +1. The clock polls rather than use the minute event, which is no more frequent and no more exact. **Since 0.2.1 it polls every 250 ms** (story 5): with the 1 s read it stepped by one or two minutes a second at Fast and Normal (VM, V8.2.3: at Fast +2 ×22, +1 ×6, +3 ×1), although the sky's `Time of Day` moves every frame; `speed` checks that each change is now one minute.

### Hand check (about 5 minutes)

Deploy without `-Test` (`./deploy.ps1 -Instance $copy`), launch with `tools/launch.ps1 -Instance $copy`, then:

1. Start a match. The clock is top-right, clear of the HUD, and the same as the Journal map.
2. Die and respawn. The clock comes back.
3. Return to the menu. No clock there.
4. Start another match. The clock is back, with that match's time.
5. Optional: set `updateEvery` to 5 (`./deploy.ps1 -Instance $copy -UpdateEvery 5`), relaunch, and watch it step.

Afterwards `./check.ps1 -Instance $copy -Scenario hand` checks the log: connected, `READY`, a time shown, no error. Record the result in story 4 (`_bmad-output/specs/spec-clock-v1/stories/4-scenarios-and-hand-check.md`).

## Layout

| Path | What |
|---|---|
| `mod.json` | The manifest (id, version, scope, game build, UE4SS, `dependsOn`, `settings`) |
| `Scripts/main.lua`, `Scripts/time.lua` | The mod (what ships) |
| `deploy.ps1`, `deploy-lib.ps1` | Install/remove; the lib holds the version-need check, `mods.txt` editing, `settings.json` (`-UpdateEvery`) and `dev.lua` (`-Test`) |
| `check.ps1`, `run.ps1`, `test.ps1` | Judge a log, run a scenario, run the unit tests |
| `test/HudClockDriver/` | The test driver (never shipped) |
| `test/unit/` | Unit tests |
| `test/pair/hud-clock-scenarios.ps1` | The `clock-client` two-player scenario for the workspace's `tools/vm/pair.ps1` |

## Feedback

Bug reports, ideas and questions go to [NuclearNightmare-Community/feedback](https://github.com/NuclearNightmare-Community/feedback). For a security problem, please report it privately: see its [SECURITY.md](https://github.com/NuclearNightmare-Community/feedback/blob/main/SECURITY.md).

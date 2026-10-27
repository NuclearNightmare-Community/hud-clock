# Clock

A Nuclear Nightmare mod that shows the in-game time as `HH:MM` (24-hour, the Journal map's format) in the HUD's top-right corner during a match, so you don't have to open the Journal to see it. It's the first mod built on **Nucleus** (core): it connects to core and puts its text on the HUD through core's UI helpers. Spec: `_bmad-output/specs/spec-clock-v1/` in the workspace.

- Scope `client`: each player runs it for themselves. It reads the time from the game's own sky (the replicated copy on a client), sends nothing over the network and reads nothing from other players.
- Version 0.1.0, built for game V8.1.2 (build 26193463) and UE4SS `v3.0.1-1181-g83330635`. Needs Nucleus `^0.2.0` (0.2.x, the first core with the UI helpers).

## Install

Nucleus must be installed in the dev copy first (its own `deploy.ps1`). Then, from this repo (from a worktree, pass the main checkout's instance path):

```powershell
./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463
./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -UpdateEvery 5
./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Remove
```

`deploy.ps1` refuses, with one line and exit code 1, when Nucleus isn't installed in the copy, is disabled in `mods.txt`, or its installed `mod.json` version doesn't satisfy `dependsOn` (`^0.2.0`). Otherwise it copies `mod.json` and `Scripts/` to `Mods/Clock/`, generates `Scripts/settings.lua` from `mod.json`'s setting defaults, and puts `Clock : 1` in `mods.txt` right below Nucleus's line and above `Keybinds : 1` (it moves the line there if it was elsewhere). It never bundles core's files and never writes outside `Mods/Clock`, `Mods/ClockDriver` and those `mods.txt` lines. `-Remove` takes all of that out again; `mods.txt` keeps its exact bytes otherwise.

Launch only with the workspace's `tools/launch.ps1 -Instance <copy>`.

## Settings

| Setting | Type | Default | Range | Changeable | Label |
|---|---|---|---|---|---|
| `updateEvery` | int | 1 | 1–60 | anytime | Update every N game minutes |

The clock shows the minute rounded down to a multiple of N (10:07 shows 10:05 with N = 5; N = 60 shows whole hours) and changes the text only when that value changes. Until core's settings service exists, the value comes from `Scripts/settings.lua`, which `deploy.ps1` generates from `mod.json` (`-UpdateEvery` overrides it). A missing or invalid `settings.lua` gives one `WARN` and N = 1.

## How it works

- `Scripts/main.lua`: the dependent bootstrap from core's `api-contract.md`, then `connect{ mod = "Clock", need = "0.2.0" }`. In `onReady` it creates one text element, `clock.time`, at `{ host = "hud", corner = "top-right" }`, hidden, and starts a 1,000 ms game-thread loop (`LoopInGameThreadWithDelay`). Each tick reads the time; when the shown value changes it sets the text, then shows the element. With no sky it hides the element and forgets the last value, so a new match shows its time at once. Core keeps the element attached through every HUD rebuild.
- `Scripts/time.lua`: `read()` finds the live `Ultra_Dynamic_Sky_C`, reads `Time of Day` and converts it in Lua with the sky's own formula (the decompiled `Time Of Day to H/M/S`: `Time % 2400`, `/ 100`, floor for the hour, the fraction × 60, floor for the minute), the conversion the Journal map uses too. Once per sky (each match) it checks that against the Blueprint function itself and logs `VERIFY`; if they ever disagree it uses the function from then on, with one `WARN`. (Calling the function every second cost about 100 µs a tick on V8.1.2; reading the property costs a few.) Between calls it keeps only a core weak handle to the sky and its path; `FindFirstOf` (about 120 µs) runs only when the handle no longer resolves or after a map change. `format` and `boundary` are pure: zero-padded `HH:MM`, hours past 23 wrap to 00.
- If core is missing, disabled, failed or too old, the log has exactly one `[Clock]` line naming the cause (core's `connect` composes it; the bootstrap writes the "not installed" one) and the clock does nothing else.

Log lines (`UE4SS.log`): `[Clock] CONNECT ok ...`, `[Clock] READY updateEvery=<n> element=clock.time`, `[Clock] VERIFY <Time of Day> -> HH:MM, the same as 'Time Of Day to H/M/S'` once per match, `[Clock] VISIBLE <HH:MM>` when the clock appears, `[Clock] HIDDEN no sky` when it goes away, and one `WARN` per distinct read error (the clock hides rather than show a wrong time). With `deploy.ps1 -Test`, `settings.lua` also turns on DEBUG lines: `DEBUG SHOW <HH:MM>` for every shown value and `DEBUG TICK n=60 avg <us> max <us> (read, set over <changes>, log)` for the read-tick cost. The `cost` scenario uses `profile = true` instead: only the whole-tick `TICK` line, at info level, as a normal install runs.

## Tests

### Unit tests (no game)

```powershell
./test.ps1                      # or: ./check.ps1 -Scenario unit
```

Lua tests run with any Lua 5.3/5.4 on PATH (MiKTeX's `texlua.exe` is one): `test/unit/time_test.lua` (formatting, rounding, boundaries over every minute of the day for several N, `read()` against a fake sky), `test/unit/main_test.lua` (the bootstrap, settings and the glue against a fake core and sky: create hidden, set before show, reset outside a match, one log line per failure), `test/unit/driver_test.lua` (the driver loads and ticks in every scenario). PowerShell tests: `test/unit/deploy_test.ps1` (caret ranges, `mods.txt` editing, `settings.lua`, and `deploy.ps1` end to end against a fake instance in a temp folder) and `test/unit/check_test.ps1` (each scenario's patterns against synthetic logs, passing and failing).

### Scenarios (in game, unattended)

`run.ps1` deploys with the test driver, launches through `tools/launch.ps1`, presses Enter at touchdown (posted to the game window only), waits for the driver's `END` line (or a crash or the time limit), closes only the game under that instance, keeps the log as `dumps/<copy>/clock/<scenario>.log` and runs `check.ps1` on it. Nucleus must be installed in the copy. Steam must be running, and nothing else may be running the game.

```powershell
$copy = 'C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463'
./run.ps1 -Instance $copy -Scenario match      # two matches with the menu between; time forced forward on the host
./run.ps1 -Instance $copy -Scenario step5      # updateEvery = 5; frozen sky set to chosen minutes
./run.ps1 -Instance $copy -Scenario rebuild    # RemoveAllWidgets and re-add the HUD mid-match
./run.ps1 -Instance $copy -Scenario no-core    # Nucleus moved aside: deploy refuses; forced, one [Clock] line, no widget
./run.ps1 -Instance $copy -Scenario old-core   # Nucleus mod.json set to 0.1.0: deploy refuses; forced, one [Clock] line
./run.ps1 -Instance $copy -Scenario cost       # cost of each engine call, then 200 s idle as installed (story 3 AC 5)
./check.ps1 -Log <a kept log> -Scenario match  # judge a kept log again
```

| Scenario | What it proves |
|---|---|
| `match` | Drawn in match 1, one widget, `HH:MM` equal to the sky's own conversion, top-right with the 16-unit gap; follows the host moving `Time of Day` forward (+120 and +61 minutes; +300 in match 2); not drawn at the menu; the same again in match 2. Every shown value is valid; each match's sky belongs to its own world; 200 s idle in match 2, still matching the sky |
| `step5` | With `updateEvery = 5` and the sky frozen (`Animate Time of Day` off): 10 chosen times each show the value rounded down to 5; every logged value is a multiple of 5 |
| `rebuild` | After `RemoveAllWidgets` and `AddToViewport`, the clock is drawn again, reused, one widget |
| `cost` | The cost of each engine call a read makes (`COST` lines), then 200 s idle in a match with the clock as installed (no DEBUG lines): the read tick averages under 0.1 ms, leaving out the first minute (menu and travel) |
| `no-core` | `deploy.ps1` refuses in one line; forced, the log has exactly one `[Clock]` line ("Nucleus is not installed. Clock will not run.") and no clock widget |
| `old-core` | `deploy.ps1` refuses naming both versions; forced, exactly one `[Clock]` line: "Nucleus 0.1.0 is not compatible; Clock needs 0.2.0 (^ rules). ..." |

`no-core` and `old-core` put Nucleus back afterwards (also after a crash or Ctrl+C, and at the start of the next run if one was killed); the backup lives in `ue4ss/_clock-test-backup/` meanwhile. For `old-core` the driver publishes the claimed version as core's runtime version (`nucleus.version`), because a real 0.1.0 core has no UI helpers and can't be built from today's source.

The driver (`test/ClockDriver/`, installed as `Mods/ClockDriver` between Nucleus and Clock, only with `deploy.ps1 -Test`) is plain UE4SS Lua and never ships. It can't reach the clock's Lua state, so it judges what's on the HUD: the clock's widget found in the live `InventoryUI_C` canvas by core's tag (`nucleus:Clock:clock.time`), its text and visibility, and the HUD's visibility.

### Scenarios in the VM

`run.ps1 -Target vm` runs a scenario in the Hyper-V VM `NNB` (account B; workspace `tools/vm/README.md`, "Single-player tests in the VM") instead of on the host, so it can run while you play on the host with your own account:

```powershell
./run.ps1 -Instance $copy -Scenario match -Target vm
./run.ps1 -Instance $copy -Scenario no-core -Target vm
./check.ps1 -Log <workspace>\dumps\v8.1.2-build26193463\clock\match.vm.log -Scenario match -Target vm
```

- `-Instance` is still the host's copy (absolute, also from a worktree): it names the build and finds the workspace's `tools/` and `mods/Nucleus/`. The VM's copy (`C:\nn\<same name>`) must be the same build; the run refuses otherwise. Nothing of the host copy is read except its exe size, and no host game is started, stopped or checked. Nucleus doesn't have to be installed anywhere first.
- What goes into the VM copy: Nucleus from the workspace's `mods/Nucleus/build/package`, installed by Nucleus's own `deploy.ps1 -Staged`, then the clock and the driver by this repo's `deploy.ps1 -Test -Scenario <s> -Staged`, all into a host-side staging folder that `tools/vm/vm-sp.ps1` copies into the VM. `no-core` and `old-core` break core in the stage and check `deploy.ps1`'s refusal there, exactly as on the host. Nothing is built. UE4SS is switched on for the run; afterwards the VM copy is put back exactly as it was (UE4SS off, no mods), also after a crash or a time limit. An interrupted run is undone by the next one, or by `tools/vm/vm-sp-restore.ps1`.
- Enter at touchdown: the driver's `request.txt`/`done.txt` are polled in the VM copy over PowerShell Direct, and the key is posted with `tools/vm/vm-key.ps1`.
- Time limits are the host's times 1.5 (the VM's game is slower), unless `-TimeoutSec` is given. The log is kept as `dumps/<copy>/clock/<scenario>.vm.log`.
- In the VM: `match`, `step5`, `rebuild`, `no-core`, `old-core`. Host only: `cost` and `measure` (they judge tick costs and real time; refused with `-Target vm`). `check.ps1 -Target vm` makes the one timing assertion inside the functional scenarios soft: core's `WARN hud slow tick ... steady state` under the clock's tag shows as `warn:` instead of failing. The read-tick cost is soft outside `cost` anyway.
- Builds still happen on the host (Nucleus's `build.ps1` is CPU-heavy: the game you're playing may stutter meanwhile), and the VM's game itself shares the host's CPU and GPU.

### Measuring how the game advances time (story 2, part A)

`./run.ps1 -Instance $copy -Scenario measure` (about 10 minutes, as host). The driver logs, once a second for 2 real minutes at each `Time Speed` (Fast 1.5, Normal 1.0, Long 0.5), `Time of Day`, the sky's H/M/S and the Journal map's own text (`MapWidget_C.GetText_0`, when the widget exists); every change of the sky's `Event Minute` (what UDS's `Every Minute` broadcasts, from `Check for Time Event Dispatchers`); 30 s across the wrap at 2400; and which skies exist after each travel. `check.ps1 -Scenario measure` prints real seconds per game minute per speed, jumps, and how many map samples differed from H/M/S. To answer the four questions:

1. **Seconds per game minute** at each speed: the `MEASURE <speed>:` summary lines.
2. **Does `Every Minute` fire once per game minute?** Compare the `MEASURE minute-event` lines with the samples: one per minute, no bursts. (Host only; a client needs a second machine.)
3. **Map text vs H/M/S:** `differing=0` in the summaries. If the map widget doesn't exist until the Journal is opened (`map=n/a`), open the Journal by hand during a hand run and compare with `[Clock] DEBUG SHOW`.
4. **Jumps and the wrap:** `jumps=` in the summaries and the `MEASURE wrap` first/last lines. Sleeping or skipping (if the game has them) needs a hand run.

Answered on V8.1.2 (2026-10-26, `docs/game-internals.md`, "In-game time"): a game minute takes 0.56 / 0.83 / 1.67 real s at Fast / Normal / Long (Day Length and Night Length 10 min each); UDS checks for a new minute on a 1 s timer, so `Every Minute` fires at most once a real second and skips minutes at Fast and Normal; the map uses the same conversion (decompiled `Get DateTime`), but its widget caches the sky only once the Journal is opened, so the unattended run can't read it (`map=nosky`: compare by hand); no jumps, and `Time of Day` wraps from 2400 to 0 with `Total Days Elapsed` +1. **The clock polls once a second:** the minute event is no more frequent and no more exact. With `updateEvery = 1` at Fast or Normal the clock therefore steps by one or two minutes a second, as the spec allows (a change may show up to one second late).

### Hand check (about 5 minutes)

Deploy without `-Test` (`./deploy.ps1 -Instance $copy`), launch with `tools/launch.ps1 -Instance $copy`, then:

1. Start a match. The clock is top-right, clear of the HUD, and the same as the Journal map.
2. Die and respawn. The clock comes back.
3. Return to the menu. No clock there.
4. Start another match. The clock is back, with that match's time.
5. Optional: set `updateEvery` to 5 (`./deploy.ps1 -Instance $copy -UpdateEvery 5`), relaunch, and watch it step.

Afterwards `./check.ps1 -Instance $copy -Scenario hand` checks the log: connected, `READY`, a time shown, no error. Record the result in story 4 (`_bmad-output/specs/spec-clock-v1/stories/story-4-scenarios-and-hand-check.md`).

## Layout

| Path | What |
|---|---|
| `mod.json` | The manifest (id, version, scope, game build, UE4SS, `dependsOn`, `settings`) |
| `Scripts/main.lua`, `Scripts/time.lua` | The mod (what ships) |
| `deploy.ps1`, `deploy-lib.ps1` | Install/remove; the lib holds the caret check, `mods.txt` editing and `settings.lua` generation |
| `check.ps1`, `run.ps1`, `test.ps1` | Judge a log, run a scenario, run the unit tests |
| `test/ClockDriver/` | The test driver (never shipped) |
| `test/unit/` | Unit tests |

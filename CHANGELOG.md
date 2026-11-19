# Changelog

All notable changes to Clock are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [0.2.1] - 2026-11-19

Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635. Needs Nucleus 0.9.0 or newer (`>=0.9.0`).

For players: with "update every 1 minute" the clock now counts every minute. Before, it skipped minutes at the Fast and Normal day/night speeds (10:01, 10:03, 10:05, ...).

### Fixed

- The time is read every 250 ms instead of once a second. A game minute lasts 0.55 real s at Fast and 0.84 s at Normal, so the 1 s read skipped most minutes; the sky itself moves every frame (story 5). The text still changes only when the shown value does, and the read tick stays within the 0.1 ms budget.
- A step back of one or two shown values is held back, so a client's once-a-second sky correction from the host can't make the time tick backwards for a moment. A bigger step back (the host setting the time back) and the midnight wrap show at once.

### Changed

- The DEBUG/profile `TICK` cost line covers 240 ticks (still one a minute).
- New test scenario `speed` (`run.ps1 -Scenario speed`, also in the VM): the text and the sky every 50 ms at Fast and Normal; it passes when at least 90% of the changes are +1 minute and none is 3 or more or backwards.
- New two-player scenario `clock-client` (`test/pair/clock-scenarios.ps1`, run by the workspace's `tools/vm/pair.ps1`): the clock on a client, whose text must never step back; judged by `check.ps1 -Scenario pair-client`.

## [0.2.0] - 2026-11-14

Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635. Needs Nucleus 0.9.0 or newer (`>=0.9.0`).

For players: the clock's "update every N minutes" setting is now kept by Nucleus in `Mods/Clock/settings.json`, so it survives a redeploy, and a change (from the Mod Manager, later) shows at the next tick without a restart.

### Changed

- `updateEvery` comes from Nucleus's settings service (`core.settings.get`), and a watched change applies live (`SETTING updateEvery=<n>`). `Scripts/settings.lua` is gone: `deploy.ps1 -UpdateEvery N` writes `Mods/Clock/settings.json` instead, a redeploy without it keeps an existing one, and a release ships no settings file.
- An existing `Scripts/settings.lua` is no longer read: a value chosen there must be set again in `Mods/Clock/settings.json` (for example `{"updateEvery":5}`; in Notepad, save with "All files" so the name ends in `.json`, not `.json.txt`).
- The test-only `debug`/`profile` flags moved to `Scripts/dev.lua`, written only by `deploy.ps1 -Test`, read as text and never run.
- Needs Nucleus `>=0.9.0` (`dependsOn` and `connect`).
- The mod id is now `nuclearnightmare-community.clock` (was `clock`), and `dependsOn` names Nucleus as `nuclearnightmare-community.nucleus` (distribution story 13, `mod-ids.md`): the namespaced ids every released mod takes before the first public release. The folder, `mods.txt` line and `name` are unchanged. `deploy.ps1` finds core's entry by the new id, so a dev copy needs a Nucleus deployed with the new id (Nucleus 0.12.0).

## [0.1.0] - 2026-11-13

Soft release to a few testers, not released publicly. Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635. Needs Nucleus 0.2.0 or newer (`>=0.2.0`).

For players: the in-game time as `HH:MM` (24-hour, like the Journal map) in the HUD's top-right corner during a match, so you don't have to open the Journal. Only your own screen is changed; it sends nothing over the network.

### Added

- Reads the time from the game's own sky once a second and shows it in the HUD's top-right corner during a match, hidden at the menu; it stays after the HUD is rebuilt.
- Setting `updateEvery` (1-60, default 1): show the time rounded down to a multiple of N game minutes.
- Without a compatible Nucleus, one `[Clock]` log line naming the cause, and nothing else.
- Log lines `[Clock] CONNECT`, `READY`, `VERIFY`, `VISIBLE`, `HIDDEN` and `WARN` in `UE4SS.log`.

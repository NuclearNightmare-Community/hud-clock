# Changelog

All notable changes to Clock are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased] - 0.2.0

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

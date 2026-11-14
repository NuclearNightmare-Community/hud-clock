# Changelog

All notable changes to Clock are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-13

Soft release to a few testers, not released publicly. Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635. Needs Nucleus 0.2.0 or newer (`>=0.2.0`).

For players: the in-game time as `HH:MM` (24-hour, like the Journal map) in the HUD's top-right corner during a match, so you don't have to open the Journal. Only your own screen is changed; it sends nothing over the network.

### Added

- Reads the time from the game's own sky once a second and shows it in the HUD's top-right corner during a match, hidden at the menu; it stays after the HUD is rebuilt.
- Setting `updateEvery` (1-60, default 1): show the time rounded down to a multiple of N game minutes.
- Without a compatible Nucleus, one `[Clock]` log line naming the cause, and nothing else.
- Log lines `[Clock] CONNECT`, `READY`, `VERIFY`, `VISIBLE`, `HIDDEN` and `WARN` in `UE4SS.log`.

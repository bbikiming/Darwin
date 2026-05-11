# 10 — RoboCup Game Controller Integration (ROBOTIS-OP2 Factory Firmware)

## TL;DR

**No RoboCup Game Controller (GC) integration exists in the ROBOTIS-OP2 factory firmware (2015-03-26).** Exhaustive grep across `robotis/Framework/`, `robotis/Linux/`, and the `demo` project source + compiled binary returned zero hits for `GameController`, `GCData`, `RoboCupGameControlData`, `RGme`/`RGrt` magic headers, GC ports (3838/3939), team color/number constants, or any SPL/Humanoid League game state vocabulary (`kickoff`, `penalty`, `secondaryState`). The shipped demo is a vision-driven ball-following + standing-up showcase, not a RoboCup competition agent.

## Source files

No GameController-related source files exist. For completeness, the only network-adjacent file in the firmware is a generic TCP socket wrapper unrelated to GC:

| File | Role | Description |
|---|---|---|
| `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/include/LinuxNetwork.h` | Generic socket wrapper | TCP-only `LinuxSocket` / `LinuxServer` classes (BSD sockets, `SOCK_STREAM`). No UDP, no broadcast, no GC packet parsing. Used by the WiFi web-control feature, not by any game-controller client. |
| `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/main.cpp` | Demo entry point | Initializes CM-730, motion modules, vision; runs a state machine over `VisionMode` (ball-following / soccer / etc.) and `StatusCheck` (button/voice/web). Contains no UDP listener, no team configuration, no game-state branches. |
| `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/VisionMode.h` & `.cpp` | Local mode switcher | Switches between offline behaviors (ball-tracking, color-filter). Pure local logic — no remote control input. |
| `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/StatusCheck.cpp` | Mode/UI dispatcher | Reads button presses, talks to MP3 voice prompts, swaps demo modes. No network input. |

## Protocol details (if found)

**Not applicable — no GC client exists.**

For reference (not from this firmware), the SPL/Humanoid League Game Controller protocol of the 2014–2015 era used:
- UDP listen port `3838` (server -> robots, broadcast)
- UDP return port `3939` (robots -> server, status return)
- Packet struct `RoboCupGameControlData` with header `"RGme"` and version `8` (SPL 2014) or version `9` (SPL 2015)
- Return packet `RoboCupGameControlReturnData` with header `"RGrt"`

None of these symbols, ports, struct names, or magic bytes appear in any file (source, header, or compiled binary `demo`) under the extraction root.

## Team config

**Not applicable.** Searches for `TEAM_NUMBER`, `TEAM_COLOR`, `PLAYER_NUMBER`, `MAX_NUM_PLAYERS`, `TEAM_BLUE`, `TEAM_RED` returned zero hits. The factory `config.ini` (loaded at demo startup) carries only walk-engine gains, ball-color HSV ranges, head-tracking limits, and motion offsets — no team identity fields.

## State machine

**Not applicable — no game state machine.**

The closest analog in the factory firmware is the `VisionMode` enum in the demo, which switches between local behaviors:
- `READY` / `SOCCER` / `BALL_TRACKING` / `HEAD_ONLY`

These are local UX modes triggered by button presses or the WiFi web UI — they are **not** RoboCup game phases (`Initial` / `Ready` / `Set` / `Playing` / `Penalized` / `Finished`).

## What this means for Darwin

- **In-scope confirmation**: Darwin's mission is humanoid-platform support (motion, perception, BCI/voice control), not RoboCup competition. The factory firmware's silence on GC matches our scope — there is no legacy GC client we need to preserve, deprecate, or interoperate with.
- **No wire-format hint on-robot**: If a future RoboCup sprint is greenlit, we cannot crib the packet layout from on-robot code (it doesn't exist). The canonical reference is the upstream `RoboCup-Humanoid-TC/GameController` repo and its `RoboCupGameControlData.h` — we'd add a fresh `gc_client` module from that spec, not port anything from ROBOTIS sources.
- **No tuning to inherit**: There are no "stop on Penalty," "head-track-only during Set," or "kickoff side flip" behaviors encoded in this firmware. Any RoboCup behavior tree we later author starts from a blank slate.
- **Integration hook (future)**: If GC is ever added, the natural seam is `StatusCheck::Check()` in `demo/StatusCheck.cpp` (already the central per-tick mode dispatcher) or — preferably for a new architecture — a dedicated UDP-listener task in our Sprint-9+ behavior runtime that pushes game-state events onto the same bus as button/voice events.

## Evidence

Searches executed (all returned **zero hits except as noted**):

1. `grep -rln "GameController\|GCData\|gameState\|GCBroadcast\|RoboCupGameControlData" /Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/` -> 0 hits
2. `grep -rln -i "robocup\|game.controller\|gc.broadcast\|spl.team" /Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/` -> 0 hits
3. `grep -rln "3838\|3939\|RGme\|RGrt" /Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/` -> only false matches in `firmware_installer/*.hex` filename strings (CM-730/MX-28 motor firmware images), unrelated to UDP ports
4. `grep -rln -i "spl\|kickoff\|penalty\|halftime\|secondary.state" /Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/` -> matches confined to `minIni/LICENSE`, `www/LICENSE.txt`, and `httpd.cpp` license text ("SPLATTER" / "split" / unrelated English words) — no game-state code
5. `grep -rln "TEAM_NUMBER\|TEAM_COLOR\|PLAYER_NUMBER\|MAX_NUM_PLAYERS\|TEAM_BLUE\|TEAM_RED" /Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/` -> 0 hits
6. `find /Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis -type d -iname "*game*"` -> 0 directories
7. `strings .../demo/demo | grep -iE "game|robocup|RGme|GCData|3838|spl"` -> 0 hits in the compiled demo binary
8. Demo project file inventory `find .../Linux/project/demo -type f -name '*.cpp' -o -name '*.h'` -> only `main.cpp`, `VisionMode.{h,cpp}`, `StatusCheck.{h,cpp}` — no `game.cpp`, no `gc.cpp`, no `GCData.h`
9. Read of `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/include/LinuxNetwork.h` confirms it is a generic TCP socket wrapper (`SOCK_STREAM` semantics via `bind/listen/accept/connect`) with no UDP, no broadcast, no packet-struct parsing
10. Read of `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/main.cpp` (lines 1-60) confirms includes are limited to `mjpg_streamer.h`, `LinuxDARwIn.h`, `StatusCheck.h`, `VisionMode.h` — no game/GC headers

## Verdict

- [ ] GC integration PRESENT — fully documented above
- [ ] GC integration PARTIAL — code stub exists but not wired up
- [x] **GC integration ABSENT** — no references found

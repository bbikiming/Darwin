# Claude Continuation Prompt: Darwin Switch Pilot

Date: 2026-06-05

Use this file as the starting prompt/context when Claude continues the Nintendo Switch + Darwin robot controller work.

## Role And Goal

You are continuing a Darwin OP robot control project for a UI/UX-focused planner who is not a firmware/Linux specialist.

The current goal is to make a Nintendo Switch v1 running Switchroot L4T Ubuntu behave like a polished Darwin robot cockpit:

- Switch app/runtime -> Mac DarwinForge relay -> robot
- Switch app/runtime -> robot directly over Wi-Fi/UDP/SSH-assisted paths
- local Switch cockpit UI with robot state, safety state, joystick state, and camera HUD

Important framing:

- This is **not** a replacement Nintendo firmware image.
- This is **not** a piracy/DRM bypass workflow.
- The current deliverable is a Switchroot Linux runtime package named `Darwin Switch Agent`.
- A later true Switch homebrew `.nro` can be considered, but the near-term path is Switchroot Ubuntu + local web cockpit.

## Why This Was Designed

The user originally wanted to control a Darwin robot with a gamepad. During feasibility research, the main blocker was not "which controller brand is best", but the robot's old Linux kernel and driver reality:

- the robot-side Linux environment is old and may not reliably support modern Bluetooth controllers
- direct USB/2.4GHz receiver support on the robot cannot be assumed without kernel/input-device testing
- Mac-mediated control is more realistic because the Mac can handle modern controllers and existing DarwinForge relay logic
- Switchroot Linux on Nintendo Switch can become a dedicated handheld robot cockpit if the Switch can boot Linux and read controller inputs

That led to a staged design:

1. Implement the Switch cockpit/runtime in advance on the Mac workspace.
2. Install it later onto Switchroot Ubuntu after the Switch boot path is ready.
3. First run in `dry_run` mode to validate UI and input mapping.
4. Then validate `mac_relay` mode through DarwinForge on Mac.
5. Only after that consider robot-direct UDP or deeper native `.nro` work.

The current architecture is intentionally conservative:

- local web UI instead of Electron/Qt to keep Switchroot dependencies low
- systemd service for reliability
- browser fullscreen cockpit for fast iteration
- deadman and E-stop visibility prioritized over visual decoration
- no automatic Arm from ambiguous browser Gamepad API mappings
- robot-direct mode remains a placeholder until robot-side receiver and safety path are verified

## Current Physical/Setup Status

This project is currently in a **pre-hardware / pre-install implementation stage**.

Known physical setup state:

- The user has a Nintendo Switch v1 that may be usable for Switchroot/Linux work.
- The user currently does **not** have an RCM jig available.
- Because there is no jig yet, the Switch cannot currently be booted into the RCM/Hekate/Switchroot install flow.
- Therefore, no real Switchroot boot, Joy-Con Linux event-code mapping, camera tunnel, or robot-control test has happened yet.
- Work so far is a prepared installable package and local browser/runtime validation from the Mac workspace.

Implication for Claude:

- Treat all Switch hardware behavior as unverified until the jig and Switchroot boot are available.
- Do not state that Joy-Con mappings are final.
- Do not state that robot direct control works on the Switch yet.
- Do state that the package is prepared so it can be copied/installed once Switchroot Ubuntu is available.

Expected future setup path once the jig is obtained:

1. Use RCM jig + payload injection to boot Hekate.
2. Boot/install Switchroot L4T Ubuntu from SD.
3. Enable network/SSH on Switchroot.
4. Copy `tools/switch-pilot` or the packaged tarball to the Switch.
5. Install and run `Darwin Switch Agent`.
6. Verify input devices and update mapping.
7. Move from `dry_run` to `mac_relay`.

## Current User Priority

The user wants the prebuilt Darwin cockpit to feel close to Nintendo Switch native app quality:

- controller-first
- clear focus states
- readable on the Switch 1280x720 screen
- strong safety visibility
- useful camera/HUD view
- installable as soon as the Switch setup is ready

The user cares most about GUI quality, usability, visual clarity, and practical setup steps.

The user also wants Claude to be explicit about what is implemented versus what is only planned. Do not blur these states:

- implemented locally: package, Python agent, local web cockpit, install scripts, camera tunnel helper
- locally verified: Python syntax, shell syntax, browser layout at 1280x720, basic UI focus behavior
- not yet physically verified: Switchroot boot, Joy-Con event codes, Switch browser performance, Mac relay end-to-end, robot camera tunnel, robot motion

## Main Files To Read First

Read these in order:

1. `docs/prd/darwin-switch-controller-prd.md`
2. `docs/reports/2026-06-03-switch-ssh-robot-control-setup-plan.md`
3. `docs/reports/2026-06-04-switch-robot-camera-hud-feasibility.md`
4. `docs/reports/2026-06-05-switch-native-ui-upgrade-methodology.md`
5. `tools/switch-pilot/README.md`
6. `tools/switch-pilot/config.example.json`

Then inspect implementation:

1. `tools/switch-pilot/src/darwin_switch_agent/main.py`
2. `tools/switch-pilot/src/darwin_switch_agent/cockpit.py`
3. `tools/switch-pilot/src/darwin_switch_agent/input_linux.py`
4. `tools/switch-pilot/src/darwin_switch_agent/mapping.py`
5. `tools/switch-pilot/src/darwin_switch_agent/mac_relay_client.py`
6. `tools/switch-pilot/src/darwin_switch_agent/robot_udp_client.py`
7. `tools/switch-pilot/src/darwin_switch_agent/safety.py`
8. `tools/switch-pilot/web/index.html`
9. `tools/switch-pilot/web/styles.css`
10. `tools/switch-pilot/web/app.js`

## Implemented Runtime

The agent lives under:

```text
tools/switch-pilot/
```

It currently does the following:

- reads Linux controller input from `/dev/input/event*`
- uses a Joy-Con-ish mapping by default
- maps ZL as deadman
- maps left stick to walking stride/turn command values
- maps right stick to head pan/tilt command values
- supports `dry_run`, `mac_relay`, and `robot_udp` modes
- serves a local cockpit UI at `http://127.0.0.1:8765/`
- exposes action endpoints for Arm, Recover, Stop, Ping, and E-Stop
- can install as a systemd service
- can autostart a fullscreen browser cockpit on Switchroot desktop login
- includes a camera tunnel helper for the robot MJPEG stream

The package script writes:

```text
dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz
```

Package size is about **1.6MB** as of 2026-06-05 (the earlier ~27KB figure was
before the real DARwIn 3D model was added: `web/assets/darwin.glb` ~1.76MB plus
vendored Three.js runtime). `package.sh` excludes build-only GLB-bake tooling
(STL assembler, GLTF exporter, bake page) from the tarball.

This package is intended to be "ready to install after Switchroot is ready", not proof that the Switch has already run it. The current deliverable should be described as:

```text
prebuilt Switchroot runtime bundle, locally validated on Mac, awaiting real Switchroot installation
```

## Current Input Defaults

From `tools/switch-pilot/config.example.json`:

```json
{
  "mode": "dry_run",
  "gui": {
    "host": "127.0.0.1",
    "port": 8765
  },
  "mapping": {
    "deadzone": 0.12,
    "deadman_key_codes": [312],
    "arm_key_codes": [304],
    "stop_key_codes": [305],
    "estop_key_codes": [],
    "left_x_abs_codes": [0],
    "left_y_abs_codes": [1],
    "right_x_abs_codes": [3],
    "right_y_abs_codes": [4],
    "invert_left_y": true,
    "invert_right_y": true
  }
}
```

Assumption:

- `312` is treated as ZL deadman.
- `304` is treated as arm.
- `305` is treated as stop.
- These must be confirmed on real Switchroot Linux with `evtest`, `lsinput`, or a small event dump.

## Current GUI State

The current cockpit UI is a plain HTML/CSS/JS local app:

```text
tools/switch-pilot/web/index.html
tools/switch-pilot/web/styles.css
tools/switch-pilot/web/app.js
```

The UI is designed as a single 1280x720 console cockpit:

- top HUD with app title, relay state, mode, clock
- left Joy-Con rail for walk stick and ZL deadman
- central robot/camera stage
- right Joy-Con rail for head stick and link state
- safety board with ARM, E-STOP, WATCHDOG, UPDATE
- telemetry row for Walk, Head, Target/Mac Relay, Events
- bottom command dock

Latest UI upgrade added:

- `COMMAND` focus panel in the bottom dock
- selected command label/hint
- strong selected/focus ring
- Switch-like circular button glyphs
- D-pad/ArrowLeft/ArrowRight command selection
- reduced-motion fallback
- no external web libraries, no remote fonts, no Electron, no Qt

Safety-related GUI decision:

- Browser Gamepad API face-button mapping is not trusted for Arm/Recover/Ping.
- Gamepad API is currently limited to D-pad focus plus safer Stop/E-Stop edges.
- Keyboard shortcuts still exist for local testing: `a`, `x`, `b`, `y`, `+`/`=`.

## Camera HUD State

Camera feasibility has been investigated in:

```text
docs/reports/2026-06-04-switch-robot-camera-hud-feasibility.md
```

Current camera config:

```json
{
  "camera": {
    "enabled": true,
    "label": "Darwin Head Camera",
    "route": "ssh-tunnel",
    "stream_url": "http://127.0.0.1:18080/?action=stream",
    "snapshot_url": "http://127.0.0.1:18080/?action=snapshot"
  }
}
```

Helper script:

```text
tools/switch-pilot/bin/darwin-switch-camera-tunnel
```

Intended command on Switchroot:

```bash
ROBOT_HOST=192.168.123.1 ROBOT_USER=robotis darwin-switch-camera-tunnel
```

The helper should:

1. SSH into the robot.
2. Start ROBOTIS `camera_tutorial` on port `8080`.
3. Forward Switch `127.0.0.1:18080` to robot `127.0.0.1:8080`.

Known robot-side references from previous investigation:

- robot backup has `uvcvideo.ko`, `videodev.ko`, `v4l2-common.ko`
- robot backup has ROBOTIS `camera_tutorial`
- robot backup has `mjpg_streamer`
- DarwinForge Mac app already has `MjpegStreamingClient`

## Open-Source UI References Already Used

Use these as public/open-source design references, not proprietary Nintendo UI copying:

- Borealis Switch: https://www.gamebrew.org/wiki/Borealis_Switch
- Borealis GitHub: https://github.com/natinusala/borealis
- nx-hbmenu GitHub: https://github.com/switchbrew/nx-hbmenu
- Switchbrew Homebrew Menu: https://www.switchbrew.org/wiki/Homebrew_Menu
- libnx HID docs: https://switchbrew.github.io/libnx/hid_8h.html

Current judgment:

- Near-term best path: Switchroot Ubuntu + local web cockpit.
- Later native `.nro` candidate stack: libnx + Borealis.
- Borealis is useful because it targets controller/TV UI, hardware acceleration, scaling, focus navigation, touch support, reusable components, and efficient list patterns.
- `nx-hbmenu` is useful for controller-first conventions, button prompts, theming, and status information.

## Commands For Local Verification

Run from repository root:

```bash
python3 -m compileall -q tools/switch-pilot/src
```

```bash
bash -n \
  tools/switch-pilot/install.sh \
  tools/switch-pilot/uninstall.sh \
  tools/switch-pilot/package.sh \
  tools/switch-pilot/bin/darwin-switch-cockpit \
  tools/switch-pilot/bin/darwin-switch-camera-tunnel
```

Start dry-run local cockpit:

```bash
PYTHONPATH=tools/switch-pilot/src \
python3 -m darwin_switch_agent.main \
  --config tools/switch-pilot/config.example.json
```

Open:

```text
http://127.0.0.1:8765/
```

Expected local API check:

```bash
curl -s http://127.0.0.1:8765/api/state
```

Package:

```bash
tools/switch-pilot/package.sh
```

Confirm tarball contents:

```bash
tar -tzf dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz | rg 'web/(index.html|styles.css|app.js)'
```

## Last Verified Results

Last local verification completed:

- Python compile passed.
- Shell syntax check passed.
- Browser-rendered cockpit at 1280x720 had no page overflow.
- Browser-rendered cockpit had no clipped text after CSS adjustment.
- Browser console warning/error list was empty.
- ArrowRight moved command focus from Arm to Recover.
- Frontend cockpit code (index.html/styles.css/app.js/setup.*) is still tens of
  KB; the bulk of the bundle is now the 3D runtime: `web/assets/darwin.glb`
  (~1.76MB) + vendored Three.js (`three.module.min.js` ~655KB, GLTFLoader,
  BufferGeometryUtils). The cockpit is fully Korean-localized with UX writing,
  and the 3D model is an optional camera-fallback (CSS robot figure if WebGL is
  unavailable; toggle via the setup page / localStorage `darwinNo3D`).
- Package was generated at `dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz`
  (~1.6MB; build-only GLB-bake tooling excluded by `package.sh`).

Important qualification:

- These are local development-machine checks.
- They do not prove Switchroot hardware behavior yet.
- The absence of an RCM jig means no Switch-side install/run test has been performed.

## Known Limitations

Hardware not yet verified:

- RCM/Hekate/Switchroot boot flow because the user does not currently have an RCM jig.
- SD-card boot and Switchroot Ubuntu desktop state after real Switch boot.
- Switchroot Linux input event codes for actual Joy-Con/Pro Controller.
- Real Switch browser fullscreen behavior.
- Real Switch CPU/GPU performance with MJPEG stream active.
- Robot direct UDP receiver is not implemented on the robot side yet.
- Real robot movement safety must be tested with robot elevated or motors disabled first.

Mac relay not fully revalidated in this bundle:

- Confirm DarwinForge `/mobile-relay` endpoint contract before switching `mode` to `mac_relay`.
- Confirm pairing code behavior.
- Confirm heartbeat and stop semantics match the current Mac app.

Camera not hardware-verified from Switch:

- SSH tunnel command needs real robot credentials/network.
- ROBOTIS `camera_tutorial` path may vary by robot image.
- Browser should prefer Firefox on Switchroot if old Chromium leaks memory with MJPEG.

## Suggested Next Work

Priority 0: obtain physical Switch setup materials.

1. Buy or borrow an RCM jig.
2. Confirm the Switch is the vulnerable/unpatched v1 model.
3. Prepare a reliable USB-C cable for payload injection.
4. Keep the already-prepared SD card available.
5. Keep a Mac/PC ready for payload injection and SSH/file copy.

Priority 1: real Switchroot install rehearsal after RCM jig is available.

1. Copy `tools/switch-pilot` or the tarball to Switchroot Ubuntu.
2. Run `sudo ./install.sh`.
3. Confirm systemd service starts.
4. Confirm cockpit opens fullscreen.
5. Confirm event devices are readable.
6. Dump Joy-Con event codes and update `config.example.json`.

Priority 2: input mapping verification.

1. Use `evtest` or a small Python event logger.
2. Press ZL, A, B, X, Y, Plus, D-pad, sticks.
3. Record actual `EV_KEY` and `EV_ABS` codes.
4. Update `mapping` config.
5. Keep deadman behavior conservative.

Priority 3: Mac relay integration.

1. Run DarwinForge on Mac.
2. Enable mobile relay endpoint.
3. Set Switch config `mode` to `mac_relay`.
4. Point `mac.host` and `mac.port` to the Mac.
5. Verify Arm, Stop, E-Stop, heartbeat, and walk command flow.

Priority 4: camera HUD on robot.

1. Confirm robot SSH login.
2. Run `darwin-switch-camera-tunnel`.
3. Confirm `http://127.0.0.1:18080/?action=stream` loads on Switch.
4. Watch CPU/memory for 10+ minutes.
5. Tune camera opacity/HUD if stream reduces readability.

Priority 5: UI polish after real device feedback.

1. Check the 1280x720 layout on actual Switch LCD.
2. Check readability at arm's length.
3. Check whether the bottom dock is too dense while holding the device.
4. Add a "camera off / telemetry priority" mode if MJPEG performance is weak.
5. Consider a two-state UI: `Pilot` and `Diagnostics`, navigated by shoulder buttons.

## Do Not Do Yet

Avoid these until hardware validation is done:

- Do not build a fake complete `.nro` and present it as install-ready native firmware.
- Do not make Arm trigger automatically from ambiguous browser Gamepad API face buttons.
- Do not remove deadman gating.
- Do not assume Linux event codes are final.
- Do not make robot direct UDP control active without a robot-side receiver and independent E-stop path.
- Do not introduce heavy UI dependencies such as Electron.

## If Asked For A Short Answer

The current best answer is:

> We have a prebuilt Switchroot Linux cockpit package, not custom firmware. It already includes a native-feeling 1280x720 cockpit UI, safety controls, Mac relay mode, direct UDP placeholder mode, and SSH-tunneled camera HUD support. Because the user does not currently have an RCM jig, this is still a pre-install/pre-hardware stage. Before real robot control, the next blocking work is booting Switchroot on the Switch, verifying input mapping, validating the Mac relay endpoint, and testing the robot camera tunnel.

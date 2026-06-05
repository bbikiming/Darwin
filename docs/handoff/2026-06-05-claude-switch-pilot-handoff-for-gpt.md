# Continuation Prompt: Darwin Switch Pilot (handoff for GPT/Claude)

Date: 2026-06-05
Audience: GPT or Claude continuing the Nintendo Switch + Darwin robot cockpit work
Status: pre-hardware (no RCM jig) — Mac-local verification only
Latest commit at handoff: `b51b8dc` on branch `claude/robotis-darwin-op-setup-oyzTi`
(previous milestone `5406b55`). Everything below is committed and pushed.

Paste this file as the starting context when you continue the work.

---

## 0. Role and hard ground rules

You are continuing a Darwin OP (DARwIn-OP) robot-control project for a **UI/UX-focused
planner who is not a Linux/firmware specialist**. Optimize for: safety, GUI quality,
honesty about implemented-vs-verified, and reuse of proven DarwinForge patterns.

Hard rules (do not violate):
- This is **NOT** Nintendo firmware replacement, piracy, DRM bypass, or SysNAND
  modification. The deliverable is a **Switchroot L4T Ubuntu sealed appliance** on the
  SD-card Linux side + a Python cockpit agent.
- The user has **no RCM jig yet** → **nothing is hardware-verified**. Never claim Switch
  boot, Joy-Con mapping, Mac-relay E2E, camera tunnel, real-GPU 3D, or robot motion is
  verified. Say "Mac-local verified" or "hardware-unverified" explicitly.
- Never weaken deadman / Stop / E-stop to make tests easier.
- Do not activate `robot_udp` real control until a robot-side UDP receiver + independent
  stop watchdog exist and are tested.
- The DarwinForge macOS app icon `app/ui/DarwinForge/Sources/DarwinForgeApp/Resources/AppIcon.png`
  is PERMANENT — never modify it; only COPY it (the cockpit/Plymouth icons are resized copies).
- `tools/switch-appliance/apply-appliance.sh` uses X11/openbox as the PRIMARY kiosk; cage
  is opt-in (`--with-cage`). Do not flip cage back to primary (wlroots has no GBM path on Tegra).

---

## 1. What exists now (architecture)

Two trees under `tools/`:

### `tools/switch-pilot/` — the cockpit agent (Python + local web UI)
- `src/darwin_switch_agent/`
  - `main.py` — control loop. **Safety ordering is settled FIRST** via
    `settle_safety_state(armed, estopped, actions, edges) -> SafetySettlement` +
    `zero_motion()`; the final command is computed only after that, then `bus.publish`,
    then per-mode sends. Modes: `dry_run` / `mac_relay` / `robot_udp` / `ssh`. Watchdog
    interval derives from `WATCHDOG_USEC` (systemd) else 5s. `watchdog_label_for(mode)`
    feeds an honest cockpit label. `try_control_call(log, label, fn)` is the transport-
    neutral guarded caller.
  - `ssh_control_client.py` — THE core remote path. Pure `ssh_args(host,user,command,
    identity,timeout,port)` mirroring `SSHShell.swift` (BatchMode, accept-new,
    ServerAlive 2/2, ControlMaster when identity exists, **+ssh-rsa / HostKeyAlgorithms=+ssh-rsa**
    for the robot's OpenSSH 5.9, `-i identity`, `-p port`). Sets `_connected=False` on
    transport failure (exit 255 / timeout). Builds the 14-token WalkLab command line,
    atomic temp+mv write; `stop()/estop()/recover()/poll_telemetry()`.
  - `cockpit.py` — `GET/POST /api/state|/api/action|/api/config`. `/api/config` is
    **loopback-enforced** (`_is_loopback`). `merge_config` deep-merges mac/robot/camera/ssh.
  - `control_bus.py` — thread-safe snapshot + `publish_telemetry` + `set_watchdog_label`;
    Korean action log labels.
  - `config.py` — `validate_provisioning` allowlist (mode + mac/robot/camera/ssh).
  - `input_linux.py` — selects ONE controller by `prefer_names`, excludes `(IMU)` nodes,
    resolves button roles from device capabilities at runtime (Nintendo A/B swap handled).
  - `mapping.py`, `safety.py` (`SafetyEdges`/`SafetyState`), `robot_udp_client.py`
    (`send_stop` repeats), `mac_relay_client.py`, `discovery.py`, `systemd_notify.py`.
  - `__init__.py` (`__version__`).
- `web/` — single-screen 1280x720 cockpit, fully **Korean (UX-written)**, no CDN/import-maps.
  - `index.html`, `styles.css`, `app.js` (camera `<img>` periodic reload + auto-retry,
    honest watchdog from snapshot, robot3d eager-mount bootstrap with `safeFlag` +
    WebGL feature-detect; **figure hidden via `body.has-robot3d`** — NOT a stage-panel
    class, because app.js rewrites stage-panel's class every tick).
  - `setup.html` / `setup.js` — first-boot provisioning (mode incl. ssh, targets, camera,
    **3D model toggle** via `localStorage darwinNo3D`).
  - `robot3d.js` — RUNTIME: loads ONE `assets/darwin.glb` via `GLTFLoader` (vendored,
    relative imports), camera-fallback only, FPS/DPR capped, paused when camera live.
  - `assets/darwin.glb` (~0.54MB, decimated), `assets/darwin-icon.png` (DarwinForge copy).
  - `vendor/` — RUNTIME: `three.module.min.js`, `GLTFLoader.js`, `BufferGeometryUtils.js`.
    BUILD-ONLY (pruned from package/install): `STLLoader.js`, `GLTFExporter.js`, `TextureUtils.js`.
  - BUILD-ONLY pages: `robot3d-rig.js` (STL→assembly rig), `build-glb.html` (bake),
    `robot3d-test.html` (on-device GPU check).
- `tests/` — 11 files, **100 tests** (mapping, gate, safety, safety_settlement, config,
  cockpit incl. loopback, control_bus, robot_udp, input_roles, ssh_control_client).
- `install.sh` (prunes build-only from the install), `uninstall.sh`, `package.sh` (prunes
  build-only; tarball ~0.59MB), `bin/darwin-switch-cockpit` (kiosk launcher), 
  `bin/darwin-switch-camera-tunnel` (autossh), `systemd/darwin-switch-agent.service`
  (`Type=notify`, `WatchdogSec=15`), `desktop/*.desktop` (Icon set), `config.example.json`,
  `assets/decimate_glb.py` (build-only).

### `tools/switch-appliance/` — L1–L4 sealing layer (SD-card Linux only)
- `boot/hekate_ipl.ini.example` — autoboot, **bootwait>=3, VOL- escape** (VOL- opens the
  Hekate menu; VOL++POWER+jig is RCM injection — different action; documented).
- `seal/` — `no-sleep.sh` (mask sleep/suspend + logind ignore), `autologin.sh`
  (getty@tty1 darwin), `ssh-harden.sh` (key-only only when a key exists; never aborts the
  installer if sshd absent), `time-sync.sh` (Switch RTC is garbage → NTP), `overlayroot.{sh,conf}` (opt-in).
- `session/` — `darwin-kiosk.sh`, `darwin-kiosk.service` (cage, opt-in), `openbox-autostart`.
- `branding/plymouth/darwin/` — `darwin.plymouth`, `darwin.script`, `logo.png` (DarwinForge
  copy), README.
- `power-button-stop/` — `darwin-power-stop.py` (+ `.service`) maps the power/sleep key to robot STOP.
- `apply-appliance.sh` (X11 primary, `--with-cage`, `--with-overlayroot`, `--dry-run`,
  dependency preflight, time-sync), `VERSION`, `README.md`, `RECOVERY.md`.

### Docs
- `docs/prd/darwin-switch-controller-prd.md`, `docs/prd/darwin-switch-appliance-design.md`
- `docs/reports/2026-06-05-switch-appliance-evidence-based-architecture.md` (the
  evidence-based stack + deltas), `…-switch-ssh-remote-control-design.md`,
  `…-switch-native-ui-upgrade-methodology.md`, `…-03-switch-ssh-robot-control-setup-plan.md`,
  `…-04-switch-robot-camera-hud-feasibility.md`.
- `docs/handoff/…-continuation-prompt.md`, `…-audit-fix-prompt.md`, and this file.

---

## 2. Robot SSH control protocol (the core path) — ground truth

The robot runs an onboard daemon `WalkLabBrokerage` (entered via `/tmp/df-pilot-mode`
== `walklab`) that polls files every 100ms. Source of truth:
`firmware-patches/walklab-brokerage/WalkLabBrokerage.cpp` / `.h`.

- COMMAND `/tmp/df-walklab-cmd` (write atomically: temp then `mv -f`): 14 space-separated
  tokens: `{cmd_id} {enabled} {x} {y} {a} {period} {foot} {hip} {bgain} {benable} {blevel}
  {headPan} {headTilt} {ballTrack}`. enabled 0/1; x=stride mm, a=turn deg; defaults
  period 600 / foot 40 / hip 13; bgain 1.0 benable 0 blevel 2; ballTrack 0.
- E-STOP `/tmp/df-walklab-estop`: presence == STOP (`touch` to stop, `rm -f` to re-arm).
- TELEMETRY `/tmp/df-walklab-telemetry`: `TEL {ts} {gx}{gy}{gz} {ax}{ay}{az} {voltage_dV}
  {walking01} {fallen}` (cat over SSH).
- The daemon has a ~5s command-staleness auto-stop. The robot is **OpenSSH 5.9** → RSA key
  + `+ssh-rsa` + ControlMaster mandatory. Wired direct `192.168.123.1`, user `robotis`.

DarwinForge reference patterns to reuse (do not reinvent):
`Connection/SSHShell.swift`, `WalkLab/Components/WalkLabOnboardBridge.swift`,
`ConnectionStore.swift`, `Connection/ConnectionWizard.swift`.

---

## 3. 3D model build pipeline (for re-baking the GLB)

The cockpit ships ONE decimated `web/assets/darwin.glb`. To regenerate it:
1. STL source: `vendor/robotis-op2-common/meshes/*.stl` (21 parts) + URDF rig replicated
   in `web/robot3d-rig.js` (mirrors the Mac app `Visualization/MeshRig.swift`).
2. Bake (browser): serve the repo with a small static+POST server that maps `/meshes/` →
   `vendor/robotis-op2-common/meshes` and accepts `POST /save-glb` → writes
   `web/assets/darwin.glb`; open `web/build-glb.html` (assembles via the rig, welds
   vertices with `BufferGeometryUtils.mergeVertices`, exports via `GLTFExporter`).
3. Decimate: `python3 -m venv venv && venv/bin/pip install trimesh fast-simplification`,
   then `venv/bin/python tools/switch-pilot/assets/decimate_glb.py
   web/assets/darwin.glb web/assets/darwin.glb 0.3` (keep ~30% faces).
Result confirmed renders identically; 101k→30k faces, 4.9MB STL → 0.54MB GLB.

Note: headless Chrome with `--virtual-time-budget` cannot reliably screenshot the live
WebGL frame in the full cockpit (it fast-forwards the clock before the render flushes).
Verify the model with a REAL browser window + `screencapture`, or `web/robot3d-test.html`.

---

## 4. Verified locally (Mac) — NOT hardware

```bash
PYTHONPATH=tools/switch-pilot/src python3 -m unittest discover -s tools/switch-pilot/tests
# -> 100 tests OK
python3 -m compileall -q tools/switch-pilot/src tools/switch-pilot/tests   # OK
node --check tools/switch-pilot/web/app.js tools/switch-pilot/web/setup.js \
  tools/switch-pilot/web/robot3d.js tools/switch-pilot/web/robot3d-rig.js   # OK
bash -n tools/switch-pilot/install.sh tools/switch-pilot/package.sh \
  tools/switch-pilot/uninstall.sh tools/switch-appliance/apply-appliance.sh \
  tools/switch-appliance/seal/time-sync.sh   # OK
# Real cockpit (real server + real browser): GLB model renders in the stage, DarwinForge
# icon shows, Korean UI, honest watchdog label, /api/config loopback-guarded.
PYTHONPATH=tools/switch-pilot/src python3 -m darwin_switch_agent.main \
  --config tools/switch-pilot/config.example.json   # cockpit at http://127.0.0.1:8765/
```

---

## 5. Suggested next work (priority order)

P0 — physical bring-up (blocked on RCM jig). Follow
`docs/reports/2026-06-05-switch-appliance-evidence-based-architecture.md` §5 bring-up order:
1. RCM jig → Hekate → NAND backup → Switchroot L4T Ubuntu Noble → SSH.
2. Capture Joy-Con `evtest` codes; confirm `input_linux.py` selection + role resolution; update `config.example.json` if needed.
3. `apply-appliance.sh` on device; confirm X11 kiosk auto-boots to the cockpit; test recovery (VOL-).
4. Mac relay E2E (Arm/heartbeat/stop/estop/walk); then SSH walklab control with the robot RAISED / torque-off.
5. Camera tunnel (`darwin-switch-camera-tunnel`, autossh) + MJPEG longevity.
6. Real-GPU 3D test (`robot3d-test.html`); decide cage vs X11; decimate further or disable 3D if the Tegra GPU struggles (toggle already exists).

P1/P2 — pre-hardware still possible:
- robot_udp robot-side receiver (firmware-patches) + ~500ms watchdog BEFORE enabling real UDP.
- Optional GLB size/perf: Draco compression (needs DRACOLoader) or deeper decimation.
- Optional UX: Pilot/Diagnostics two-state cockpit (PRD §15.5); more tests.

---

## 6. Constraints recap — do NOT claim
- "Switch install verified", "Joy-Con mapping verified", "Robot direct control verified",
  "Camera verified on Switch", "3D verified on Switch GPU", "Safe for floor-walking".

Correct status line:
> Prebuilt Switchroot Darwin cockpit (SSH walklab control + Mac relay + real 3D model +
> Korean UI + DarwinForge icon), Mac-local verified and Codex-audited. Still awaiting RCM
> jig, Switchroot boot, input mapping capture, Mac-relay E2E, camera tunnel, real-GPU 3D,
> and raised-robot safety tests before real robot motion.

---

## 7. Conventions
- Conventional Commits, Korean subjects common (e.g. `feat(switch): …`). Branch
  `claude/robotis-darwin-op-setup-oyzTi` (has upstream). Commit hooks block `--no-verify`
  and heredoc commit messages may trip the hook — write the message to a file and use
  `git commit -F`.
- Unrelated already-dirty files in the tree (`.gitignore`, two DarwinForge Swift Connection
  files) are NOT part of this work — do not stage them with the switch changes.

# Darwin Switch Agent

Installable runtime bundle for a Nintendo Switch running Switchroot L4T Ubuntu.

This is not a replacement Nintendo firmware image. It is a Darwin-specific
Linux runtime package that can be copied onto the Switch after Switchroot
Ubuntu is booting and SSH is enabled.

## Current Scope

- Reads Linux input events from `/dev/input/event*`.
- Uses `ZL` as the deadman input by default.
- Maps the left stick to walk forward/back and turn.
- Maps the right stick to head pan/tilt values for future robot-direct support.
- Sends Mac relay commands over the DarwinForge `/mobile-relay` WebSocket.
- Sends robot-direct UDP line protocol packets for later onboard receiver work.
- In `ssh` mode, opens an event-driven **UDP fast path**
  (`ssh-parity-contract.md §G`) alongside the SSH WalkLab file path: a 20Hz
  `DFCMD` command stream, an E-STOP ×3 burst (0/50/100ms), and a TEL2 30Hz
  telemetry receive, with automatic fallback to the SSH file path. The file path
  stays the permanent fallback.
- Serves a Switch-sized local cockpit at `http://127.0.0.1:8765/`.
- Serves a runtime 3D model performance check at
  `http://127.0.0.1:8765/model-check.html`.
- Displays the robot MJPEG camera stream as a mecha-style cockpit HUD when a
  camera tunnel is open.
- Lets the operator switch between `모델` control mode and `카메라` control
  mode. Model mode uses the local GLB viewer; camera mode uses the SSH-tunneled
  robot camera with speed, command, and gyro overlays.
- Includes selectable `라이트` and `다크` cockpit themes. The light theme is the
  default for a cleaner Switch dashboard look.
- Uses a local inline SVG icon system across cockpit, setup, and model-check
  screens. The icons are intentionally flat line icons, so the GUI keeps a
  native-app feel without network fonts or external icon packages.
- Includes a selectable `계기판` dashboard style inspired by classic luxury
  sedan clusters: dark glass panel, thin analog ticks, restrained gold accents,
  and compact speed/angle/gyro readouts for the Switch's 1280x720 screen. In
  this mode the GLB/WebGL model stage is not mounted; the screen is data-only.
- Ships a local app manifest and service worker so the kiosk browser behaves
  more like a native cockpit shell. Static UI/model assets are cached; control
  APIs and camera streams always stay live and uncached.
- The kiosk launcher gives Chromium/Chrome a dedicated cockpit browser profile
  under the user's cache directory. This keeps PWA/service-worker cache stable
  across launches while avoiding normal browser tabs, restore prompts, and
  first-run UI.
- Opens `/setup.html` automatically on first boot until the local config is
  saved. After provisioning, the same kiosk launcher opens the cockpit at `/`.
- Provides a setup `연결 점검` preflight that validates the pending mode before
  saving: Mac/SSH TCP reachability, local SSH key presence, robot UDP target
  shape, and camera stream/tunnel port availability. It does not send robot
  control commands.
- Provides a setup `시스템` readiness check backed by `/api/health` so the
  operator can see kiosk browser, systemd service, joycond, input nodes, camera
  tunnel helper/service, autossh, and config-file readiness before piloting.
- Provides a read-only `darwin-switch-input-check` command that lists the
  selected evdev controller, resolved ZL/ZR/A/B/Home role codes, and optional
  raw button/stick event capture before any robot command is sent.
- Provides a read-only `darwin-switch-network-check` command for local cockpit
  API, Mac relay target, robot SSH TCP/auth probe, autossh, and camera stream
  URL readiness. It does not send robot control commands.
- Provides a Switch-side `darwin-switch-day0-acceptance` command that runs the
  installed preflight, local smoke test, controller input check, and
  network/camera check as one post-install go/no-go report.
- Provides a read-only `darwin-switch-native-acceptance` command for the
  native cockpit stage. It verifies GTK runtime availability, `ssh` mode,
  absolute SSH identity path, live Joy-Con input selection, local cockpit API,
  and the robot-side WalkLab command file parse including `stride`, `side`,
  `turn`, and held head pan/tilt tokens.
- Shows an in-cockpit recovery panel with `재연결`, `점검`, and `설정` controls.
  `재연결` restarts the Mac relay / SSH transport path without changing the
  current safety state.
- Uses single-flight state polling with short fetch timeouts, so a slow local
  agent or temporarily stalled network path cannot pile up overlapping
  `/api/state` requests in the Switch browser.
- Installs a desktop autostart launcher that opens the cockpit fullscreen.
- Installs as a systemd service.

The cockpit is intentionally implemented as a local web UI so the first
Switchroot Ubuntu install does not need Qt, Electron, or other heavy GUI
dependencies. It is laid out for the Switch's 1280x720 screen and exposes
safety state, command authority, stick axes, logs, and direct safety actions.

## Switch Controls

The setup and model-check pages can be completed without a mouse when the
browser receives Joy-Con/keyboard-style keys:

- D-pad / arrow keys: move focus between visible controls.
- `A` / Enter / Space: activate the focused control.
- Setup: `X` runs `연결 점검`, `Y` opens `3D 성능 점검`, `+` saves, `B` opens
  the cockpit.
- 3D check: `X` applies the measured recommendation, `Y` turns 3D on, `B`
  returns to setup, `+` opens the cockpit.

## Switchroot OS Prerequisites

Install and boot Switchroot L4T Ubuntu before installing this package. The
recommended target is L4T Ubuntu Noble 24.04; Jammy 22.04 is still acceptable
for this cockpit because the runtime only requires Python 3, systemd, a kiosk
browser, local input devices, and SSH client tools.

Official Switchroot references:

- Noble guide: https://wiki.switchroot.org/wiki/linux/l4t-ubuntu-noble-installation-guide
- Linux distributions / first install flow: https://wiki.switchroot.org/wiki/linux/linux-distributions

Project day-0 runbook:

- `docs/guides/switchroot-darwin-day0-runbook.md`

Optional SD layout check from the Mac before Hekate `Flash Linux`:

```bash
tools/switch-pilot/check-switchroot-sd.sh --stage before-flash /Volumes/<SD_NAME>
```

Optional physical transfer helper when Switchroot SSH is not ready:

```bash
tools/switch-pilot/copy-kit-to-sd.sh --stage any /Volumes/<SD_NAME>
```

The copy helper reruns the SD checker with `--require-darwin-kit`. That check
now verifies the Darwin kit folder, install tarball checksum, runtime package
checksum, and manifest/package metadata before you eject the SD.
It also runs an SD layout precheck plus a tiny temporary-file write/remove
check before copying, so an accidental non-Switchroot path or read-only mount is
rejected before any Darwin install kit files are written.

Recommended one-command Mac/PC preparation before ejecting the SD:

```bash
tools/switch-pilot/prepare-day0-host.sh \
    --hekate-payload /path/to/hekate_ctcaer_6.0.6_or_newer.bin \
    --rcm-injector /path/to/rcm-injector-or-app \
    --switchroot-archive /path/to/switchroot-l4t-ubuntu-noble.7z \
    --sd-root /Volumes/<SD_NAME> \
    --copy-kit-to-sd \
    --strict
```

This runs `verify-release.sh`, checks host prerequisites, copies the Darwin
install kit to the SD root, reruns host/SD validation with
`--require-darwin-kit`, and leaves the SD ready for the physical RCM/Hekate
stage.

macOS RCM injection helper:

```bash
tools/switch-pilot/mac-rcm-injector/darwin-switch-rcm-inject.sh --check-only
tools/switch-pilot/mac-rcm-injector/darwin-switch-rcm-inject.sh \
    --payload dist/switch-pilot/hekate_ctcaer_6.5.2.bin
```

Optional double-click app wrapper:

```bash
tools/switch-pilot/mac-rcm-injector/make-macos-app.sh
open "dist/switch-pilot/Darwin Switch RCM Injector.app"
```

The `.app` is a native AppKit GUI for payload selection, APX/RCM status,
dependency checks, injection, and logs. Both the app and command-line helper use
the same `darwin-switch-rcm-inject.sh` backend, which runs `fusee-launcher.py`
from a local app-support checkout. It does not inject unless the Switch is
connected in RCM. Keep a Mac-local Hekate payload copy because the SD card is
inside the Switch during this stage.

To include the final sync + safe eject step in the same preparation command,
add `--eject-sd`:

```bash
tools/switch-pilot/prepare-day0-host.sh \
    --hekate-payload /path/to/hekate_ctcaer_6.0.6_or_newer.bin \
    --rcm-injector /path/to/rcm-injector-or-app \
    --switchroot-archive /path/to/switchroot-l4t-ubuntu-noble.7z \
    --sd-root /Volumes/<SD_NAME> \
    --copy-kit-to-sd \
    --eject-sd \
    --strict
```

If the kit is already on the SD and you only want the final validation + eject:

```bash
tools/switch-pilot/eject-day0-sd.sh \
    --stage any \
    --require-darwin-kit \
    /Volumes/<SD_NAME>
```

Optional Mac/PC day-0 readiness check before touching the Switch:

```bash
tools/switch-pilot/check-day0-host.sh \
    --hekate-payload /path/to/hekate_ctcaer_6.0.6_or_newer.bin \
    --rcm-injector /path/to/rcm-injector-or-app \
    --switchroot-archive /path/to/switchroot-l4t-ubuntu-noble.7z
```

After copying the Darwin kit to the mounted SD root, the host check can also
require that the kit is present and self-consistent:

```bash
tools/switch-pilot/check-day0-host.sh \
    --hekate-payload /path/to/hekate_ctcaer_6.0.6_or_newer.bin \
    --rcm-injector /path/to/rcm-injector-or-app \
    --switchroot-archive /path/to/switchroot-l4t-ubuntu-noble.7z \
    --sd-root /Volumes/<SD_NAME> \
    --require-darwin-kit \
    --strict
```

Hardware and OS assumptions for a one-pass Darwin install:

- Unpatched Switch that can enter RCM, plus RCM jig and USB-C cable.
- Local RCM payload injection tool prepared and tested with the chosen cable.
- Hekate 6.0.6 or newer for Noble.
- microSD: 16GB minimum, 128GB+ U3/U3/A2 recommended.
- SD content backed up before Hekate partitioning; Hekate partitioning is
  destructive.
- Switchroot L4T Ubuntu booted from Hekate `More Configs`.
- Joy-Con BT data dumped in Hekate Nyx Options after pairing Joy-Cons in the
  normal Nintendo OS.
- Wi-Fi working in Ubuntu. If a WPA3/WPA2 transition network fails, use a WPA2
  network or configure it manually from NetworkManager/nmcli.
- Terminal access on the Switch, either directly with keyboard/touch or via SSH.

After first Ubuntu boot, update the base OS once:

```bash
sudo apt update
sudo apt-get dist-upgrade
sudo reboot
```

The one-pass installer runs a small OS bootstrap automatically, but on a very
fresh image it is still useful to know what it may install:

```bash
python3 python3-gi gir1.2-gtk-3.0 openssh-client openssh-server autossh xdg-utils curl firefox/chromium
```

If `joycond` is absent, install it via the Switchroot/L4T tooling available on
the image, then enable it:

```bash
sudo systemctl enable --now joycond
```

## One-Pass Darwin Install On Switchroot Ubuntu

From the Mac/repository root, build the install tarball:

```bash
tools/switch-pilot/verify-release.sh
```

This is the release gate. It runs shell/Python/web tests, bundle preflight, a
no-root simulated install tree for `/opt`, `/etc`, `/usr/local/bin`, systemd,
and desktop files, validates systemd/desktop path references, then builds and
validates the runtime package and field kit.

This produces both the raw runtime package and a field install kit:

```text
dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz
dist/switch-pilot/darwin-switch-install-kit-0.1.0/
dist/switch-pilot/darwin-switch-install-kit-0.1.0.tar.gz
```

Preferred field flow from the Mac:

```bash
dist/switch-pilot/darwin-switch-install-kit-0.1.0/copy-to-switch.sh \
    <switch-user>@<switch-ip>
```

One-command remote deploy from the Mac, when SSH to the Switch is reachable:

```bash
dist/switch-pilot/darwin-switch-install-kit-0.1.0/deploy-to-switch.sh \
    <switch-user>@<switch-ip>
```

This copies the kit, runs `install-on-switch.sh` over SSH, then prints the
robot SSH readiness plan from the installed Switch runtime. The command still
uses normal SSH/password prompts; it does not store the Switch password.

Then on the Switch:

```bash
cd ~/darwin-switch-install-kit-0.1.0
./install-on-switch.sh
```

The kit script verifies checksum, cross-checks manifest/package metadata when
`python3` is available, extracts the runtime package, runs the one-pass
installer, reruns installed preflight, runs local smoke checks, records a
read-only input device report, records a network/camera report, and writes a
timestamped install log under `~/darwin-switch-install-*.log`.
The log starts before package presence, checksum, manifest, and extraction
checks, so early transfer/corruption failures are captured too.
The log also prints `manifest.json`, including package SHA-256, package size,
runtime entry count, release-gate checks, install sequence, runtime exclusions,
and post-install triage commands.
When `install-on-switch.sh` invokes the one-pass installer, it passes the active
install log path and kit directory to diagnostics. Failure bundles therefore
include `install-logs/` and `install-kit/manifest.json`, which lets the Mac-side
summary identify both the failing step and the exact release kit.

Before real robot piloting, power the robot, confirm the Switch can reach the
robot network, then run on the Switch:

```bash
darwin-switch-robot-ready plan
darwin-switch-robot-ready keygen
darwin-switch-robot-ready copy-key
darwin-switch-robot-ready probe
darwin-switch-robot-ready status
darwin-switch-robot-ready start-walklab
darwin-switch-robot-ready enable-agent-ssh
```

### Robot endpoint override + reachability (Mac wizard bridge)

The deployed config often defaults the robot host to the wired direct-ethernet
IP (`192.168.123.1`), which the Switch on Wi-Fi cannot route to — key
distribution alone does not connect them. Two additions close the network half:

```bash
# Which candidate robot IPs can THIS host (the Switch) actually reach on :22?
darwin-switch-robot-ready reachability --candidates 192.168.123.1,192.168.0.100
#   → reach=<ip>:22 open|closed ; DF_REACHABLE=<first-open>  (or =none)

# Point every command at a routable robot IP; enable-agent-ssh persists it.
darwin-switch-robot-ready probe            --robot-host 192.168.0.100
darwin-switch-robot-ready enable-agent-ssh --robot-host 192.168.0.100
```

The DarwinForge Mac app's **Switch Robot Link Setup** wizard (전문가 ▸ 스위치 연결)
drives this end to end: it reads the robot's own IPs over its *working* robot
SSH channel, runs `reachability` on the Switch to pick the routable one,
registers the Switch public key into the robot's `authorized_keys` via that same
working channel (sidestepping the Switch `ssh-copy-id` hang), then runs
`probe`/`status`/`start-walklab`/`enable-agent-ssh --robot-host <reachable>`.

`darwin-switch-robot-ready all` runs the same sequence up to the first
actionable stop. It mirrors DarwinForge's successful robot SSH path:
`BatchMode=yes`, `StrictHostKeyChecking=accept-new`, server keepalives,
legacy `+ssh-rsa` compatibility for the robot's OpenSSH 5.x server, the
`~/.ssh/id_rsa_darwin` RSA identity, and ControlMaster reuse when that identity
exists. It refuses to claim readiness if the robot-side DarwinForge WalkLab
brokerage patch is missing. On success it updates the Switch agent config to
`mode=ssh` and restarts `darwin-switch-agent.service`; it may ask for the Switch
sudo password.

### Native Cockpit Control Acceptance

Launch the GTK cockpit on the Switch:

```bash
darwin-switch-native-cockpit
```

Before moving the real robot, press the cockpit `조종 검증 6초` button, or run
the same read-only check from a Switch terminal:

```bash
darwin-switch-native-acceptance --sample-seconds 6 --strict
```

During the 6-second sample, press `A` once to arm, hold `ZL/ZR`, move the left
stick gently and strongly in several directions, and move/release the right
stick once to confirm head-hold. Interpret the cockpit result as follows:

- `agentΔ` non-zero: Joy-Con input is reaching the Switch agent.
- `robotΔ` non-zero and close to `agentΔ`: SSH writes are reaching the robot
  `/tmp/df-walklab-cmd` file.
- `periodΔ` non-zero: gait cadence changes with stick strength, so walking
  speed is not stuck at one fixed value.
- `speedVar=true`: the sampled robot command file shows gait period/foot
  variation, so stick strength is changing the robot-side gait values.
- `headHold=true`: after the right stick is released, the robot command file
  still carries the last head pan/tilt value instead of snapping to center.

If `agentΔ` is large but `robotΔ` is near zero, the Switch UI/input layer is
working and the remaining fault is in SSH write/auth, robot file permissions,
or WalkLab brokerage state. If both are near zero, check A/ZL/ZR, Joy-Con
pairing, and `/dev/input/event*` selection first.

For a faster package-only build during iteration, use
`tools/switch-pilot/package.sh`. To rebuild only the field kit, use
`tools/switch-pilot/make-install-kit.sh`. Before copying to the Switch, prefer
`verify-release.sh`.

Raw tarball fallback:

Copy the tarball and checksum to the Switch:

```bash
scp dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz \
    dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz.sha256 \
    <switch-user>@<switch-ip>:~
```

On the Switch, verify the transfer, unpack, and run the one-pass installer:

```bash
cd ~
sha256sum -c darwin-switch-agent-0.1.0.tar.gz.sha256
tar -xzf ~/darwin-switch-agent-0.1.0.tar.gz
cd ~/darwin-switch-agent-0.1.0
./bin/darwin-switch-onepass-install
```

The one-pass installer runs OS dependency bootstrap, source-bundle preflight,
`sudo ./install.sh`, `sudo systemctl enable --now darwin-switch-agent`,
installed preflight, local smoke test, and a read-only input device report. It
also records a network/camera readiness report and stops on `BAD` preflight
results.

To run only the OS bootstrap before the full installer:

```bash
./bin/darwin-switch-bootstrap-os --if-needed
```

Bootstrap writes a persistent log here:

```text
${XDG_CACHE_HOME:-~/.cache}/darwin-switch-cockpit/logs/bootstrap.log
```

If this fails during `apt-get update` or package install, check Switchroot
Wi-Fi, DNS, date/time, and repository availability, then rerun the same command.

For manual installation or debugging, run the same steps individually:

```bash
./bin/darwin-switch-bootstrap-os --if-needed
./bin/darwin-switch-preflight --root . --config config.example.json
sudo ./install.sh
sudo systemctl enable --now darwin-switch-agent
darwin-switch-preflight --installed
curl -fsS http://127.0.0.1:8765/api/state
journalctl -u darwin-switch-agent -f
```

Open the cockpit manually if the desktop autostart has not run yet:

```bash
darwin-switch-cockpit
```

On first launch this opens `/setup.html`. Save the setup once; that writes
`/etc/darwin-switch-agent/.provisioned`, after which the kiosk launcher opens
the cockpit directly.

Edit configuration only when the setup screen cannot cover a hardware-specific
edge case:

```bash
sudo nano /etc/darwin-switch-agent/config.json
```

Useful recovery commands:

```bash
sudo systemctl restart darwin-switch-agent
sudo systemctl restart darwin-switch-camera-tunnel
darwin-switch-preflight --installed
darwin-switch-day0-acceptance --input-seconds 8 --strict
darwin-switch-smoke-test --installed
darwin-switch-input-check --seconds 8
darwin-switch-network-check
darwin-switch-collect-diagnostics
```

## Legacy Folder Copy Install

The tarball flow above is preferred. For local development only, you can still
copy this folder directly to the Switch:

```bash
scp -r tools/switch-pilot <switch-user>@<switch-ip>:~/switch-pilot
ssh <switch-user>@<switch-ip>
cd ~/switch-pilot
./bin/darwin-switch-preflight --root . --config config.example.json --strict
sudo ./install.sh
```

On Chromium-based browsers the launcher uses:

```text
${XDG_CACHE_HOME:-~/.cache}/darwin-switch-cockpit/chromium
```

as the dedicated kiosk profile. Override it with
`DARWIN_SWITCH_CHROMIUM_PROFILE=/path/to/profile` only when debugging browser
state or clearing a corrupted profile.

The fullscreen launcher also writes a persistent first-boot log:

```text
${XDG_CACHE_HOME:-~/.cache}/darwin-switch-cockpit/logs/launcher.log
```

This records the URL readiness wait, browser selected, and no-browser failures.
Override it with `DARWIN_SWITCH_COCKPIT_LOG=/path/to/launcher.log` only for
debugging.

On a fresh install this opens the first-boot setup screen. Saving the setup
writes `/etc/darwin-switch-agent/.provisioned`, after which the launcher opens
the cockpit directly. To inspect the cockpit before provisioning, open:

```text
http://127.0.0.1:8765/index.html
```

Check whether the Switch can show the cockpit model comfortably:

```text
http://127.0.0.1:8765/model-check.html
```

Use the page on the Switch itself. The verdict is based on the local browser's
actual WebGL frame timing at the 30fps cap:

- `충분`: average at least 24fps and no long frame spike over 120ms.
- `주의`: usable as a camera-fallback model, but do not run MJPEG and WebGL together.
- `불충분`: disable the 3D model from setup and keep the CSS fallback.

Logs:

```bash
journalctl -u darwin-switch-agent -f
```

The setup screen's `현재 상태 > 시스템` card is the fastest local readiness
check after install. `bad` means the fullscreen cockpit cannot behave like a
native shell yet (usually no browser). `warn` means the cockpit can run but a
Switch-specific support piece such as `joycond`, `/dev/input` access, or
`autossh` still needs attention. The same panel includes `카메라 터널 시작/복구`,
which runs the whitelisted local service action equivalent to:

```bash
sudo systemctl enable --now darwin-switch-camera-tunnel
```

If install or first boot fails, collect a diagnostic tarball before changing
more state:

```bash
darwin-switch-collect-diagnostics
```

The one-pass installer also tries to run this automatically on failure. If the
failure happens after the runtime has been installed, it attempts both source
bundle diagnostics and installed `/opt`/`/etc` diagnostics.
When launched from the field install kit, diagnostics also copies the active
`~/darwin-switch-install-*.log` and the kit `manifest.json` into the tarball.
Diagnostics also copies `bootstrap.log` and the kiosk `launcher.log`, so apt
dependency failures, a black screen, or a missing browser on first login can be
diagnosed after the fact.
After copying `~/darwin-switch-diagnostics-*.tar.gz` back to the Mac, summarize
it from the repository root:

```bash
tools/switch-pilot/summarize-diagnostics.py ~/darwin-switch-diagnostics-*.tar.gz
```

After install, run the combined day-0 acceptance command first. During the
input capture window, hold ZL/ZR, press A, B, Home, and move both sticks:

```bash
darwin-switch-day0-acceptance --input-seconds 8 --strict
```

`GOOD` means the local cockpit/service path and controller mapping are ready for
setup/model-check. `WARN` means a hardware-dependent item still needs attention.
`BAD` means do not pilot yet; the command attempts diagnostics when available.

Then run the local smoke test if you need the detailed service/API/page list:

```bash
darwin-switch-smoke-test --installed
```

Then verify Joy-Con/Pro Controller input without sending any robot command:

```bash
darwin-switch-input-check --seconds 8
```

During the capture window, hold ZL or ZR, press A, B, Home, and move both
sticks. Expected result: selected device is a combined Joy-Con or Pro Controller
node, deadman/arm/stop/estop are `seen`, and all four stick axes are `seen`.
If only an `(IMU)` node appears, or roles/axes stay `not seen`, fix Joy-Con
pairing, `joycond`, or `/dev/input` permissions before piloting.

Then verify local networking, robot SSH, and camera stream readiness without
sending robot movement commands:

```bash
darwin-switch-network-check
```

`WARN` is acceptable before the robot, Mac relay, or camera tunnel is actually
configured. Use `--ssh-probe` only when the robot is powered and SSH settings
are ready; it runs a read-only `echo ok`.

## Modes

`mode = "ssh"` (primary WalkLab path):

Switch -> robot over SSH to the WalkLab brokerage. Commands are written to the
robot command file (`/tmp/df-walklab-cmd`), E-STOP touches
`/tmp/df-walklab-estop`, and telemetry is read from `/tmp/df-walklab-telemetry`.
These file paths are the **permanent fallback** and always work.

When `ssh.transport = "auto"` (default) and an SSH identity exists, the agent
ALSO opens the event-driven **UDP fast path** from `ssh-parity-contract.md §G`
on top of the same SSH session. It is purely additive — the robot side (O1/O4)
already consumes this contract, so no robot or Mac code changes are needed:

- **Handshake (§G.1)** — writes `/tmp/df-walklab-channel` =
  `"{token} {estop_port} {cmd_port}"` (atomic tmp+mv) plus
  `/tmp/df-walklab-uplink` = `"{ip}:{port}"` so the robot streams telemetry back
  to us. The robot picks it up within ≤1s and starts its UDP threads. On session
  end / fallback the agent clears both files so the robot returns to file-poll
  with no stale listener or old token.
- **Command (§G.3)** — `DFCMD {token} {seq} {line}` datagrams to `cmd_port`
  (17374) at `udp_send_hz` (20Hz), `seq` strictly monotonic; the robot replies
  `ACK {seq} {t_rx}` (used for RTT + effective-Hz). `line` is the same §C
  14-token command line as the file path — the Switch stays on v1, which the
  robot accepts permanently.
- **E-STOP (§G.2)** — `DF-ESTOP v1 {token} {ms}` fired as a **×3 burst at
  0/50/100ms**, in parallel with the SSH file touch (first to land wins). The
  file touch always fires too, so a dropped burst can never leave the robot
  un-stopped.
- **Telemetry (§A.2-TEL2)** — receives the robot's `TEL2 …` 30Hz stream (gait
  phase, shaped latch amplitudes, FSR ground contact, CoP, `active_source`);
  while it is fresh the SSH `cat` poll relaxes to a 1Hz fallback heartbeat.

**auto fallback**: if no `ACK` arrives within `ack_probe_ms` (1.5s) the agent
tears down the UDP socket, clears the handshake, and continues on the SSH file
path at `send_hz` (5Hz) — no interruption to piloting. Set
`ssh.transport = "ssh"` to force the file path only and skip the UDP probe.

> Single-pilot assumption: the handshake file holds one token. If the Mac
> cockpit and the Switch both write it, last-writer-wins — run one controller at
> a time.

`mode = "mac_relay"`:

Switch -> Mac DarwinForge MobileRelay -> robot.

`mode = "robot_udp"`:

Switch -> robot over a standalone raw UDP line protocol. This is a separate,
legacy experiment whose onboard receiver was never built, so it is for protocol
testing only. For the real onboard UDP path, use `mode = "ssh"` with
`transport = "auto"` (the implemented §G transport described above).

`mode = "dry_run"`:

Prints mapped state without sending commands.

## Configuration

See `config.example.json`.

Important values:

- `camera.enabled`, `camera.stream_url`, `camera.snapshot_url`
- `camera.local_port`, `camera.remote_port` for the managed SSH camera tunnel
- `camera.route`, `camera.label` for cockpit HUD labeling
- `mac.host`, `mac.port`, `mac.pairing_code`
- `robot.host`, `robot.port`, `robot.token`
- `input.event_globs`
- `mapping.deadman_key_codes`
- `gui.port`, normally `8765`

### SSH transport (`mode = "ssh"`)

The `ssh` section owns the WalkLab path and the §G UDP fast path:

- `ssh.transport` — `"auto"` (default: try the §G UDP path, fall back to the SSH
  file path) or `"ssh"` (force the file path only, no UDP probe).
- `ssh.send_hz` — SSH file-path command rate (default `5`). Used while on the
  file path or after a UDP fallback.
- `ssh.udp_send_hz` — UDP `DFCMD` stream rate while the UDP path is live
  (default `20`).
- `ssh.cmd_port` / `ssh.estop_port` / `ssh.telemetry_port` — §G.7 UDP ports
  (default `17374` / `17372` / `17371`). Conveyed to the robot via the handshake
  file; do not hard-code them elsewhere.
- `ssh.ack_probe_ms` — how long to wait for the first `ACK` after writing the
  handshake before declaring UDP dead and falling back to SSH (default `1500`).
- `ssh.udp_tel_fresh_s` — TEL2 freshness window (default `1.0`); while UDP
  telemetry is fresher than this, the SSH `cat` poll relaxes to a 1Hz heartbeat.

`motion.max_stride_mm` and `ssh.stride_ref_mm` default to **38mm** (was 50): the
robot governor (§G.8) clamps stride per period regardless, so 38 makes the
displayed value match the applied value (mapping-parity table,
`handheld-direct-pilot-upgrade.md §5`).

## Robot Camera

The cockpit is preconfigured to read the robot camera at:

```text
http://127.0.0.1:18080/?action=stream
```

That URL is local to the Switch. Open an SSH tunnel from the Switch to the
robot:

```bash
ROBOT_HOST=192.168.123.1 ROBOT_USER=robotis darwin-switch-camera-tunnel
```

For the native-style Switch install, prefer the managed service. It reads
`/etc/darwin-switch-agent/config.json` (`ssh.host`, `ssh.user`,
`ssh.identity_file`, `camera.local_port`, and `camera.remote_port`) and restarts
the tunnel when it drops:

```bash
sudo systemctl enable --now darwin-switch-camera-tunnel
journalctl -u darwin-switch-camera-tunnel -f
```

Manual launch remains useful for one-off debugging:

```bash
darwin-switch-camera-tunnel --from-config /etc/darwin-switch-agent/config.json
```

The first-boot setup GUI can edit the camera stream URL, snapshot URL, local
Switch tunnel port, robot camera port, route label, and camera label. Use that
screen first; edit `/etc/darwin-switch-agent/config.json` manually only for
hardware-specific edge cases.

The helper does two things:

1. SSH into the robot and start ROBOTIS `camera_tutorial` on port `8080`.
2. Forward Switch `127.0.0.1:18080` to robot `127.0.0.1:8080`.

In the cockpit, choose `카메라` in the top control-mode switch to show the
stream as the primary view. The HUD overlays current speed, stride, turn,
head pan/tilt, and gyro values. Choose `모델` to close the MJPEG image stream
and return to the local 3D robot model. The cockpit intentionally avoids
running MJPEG camera decode and WebGL rendering at the same time on the Switch.

The robot-side stream endpoints are:

```text
http://<robot-ip>:8080/?action=snapshot
http://<robot-ip>:8080/?action=stream
```

If the Switch and robot are on the same trusted network, the cockpit can point
directly to `http://<robot-ip>:8080/?action=stream`. The SSH tunnel is the
safer default because it does not require exposing the camera server beyond the
robot login path.

## Safety Defaults

- Movement is allowed only while deadman is held.
- Deadzone defaults to `0.12`.
- Mac relay heartbeat interval is `100ms`.
- Command send rate defaults to `20Hz`.
- On deadman release, the agent sends stop.
- The fullscreen cockpit has Arm, Stop, Recover, and E-stop controls.

Robot physical safety still matters. Keep the robot's independent stop or
power-cut path available during all tests.

## Package

From the repository root:

```bash
tools/switch-pilot/package.sh
```

The tarball is written to:

```text
dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz
```

`package.sh` runs the bundle-only preflight before creating the tarball. It also
writes a checksum next to the package when `shasum` or `sha256sum` is available:

```text
dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz.sha256
```

Verify the package on macOS before transfer:

```bash
shasum -a 256 -c dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz.sha256
```

Because the checksum file stores only the tarball basename, it can also be
copied to the Switch and verified there with:

```bash
cd ~
sha256sum -c darwin-switch-agent-0.1.0.tar.gz.sha256
```

## Verification

Run the backend, config, safety, transport, and setup-boundary tests:

```bash
PYTHONPATH=tools/switch-pilot/src python3 -m unittest discover -s tools/switch-pilot/tests
```

Run the browser-runtime regression test. This guards the cockpit's single-flight
state polling so a slow `/api/state` response cannot pile up overlapping fetches
inside the Switch browser:

```bash
node tools/switch-pilot/tests/test_web_runtime.mjs
```

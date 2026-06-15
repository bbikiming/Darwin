# Switchroot Darwin Cockpit One-Pass Install Readiness

Date: 2026-06-06

## Purpose

스위치에 Switchroot L4T Ubuntu를 올린 직후 Darwin 전용 조종석을 한 번에
설치하고 실행하기 위한 사전 준비 상태를 정리한다. 이 문서는 Nintendo
Switch 커펌/리눅스 설치 자체를 자동화하지 않는다. 목표는 Linux가 정상
부팅된 뒤 `darwin-switch-agent` 패키지가 설치 중 막히지 않도록 필요한
전제, 순서, 점검 명령, 실패 시 복구 지점을 고정하는 것이다.

## Current Decision

- OS target: Switchroot L4T Ubuntu Noble 24.04 우선.
- Compatibility fallback: Jammy 22.04도 가능하도록 유지.
- Darwin package type: Switchroot 위에 설치하는 Linux runtime tarball.
- Not a firmware image: Nintendo firmware replacement가 아니라 `/opt`,
  `/etc`, `systemd`, kiosk launcher를 설치하는 Linux 앱 패키지다.
- First screen after install: local setup screen, then cockpit.

Official references checked:

- Switchroot Noble guide:
  https://wiki.switchroot.org/wiki/linux/l4t-ubuntu-noble-installation-guide
- Switchroot Linux distributions / first install flow:
  https://wiki.switchroot.org/wiki/linux/linux-distributions

Project day-0 execution runbook:

- `docs/guides/switchroot-darwin-day0-runbook.md`

Mac-side SD layout checker:

- `tools/switch-pilot/check-switchroot-sd.sh`
- `tools/switch-pilot/copy-kit-to-sd.sh`

Mac/PC day-0 host checker:

- `tools/switch-pilot/check-day0-host.sh`

Mac/PC day-0 preparation orchestrator:

- `tools/switch-pilot/prepare-day0-host.sh`

## Hardware And OS Prerequisites

Darwin 패키지 설치 전에 아래가 먼저 끝나야 한다.

- Unpatched Nintendo Switch that can enter RCM.
- RCM jig.
- USB-C cable.
- RCM payload injection tool on the Mac/PC, separate from the Hekate payload
  `.bin` file.
- microSD card: 16GB minimum, 128GB+ U3/U3/A2 recommended.
- Hekate 6.0.6 or newer for Noble.
- Switchroot L4T Ubuntu image extracted to SD FAT32 root.
- Hekate partition/Flash Linux completed.
- Joy-Con BT pairing data dumped from Hekate Nyx Options after normal OS
  pairing.
- Switchroot Ubuntu bootable from Hekate `More Configs`.
- Wi-Fi working in Ubuntu.
- Terminal access on the Switch, or SSH access from Mac.

Important limitation: Hekate partitioning is destructive. Back up SD/FAT32 and
emuMMC data before partitioning.

## Recommended One-Pass Flow

Start with the day-0 runbook when the Switch has not yet booted Switchroot:

```text
docs/guides/switchroot-darwin-day0-runbook.md
```

### 1. Prepare Package On Mac

From repository root:

```bash
tools/switch-pilot/verify-release.sh
```

Expected output:

```text
dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz
dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz.sha256
dist/switch-pilot/darwin-switch-install-kit-0.1.0/
dist/switch-pilot/darwin-switch-install-kit-0.1.0.tar.gz
dist/switch-pilot/darwin-switch-install-kit-0.1.0.tar.gz.sha256
```

Verify package checksum before transfer:

```bash
shasum -a 256 -c dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz.sha256
```

### 2. Copy Field Kit To Switch

Preferred path:

```bash
dist/switch-pilot/darwin-switch-install-kit-0.1.0/copy-to-switch.sh \
    <switch-user>@<switch-ip>
```

Then on the Switch:

```bash
cd ~/darwin-switch-install-kit-0.1.0
./install-on-switch.sh
```

The field installer verifies checksum, cross-checks manifest/package metadata
when `python3` is available, extracts the runtime package, runs the one-pass
installer, reruns installed preflight, runs local smoke checks, records
read-only input and network/camera reports, and writes
`~/darwin-switch-install-*.log`. The log starts before package presence,
checksum, manifest, and extraction checks, so early transfer/corruption
failures are captured too. The log now prints `manifest.json` so a field failure
can be traced back to package SHA-256, package size, runtime entry count,
release-gate checks, install sequence, runtime exclusions, and post-install
triage commands.

Single-file transfer alternative:

```bash
scp dist/switch-pilot/darwin-switch-install-kit-0.1.0.tar.gz \
    <switch-user>@<switch-ip>:~
```

Then:

```bash
tar -xzf ~/darwin-switch-install-kit-0.1.0.tar.gz
cd ~/darwin-switch-install-kit-0.1.0
./install-on-switch.sh
```

### 3. Raw Package Copy Fallback

```bash
scp dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz \
    dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz.sha256 \
    <switch-user>@<switch-ip>:~
```

### 4. Verify And Run One-Pass Installer On Switch

```bash
cd ~
sha256sum -c darwin-switch-agent-0.1.0.tar.gz.sha256
tar -xzf ~/darwin-switch-agent-0.1.0.tar.gz
cd ~/darwin-switch-agent-0.1.0
./bin/darwin-switch-onepass-install
```

The one-pass installer executes:

1. OS dependency bootstrap.
2. Source bundle preflight.
3. `sudo ./install.sh`.
4. `sudo systemctl enable --now darwin-switch-agent`.
5. Installed runtime preflight.
6. Local smoke test for agent/API/static cockpit routes.
7. Read-only input device report.
8. Read-only network/camera readiness report.

Interpretation:

- `GOOD`: safe to continue.
- `WARN`: install may work, but a hardware/runtime item still needs attention.
  Common acceptable pre-install warnings are Joy-Con not paired yet, no input
  node while no controller is connected, or camera tunnel not ready before robot
  setup.
- `BAD`: the one-pass installer stops. Fix the listed item first.

### 5. Manual Install Fallback

```bash
./bin/darwin-switch-bootstrap-os --if-needed
./bin/darwin-switch-preflight --root . --config config.example.json
sudo ./install.sh
sudo systemctl enable --now darwin-switch-agent
darwin-switch-preflight --installed
curl -fsS http://127.0.0.1:8765/api/state
```

The installer copies the runtime to `/opt/darwin-switch-agent`, installs
systemd units and launchers, keeps existing `/etc/darwin-switch-agent/config.json`
when present, compiles Python modules, reloads systemd, and prints post-install
readiness. No `BAD` result should remain. `WARN` on camera is acceptable only
before the robot camera endpoint and SSH tunnel are configured.

Manual cockpit launch:

```bash
darwin-switch-cockpit
```

First launch opens `/setup.html`. Save setup once to create:

```text
/etc/darwin-switch-agent/.provisioned
```

After that, the kiosk launcher opens the cockpit directly.

## Implemented Readiness Assets

- `tools/switch-pilot/bin/darwin-switch-preflight`
  - portable wrapper before install and installed launcher after install.
- `tools/switch-pilot/bin/darwin-switch-bootstrap-os`
  - Switch-side first-boot bootstrap for Python, SSH client, autossh, xdg
    browser launch support, curl, kiosk browser fallback, joycond enablement,
    and interactive input group membership.
  - writes
    `${XDG_CACHE_HOME:-~/.cache}/darwin-switch-cockpit/logs/bootstrap.log`
    with the current install step, missing package list, browser detection, and
    apt/Wi-Fi/DNS/date-time recovery hint so first-boot package failures are
    diagnosable after reboot.
- `tools/switch-pilot/bin/darwin-switch-collect-diagnostics`
  - Switch-side diagnostics bundle collector for install failures and first
    boot triage. It collects preflight JSON, systemd status, journal snippets,
    input nodes, input-check JSON, network state, installed unit files, and
    redacted config into `~/darwin-switch-diagnostics-*.tar.gz`.
- `tools/switch-pilot/summarize-diagnostics.py`
  - Mac-side diagnostics reader. It accepts a copied
    `darwin-switch-diagnostics-*.tar.gz` or extracted diagnostics directory and
    summarizes preflight BAD/WARN items, selected input device status, missing
    input roles/axes, and network/camera BAD/WARN items.
- `tools/switch-pilot/bin/darwin-switch-input-check`
  - Switch-side read-only evdev checker. It lists controller-like event nodes,
    excludes `(IMU)` nodes, selects the same preferred controller as the agent,
    prints resolved deadman/arm/stop/estop codes, and optionally captures raw
    button/stick events with `--seconds N`.
- `tools/switch-pilot/bin/darwin-switch-network-check`
  - Switch-side read-only networking checker. It validates local cockpit API
    reachability, Mac relay TCP shape/reachability, robot SSH TCP/key/auth
    readiness when requested, autossh availability, and configured camera
    stream/snapshot URLs without sending robot movement commands.
- `tools/switch-pilot/bin/darwin-switch-day0-acceptance`
  - Switch-side post-install acceptance command. It runs installed preflight,
    local cockpit smoke, controller input, and network/camera checks as one
    GOOD/WARN/BAD report and writes a timestamped acceptance log.
- `tools/switch-pilot/bin/darwin-switch-onepass-install`
  - Switch-side one-command installer for OS bootstrap, preflight, install,
    service start, installed preflight, smoke test, input/network reports, and
    failure-triggered diagnostics collection.
  - on failure, collects source-bundle diagnostics and, when available,
    installed `/opt`/`/etc` diagnostics so failures after partial install can be
    triaged against the real installed state.
- `tools/switch-pilot/bin/darwin-switch-smoke-test`
  - Switch-side post-install smoke test for installed preflight, agent service,
    `/api/state`, `/api/health`, `/index.html`, `/setup.html`,
    `/model-check.html`, manifest, and service worker reachability.
- `tools/switch-pilot/bin/darwin-switch-cockpit`
  - fullscreen desktop launcher for the local cockpit. It waits for the local
    cockpit URL, disables screen blanking when desktop tools are available,
    launches Firefox/Chromium in kiosk mode, and writes
    `${XDG_CACHE_HOME:-~/.cache}/darwin-switch-cockpit/logs/launcher.log` so
    first-login black-screen/browser failures are recoverable.
- `tools/switch-pilot/bin/darwin-switch-collect-diagnostics`
  - collects read-only OS, service, input, network, preflight, install-log,
    install-kit manifest, OS bootstrap-log, and kiosk launcher-log evidence
    into `~/darwin-switch-diagnostics-*.tar.gz`.
- `tools/switch-pilot/src/darwin_switch_agent/preflight.py`
  - checks OS, Switchroot/L4T hints, architecture, Python, systemd, kiosk
    browser, SSH client, autossh, required bundle files, config validity, GLB
    size, disk space, input nodes, joycond, installed launchers/units, and
    service state.
- `tools/switch-pilot/install.sh`
  - fails early when Python or systemd is missing.
  - installs the preflight, smoke, diagnostics, input-check, and network-check
    launchers to `/usr/local/bin`.
  - keeps the installed `/opt/darwin-switch-agent` tree runtime-focused by
    removing tests, host-side kit builders, release gates, SD helpers, and GLB
    build-only tools after copying.
  - runs installed preflight after systemd reload.
- `tools/switch-pilot/package.sh`
  - runs bundle-only preflight, builds a runtime tarball, writes SHA-256 when
    checksum tooling is available, and excludes tests, host-side kit builders,
    release gates, SD helpers, and GLB build-only tooling.
- `tools/switch-pilot/simulate-install-tree.sh`
  - Mac-side no-root install simulation. It builds a fake `/opt`,
    `/etc/darwin-switch-agent`, `/usr/local/bin`, systemd, autostart, and app
    desktop tree under a temporary directory, runs installed launchers against
    that tree, runs bundle preflight, and fails if runtime-only exclusions leak
    into the installed tree.
  - validates `systemd` `ExecStart`, `Environment=PYTHONPATH`, `PartOf`,
    desktop `Exec`, and desktop `Icon` references against the simulated tree.
- `tools/switch-pilot/make-install-kit.sh`
  - builds a field kit folder/tarball with the runtime package, checksums,
    Switch-side `install-on-switch.sh`, Mac-side `copy-to-switch.sh`, manifest,
    and field instructions.
  - writes an evidence-oriented `manifest.json` and prints it into the Switch
    install log for later triage.
- `tools/switch-pilot/check-switchroot-sd.sh`
  - validates mounted SD/FAT32 layout before Hekate flash or before physical
    Darwin kit transfer: `bootloader`, `switchroot`, L4T install payload,
    boot files, nested extraction mistakes, Darwin kit presence, Darwin kit
    tarball checksum, embedded runtime checksum, manifest/package metadata, and
    free space.
  - remains read-only by default; `--write-check` adds a temporary-file
    create/remove probe for copy-time readiness.
- `tools/switch-pilot/copy-kit-to-sd.sh`
  - copies the generated Darwin install kit folder/tarball/checksum to a
    mounted SD root for non-SSH physical transfer.
  - first runs an SD layout precheck with `--write-check` and refuses to copy
    if the path does not look like a Switchroot SD root or the mount is not
    writable; after copying, runs the SD layout checker with
    `--require-darwin-kit`.
- `tools/switch-pilot/eject-day0-sd.sh`
  - validates the mounted SD root, runs `sync`, and then safely ejects/unmounts
    it using macOS `diskutil eject` or Linux `udisksctl`/`umount`.
  - refuses non-`/Volumes/...` paths on macOS by default, so a fake local
    folder cannot accidentally be treated as removable media.
- `tools/switch-pilot/check-day0-host.sh`
  - validates Mac/PC day-0 prerequisites without writing to SD or contacting
    the Switch: local command availability, release artifacts/checksums,
    field kit scripts, optional Hekate payload version filename, optional RCM
    injector path/command, optional Switchroot `.7z` path, optional mounted SD
    layout, and optional `--require-darwin-kit` validation for SD-based
    physical transfer.
- `tools/switch-pilot/prepare-day0-host.sh`
  - host-side orchestration command for the real pre-hardware flow. It runs the
    release gate, host prerequisite check, optional SD kit copy, post-copy
    Darwin kit validation, and optional `--eject-sd` safe eject, then writes a
    timestamped preparation log under `dist/switch-pilot/`.
- `tools/switch-pilot/verify-release.sh`
  - Mac-side release gate for shell syntax, Python compile/tests, web syntax,
    web runtime test, bundle preflight, simulated installed filesystem tree,
    systemd/desktop path reference checks, package checksum, tarball content,
    extracted bundle preflight, and field kit validation.
- `tools/switch-pilot/web/model-check.html`
  - Switch-local WebGL/GLB performance check.
- `tools/switch-pilot/web/setup.html`
  - first-boot GUI for mode, robot/Mac/SSH/camera settings and system health.
- `docs/guides/switchroot-darwin-day0-runbook.md`
  - Hekate/Switchroot/Darwin field execution sequence with go/no-go gates from
    RCM through robot-safe dry-run.

## Dependency Expectations

Minimum runtime packages:

```bash
python3 openssh-client autossh xdg-utils curl firefox/chromium
```

The preferred path is not to run package installation manually. Run:

```bash
./bin/darwin-switch-bootstrap-os --if-needed
```

or let `./bin/darwin-switch-onepass-install` run it as step 1.

Acceptable browser alternatives:

- `firefox`
- `firefox-esr`
- `chromium-browser`
- `chromium`
- `google-chrome`

Joy-Con support:

- `joycond` should be active.
- `/dev/input/event*` should exist after controller pairing.
- Interactive user should be in the `input` group for manual evtest-style
  diagnostics. The systemd agent itself runs as root.
- `darwin-switch-input-check --seconds 8` should show a combined Joy-Con or Pro
  Controller as the selected node, with deadman/arm/stop/estop and all four
  stick axes marked `seen`.

## First-Run Validation Checklist

Run these on the Switch after install:

```bash
darwin-switch-preflight --installed
darwin-switch-day0-acceptance --input-seconds 8 --strict
darwin-switch-smoke-test --installed
darwin-switch-input-check --seconds 8
darwin-switch-network-check
systemctl status darwin-switch-agent --no-pager
curl -fsS http://127.0.0.1:8765/api/state
```

Then from the Switch browser/kiosk:

```text
http://127.0.0.1:8765/setup.html
http://127.0.0.1:8765/model-check.html
http://127.0.0.1:8765/
```

Expected UI behavior:

- Setup page can be operated with Joy-Con/keyboard keys.
- Saving setup opens cockpit on the next launch.
- `모델` mode shows the GLB only when enabled and WebGL is available.
- `카메라` mode uses the MJPEG stream and does not run WebGL at the same time.
- `계기판` mode hides the model/camera stage, does not mount GLB/WebGL, and
  shows data-only gauges.
- Emergency stop, stop, recover, ping, and reconnect buttons are visible and
  focusable.

## Camera Tunnel Validation

After robot SSH and camera endpoint are configured:

```bash
sudo systemctl enable --now darwin-switch-camera-tunnel
journalctl -u darwin-switch-camera-tunnel -f
curl -fsS http://127.0.0.1:18080/?action=snapshot >/tmp/darwin-camera.jpg
darwin-switch-network-check --ssh-probe
```

If this fails, validate in this order:

1. Robot SSH host/user/key in `/etc/darwin-switch-agent/config.json`.
2. Robot `camera_tutorial` availability.
3. Switch local port `18080`.
4. Robot camera remote port `8080`.
5. `autossh` installed.

## Known Limits Before Real Hardware

The following cannot be proven on Mac before the Switch is prepared:

- RCM/Hekate boot path.
- SD partitioning and Switchroot flash success.
- Joy-Con BT dump correctness.
- Real `/dev/input` event names/codes on the Switch image. The new
  `darwin-switch-input-check --seconds 8` command is the planned evidence
  collector for this item, but the evidence is still missing until real Switch
  hardware is available.
- Kiosk autostart behavior in the selected Switchroot desktop flavor.
- Actual GLB frame timing on the Switch GPU/browser.
- Robot SSH latency and camera stream stability.
- Physical robot movement safety.

The current preparation reduces install-time mistakes, but final confidence
requires the `darwin-switch-preflight --installed`, cockpit, model-check, input,
network/camera, and robot-safe dry-run checks on the real Switch.

## Recovery Commands

```bash
darwin-switch-preflight --installed
darwin-switch-smoke-test --installed
darwin-switch-input-check --seconds 8
darwin-switch-network-check
darwin-switch-collect-diagnostics
sudo systemctl restart darwin-switch-agent
sudo systemctl restart darwin-switch-camera-tunnel
journalctl -u darwin-switch-agent -n 100 --no-pager
journalctl -u darwin-switch-camera-tunnel -n 100 --no-pager
sudo /opt/darwin-switch-agent/uninstall.sh
```

On the Mac, summarize a copied diagnostics bundle with:

```bash
tools/switch-pilot/summarize-diagnostics.py ~/darwin-switch-diagnostics-*.tar.gz
```

## Current Readiness Verdict

Repository-side preparation is ready for a first hardware trial once Switchroot
Ubuntu is booting. Full “one time, no error” proof is still blocked by real
Switch hardware validation, but the repo now includes a repeatable package,
pre-install audit, installed audit, first-boot setup, kiosk launcher, service
units, and explicit recovery path.

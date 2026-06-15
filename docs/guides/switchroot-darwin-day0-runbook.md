# Switchroot Darwin Day-0 Runbook

Date: 2026-06-06  
Status: pre-hardware, RCM/Hekate/Switchroot not yet verified on the real Switch

## Purpose

Nintendo Switch v1에 Switchroot L4T Ubuntu를 올린 직후 Darwin cockpit install
kit를 최대한 한 번에 적용하기 위한 현장 실행 순서다. 이 문서는 Nintendo
firmware를 교체하는 문서가 아니다. 목표는 다음 네 가지를 실수 없이
이어붙이는 것이다.

1. RCM -> Hekate/Nyx.
2. Switchroot L4T Ubuntu Noble 설치.
3. Switchroot 첫 부팅, Wi-Fi/SSH 준비.
4. Darwin Switch install kit 실행.

## Authoritative References

- Switchroot Noble 24.04 install guide:
  https://wiki.switchroot.org/wiki/linux/l4t-ubuntu-noble-installation-guide
- Switchroot Linux distributions / first install flow:
  https://wiki.switchroot.org/wiki/linux/linux-distributions

Reference facts confirmed on 2026-06-06:

- Recommended target: L4T Ubuntu Noble 24.04, current Switchroot version 5.1.2.
- Hekate 6.0.6 or newer is required for Noble.
- SD card minimum is 16GB; 128GB+ U3/U3/A2 is recommended.
- Hekate partitioning is destructive. Back up FAT32 files, file-based emuMMC,
  raw emuMMC, and Android/TWRP data before partitioning if they exist.
- Extract the Switchroot `.7z` contents directly to the SD FAT32 root. Do not
  create an extra folder around the extracted files.
- Use Hekate `Tools -> Partition SD Card -> Flash Linux`.
- Run `hekate -> Nyx Options -> Dump Joy-Con BT` after Joy-Cons are paired in
  Horizon OS and connected to the console. This is needed for pairing and
  calibration data.
- WPA3/WPA2 transition networks can fail; use WPA2-only or `nmcli` if needed.

## Hard No-Go Conditions

Do not continue until these are true:

- Switch is an unpatched/RCM-capable v1 unit.
- RCM jig and data-capable USB-C cable are available.
- Battery is sufficiently charged or dock/USB power is available.
- microSD contents are backed up.
- Hekate payload is available on the Mac/PC that will inject payload. Keep a
  Mac-local copy because the SD card is inserted into the Switch during RCM
  injection.
- RCM payload injection tool is available on the same Mac/PC and has been
  opened or dry-run at least once. For this repo on macOS, use:
  - command: `tools/switch-pilot/mac-rcm-injector/darwin-switch-rcm-inject.sh`
  - native macOS app: `dist/switch-pilot/Darwin Switch RCM Injector.app`
  - dry run: `tools/switch-pilot/mac-rcm-injector/darwin-switch-rcm-inject.sh --check-only`
- Switchroot Noble image is downloaded from the official Switchroot source.
- Darwin repo release gate has passed:

```bash
tools/switch-pilot/verify-release.sh
```

- Mac/PC host-side day-0 check has no `BAD` items:

```bash
tools/switch-pilot/check-day0-host.sh \
    --hekate-payload /path/to/hekate_ctcaer_6.0.6_or_newer.bin \
    --rcm-injector /path/to/rcm-injector-or-app \
    --switchroot-archive /path/to/switchroot-l4t-ubuntu-noble.7z
```

If the SD is already mounted and you want the Darwin kit copied, validated,
synced, and ejected, prefer the combined preparation command:

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

This runs the release gate, host prerequisite check, SD layout/write precheck,
kit copy, post-copy Darwin kit validation, filesystem sync, and safe eject,
then writes a log under `dist/switch-pilot/`.

Expected Darwin outputs:

```text
dist/switch-pilot/darwin-switch-install-kit-0.1.0/
dist/switch-pilot/darwin-switch-install-kit-0.1.0.tar.gz
dist/switch-pilot/darwin-switch-install-kit-0.1.0.tar.gz.sha256
```

## Phase 1 - RCM And Hekate

1. Power off the Switch completely.
2. Insert the RCM jig into the right Joy-Con rail.
3. Hold `VOL+` and press power to enter RCM.
4. Inject the Hekate payload from the Mac/PC:

```bash
tools/switch-pilot/mac-rcm-injector/darwin-switch-rcm-inject.sh \
    --payload dist/switch-pilot/hekate_ctcaer_6.5.2.bin
```

   Or open the native macOS app:

```bash
open "dist/switch-pilot/Darwin Switch RCM Injector.app"
```

5. Confirm Hekate/Nyx UI appears.

Go/no-go:

- GO: Hekate/Nyx UI is visible.
- NO-GO: Nintendo logo appears, screen boots normally, or payload injection
  tool cannot see the device. Recheck jig seating, cable, payload tool, and
  whether the unit is patched.

## Phase 2 - Backup And Partition

1. Back up FAT32 files from the SD card.
2. If raw emuMMC exists, use Hekate backup/restore tooling as appropriate.
3. In Hekate, open `Tools -> Partition SD Card`.
4. Leave enough FAT32 space for the Switchroot install files. Use at least 8GiB
   FAT32; more is fine if you need room for Nintendo files and the Darwin kit.
5. Create the Linux partition using Hekate's partition manager.

Go/no-go:

- GO: partitioning completes and the SD FAT32 partition is mountable.
- NO-GO: backup is incomplete, Hekate warns about destructive changes you are
  not ready to accept, or the SD mount is unstable.

## Phase 3 - Copy Switchroot Files

Recommended transfer method is Hekate UMS:

1. In Hekate, use `Tools -> USB Tools` to mount SD over USB.
2. From the Mac/PC, extract the Switchroot Noble `.7z` directly to the SD FAT32
   root.
3. Confirm the extracted layout contains Switchroot/Hekate files at the root,
   not inside an extra folder.
4. If the SD is mounted on this Mac, run the layout checker before ejecting:

```bash
tools/switch-pilot/check-switchroot-sd.sh --stage before-flash /Volumes/<SD_NAME>
```

5. Safely eject/unmount the SD storage:

```bash
tools/switch-pilot/eject-day0-sd.sh \
    --stage before-flash \
    /Volumes/<SD_NAME>
```

Go/no-go:

- GO: SD root contains expected `bootloader` and `switchroot` layout.
- NO-GO: extracted files sit under a nested folder, eject was unsafe, or copy
  failed. Re-extract before flashing.

## Phase 4 - Flash Linux And Joy-Con Data

1. Return to Hekate/Nyx.
2. Run `Tools -> Partition SD Card -> Flash Linux`.
3. After flashing completes, go to `Nyx Options -> Dump Joy-Con BT`.
4. Reboot or return to Hekate home.
5. Boot L4T Ubuntu Noble from `More Configs`.

Go/no-go:

- GO: L4T Ubuntu boots to desktop/login.
- NO-GO: no L4T entry appears, boot loops, or Joy-Con BT dump was skipped.
  Recheck extracted SD layout, Hekate version, and flash step.

## Phase 5 - First Ubuntu Boot

1. Connect Wi-Fi.
2. If WPA3/WPA2 transition mode fails, use a WPA2-only network or terminal:

```bash
nmcli dev wifi connect "SSID_NAME"
```

3. Update the OS once:

```bash
sudo apt update
sudo apt-get dist-upgrade
sudo reboot
```

4. After reboot, confirm network and IP:

```bash
ip addr
hostname -I
```

5. Optional but useful for Mac transfer: enable SSH server if not already
   available on the image.

```bash
sudo apt-get install openssh-server
sudo systemctl enable --now ssh
```

Go/no-go:

- GO: terminal works, Wi-Fi works, and either SSH is reachable from Mac or the
  Darwin install kit can be transferred by USB/SD.
- NO-GO: network is unavailable and no physical transfer route exists.

## Phase 6 - Copy Darwin Install Kit

Preferred from Mac:

```bash
dist/switch-pilot/darwin-switch-install-kit-0.1.0/copy-to-switch.sh \
    <switch-user>@<switch-ip>
```

Alternative single-file transfer:

```bash
scp dist/switch-pilot/darwin-switch-install-kit-0.1.0.tar.gz \
    <switch-user>@<switch-ip>:~
```

Then on the Switch:

```bash
tar -xzf ~/darwin-switch-install-kit-0.1.0.tar.gz
cd ~/darwin-switch-install-kit-0.1.0
```

If the folder was copied with `copy-to-switch.sh`, only the `cd` is needed:

```bash
cd ~/darwin-switch-install-kit-0.1.0
```

If you copied the Darwin kit onto the SD FAT32 root as a physical transfer
fallback, verify the SD before ejecting:

```bash
tools/switch-pilot/copy-kit-to-sd.sh \
    --stage any \
    /Volumes/<SD_NAME>
```

The copy helper first runs a Switchroot SD layout precheck plus a tiny
temporary-file write/remove check. It refuses to write the Darwin kit if the
path is not a plausible SD root or the mount is read-only. After copying, it
reruns the SD layout checker with Darwin kit validation. To run only the
checker:

```bash
tools/switch-pilot/check-switchroot-sd.sh \
    --stage any \
    --require-darwin-kit \
    /Volumes/<SD_NAME>
```

Add `--write-check` to the checker when you specifically want to prove the SD
root can be written before a copy step:

```bash
tools/switch-pilot/check-switchroot-sd.sh \
    --write-check \
    --stage any \
    --require-darwin-kit \
    /Volumes/<SD_NAME>
```

With `--require-darwin-kit`, the checker does more than confirm that a Darwin
folder exists. It validates the kit folder files, the SD-root kit tarball
checksum, the embedded runtime package checksum, and the kit manifest/package
metadata. Treat a BAD result here as a no-go before ejecting the SD.

To safely sync and eject the SD after the Darwin kit is present:

```bash
tools/switch-pilot/eject-day0-sd.sh \
    --stage any \
    --require-darwin-kit \
    /Volumes/<SD_NAME>
```

To combine host prerequisites and SD Darwin kit validation in one read-only
command before ejecting:

```bash
tools/switch-pilot/check-day0-host.sh \
    --hekate-payload /path/to/hekate_ctcaer_6.0.6_or_newer.bin \
    --rcm-injector /path/to/rcm-injector-or-app \
    --switchroot-archive /path/to/switchroot-l4t-ubuntu-noble.7z \
    --sd-root /Volumes/<SD_NAME> \
    --require-darwin-kit \
    --strict
```

## Phase 7 - Run Darwin Installer

On the Switch:

```bash
./install-on-switch.sh
```

The installer writes a log:

```text
~/darwin-switch-install-YYYYMMDD-HHMMSS.log
```

Expected final checks:

```bash
darwin-switch-preflight --installed
darwin-switch-day0-acceptance --input-seconds 8 --strict
darwin-switch-smoke-test --installed
darwin-switch-input-check
darwin-switch-network-check
curl -fsS http://127.0.0.1:8765/api/state
darwin-switch-cockpit
```

Go/no-go:

- GO: installed preflight is `GOOD` or only has understood hardware warnings,
  `/api/state` responds, cockpit opens, and input check selects a controller
  node or clearly reports that controller pairing is still missing.
- NO-GO: any `BAD` preflight item remains, local API does not respond, or kiosk
  browser is missing.

## Phase 8 - Cockpit Acceptance

Open:

```text
http://127.0.0.1:8765/setup.html
http://127.0.0.1:8765/model-check.html
http://127.0.0.1:8765/
```

Acceptance checks:

- Run `darwin-switch-day0-acceptance --input-seconds 8 --strict` first. During
  capture, hold ZL/ZR, press A, B, Home, and move both sticks. GO only when it
  returns `GOOD`.
- Setup page can be operated with Joy-Con/keyboard controls.
- `model-check.html` measures actual Switch browser/WebGL performance.
- `모델` mode does not run camera MJPEG at the same time.
- `카메라` mode shows MJPEG only after robot SSH/camera tunnel is configured.
- `계기판` mode hides model/camera stage and shows data-only gauges.
- Emergency stop, stop, recover, reconnect, setup, and inspection controls are
  visible and focusable.
- Run `darwin-switch-input-check --seconds 8`; during capture hold ZL/ZR, press
  A, B, Home, and move both sticks. GO only when deadman/arm/stop/estop and all
  four stick axes are `seen`.
- Run `darwin-switch-network-check`; GO when local cockpit API is reachable and
  any remaining `WARN` items match hardware that has not been configured yet
  such as robot SSH, Mac relay, or camera tunnel.

## Phase 9 - Robot-Safe Dry Run

Do this before any physical robot movement:

1. Keep Darwin config in `dry_run` or Mac relay dry-run mode.
2. Confirm button mapping with `darwin-switch-input-check --seconds 8`.
3. Confirm network/camera readiness with `darwin-switch-network-check`.
4. Confirm deadman behavior in cockpit.
5. Confirm logs change when sticks/buttons move.
6. Confirm emergency stop state is visible and recoverable.
7. Only after dry-run passes, connect to Mac relay or robot SSH target.

## Recovery

Agent:

```bash
sudo systemctl restart darwin-switch-agent
journalctl -u darwin-switch-agent -n 100 --no-pager
```

Camera tunnel:

```bash
sudo systemctl restart darwin-switch-camera-tunnel
journalctl -u darwin-switch-camera-tunnel -n 100 --no-pager
```

OS bootstrap / apt dependency log:

```bash
tail -n 160 "${XDG_CACHE_HOME:-$HOME/.cache}/darwin-switch-cockpit/logs/bootstrap.log"
```

If this shows an `apt-get update` or package install failure, check Switchroot
Wi-Fi, DNS, date/time, and repository availability before rerunning
`./bin/darwin-switch-bootstrap-os --if-needed`.

Kiosk/browser first-login log:

```bash
tail -n 120 "${XDG_CACHE_HOME:-$HOME/.cache}/darwin-switch-cockpit/logs/launcher.log"
```

This shows whether the local cockpit URL responded, which browser was selected,
or whether no kiosk-capable browser was available.

Re-run readiness:

```bash
darwin-switch-preflight --installed
darwin-switch-day0-acceptance --input-seconds 8 --strict
darwin-switch-smoke-test --installed
darwin-switch-network-check
```

Collect a diagnostics bundle before changing more state:

```bash
darwin-switch-collect-diagnostics
```

The one-pass installer tries to run this automatically if it fails. The output
is a `~/darwin-switch-diagnostics-*.tar.gz` file.
Copy that file back to the Mac and summarize it from the repository root:

```bash
tools/switch-pilot/summarize-diagnostics.py ~/darwin-switch-diagnostics-*.tar.gz
```

Uninstall runtime only:

```bash
sudo /opt/darwin-switch-agent/uninstall.sh
```

This does not undo Switchroot, Hekate, SD partitioning, or Nintendo OS state.

## Remaining Proof Required

This runbook is ready for the first hardware trial, but completion still
requires real evidence from the Switch:

- Hekate payload injection works on this exact console.
- Switchroot Noble flashes and boots from this exact SD.
- Joy-Con BT dump produces working `/dev/input` events.
- Browser/kiosk launches on the chosen Switchroot flavor.
- `model-check.html` passes on the real Switch GPU/browser.
- SSH camera tunnel works against the robot.
- Robot-safe dry-run passes before physical movement.

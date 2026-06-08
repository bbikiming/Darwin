# Switchroot Darwin RCM Fastpath

Date: 2026-06-07  
Status: RCM jig before first real-device run

## Purpose

RCM jig 진입에 성공한 직후 Nintendo Switch v1을 최대한 빠르게 Darwin 전용
컨트롤러 환경으로 넘기기 위한 현장용 절차다. 이미 Mac 로컬에는 Switchroot
Ubuntu 이미지와 Darwin 설치 키트가 준비되어 있다.

이 문서는 Nintendo firmware를 교체하는 절차가 아니다. 흐름은 RCM -> Hekate
-> Switchroot L4T Ubuntu -> Darwin cockpit Linux 앱 설치다.

## Prepared Local Assets

Switchroot Ubuntu Noble image:

```text
dist/switchroot-cache/theofficialgman-ubuntu-unity-noble-5.1.2-2025-08-16.7z
```

Local checksum file:

```text
dist/switchroot-cache/theofficialgman-ubuntu-unity-noble-5.1.2-2025-08-16.7z.sha256
```

Verified metadata:

```text
size: 2031455562 bytes
sha256: 1195077cd8fc4ba34b2383a9c2d2f69173738128636c0ffe8c618b294c3d5a4e
archive type: 7-zip
```

Archive layout was checked with macOS `bsdtar`. Expected root entries include:

```text
bootloader/
bootloader/ini/L4T-noble.ini
switchroot/
switchroot/install/l4t.00
switchroot/install/l4t.01
switchroot/ubuntu-noble/
```

Darwin Switch install kit on the current SD card:

```text
/Volumes/SWITCHSD/darwin-switch-install-kit-0.1.0/
/Volumes/SWITCHSD/darwin-switch-install-kit-0.1.0.tar.gz
/Volumes/SWITCHSD/darwin-switch-install-kit-0.1.0.tar.gz.sha256
```

Hekate payload on the current SD card:

```text
/Volumes/SWITCHSD/hekate_ctcaer_6.5.2.bin
```

Mac RCM injector app:

```text
dist/switch-pilot/Darwin Switch RCM Injector.app
```

Command-line injector fallback:

```bash
tools/switch-pilot/mac-rcm-injector/darwin-switch-rcm-inject.sh \
    --payload /Volumes/SWITCHSD/hekate_ctcaer_6.5.2.bin
```

## Why The Image Is Not Extracted To SD Yet

Do not extract the Switchroot `.7z` to the SD before Hekate partitioning.
Hekate's Linux partition step can rewrite the SD layout and erase or move files.
The efficient order is:

1. Enter RCM and boot Hekate.
2. Let Hekate create the Linux partition.
3. Mount the SD back on the Mac.
4. Extract the local Switchroot archive directly to the SD FAT32 root.
5. Return to Hekate and run `Flash Linux`.

This avoids copying the 1.9GB archive contents twice.

## RCM-Day Fast Sequence

### 1. Enter Hekate

1. Insert the prepared SD card into the Switch.
2. Power the Switch off completely.
3. Insert the RCM jig.
4. Hold `VOL+` and press `POWER`.
5. Connect the Switch to the Mac with a USB-C data cable.
6. Open `dist/switch-pilot/Darwin Switch RCM Injector.app`.
7. Select or confirm `hekate_ctcaer_6.5.2.bin`.
8. Inject Hekate.

Go condition: Hekate/Nyx appears on the Switch screen.  
Stop condition: Nintendo logo appears, or Mac cannot see an RCM/APX device.

### 2. Partition For Linux

1. In Hekate, open `Tools -> Partition SD Card`.
2. Allocate a Linux partition.
3. For this 128GB SD card, use at least 32GB for Linux. More is acceptable if
   the Switch will mainly be a Darwin controller.
4. Apply the partition operation.

Stop condition: there is anything on the SD that has not been backed up.
Partitioning is destructive.

### 3. Mount SD Back On Mac

Preferred method:

1. In Hekate, use `Tools -> USB Tools -> SD Card` to expose the SD to the Mac.
2. Confirm the SD appears under `/Volumes`.

Alternative:

1. Power off.
2. Remove SD.
3. Mount it with the Mac card reader.

### 4. Extract Switchroot To SD Root

Fast path from this repo root:

```bash
tools/switch-pilot/extract-switchroot-to-sd.sh --sd-root /Volumes/SWITCHSD
```

Manual equivalent:

```bash
bsdtar -xf \
  dist/switchroot-cache/theofficialgman-ubuntu-unity-noble-5.1.2-2025-08-16.7z \
  -C /Volumes/SWITCHSD
```

After manual extraction, verify:

```bash
tools/switch-pilot/check-switchroot-sd.sh \
  --stage before-flash \
  --require-darwin-kit \
  /Volumes/SWITCHSD
```

Expected key items:

```text
[OK] bootloader folder exists
[OK] switchroot folder exists
[OK] L4T-noble.ini exists
[OK] switchroot/install/l4t.* exists
[OK] Darwin install kit folder exists
```

If extracted files are nested inside an extra folder, move the contents to the
SD root before continuing.

### 5. Flash Linux In Hekate

1. Safely eject the SD from macOS.
2. Return the SD to the Switch or unmount Hekate UMS.
3. In Hekate, run `Tools -> Partition SD Card -> Flash Linux`.
4. Wait until flashing completes.
5. Run `Nyx Options -> Dump Joy-Con BT` after Joy-Cons have been paired in
   normal Switch OS when needed.
6. Boot `L4T Ubuntu Noble` from Hekate `More Configs`.

### 6. First Ubuntu Boot

1. Complete first boot setup.
2. Connect Wi-Fi.
3. Open Terminal.
4. Optional but recommended:

```bash
sudo apt update
sudo apt-get dist-upgrade
sudo reboot
```

5. Enable SSH if not already enabled:

```bash
sudo apt-get install openssh-server
sudo systemctl enable --now ssh
hostname -I
```

### 7. Install Darwin Cockpit

If the Darwin install kit is visible from the SD inside Ubuntu:

```bash
cd /media/$USER/*/darwin-switch-install-kit-0.1.0
./install-on-switch.sh
```

If using SSH from the Mac:

```bash
dist/switch-pilot/darwin-switch-install-kit-0.1.0/copy-to-switch.sh \
  <switch-user>@<switch-ip>
```

Then on the Switch:

```bash
cd ~/darwin-switch-install-kit-0.1.0
./install-on-switch.sh
```

### 8. Acceptance Checks

On the Switch:

```bash
darwin-switch-day0-acceptance --input-seconds 8 --strict
darwin-switch-input-check --seconds 8
darwin-switch-network-check
darwin-switch-cockpit
```

Success target:

- cockpit opens locally.
- Joy-Con or controller input is detected.
- network status is readable.
- SSH or local terminal remains usable for recovery.

## Remaining Real-Hardware Risks

- RCM jig seating can fail; if the Nintendo logo appears, it booted normally.
- Some USB-C cables charge only and do not carry data.
- Patched Switch units cannot use the classic unpatched v1 RCM path.
- Hekate partitioning can erase SD data.
- Switchroot first boot, Joy-Con BT dump, Wi-Fi, and GPU/display behavior still
  require real-device validation.
- Darwin cockpit package passed host-side verification, but has not yet been
  proven on the actual Switch Linux runtime.

## Official References

- Switchroot Noble installation guide:
  https://wiki.switchroot.org/wiki/linux/l4t-ubuntu-noble-installation-guide
- Switchroot Noble downloads:
  https://download.switchroot.org/ubuntu-noble/

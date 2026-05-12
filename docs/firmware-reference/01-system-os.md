# 01 — System & OS (ROBOTIS-OP2 Factory Firmware)

> Snapshot: ROBOTIS-OP2_Recovery_20150326 (sda1 ext4 rootfs cloned via Clonezilla on 2015-03-26 09:03 UTC).
> Extraction root: `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/`

## TL;DR

The factory image is **Ubuntu 12.04.5 LTS "Precise" (i386 / 32-bit)** with Upstart as init and LightDM/Xorg on top. Two kernels are installed side-by-side: stock `3.2.0-79-generic` and ROBOTIS' custom `3.2.66-op2` build (the GRUB default), the latter compiled on host `robotis` on **Fri Feb 13 2015 12:17 KST** against a rebased Ubuntu 3.2.0-76.111 source with `SMP PREEMPT` enabled. The OS exposes the CM-740 servo controller as `/dev/ttyUSB0` via the kernel's `ftdi_sio` driver and the head camera as a `uvcvideo` UVC 1.00 device (Logitech USB ID `046d:080a`). No OpenCV / Dynamixel / robotis packages exist in dpkg — every robotics layer above the kernel is built from source under `/robotis` (see Framework doc).

## Distribution

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/lsb-release`:

```
DISTRIB_ID=Ubuntu
DISTRIB_RELEASE=12.04
DISTRIB_CODENAME=precise
DISTRIB_DESCRIPTION="Ubuntu 12.04.5 LTS"
```

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/os-release` (also present, despite Ubuntu 12.04 normally lacking it — likely backported by an `lsb-release` update):

```
NAME="Ubuntu"
VERSION="12.04.5 LTS, Precise Pangolin"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu precise (12.04.5 LTS)"
VERSION_ID="12.04"
```

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/debian_version`: `wheezy/sid` (boilerplate value typical for Ubuntu base — not a real Debian).

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/issue`: `Ubuntu 12.04.5 LTS \n \l`.

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/timezone`: `Asia/Seoul` (manufacturer locale — ROBOTIS HQ).

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/hostname`: `robotis`.

**Architecture: i386 (32-bit x86).** Confirmed by `Architecture: i386` field on every dpkg `linux-image-*` entry and by `Linux/i386` in the kernel config header. The platform CPU (Atom N2600) is x86_64-capable, but the factory userland is 32-bit only.

## Kernels (CRITICAL)

Two kernels coexist; the OP2-custom one is the GRUB default.

### Kernel A — `3.2.66-op2` (ROBOTIS custom, BOOT DEFAULT)

- **Version string** (from `var/log_extra/dmesg`, line 1):
  `Linux version 3.2.66-op2 (root@robotis) (gcc version 4.6.3 (Ubuntu/Linaro 4.6.3-1ubuntu5) ) #1 SMP PREEMPT Fri Feb 13 12:17:45 KST 2015 (Ubuntu 3.2.0-76.111-generic 3.2.66)`
- **Build origin**: rebuilt from Ubuntu's `3.2.0-76.111-generic` source tree, retargeted to upstream 3.2.66, on the manufacturer's own machine (`root@robotis`).
- **Custom flags**: `SMP PREEMPT` — preemption enabled. Important for the motion thread that must hit 8 ms Dynamixel cycle deadlines.
- **dpkg metadata** (`var/lib/dpkg/status`):
  ```
  Package: linux-image-3.2.66-op2
  Status: install ok installed
  Section: kernel
  Installed-Size: 112373
  Maintainer: Unknown Kernel Package Maintainer <unknown@unconfigured.in.etc.kernel-pkg.conf>
  Architecture: i386
  Source: linux-source-3.2.66-op2
  Version: 1.0
  ```
  The "Unknown … unconfigured" maintainer string is a tell-tale sign of a `make-kpkg` build on a developer workstation rather than an Ubuntu archive package. Companion `linux-headers-3.2.66-op2` (42 MB) is also installed, so out-of-tree modules can be built against the running kernel directly on the bot.
- **Modules root**: `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/lib/modules/3.2.66-op2/`
- **Subtree layout** (`kernel/`): `arch crypto drivers fs lib net sound ubuntu` — same shape as Ubuntu's stock kernel.
- **No OP2-specific `.ko`**: a recursive search for `*op2*`, `*robotis*`, `*dynamixel*` under `lib/modules/3.2.66-op2/` matched only the directory name itself. The hardware glue is therefore not a kernel module — it is the standard `ftdi_sio` USB-serial driver plus `uvcvideo`, used by ROBOTIS' userland framework via libusb / /dev nodes.
- **Notable enabled modules** (sampled — full set is the standard Ubuntu module farm):
  - USB-serial: `ftdi_sio.ko`, `cp210x.ko`, `pl2303.ko`, `ch341.ko` under `kernel/drivers/usb/serial/` — covers the CM-740 FTDI bridge and other common USB-UART parts.
  - Media: `uvcvideo` plus the `kernel/drivers/media/video/` farm (registered at boot for the Logitech head camera).
  - CAN: `kernel/drivers/net/can/` (mcp251x, slcan, vcan) — present but not used by the OP2 wiring.
  - Sound: `snd-hda-intel` driver path; ALSA core (`soundcore.ko`).
  - Wireless: full Ubuntu wifi farm (b43, iwlwifi, ath9k …) — supports the optional USB Wi-Fi dongle ROBOTIS ships separately.

### Kernel B — `3.2.0-79-generic` (Ubuntu stock, FALLBACK)

- **Version**: standard Ubuntu Precise HWE kernel, package `linux-image-3.2.0-79-generic`, installed 2015-03-25 (12 days before the recovery snapshot, after the OP2 kernel was already running).
- **Modules root**: `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/lib/modules/3.2.0-79-generic/` — has an extra `initrd/` subdirectory (built via `update-initramfs`), which the op2 kernel lacks (only `build/` and `kernel/`).
- **Purpose**: kept as a known-good fallback in case the custom kernel fails to boot. Listed under GRUB's "Previous Linux versions" submenu, never the default.

## Boot config

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/boot/` contains:

```
System.map-3.2.0-79-generic        config-3.2.0-79-generic   initrd.img-3.2.0-79-generic   vmlinuz-3.2.0-79-generic
System.map-3.2.66-op2              config-3.2.66-op2         initrd.img-3.2.66-op2         vmlinuz-3.2.66-op2
abi-3.2.0-79-generic               grub/                     memtest86+.bin                memtest86+_multiboot.bin
```

Both kernels have their own `System.map`, `config`, `initrd.img`, and `vmlinuz`. `memtest86+` images are included by the standard Ubuntu installer template.

`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/boot/grub/grub.cfg` — auto-generated, four real menu entries plus memtest:

```
menuentry 'Ubuntu, with Linux 3.2.66-op2'                       --class ubuntu --class gnu-linux --class gnu --class os {
menuentry 'Ubuntu, with Linux 3.2.66-op2 (recovery mode)'       --class ubuntu --class gnu-linux --class gnu --class os {
submenu "Previous Linux versions" {
  menuentry 'Ubuntu, with Linux 3.2.0-79-generic'               --class ubuntu --class gnu-linux --class gnu --class os {
  menuentry 'Ubuntu, with Linux 3.2.0-79-generic (recovery mode)' --class ubuntu --class gnu-linux --class gnu --class os {
}
menuentry "Memory test (memtest86+)" { ... }
menuentry "Memory test (memtest86+, serial console 115200)" { ... }
```

The first physical entry is the OP2 kernel, and the file declares `set default="0"` — i.e. **the bot boots the custom op2 kernel by default**.

Boot command lines, as written into the config:

```
linux /boot/vmlinuz-3.2.66-op2          root=UUID=82a1d662-49bd-4b55-9199-194017844429 ro   quiet splash $vt_handoff
linux /boot/vmlinuz-3.2.66-op2          root=UUID=82a1d662-49bd-4b55-9199-194017844429 ro recovery nomodeset
linux /boot/vmlinuz-3.2.0-79-generic    root=UUID=82a1d662-49bd-4b55-9199-194017844429 ro   quiet splash $vt_handoff
linux /boot/vmlinuz-3.2.0-79-generic    root=UUID=82a1d662-49bd-4b55-9199-194017844429 ro recovery nomodeset
```

Confirmed in dmesg as the actual runtime cmdline: `BOOT_IMAGE=/boot/vmlinuz-3.2.66-op2 root=UUID=82a1d662-49bd-4b55-9199-194017844429 ro quiet splash vt.handoff=7`. Root filesystem UUID `82a1d662-49bd-4b55-9199-194017844429` is the ext4 partition on `/dev/sda1` (25 GiB) per the Clonezilla hardware dump.

There is **no `/boot/grub/menu.lst`** (GRUB 1 legacy file) — the system is on GRUB 2 with the menu produced by `grub-mkconfig` from `/etc/grub.d/` and `/etc/default/grub`.

## Installed packages

`grep -c "^Package:" var/lib/dpkg/status` → **1035 packages**; `^Status: install ok installed` → **1035** (all live, no half-installed leftovers).

### Robotics / Dynamixel related
**Nothing.** Searching dpkg for `dxl|dynamixel|robotis|op2|opencv|libcv` returns only:

```
Package: linux-image-3.2.66-op2
Package: linux-headers-3.2.66-op2
Package: libgtop2-common   (false positive — GNOME system monitor)
Package: libgtop2-7        (false positive)
```

OpenCV, the Dynamixel framework, MJPG-Streamer, and every other robotics-stack library are **not** Debian-packaged. They are built from source in-place — typically under `/robotis/` (the home directory of user `robotis`, separate doc). The presence of `gcc-4.6`, `g++-4.6`, `make`, `libc6-dev`, `libjpeg62-dev`, `libncurses5-dev`, and `linux-headers-3.2.66-op2` confirms a complete on-bot build environment.

### Hardware-facing libraries (Debian-packaged)
```
libusb-0.1-4              # legacy libusb 0.1
libusb-1.0-0              # current libusb 1.x — used by ROBOTIS' framework + uvccapture
libjpeg62 / libjpeg62-dev # JPEG encode/decode for vision pipeline
libjpeg8 / libjpeg-turbo8
libv4l-0 / libv4lconvert0 # video4linux user-space helpers (for the UVC camera)
alsa-utils / alsa-base / libasound2 / libsndfile1   # audio output (mp3 cues etc.)
mpg321 / mplayer2 / madplay                          # audio playback CLIs invoked by demos
```
Notably absent: `libftdi-dev` (the FTDI USB-serial bridge for the CM-740 is accessed via the in-kernel `ftdi_sio` ttyUSB device, not via libftdi).

### Languages / toolchains
```
gcc-4.6, g++-4.6, binutils, make, cmake (not present), subversion
linux-headers-3.2.66-op2 + linux-libc-dev + libc6-dev + libstdc++6-4.6-dev
python 2.7 (python-minimal, python2.7), python-gi, python-dbus, python-pkg-resources
perl-base, perl-modules
```
**No `cmake`** in dpkg — ROBOTIS' demo programs build with hand-written Makefiles (see Framework doc). **No Python 3**; everything Python-side is 2.7-era. **No git** — source control on the bot is Subversion (`subversion`), which matches ROBOTIS' historical SVN hosting.

### Vision
- `libv4l-0`, `libv4lconvert0`, `libjpeg62/8`, `libjpeg-turbo8` (Debian-packaged).
- OpenCV: source build only; not in dpkg.
- MJPG-Streamer: source build only; not in dpkg.

### Audio
`alsa-utils`, `alsa-base`, `libasound2`, `libsndfile1`, `mpg321`, `mplayer2`, `madplay`. No `espeak`, `festival`, `flite`, `sox`, or `portaudio` — i.e. the factory has **playback** only, no on-bot TTS, recording, or synthesis. Speech output, if any, is pre-rendered mp3 files played through `mpg321`.

### System layer
- Init: **Upstart** (no `systemd` package). Service files live in `/etc/init/*.conf` (Upstart job format).
- Desktop: full **Xorg** (`xserver-xorg-core` plus the full Precise driver pack) with **LightDM** as the display manager. No `gdm` or `unity-greeter`. Suggests the bot's HDMI port is auto-logged into a desktop session that runs the demo GUI.
- Network: `network-manager`, `wpasupplicant`, `samba`, `openssh-server` + `openssh-client` (so the bot is SSH-reachable out of the box), `isc-dhcp-server` (so it can hand out an address to a connected laptop).
- Browsers: `chromium-browser` + `chromium-browser-l10n` and `firefox-locale-en` (Firefox UI was likely removed but its locale stub leaked through).
- Editors: `vim` (full), no emacs/nano-extras.

### Anything unexpected for a humanoid platform
- `samba` + `system-config-samba` + `tdb-tools`: full Windows file-sharing server. Likely used so a developer on a Windows machine can mount `/robotis/` over SMB and edit demos.
- `vino` (VNC server, GNOME). Together with `openssh-server` and `isc-dhcp-server` this is a "remote access SDK" posture — plug the bot into a laptop and it exposes SSH + VNC + file share.
- `chromium-browser` on a 1.6 GHz Atom is heavy; it is presumably part of the demo "robot kiosk" mode.
- Full Ubuntu desktop stack (X, LightDM, Compiz era) implies the bot can drive HDMI-out for debugging.

## Install timeline

From `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/var/log/dpkg.log` (18 482 lines):

| Date | Install events | What happened |
|---|---|---|
| 2012-04-23 | 1 192 | First-boot installer day — base Ubuntu 12.04 rolls in (`base-files` is the first row, at 13:40:24). |
| 2015-02-13 | **60** | ROBOTIS personalisation day — Samba, OpenSSH, VNC (vino), the custom OP2 kernel, GCC/G++ 4.6, make, libjpeg62-dev, libncurses5-dev, mpg321, madplay, subversion, isc-dhcp-server. This is the date the image stopped being generic Ubuntu and became ROBOTIS firmware. |
| 2015-02-16 | 2 | `acpi`, `acpid` (power-button handling). |
| 2015-03-25 | 3 | Late catch-up of the upstream Ubuntu kernel: `linux-image-3.2.0-79-generic` + matching headers (added as a fallback, not made default). |

- First install timestamp: `2012-04-23 13:40:24` (Ubuntu installer base).
- Last install timestamp: `2015-03-25 15:50:31` (status row when `linux-image-3.2.0-23-generic` was purged in favour of -79).
- Total distinct `install` lines: **1257**.

The 2015-02-13 batch is effectively the ROBOTIS "factory provisioning" — the OP2 kernel and headers landed at 16:23:13–16:23:24 KST that day, sandwiched between Samba (16:18) and OpenSSH (16:25).

## Hardware context (from `clonezilla-image/Info-lshw.txt` and `Info-lspci.txt`)

- **CPU**: Intel Atom N2600 @ 1.60 GHz, dual-core / four threads, 32-bit kernel mode (the userland is i386, so the second core's full 64-bit potential is unused).
- **RAM**: 3 282 MiB system memory (≈ 3.2 GB usable).
- **Storage**: a single 32 GB mSATA SSD (`mSATA mini 3ME`, serial `20141022AAAA72400039`) with one 25 GiB ext4 root partition (`/dev/sda1`, UUID `82a1d662-…`) plus a 4 080 MiB extended partition containing a swap volume (`/dev/sda5`). Filesystem created `2015-02-13 07:06:19`, modified `2015-03-26 08:51:34` — matching the dpkg dates.
- **USB**: NM10/ICH7 chipset exposes **five USB controllers** — four UHCI (USB 1.1) plus one EHCI (USB 2.0) on the same chipset. Plenty of headroom for: CM-740 FTDI on ttyUSB0, Logitech UVC head camera, optional Wi-Fi/keyboard dongles.
- **Camera**: confirmed by dmesg —
  `uvcvideo: Found UVC 1.00 device <unnamed> (046d:080a)` and `input: UVC Camera (046d:080a)` — Logitech vendor ID `046d`, product `080a` (Logitech HD WebCam series).
- **Audio**: Intel NM10/ICH7 HD Audio controller (PCI `00:1b.0`), driven by `snd_hda_intel`. There is no microphone-specific driver attached, consistent with the audio-output-only userland package set.
- **Network**: Realtek RTL8111/8168B PCIe Gigabit Ethernet (`r8169`, MAC `00:07:32:2b:a7:0f`). No on-board Wi-Fi — only the wired NIC. Wi-Fi must be added as a USB dongle.

## What this means for the Darwin project

- **Reproducibility risk is real.** The bot does *not* boot a stock Ubuntu kernel — it boots a hand-rolled `3.2.66-op2` build with `SMP PREEMPT` and headers shipped with `Maintainer: Unknown` (i.e. no upstream package archive backs it). If we ever flash a vanilla Ubuntu 12.04 image, **we must rebuild the same op2 kernel** (or accept the latency hit from a non-preemptive kernel). The reference build artifact path on the bot is `/usr/src/linux-headers-3.2.66-op2/`.
- **No package layer to lean on.** OpenCV, Dynamixel SDK, MJPG-Streamer — every interesting piece is source-built; do not assume `apt-get install` will resurrect anything in a port. Cross-compilation for the Darwin successor needs to start from the source trees under `/robotis/`, not from dpkg metadata.
- **Hardware contract is simple and well-supported by mainline.** The CM-740 link is just `ftdi_sio` → `/dev/ttyUSB0`, and the camera is just `uvcvideo`. Both are present in any modern Linux kernel (incl. macOS via libusb or via Linux VM). Porting away from the 2015 image therefore does **not** require kernel work — it requires recompiling the userland framework against newer libc/OpenCV/Boost and resolving the libusb 0.1 → 1.0 split.
- **i386-only userland.** Anything that ships pre-built binaries from the legacy tree will be 32-bit ELF and unrunnable on a modern x86_64 OS without `lib32` shims (and impossible on macOS / ARM). All ports must be source-rebuild ports.
- **Timing pressure justifies PREEMPT.** The kernel was explicitly built with `SMP PREEMPT` on a 1.6 GHz Atom — i.e. ROBOTIS deemed Ubuntu's non-preemptive 3.2 kernel unsuitable for the 125 Hz motion loop. Any successor design either keeps a PREEMPT-RT kernel on the robot's CPU or moves the time-critical loop onto a dedicated MCU (the CM-740 already does most of this) and lets the OS run at normal priority.

## Evidence

Cited file paths (all absolute):

- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/lsb-release`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/os-release`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/debian_version`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/issue`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/timezone`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/etc/hostname`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/boot/`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/boot/grub/grub.cfg`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/boot/config-3.2.66-op2`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/lib/modules/3.2.66-op2/`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/lib/modules/3.2.66-op2/kernel/drivers/usb/serial/ftdi_sio.ko`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/lib/modules/3.2.0-79-generic/`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/var/lib/dpkg/status`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/var/log/dpkg.log`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/var/log_extra/dmesg`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/clonezilla-image/Info-lshw.txt`
- `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/clonezilla-image/Info-lspci.txt`

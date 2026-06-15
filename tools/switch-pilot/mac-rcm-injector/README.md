# Darwin Switch RCM Injector for macOS

This folder provides a small Mac-side launcher for injecting Hekate into an
unpatched Nintendo Switch in RCM.

It does not bundle Switchroot. It uses a Hekate `.bin` payload from either a
Mac-local release folder or the mounted SD card, and bootstraps a local
`fusee-launcher.py` checkout under:

```bash
~/Library/Application Support/DarwinSwitchRCM
```

## Direct Command

Recommended after the SD card has been moved into the Switch:

```bash
tools/switch-pilot/mac-rcm-injector/darwin-switch-rcm-inject.sh \
  --payload dist/switch-pilot/hekate_ctcaer_6.5.2.bin
```

The default search also checks `dist/switch-pilot/hekate_ctcaer_*.bin`, so this
usually works once the local copy exists:

```bash
tools/switch-pilot/mac-rcm-injector/darwin-switch-rcm-inject.sh
```

With the SD still mounted as `SWITCHSD`, an explicit SD payload also works:

```bash
tools/switch-pilot/mac-rcm-injector/darwin-switch-rcm-inject.sh \
  --payload /Volumes/SWITCHSD/hekate_ctcaer_6.5.2.bin
```

Check dependencies and APX detection without injecting:

```bash
tools/switch-pilot/mac-rcm-injector/darwin-switch-rcm-inject.sh --check-only
```

## Double-Click Command

Double-click:

```text
tools/switch-pilot/mac-rcm-injector/Darwin Switch RCM Injector.command
```

macOS may warn because this is a local unsigned script. If needed:

```bash
chmod +x tools/switch-pilot/mac-rcm-injector/*.sh \
  "tools/switch-pilot/mac-rcm-injector/Darwin Switch RCM Injector.command"
```

## Native macOS App

Build the AppKit-based native macOS app:

```bash
tools/switch-pilot/mac-rcm-injector/make-macos-app.sh
open "dist/switch-pilot/Darwin Switch RCM Injector.app"
```

The app provides a native macOS layout with payload selection, passive APX/RCM
status polling, dependency checks, injection, and log viewing. Its app icon is
built from `assets/app-icon-source.png`: the build first center-crops it to a
square, applies a rounded-square alpha mask that follows the image's app-icon
rounding, then exports the full macOS `.icns` set. The current source image
uses a generic translucent controller shape instead of Nintendo logos or exact
Switch trade dress. The app still uses `darwin-switch-rcm-inject.sh` as the
execution backend so the command-line and GUI paths stay consistent.

The `Hekate 주입` button only enables when the app can see the injector script,
the selected payload, local libusb, and the Switch APX/RCM USB device. If the
button stays disabled, run `RCM 다시 확인` after checking the jig, cable, and
that the Switch screen stayed black.

## Physical Steps

1. Insert the prepared SD card into the Switch.
2. Fully power off the Switch.
3. Insert the RCM jig into the right Joy-Con rail.
4. Hold `VOL+` and press `POWER` once.
5. The Switch screen should stay black.
6. Connect the Switch to the Mac with a data-capable USB-C cable.
7. Run the injector.

If Hekate appears, injection worked. If the Nintendo logo appears, RCM entry
failed. If the injector reports success but the screen stays black, the console
may be patched, the cable may be unstable, or the payload may be wrong.

## Requirements

- macOS with Python 3.
- Xcode Command Line Tools only if rebuilding the native app.
- Homebrew `libusb` (`brew install libusb`) or an equivalent libusb install.
- Network access on first run to download `fusee-launcher.py`.
- A Mac-local Hekate payload copy is recommended because the SD card is inside
  the Switch during RCM injection.
- Unpatched Switch v1/Erista, RCM jig, and a data-capable USB-C cable.

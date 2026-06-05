# Darwin Switch — Boot Branding (Plymouth)

Boot splash for the sealed Darwin Switch appliance. Replaces the Ubuntu
Plymouth logo so the Switch boots showing **DARWIN**, not Ubuntu.

This is part of the L2 (branding) sealing layer. It does **not** touch
SysNAND, Nintendo firmware, or the bootloader — it only restyles the
SD-card Switchroot L4T Ubuntu boot splash via Plymouth's standard theme
mechanism.

## What's here

```
plymouth/darwin/
  darwin.plymouth   # theme descriptor (ModuleName=script)
  darwin.script     # Plymouth script: dark bg, centered logo, progress dots
  logo.png          # NOT in git — you provide it (see "Logo" below)
```

The script is defensive: if `logo.png` is missing it still paints the dark
background, the pulsing progress dots, and the "DARWIN" message line. A
missing or unreadable image must never break boot.

## Logo — IMPORTANT (project rule)

**The project app icon file must NEVER be modified or moved.** It is
permanent per a standing project rule. The macOS app references it from the
Swift app resources:

```
app/ui/DarwinForge/Sources/DarwinForgeApp/Resources/AppIcon.png
```

To produce the boot logo, **COPY (duplicate)** that icon into the theme
directory as `logo.png`. Do **not** edit, rename, or move the original. You
provide `logo.png` yourself — it is intentionally not committed and not
generated here.

```bash
# Copy the permanent app icon into the theme dir as logo.png (original untouched).
cp "app/ui/DarwinForge/Sources/DarwinForgeApp/Resources/AppIcon.png" \
   "tools/switch-appliance/branding/plymouth/darwin/logo.png"
```

A square PNG roughly 256x256–512x512 looks best centered on the 1280x720
Switch screen. The script auto-centers whatever size you supply.

## Install on the Switch (Switchroot Ubuntu)

Run these on the Switch (over SSH or locally). All steps are idempotent.

1. Copy the theme into Plymouth's themes directory:

   ```bash
   sudo mkdir -p /usr/share/plymouth/themes/darwin
   sudo cp -a tools/switch-appliance/branding/plymouth/darwin/. \
             /usr/share/plymouth/themes/darwin/
   ```

   Confirm `logo.png` is present (optional but recommended):

   ```bash
   ls -l /usr/share/plymouth/themes/darwin/
   ```

2. Set Darwin as the default Plymouth theme and rebuild the initramfs:

   ```bash
   sudo plymouth-set-default-theme -R darwin
   ```

   `-R` rebuilds the initramfs so the theme is embedded into the early-boot
   image. On most Debian/Ubuntu systems this is all you need.

### Fallback: distros without `plymouth-set-default-theme`

If that helper is unavailable, register the theme via `update-alternatives`
and rebuild the initramfs manually:

```bash
sudo update-alternatives --install \
  /usr/share/plymouth/themes/default.plymouth default.plymouth \
  /usr/share/plymouth/themes/darwin/darwin.plymouth 200

sudo update-alternatives --set default.plymouth \
  /usr/share/plymouth/themes/darwin/darwin.plymouth

sudo update-initramfs -u
```

## Verify (without rebooting)

Preview the splash in a window or on the current console:

```bash
# Confirm the active theme is darwin:
plymouth-set-default-theme

# Sandboxed preview (X session):
sudo plymouthd ; sudo plymouth --show-splash ; sleep 4 ; sudo plymouth --quit
```

If the splash shows a blank dark screen with pulsing dots but no logo, that
means `logo.png` was not copied into `/usr/share/plymouth/themes/darwin/` —
copy it (step 1) and re-run `update-initramfs -u` (or the `-R` form).

## Uninstall / revert to Ubuntu splash

```bash
sudo plymouth-set-default-theme -R ubuntu-logo   # or your previous theme
# (fallback) sudo update-alternatives --auto default.plymouth && sudo update-initramfs -u
sudo rm -rf /usr/share/plymouth/themes/darwin
```

## Notes

- The Switch screen is 1280x720; the script centers all elements relative to
  the detected window geometry, so it adapts to docked/handheld resolutions.
- Re-running the install steps is safe (idempotent): the copy overwrites the
  theme dir and `plymouth-set-default-theme -R` is repeatable.
- Keep this purely cosmetic. It does not affect the cockpit agent, the
  systemd service, or any safety behavior.

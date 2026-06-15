#!/usr/bin/env bash
set -euo pipefail

# apply-appliance.sh — master idempotent installer for the Darwin Switch Appliance.
#
# Ties together the sealing layers (L1 boot docs, L2 seal/session/branding,
# L4 power-stop) on top of the existing tools/switch-pilot agent bundle. Run it
# ON the Switch (Switchroot L4T Ubuntu), over SSH or locally, with sudo.
#
# This is a SEALING layer for the SD-card Linux experience only. It does NOT
# touch SysNAND, Nintendo firmware, or the Hekate bootloader. The Vol- recovery
# escape window stays intact (see boot/hekate_ipl.ini.example and RECOVERY.md).
#
# Every step is idempotent (safe to re-run). Optional steps that depend on an
# image feature (cage, plymouth, apt) are guarded and never abort the whole run;
# they print a clear WARNING and continue. Distro files are configured via
# drop-ins, not in-place edits (the individual seal/*.sh scripts enforce this).
#
# Usage:
#   sudo ./apply-appliance.sh                  # apply the sealing layer
#   sudo ./apply-appliance.sh --dry-run        # print actions, change nothing
#   sudo ./apply-appliance.sh --with-overlayroot   # also enable read-only rootfs

# --- Resolve our own directory robustly (works via symlink / odd cwd). --------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Existing agent bundle lives next to this appliance dir.
PILOT_DIR="${ROOT_DIR}/../switch-pilot"
PILOT_INSTALL="${PILOT_DIR}/install.sh"

INSTALL_DIR="/opt/darwin-switch-agent"
APPLIANCE_DST="${INSTALL_DIR}/appliance"
CONFIG_DIR="/etc/darwin-switch-agent"

# --- Parse flags. -------------------------------------------------------------
DRY_RUN=0
WITH_OVERLAYROOT=0
WITH_CAGE=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --with-overlayroot) WITH_OVERLAYROOT=1 ;;
    --with-cage) WITH_CAGE=1 ;;
    -h|--help)
      echo "Usage: sudo $0 [--dry-run] [--with-overlayroot] [--with-cage]"
      echo "  --with-cage   use the cage/Wayland kiosk instead of the X11 default."
      echo "                Only choose this AFTER verifying cage renders on this"
      echo "                Switch — wlroots has no GBM path on Tegra and may"
      echo "                black-screen (see docs/reports/2026-06-05-switch-appliance-evidence-based-architecture.md)."
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: ${arg}" >&2
      echo "Usage: sudo $0 [--dry-run] [--with-overlayroot] [--with-cage]" >&2
      exit 1
      ;;
  esac
done

# --- Root guard. Dry-run is allowed without root so anyone can preview. --------
if [[ "${DRY_RUN}" -eq 0 && "${EUID}" -ne 0 ]]; then
  echo "apply-appliance.sh must be run with sudo (or use --dry-run to preview)." >&2
  exit 1
fi

# --- Helpers. -----------------------------------------------------------------
banner() {
  echo
  echo "================================================================"
  echo "  $*"
  echo "================================================================"
}

# run: echo + execute, or just echo when --dry-run.
run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    echo "+ $*"
    "$@"
  fi
}

warn() { echo "WARNING: $*" >&2; }

# --- VERSION (read early; used in the os-release step and the summary). --------
VERSION_FILE="${ROOT_DIR}/VERSION"
if [[ -f "${VERSION_FILE}" ]]; then
  DARWIN_SWITCH_OS_VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
fi
DARWIN_SWITCH_OS_VERSION="${DARWIN_SWITCH_OS_VERSION:-0.1.0}"

banner "Darwin Switch Appliance installer v${DARWIN_SWITCH_OS_VERSION}"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "MODE: dry-run (no changes will be made)"
fi
echo "ROOT_DIR: ${ROOT_DIR}"

# =============================================================================
# Dependency preflight — WARN (never fatal) for each missing tool, with the
# apt package name. Lets an offline / partial image continue so the safety
# services still install; the operator gets a clear punch-list of what to add.
# =============================================================================
banner "Dependency preflight"

# check_dep CMD PKG WHY — warn (not fatal) when CMD is missing.
check_dep() {
  local cmd="$1" pkg="$2" why="$3"
  if command -v "${cmd}" >/dev/null 2>&1; then
    echo "  ok   : ${cmd}"
  else
    warn "missing '${cmd}' — apt-get install ${pkg}  (${why})"
  fi
}

# ssh is required to reach the robot (camera tunnel + mode control).
check_dep ssh openssh-client "robot SSH + camera tunnel"
# autossh keeps the camera tunnel reconnecting; plain ssh is a degraded fallback.
check_dep autossh autossh "auto-reconnecting camera tunnel"
# evtest + joycond are how Joy-Cons surface as a usable evdev gamepad.
check_dep evtest evtest "verify gamepad event codes (deadman/stop/estop)"
check_dep joycond joycond "merge paired Joy-Cons into one virtual controller"

# Kiosk stack: cage (Wayland) only when opted in; otherwise the X11 default.
if [[ "${WITH_CAGE}" -eq 1 ]]; then
  check_dep cage cage "Wayland kiosk session (verify it renders on Tegra first)"
else
  check_dep xinit xinit "X11 kiosk startx launcher (primary path)"
  check_dep openbox openbox "X11 window manager for the kiosk"
  check_dep firefox firefox "kiosk browser (native .deb/PPA; NOT snap on L4T)"
fi

# =============================================================================
# Step 1 — Install the existing agent bundle (tools/switch-pilot/install.sh).
# =============================================================================
banner "Step 1/7 — Install Darwin Switch agent (switch-pilot)"
if [[ ! -f "${PILOT_INSTALL}" ]]; then
  echo "ERROR: agent installer not found: ${PILOT_INSTALL}" >&2
  echo "       Expected tools/switch-pilot next to tools/switch-appliance." >&2
  exit 1
fi
run bash "${PILOT_INSTALL}"

# =============================================================================
# Step 2 — Copy this appliance dir into the agent install tree.
# The power-button-stop service hardcodes
# /opt/darwin-switch-agent/appliance/power-button-stop/darwin-power-stop.py,
# so the appliance files must live there. Clean any stale copy first.
# =============================================================================
banner "Step 2/7 — Stage appliance files under ${APPLIANCE_DST}"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[dry-run] rm -rf ${APPLIANCE_DST}"
  echo "[dry-run] install -d ${APPLIANCE_DST}"
  echo "[dry-run] cp -a ${ROOT_DIR}/. ${APPLIANCE_DST}/  (excluding __pycache__)"
else
  rm -rf "${APPLIANCE_DST}"
  install -d "${APPLIANCE_DST}"
  cp -a "${ROOT_DIR}/." "${APPLIANCE_DST}/"
  # Drop compiled-Python caches that may have come along for the ride.
  find "${APPLIANCE_DST}" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
  echo "Staged appliance files at ${APPLIANCE_DST}."
fi

# =============================================================================
# Step 3 — Run the L2 seal scripts (time-sync, no-sleep, autologin, ssh-harden).
# Each is idempotent and EUID-guarded; order matters: autologin creates the
# 'darwin' user that ssh-harden then secures. time-sync runs first so the clock
# is correctable from the very first boot — the Switch RTC is garbage (~19y off
# after power-off), which would otherwise break TLS, journald and time logic.
# =============================================================================
banner "Step 3/7 — Apply seal layer (time-sync, no-sleep, autologin, ssh-harden)"
SEAL_DIR="${ROOT_DIR}/seal"
for s in time-sync.sh no-sleep.sh autologin.sh ssh-harden.sh; do
  seal_script="${SEAL_DIR}/${s}"
  if [[ ! -f "${seal_script}" ]]; then
    warn "seal script missing, skipping: ${seal_script}"
    continue
  fi
  echo "--- seal: ${s} ---"
  run bash "${seal_script}"
done

# =============================================================================
# Step 4 — Install the kiosk session.
#
# PRIMARY = X11 + openbox + browser --kiosk (always installed). This is the
# evidence-based default: wlroots (which cage uses) has no GBM/PRIME allocator
# on NVIDIA Tegra (meta-tegra #1209), so cage can black-screen on first boot
# with no operator present. X11 is the reliable path on Tegra L4T.
#
# cage (Wayland) is OPT-IN via --with-cage, and only AFTER you have verified it
# actually renders on this Switch. darwin-kiosk.sh is installed in both cases.
# =============================================================================
banner "Step 4/7 — Install kiosk session"
SESSION_DIR="${ROOT_DIR}/session"
KIOSK_SH_SRC="${SESSION_DIR}/darwin-kiosk.sh"
KIOSK_SH_DST="/usr/local/bin/darwin-kiosk.sh"
KIOSK_SVC_SRC="${SESSION_DIR}/darwin-kiosk.service"
KIOSK_SVC_DST="/etc/systemd/system/darwin-kiosk.service"
OPENBOX_SRC="${SESSION_DIR}/openbox-autostart"
OPENBOX_DIR="/home/darwin/.config/openbox"
OPENBOX_DST="${OPENBOX_DIR}/autostart"
XINITRC_DST="/home/darwin/.xinitrc"
BASH_PROFILE_DST="/home/darwin/.bash_profile"
STARTX_LINE='[ "$(tty)" = /dev/tty1 ] && [ -z "${DISPLAY:-}" ] && exec startx -- -nocursor'

# install_user_file SRC DST MODE — install owned by darwin when the user exists.
install_user_file() {
  local src="$1" dst="$2" mode="$3"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[dry-run] install -m ${mode} (owner darwin) ${src} ${dst}"
    return 0
  fi
  install -d -m 0755 "$(dirname "${dst}")"
  install -m "${mode}" "${src}" "${dst}"
  if id -u darwin >/dev/null 2>&1; then
    chown darwin:darwin "$(dirname "${dst}")" "${dst}" 2>/dev/null || true
  fi
}

if [[ ! -f "${KIOSK_SH_SRC}" ]]; then
  warn "kiosk entry point missing: ${KIOSK_SH_SRC}; skipping Step 4."
else
  # Always install the kiosk entry point — both X11 and cage exec it.
  run install -m 0755 "${KIOSK_SH_SRC}" "${KIOSK_SH_DST}"

  # --- PRIMARY: X11 + openbox (always installed, regardless of cage) ----------
  echo "Installing X11 + openbox kiosk (primary path)."
  # Best-effort: pull in a minimal X stack + openbox + browser. Non-fatal offline.
  if command -v apt-get >/dev/null 2>&1; then
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      xserver-xorg xinit openbox firefox || warn "X/openbox/firefox install failed (offline?); ensure they exist on the image."
  else
    warn "no apt-get; ensure xserver-xorg, xinit, openbox and a browser are present."
  fi

  if [[ -f "${OPENBOX_SRC}" ]]; then
    install_user_file "${OPENBOX_SRC}" "${OPENBOX_DST}" 0644
    echo "Installed openbox autostart at ${OPENBOX_DST}."
  else
    warn "openbox autostart source missing: ${OPENBOX_SRC}."
  fi

  # ~/.xinitrc — startx launches openbox, whose autostart execs darwin-kiosk.sh.
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[dry-run] write ${XINITRC_DST} (xset blank off; exec openbox-session)"
  else
    printf '%s\n' \
      '#!/bin/sh' \
      '# Darwin Switch kiosk X session (installed by apply-appliance.sh).' \
      'xset s off -dpms s noblank 2>/dev/null || true' \
      'exec openbox-session' > "${XINITRC_DST}"
    chmod 0644 "${XINITRC_DST}"
    id -u darwin >/dev/null 2>&1 && chown darwin:darwin "${XINITRC_DST}" 2>/dev/null || true
    echo "Wrote ${XINITRC_DST}."
  fi

  # ~/.bash_profile — on the tty1 autologin (seal/autologin.sh), launch X once.
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[dry-run] ensure startx line in ${BASH_PROFILE_DST}"
  else
    touch "${BASH_PROFILE_DST}"
    if ! grep -qF 'exec startx' "${BASH_PROFILE_DST}" 2>/dev/null; then
      printf '\n# Darwin Switch kiosk: launch X on the tty1 autologin.\n%s\n' "${STARTX_LINE}" >> "${BASH_PROFILE_DST}"
      echo "Added startx launch line to ${BASH_PROFILE_DST}."
    else
      echo "startx launch line already present in ${BASH_PROFILE_DST}."
    fi
    id -u darwin >/dev/null 2>&1 && chown darwin:darwin "${BASH_PROFILE_DST}" 2>/dev/null || true
  fi

  # X11 boots via getty@tty1 autologin -> startx, so the default target must be
  # multi-user (NOT graphical, which would hand tty1 to a display manager).
  run systemctl set-default multi-user.target
  # Make sure no display manager grabs the VT out from under our autologin.
  for dm in gdm gdm3 sddm lightdm; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${dm}\.service"; then
      run systemctl disable "${dm}.service" || warn "could not disable ${dm}.service"
    fi
  done

  # --- OPT-IN: cage / Wayland (only with --with-cage AND cage present) --------
  if [[ "${WITH_CAGE}" -eq 1 ]]; then
    if command -v cage >/dev/null 2>&1 && [[ -f "${KIOSK_SVC_SRC}" ]]; then
      warn "--with-cage: enabling cage/Wayland kiosk. Verify it renders on THIS Switch;"
      warn "             wlroots may fail on Tegra (no GBM). Keep the Vol- escape ready."
      run install -m 0644 "${KIOSK_SVC_SRC}" "${KIOSK_SVC_DST}"
      run systemctl enable darwin-kiosk.service
      run systemctl set-default graphical.target
      if [[ "${DRY_RUN}" -eq 0 ]]; then
        echo "Enabled darwin-kiosk.service (cage/Wayland, opt-in)."
      fi
    else
      warn "--with-cage requested but cage binary or ${KIOSK_SVC_SRC} missing; staying on X11."
    fi
  else
    echo "cage/Wayland NOT enabled (default). Re-run with --with-cage only after verifying cage on hardware."
  fi
fi

# =============================================================================
# Step 5 — Install the L4 power-button-stop safety service.
# Its ExecStart points at the staged copy under ${APPLIANCE_DST} (Step 2).
# =============================================================================
banner "Step 5/7 — Install power-button STOP safety service"
PWR_SVC_SRC="${ROOT_DIR}/power-button-stop/darwin-power-stop.service"
PWR_SVC_DST="/etc/systemd/system/darwin-power-stop.service"
if [[ -f "${PWR_SVC_SRC}" ]]; then
  run install -m 0644 "${PWR_SVC_SRC}" "${PWR_SVC_DST}"
  run systemctl enable darwin-power-stop.service
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    echo "Enabled darwin-power-stop.service (power/sleep button -> robot STOP)."
  fi
else
  warn "power-button-stop service missing: ${PWR_SVC_SRC}; safety service NOT installed."
fi

# =============================================================================
# Step 6 — Install the Plymouth boot branding (optional, cosmetic, non-fatal).
# =============================================================================
banner "Step 6/7 — Install Plymouth boot branding (optional)"
PLY_SRC="${ROOT_DIR}/branding/plymouth/darwin"
PLY_DST="/usr/share/plymouth/themes/darwin"
if ! command -v plymouth >/dev/null 2>&1 && [[ ! -d /usr/share/plymouth/themes ]]; then
  warn "Plymouth not present on this image; skipping boot branding."
elif [[ ! -d "${PLY_SRC}" ]]; then
  warn "Plymouth theme source missing: ${PLY_SRC}; skipping boot branding."
else
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[dry-run] install -d ${PLY_DST}"
    echo "[dry-run] cp -a ${PLY_SRC}/. ${PLY_DST}/"
    echo "[dry-run] plymouth-set-default-theme -R darwin"
  else
    install -d "${PLY_DST}"
    cp -a "${PLY_SRC}/." "${PLY_DST}/"
    echo "Copied Plymouth theme to ${PLY_DST}."
    # logo.png is user-provided (see branding/README.md) — the theme is
    # defensive and boots fine without it.
    if [[ ! -f "${PLY_DST}/logo.png" ]]; then
      echo "NOTE: logo.png not present in theme dir (user-provided)."
      echo "      Splash will show the dark background + progress dots only."
    fi
    if command -v plymouth-set-default-theme >/dev/null 2>&1; then
      if plymouth-set-default-theme -R darwin; then
        echo "Set default Plymouth theme to 'darwin' and rebuilt initramfs."
      else
        warn "plymouth-set-default-theme -R darwin failed; theme copied but not active."
        warn "See branding/README.md for the update-alternatives fallback."
      fi
    else
      warn "plymouth-set-default-theme not found; theme copied but not activated."
      warn "See branding/README.md for the update-alternatives / update-initramfs fallback."
    fi
  fi
fi

# =============================================================================
# Step 7 — Write the appliance OS-release marker.
# =============================================================================
banner "Step 7/7 — Write /etc/darwin-switch-os-release"
OS_RELEASE_DST="/etc/darwin-switch-os-release"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "[dry-run] write ${OS_RELEASE_DST} (DARWIN_SWITCH_OS_VERSION=${DARWIN_SWITCH_OS_VERSION})"
else
  # Atomic write via tempfile + mv so a partial write never leaves a broken file.
  os_tmp="$(mktemp)"
  {
    echo "DARWIN_SWITCH_OS_NAME=\"Darwin Switch Appliance\""
    echo "DARWIN_SWITCH_OS_VERSION=\"${DARWIN_SWITCH_OS_VERSION}\""
    echo "DARWIN_SWITCH_OS_ID=darwin-switch-appliance"
    echo "DARWIN_SWITCH_OS_APPLIED=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  } > "${os_tmp}"
  install -m 0644 "${os_tmp}" "${OS_RELEASE_DST}"
  rm -f "${os_tmp}"
  echo "Wrote ${OS_RELEASE_DST} (version ${DARWIN_SWITCH_OS_VERSION})."
fi

# =============================================================================
# Optional — overlayroot (read-only rootfs). OPT-IN via --with-overlayroot.
# =============================================================================
if [[ "${WITH_OVERLAYROOT}" -eq 1 ]]; then
  banner "Optional — Enable read-only rootfs (overlayroot)"
  OVERLAY_SH="${SEAL_DIR}/overlayroot.sh"
  if [[ -f "${OVERLAY_SH}" ]]; then
    # overlayroot.sh itself requires --confirm and prints the rationale.
    run bash "${OVERLAY_SH}" --confirm
  else
    warn "overlayroot requested but ${OVERLAY_SH} missing; skipping."
  fi
else
  echo
  echo "(overlayroot read-only rootfs NOT enabled; re-run with --with-overlayroot to enable.)"
fi

# --- Reload systemd so all newly installed units are visible. -----------------
banner "Reload systemd"
run systemctl daemon-reload

# =============================================================================
# Final summary.
# =============================================================================
banner "Darwin Switch Appliance — install complete"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "DRY-RUN finished. No changes were made. Re-run with sudo to apply."
  echo
fi
cat <<SUMMARY
Applied (idempotent) sealing layers:
  L1 boot   : Hekate autoboot is documented in boot/hekate_ipl.ini.example
              (copy to SD /bootloader/hekate_ipl.ini yourself; keep bootwait>=3).
  L2 seal   : time-sync (NTP at boot — Switch RTC is unreliable, ~19y off
              after power-off; agent/cockpit must NOT gate on wall-clock),
              no-sleep (suspend/sleep masked), autologin (darwin@tty1),
              ssh-harden (key-only when a key exists, else password kept).
  L2 session: X11 + openbox kiosk (PRIMARY) — getty@tty1 autologin -> startx ->
              openbox -> darwin-kiosk.sh. cage/Wayland is opt-in (--with-cage)
              because wlroots can black-screen on Tegra (no GBM).
  L2 brand  : Plymouth 'darwin' boot theme (if Plymouth present; logo.png is
              user-provided).
  L4 safety : darwin-power-stop.service — power/sleep button fires robot STOP
              (double-press within 1.5s = ESTOP). This NEVER weakens deadman.

Enabled services / autostart (start on next boot):
  darwin-switch-agent.service   (cockpit on http://127.0.0.1:8765/)
  darwin-power-stop.service     (power-button -> STOP/ESTOP)
  X11 kiosk via tty1 autologin  (default; multi-user.target, display managers disabled)
  darwin-kiosk.service          (cage/Wayland — only if you ran --with-cage)

RECOVERY / un-brick (always available):
  HOLD Volume-Down (Vol-) while powering on to reach the Hekate menu, then pick
  Nintendo OS, recovery, or tools. SysNAND is preserved and untouched. The
  device cannot be permanently bricked while bootwait>=3 keeps that Vol- window.
  See RECOVERY.md for step-by-step recovery.

How to start now (without rebooting):
  sudo systemctl start darwin-switch-agent.service
  sudo systemctl start darwin-power-stop.service
  # cage path: sudo systemctl start darwin-kiosk.service

A REBOOT is recommended so autologin, the kiosk session, and the boot splash
all take effect from a clean start.
SUMMARY

echo
echo "Done."

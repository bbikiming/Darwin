#!/usr/bin/env bash
set -euo pipefail

# ssh-harden.sh — install + harden SSH for the 'darwin' user, anti-lockout safe.
#
# Hardening (key-only auth) is ONLY applied when an authorized_keys file with
# at least one key already exists. Without a key we would lock ourselves out of
# a headless appliance, so we keep password auth and print a clear WARNING.
# All changes go through a drop-in (/etc/ssh/sshd_config.d) validated with
# `sshd -t` before any restart. Idempotent: safe to re-run.

if [[ "${EUID}" -ne 0 ]]; then
  echo "ssh-harden.sh must be run with sudo" >&2
  exit 1
fi

DARWIN_USER="darwin"
DARWIN_HOME="/home/${DARWIN_USER}"
SSH_DIR="${DARWIN_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="${SSHD_DROPIN_DIR}/darwin-harden.conf"

# The hardened distro path for the ssh server unit varies; resolve a name.
ssh_service() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    echo "ssh"
  else
    echo "sshd"
  fi
}
SSH_SERVICE="$(ssh_service)"

# Ensure openssh-server is installed. Only attempt apt-get if present; an
# offline appliance image may already ship it, so this is non-fatal.
if command -v sshd >/dev/null 2>&1; then
  echo "openssh-server already present."
elif command -v apt-get >/dev/null 2>&1; then
  echo "Installing openssh-server..."
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server >/dev/null 2>&1; then
    echo "WARNING: apt-get install openssh-server failed (offline?); continuing." >&2
  fi
else
  echo "WARNING: sshd not found and no apt-get; assuming image ships SSH." >&2
fi

# Ensure the user's .ssh tree exists with correct ownership/permissions.
if id -u "${DARWIN_USER}" >/dev/null 2>&1; then
  install -d -m 0700 -o "${DARWIN_USER}" -g "${DARWIN_USER}" "${SSH_DIR}"
  if [[ ! -f "${AUTH_KEYS}" ]]; then
    install -m 0600 -o "${DARWIN_USER}" -g "${DARWIN_USER}" /dev/null "${AUTH_KEYS}"
  else
    chown "${DARWIN_USER}:${DARWIN_USER}" "${AUTH_KEYS}"
    chmod 0600 "${AUTH_KEYS}"
  fi
  echo "Ensured ${SSH_DIR} (0700) and ${AUTH_KEYS} (0600)."
else
  echo "WARNING: user ${DARWIN_USER} missing; run autologin.sh first. Skipping key setup." >&2
fi

# Anti-lockout gate: only harden to key-only auth when a non-empty
# authorized_keys exists. -s tests for a file that exists and is non-empty.
if [[ -s "${AUTH_KEYS}" ]]; then
  install -d -m 0755 "${SSHD_DROPIN_DIR}"
  cat > "${SSHD_DROPIN}" <<'EOF'
# Managed by darwin-switch-appliance seal/ssh-harden.sh — do not edit by hand.
# Key-only SSH; applied only because a non-empty authorized_keys was present.
PasswordAuthentication no
PermitRootLogin prohibit-password
EOF
  chmod 0644 "${SSHD_DROPIN}"
  echo "Wrote ${SSHD_DROPIN} (key-only auth)."
else
  # Remove any stale hardening drop-in so we never lock out without a key.
  if [[ -f "${SSHD_DROPIN}" ]]; then
    rm -f "${SSHD_DROPIN}"
    echo "Removed stale ${SSHD_DROPIN} (no keys present)."
  fi
  echo "WARNING: key-only SSH SKIPPED — ${AUTH_KEYS} is missing or empty." >&2
  echo "WARNING: password auth stays ENABLED to avoid locking out the appliance." >&2
  echo "         Add a public key to ${AUTH_KEYS}, then re-run ssh-harden.sh." >&2
fi

# If no sshd binary is present (tolerated above for offline images), there is
# nothing to validate or restart. Exit 0 so the master installer continues and
# the L4 power-button STOP safety service still gets installed.
if ! command -v sshd >/dev/null 2>&1; then
  echo "WARNING: sshd binary absent; skipping config validation + service restart." >&2
  echo "ssh-harden seal applied (no sshd present)."
  exit 0
fi

# Always validate the resulting config before touching the running service.
if sshd -t 2>/dev/null || sshd -t -f /etc/ssh/sshd_config 2>/dev/null; then
  echo "sshd config validated."
else
  if [[ -f "${SSHD_DROPIN}" ]]; then
    rm -f "${SSHD_DROPIN}"
    echo "Removed ${SSHD_DROPIN} after validation failure." >&2
  fi
  echo "ERROR: sshd config validation failed; aborting without restart." >&2
  exit 1
fi

# Enable + restart the SSH service so the validated config takes effect.
if systemctl enable "${SSH_SERVICE}" >/dev/null 2>&1; then
  echo "Enabled ${SSH_SERVICE} service."
else
  echo "WARNING: could not enable ${SSH_SERVICE} service." >&2
fi

if systemctl restart "${SSH_SERVICE}" >/dev/null 2>&1; then
  echo "Restarted ${SSH_SERVICE} service."
else
  echo "WARNING: could not restart ${SSH_SERVICE} service; restart manually." >&2
fi

echo "ssh-harden seal applied."

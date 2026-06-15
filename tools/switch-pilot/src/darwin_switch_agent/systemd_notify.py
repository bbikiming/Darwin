from __future__ import annotations

import logging
import os
import socket

# Pure-stdlib sd_notify (no python-systemd dependency).
# Talks the systemd notification protocol over $NOTIFY_SOCKET (AF_UNIX
# datagram). When NOTIFY_SOCKET is unset (e.g. running under `swift run`,
# manual launch, or a non-notify unit), every function is a safe no-op so
# the agent behaves identically off systemd.

_log = logging.getLogger("agent.sd_notify")


def _socket_address() -> str | None:
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return None
    # Abstract namespace sockets start with '@' on the wire as a NUL byte.
    if addr.startswith("@"):
        return "\0" + addr[1:]
    return addr


def notify(state: str) -> bool:
    """Send a raw sd_notify message (e.g. 'READY=1', 'WATCHDOG=1').

    Returns True on success, False if there is no socket or the send failed.
    Never raises — watchdog plumbing must not crash the control loop.
    """
    addr = _socket_address()
    if not addr:
        return False
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            sock.connect(addr)
            sock.sendall(state.encode("utf-8"))
        return True
    except OSError as exc:
        _log.debug("sd_notify '%s' failed: %s", state, exc)
        return False


def ready() -> bool:
    """Tell systemd the unit finished startup (Type=notify becomes active)."""
    return notify("READY=1")


def watchdog() -> bool:
    """Pet the systemd watchdog (keeps WatchdogSec from restarting us)."""
    return notify("WATCHDOG=1")

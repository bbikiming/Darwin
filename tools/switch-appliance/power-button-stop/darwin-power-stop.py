#!/usr/bin/env python3
"""Darwin Switch Appliance — L4 safety: power/sleep button -> robot STOP.

Listens to Linux input devices for the power, sleep, and suspend keys and,
on a key PRESS, POSTs {"action":"stop"} to the cockpit. A second power press
within ESCALATE_WINDOW_S escalates to {"action":"estop"}.

Pure stdlib. Runs as root (needs /dev/input read). Never crashes the loop:
unreadable devices are skipped, HTTP failures are logged, and if every device
goes away we rescan and reconnect.
"""

from __future__ import annotations

import glob
import json
import logging
import os
import select
import struct
import sys
import time
import urllib.error
import urllib.request
from typing import NamedTuple


# --- input_event constants ----------------------------------------------------
EV_KEY = 0x01  # key/button event type
KEY_PRESS = 1  # input_event.value on press (2 == autorepeat, 0 == release)

KEY_POWER = 116
KEY_SLEEP = 142
KEY_SUSPEND = 205
TARGET_CODES = frozenset({KEY_POWER, KEY_SLEEP, KEY_SUSPEND})

# input_event layout. The kernel timeval is two C longs (struct timeval),
# so the record is 16 (timeval) + 2 (type) + 2 (code) + 4 (value) bytes.
# On 64-bit 'l' is 8 bytes -> 24-byte record. On 32-bit 'l' is 4 bytes,
# which yields a 16-byte record; struct.calcsize tracks the native width,
# so EVENT_STRUCT.size below adapts automatically and the read stays aligned.
EVENT_STRUCT = struct.Struct("llHHI")

EVENT_GLOB = "/dev/input/event*"
ESCALATE_WINDOW_S = 1.5  # second power press within this window -> estop
SELECT_TIMEOUT_S = 1.0  # block here; no busy-spin
HTTP_TIMEOUT_S = 2.0
RESCAN_BACKOFF_S = 2.0  # pause before re-globbing when no devices are open
POST_RETRIES = 3  # safety action: retry if the cockpit is briefly down (e.g. agent restart)
RETRY_BACKOFF_S = 0.2  # short pause between retries; keeps total latency < ~0.5s

log = logging.getLogger("power-stop")


class PressState(NamedTuple):
    """Immutable record of the last actionable power-key press."""

    last_power_ts: float = 0.0


def cockpit_url() -> str:
    """Resolve the cockpit action endpoint (env-overridable)."""
    return os.environ.get("COCKPIT_URL", "http://127.0.0.1:8765/api/action")


def post_action(url: str, action: str) -> bool:
    """POST {"action": action} to the cockpit. Returns True on success.

    Never raises: any failure is logged and reported as False so the caller's
    loop keeps running. Safety actions must not be lost to an exception.
    """
    body = json.dumps({"action": action}).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_S) as resp:
            ok = 200 <= resp.status < 300
            if ok:
                log.warning("power-button safety fired: %s -> %s", action, url)
            else:
                log.error("cockpit returned status %s for %s", resp.status, action)
            return ok
    except urllib.error.URLError as exc:
        log.error("failed to POST %s to %s: %s", action, url, exc)
        return False
    except OSError as exc:
        log.error("network error posting %s: %s", action, exc)
        return False


def fire_action(url: str, action: str) -> bool:
    """Deliver a safety action, retrying briefly so a transient cockpit outage
    (e.g. the agent restarting under its systemd watchdog) does not silently
    drop a STOP/ESTOP. Best-effort and bounded: total added latency stays small.
    """
    for attempt in range(1, POST_RETRIES + 1):
        if post_action(url, action):
            return True
        if attempt < POST_RETRIES:
            time.sleep(RETRY_BACKOFF_S)
    log.error("safety action %s undelivered after %d attempts", action, POST_RETRIES)
    return False


def open_devices() -> dict[int, str]:
    """Open every /dev/input/event* read-only and non-blocking.

    Returns a new {fd: path} map. Devices that cannot be opened are skipped
    with a log line and never abort the scan.
    """
    devices: dict[int, str] = {}
    for path in sorted(glob.glob(EVENT_GLOB)):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        except PermissionError:
            log.warning("permission denied for %s; run as root", path)
            continue
        except OSError as exc:
            log.debug("skipping input device %s: %s", path, exc)
            continue
        devices[fd] = path
        log.info("watching input device %s", path)
    return devices


def close_devices(devices: dict[int, str]) -> None:
    """Close all open device fds, ignoring already-closed ones."""
    for fd in devices:
        try:
            os.close(fd)
        except OSError:
            pass


def decide_action(code: int, value: int, state: PressState, now: float) -> tuple[str | None, PressState]:
    """Pure decision: map a key event to a safety action + new press state.

    Returns (action_or_None, new_state). Builds a new PressState instead of
    mutating the old one. A second KEY_POWER press within ESCALATE_WINDOW_S
    escalates stop -> estop. Sleep/suspend always map to plain stop.
    """
    if value != KEY_PRESS or code not in TARGET_CODES:
        return None, state
    if code != KEY_POWER:
        return "stop", state  # sleep/suspend: stop, no escalation
    within_window = (now - state.last_power_ts) <= ESCALATE_WINDOW_S
    is_repeat = state.last_power_ts > 0.0 and within_window
    action = "estop" if is_repeat else "stop"
    return action, PressState(last_power_ts=now)


def drain_fd(fd: int) -> list[tuple[int, int]]:
    """Read all pending input_event records from fd.

    Returns a list of (code, value) for EV_KEY events only. A short/odd read
    or any OSError stops the drain cleanly without raising.
    """
    events: list[tuple[int, int]] = []
    while True:
        try:
            data = os.read(fd, EVENT_STRUCT.size)
        except (BlockingIOError, OSError):
            break
        if len(data) != EVENT_STRUCT.size:
            break
        _, _, event_type, code, value = EVENT_STRUCT.unpack(data)
        if event_type == EV_KEY:
            events.append((code, value))
    return events


def handle_ready(fds: list[int], devices: dict[int, str], url: str, state: PressState) -> PressState:
    """Process readable fds, firing safety actions. Returns new press state."""
    for fd in fds:
        for code, value in drain_fd(fd):
            action, state = decide_action(code, value, state, time.monotonic())
            if action is not None:
                fire_action(url, action)
    return state


def run() -> int:
    """Main loop: open devices, block in select, dispatch, reconnect."""
    url = cockpit_url()
    log.info("darwin-power-stop watching for power/sleep keys -> %s", url)
    state = PressState()
    devices = open_devices()
    try:
        while True:
            if not devices:
                log.warning("no readable input devices; rescanning in %ss", RESCAN_BACKOFF_S)
                time.sleep(RESCAN_BACKOFF_S)
                devices = open_devices()
                continue
            try:
                ready, _, _ = select.select(list(devices), [], [], SELECT_TIMEOUT_S)
            except (OSError, ValueError) as exc:
                log.error("select failed (%s); reopening devices", exc)
                close_devices(devices)
                devices = {}
                continue
            state = handle_ready(ready, devices, url, state)
    except KeyboardInterrupt:
        log.info("interrupted; shutting down")
        return 0
    finally:
        close_devices(devices)


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    try:
        return run()
    except Exception as exc:  # last-resort guard; systemd will restart us
        log.critical("fatal error in power-stop loop: %s", exc, exc_info=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())

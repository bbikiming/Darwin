from __future__ import annotations

import json
import logging
import mimetypes
import os
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from .config import validate_provisioning
from .control_bus import ControlBus


WEB_ROOT = Path(__file__).resolve().parents[2] / "web"
DEFAULT_CONFIG_PATH = "/etc/darwin-switch-agent/config.json"

# Config keys whose values are nested dicts and must be merged one level deep.
_NESTED_SECTIONS = ("mac", "robot", "camera", "ssh")


def merge_config(existing: dict[str, Any], updates: dict[str, Any]) -> dict[str, Any]:
    """Merge validated provisioning updates into config without mutation.

    Top-level scalars (e.g. 'mode') replace; known nested sections are merged
    one level deep so partial section updates keep untouched sub-keys.
    """
    merged = {**existing, **{k: v for k, v in updates.items() if k not in _NESTED_SECTIONS}}
    for section in _NESTED_SECTIONS:
        if section in updates:
            base = existing.get(section, {})
            base = base if isinstance(base, dict) else {}
            merged = {**merged, section: {**base, **updates[section]}}
    return merged


class CockpitServer:
    def __init__(
        self,
        bus: ControlBus,
        host: str = "127.0.0.1",
        port: int = 8765,
        config_path: str = DEFAULT_CONFIG_PATH,
    ):
        self.bus = bus
        self.host = host
        self.port = port
        self.config_path = config_path
        self.log = logging.getLogger("cockpit")
        self.httpd: ThreadingHTTPServer | None = None
        self.thread: threading.Thread | None = None

    def start(self) -> None:
        bus = self.bus
        cfg_path = self.config_path

        class Handler(CockpitHandler):
            control_bus = bus
            config_path = cfg_path

        self.httpd = ThreadingHTTPServer((self.host, self.port), Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        self.log.info("cockpit listening on http://%s:%d", self.host, self.port)

    def stop(self) -> None:
        if self.httpd:
            self.httpd.shutdown()
            self.httpd.server_close()
        if self.thread:
            self.thread.join(timeout=1.0)


class CockpitHandler(BaseHTTPRequestHandler):
    control_bus: ControlBus
    config_path: str = DEFAULT_CONFIG_PATH

    def log_message(self, fmt: str, *args: Any) -> None:
        logging.getLogger("cockpit.http").debug(fmt, *args)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path.startswith("/api/state"):
            self._send_json(self.control_bus.snapshot())
            return
        if parsed.path == "/api/config":
            self._handle_get_config()
            return
        path = "/index.html" if parsed.path in {"", "/"} else parsed.path
        self._send_static(path)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/action":
            self._handle_action()
            return
        if parsed.path == "/api/config":
            self._handle_post_config()
            return
        self.send_error(404)

    def _read_json_body(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0") or 0)
        except (TypeError, ValueError):
            length = 0
        length = max(length, 0)
        body = self.rfile.read(length) if length > 0 else b"{}"
        try:
            payload = json.loads(body.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return {}
        return payload if isinstance(payload, dict) else {}

    def _handle_action(self) -> None:
        payload = self._read_json_body()
        action = str(payload.get("action", "")).strip()
        if action not in {"arm", "stop", "estop", "recover", "ping"}:
            self._send_json({"ok": False, "error": "unknown action"}, status=400)
            return
        self.control_bus.request(action)
        self._send_json({"ok": True, "action": action})

    def _is_loopback(self) -> bool:
        """True only for loopback clients. /api/config reads+writes device
        config (incl. secrets), so it is restricted to the Switch's own kiosk
        browser even if gui.host is ever set to 0.0.0.0."""
        client = (self.client_address[0] if self.client_address else "")
        return client in {"127.0.0.1", "::1", "::ffff:127.0.0.1"}

    def _handle_get_config(self) -> None:
        if not self._is_loopback():
            self._send_json({"ok": False, "error": "local config only"}, status=403)
            return
        # First-boot provisioning UI reads current device config (localhost only).
        try:
            with open(self.config_path, "r", encoding="utf-8") as fp:
                current = json.load(fp)
        except FileNotFoundError:
            self._send_json({})
            return
        except (OSError, json.JSONDecodeError) as exc:
            logging.getLogger("cockpit").warning("config read failed: %s", exc)
            self._send_json({"ok": False, "error": "config unreadable"}, status=500)
            return
        self._send_json(current if isinstance(current, dict) else {})

    def _handle_post_config(self) -> None:
        if not self._is_loopback():
            self._send_json({"ok": False, "error": "local config only"}, status=403)
            return
        payload = self._read_json_body()
        try:
            updates = validate_provisioning(payload)
        except ValueError as exc:
            self._send_json({"ok": False, "error": str(exc)}, status=400)
            return
        try:
            self._write_config(updates)
        except OSError as exc:
            logging.getLogger("cockpit").error("config write failed: %s", exc)
            self._send_json({"ok": False, "error": "write failed"}, status=500)
            return
        self._send_json({"ok": True})

    def _write_config(self, updates: dict[str, Any]) -> None:
        # Merge immutably into existing config, write atomically, drop marker.
        path = Path(self.config_path)
        try:
            with path.open("r", encoding="utf-8") as fp:
                existing = json.load(fp)
            if not isinstance(existing, dict):
                existing = {}
        except (FileNotFoundError, json.JSONDecodeError):
            existing = {}
        merged = merge_config(existing, updates)
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".config.", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fp:
                json.dump(merged, fp, indent=2)
                fp.write("\n")
            os.replace(tmp, path)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        marker = path.parent / ".provisioned"
        try:
            marker.write_text("1\n", encoding="utf-8")
        except OSError as exc:
            logging.getLogger("cockpit").warning("marker write failed: %s", exc)

    def _send_static(self, request_path: str) -> None:
        rel = request_path.lstrip("/")
        if not rel or ".." in Path(rel).parts:
            self.send_error(404)
            return
        path = WEB_ROOT / rel
        if not path.is_file():
            self.send_error(404)
            return
        content_type = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _send_json(self, payload: dict[str, Any], status: int = 200) -> None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

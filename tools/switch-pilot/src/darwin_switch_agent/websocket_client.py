from __future__ import annotations

import base64
import hashlib
import os
import socket
import ssl
import struct
from urllib.parse import urlparse


class WebSocketError(RuntimeError):
    pass


class SimpleWebSocket:
    """Minimal RFC6455 client for text frames.

    This avoids third-party Python dependencies on Switchroot Ubuntu.
    """

    def __init__(self, url: str, timeout: float = 5.0):
        self.url = url
        self.timeout = timeout
        self.sock: socket.socket | None = None

    def connect(self) -> None:
        parsed = urlparse(self.url)
        if parsed.scheme not in ("ws", "wss"):
            raise WebSocketError(f"unsupported scheme: {parsed.scheme}")
        host = parsed.hostname
        if not host:
            raise WebSocketError("missing host")
        port = parsed.port or (443 if parsed.scheme == "wss" else 80)
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query

        raw = socket.create_connection((host, port), timeout=self.timeout)
        if parsed.scheme == "wss":
            raw = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
        raw.settimeout(self.timeout)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        raw.sendall(request.encode("ascii"))
        response = self._recv_http_response(raw)
        if " 101 " not in response.split("\r\n", 1)[0]:
            raise WebSocketError(f"handshake failed: {response.splitlines()[0] if response else 'empty'}")
        accept = self._header(response, "sec-websocket-accept")
        expected = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        ).decode("ascii")
        if accept != expected:
            raise WebSocketError("bad Sec-WebSocket-Accept")
        self.sock = raw

    def close(self) -> None:
        sock = self.sock
        self.sock = None
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    def send_text(self, text: str) -> None:
        if self.sock is None:
            raise WebSocketError("not connected")
        payload = text.encode("utf-8")
        self.sock.sendall(self._encode_frame(0x1, payload))

    def recv_text(self, timeout: float | None = None) -> str | None:
        if self.sock is None:
            raise WebSocketError("not connected")
        old_timeout = self.sock.gettimeout()
        if timeout is not None:
            self.sock.settimeout(timeout)
        try:
            opcode, payload = self._read_frame()
        except socket.timeout:
            return None
        finally:
            if timeout is not None:
                self.sock.settimeout(old_timeout)
        if opcode == 0x8:
            self.close()
            return None
        if opcode == 0x9:
            self.sock.sendall(self._encode_frame(0xA, payload))
            return None
        if opcode != 0x1:
            return None
        return payload.decode("utf-8", errors="replace")

    def _read_frame(self) -> tuple[int, bytes]:
        assert self.sock is not None
        header = self._recv_exact(2)
        first, second = header[0], header[1]
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", self._recv_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self._recv_exact(8))[0]
        mask = self._recv_exact(4) if masked else b""
        payload = self._recv_exact(length)
        if masked:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return opcode, payload

    def _recv_exact(self, count: int) -> bytes:
        assert self.sock is not None
        chunks: list[bytes] = []
        remaining = count
        while remaining > 0:
            chunk = self.sock.recv(remaining)
            if not chunk:
                raise WebSocketError("connection closed")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _encode_frame(self, opcode: int, payload: bytes) -> bytes:
        first = 0x80 | (opcode & 0x0F)
        mask = os.urandom(4)
        length = len(payload)
        if length < 126:
            header = struct.pack("!BB", first, 0x80 | length)
        elif length <= 0xFFFF:
            header = struct.pack("!BBH", first, 0x80 | 126, length)
        else:
            header = struct.pack("!BBQ", first, 0x80 | 127, length)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return header + mask + masked

    @staticmethod
    def _recv_http_response(sock: socket.socket) -> str:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
            if len(data) > 65536:
                break
        return data.decode("iso-8859-1", errors="replace")

    @staticmethod
    def _header(response: str, name: str) -> str | None:
        prefix = name.lower() + ":"
        for line in response.split("\r\n")[1:]:
            if line.lower().startswith(prefix):
                return line.split(":", 1)[1].strip()
        return None

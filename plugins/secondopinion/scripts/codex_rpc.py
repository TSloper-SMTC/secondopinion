"""Bounded public app-server JSON-RPC over a same-user private Unix socket.

No private Codex files, TCP listener, credentials, shell execution or session
resumption. Each client is single-threaded; callers serialize their requests.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import struct
import time

MAX_FRAME = 16 * 1024 * 1024


class ProtocolError(ValueError):
    pass


class RpcError(ProtocolError):
    def __init__(self, error):
        self.code = error.get("code")
        super().__init__("Codex rejected request: " + str(error.get("message", error)))


def _private_directory(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError("Codex socket link and target directories must be owned by this user "
                         "and not group/world-writable")


def socket_target(value):
    """Validate a same-user private socket; return the canonical path to connect to.

    Only the final component may be a symlink: the managed daemon's stable control
    link to its per-start socket. It must point directly at an absolute canonical
    path, and neither directory may be writable by anyone else, so the checked
    target is what connect() reaches. Resolved on every connect, never stored.
    """
    path = Path(value)
    if not path.is_absolute() or path.name in ("", "..") or str(path.parent) != str(path.parent.resolve()):
        raise ValueError("socket must be an absolute path in a canonical directory, without symlinks")
    target = path
    if path.is_symlink():
        _private_directory(path.parent)
        target = Path(os.readlink(path))
        if path.lstat().st_uid != os.getuid() or not target.is_absolute() or \
                str(target) != str(target.resolve()):
            raise ValueError("socket link must be owned by this user and point directly at an "
                             "absolute canonical path")
        _private_directory(target.parent)
    if len(str(target).encode()) >= 104:
        raise ValueError("Unix socket path is too long")
    info = target.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Codex socket must be owned by this user and private (mode 0600)")
    return str(target)


def socket_path(value):
    """Validate; return the stable path to register, which may be the daemon's link."""
    socket_target(value)
    return str(Path(value))


class Client:
    def __init__(self, path, timeout=10):
        self.timeout = timeout
        self.counter = 0
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.deadline = time.monotonic() + timeout
        try:
            self.sock.settimeout(timeout)
            self.sock.connect(socket_target(path))
            _, uid, _ = struct.unpack("3i", self.sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
            if uid != os.getuid():
                raise ValueError("Codex endpoint peer belongs to another user")
            key = base64.b64encode(os.urandom(16)).decode()
            self._send(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: " + key + "\r\n\r\n").encode())
            header = b""
            while not header.endswith(b"\r\n\r\n"):
                header += self._read(1)
                if len(header) > 16384:
                    raise ProtocolError("oversized WebSocket handshake")
            lines = header.decode("ascii").split("\r\n")
            fields = dict(line.split(":", 1) for line in lines[1:] if ":" in line)
            fields = {k.lower(): v.strip() for k, v in fields.items()}
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            if (not lines[0].startswith("HTTP/1.1 101 ") or fields.get("sec-websocket-accept") != accept or
                    fields.get("upgrade", "").lower() != "websocket"):
                raise ProtocolError("invalid WebSocket handshake")
            self.call("initialize", {"clientInfo": {"name": "secondopinion_wakeup", "version": "1"},
                "capabilities": {"experimentalApi": True}})
            self._frame(1, b'{"method":"initialized"}')
        except BaseException:
            self.close()
            raise

    def _remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Codex request deadline exceeded")
        self.sock.settimeout(remaining)

    def _send(self, data):
        self._remaining()
        self.sock.sendall(data)

    def _read(self, length):
        result = bytearray()
        while len(result) < length:
            self._remaining()
            chunk = self.sock.recv(length - len(result))
            if not chunk:
                raise EOFError("Codex connection closed")
            result.extend(chunk)
        return bytes(result)

    def _frame(self, opcode, payload):
        size = len(payload)
        if size > MAX_FRAME:
            raise ProtocolError("outgoing message too large")
        prefix = bytes([0x80 | opcode])
        prefix += (bytes([0x80 | size]) if size < 126 else b"\xfe" + struct.pack("!H", size)
                   if size < 65536 else b"\xff" + struct.pack("!Q", size))
        mask = os.urandom(4)
        self._send(prefix + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _receive(self):
        message = bytearray()
        started = False
        while True:
            first, second = self._read(2)
            opcode, final = first & 15, bool(first & 128)
            if first & 0x70 or second & 128:
                raise ProtocolError("invalid server WebSocket flags")
            size = second & 127
            if size == 126:
                size = struct.unpack("!H", self._read(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self._read(8))[0]
            if size > MAX_FRAME or len(message) + size > MAX_FRAME:
                raise ProtocolError("incoming message too large")
            if opcode >= 8 and (not final or size > 125):
                raise ProtocolError("invalid control frame")
            payload = self._read(size)
            if opcode == 8:
                raise EOFError("Codex closed WebSocket")
            if opcode == 9:
                self._frame(10, payload)
                continue
            if opcode == 10:
                continue
            if opcode not in (0, 1) or (opcode == 0) != started:
                raise ProtocolError("invalid text frame sequence")
            started = True
            message.extend(payload)
            if final:
                decoded = json.loads(message)
                if not isinstance(decoded, dict):
                    raise ProtocolError("invalid JSON-RPC envelope")
                return decoded

    def call(self, method, params):
        self.counter += 1
        request_id = self.counter
        self.deadline = time.monotonic() + self.timeout
        self._frame(1, json.dumps({"id": request_id, "method": method, "params": params}).encode())
        while True:
            reply = self._receive()
            # This client never answers approval requests or supplies credentials.
            if reply.get("id") != request_id or "method" in reply:
                continue
            if "error" in reply:
                raise RpcError(reply["error"])
            if "result" not in reply:
                raise ProtocolError("missing JSON-RPC result")
            return reply["result"]

    def close(self):
        self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

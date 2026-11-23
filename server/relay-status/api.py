"""Private, bounded Unix HTTP endpoint. No request or authorization logging."""
import base64
from dataclasses import dataclass
import errno
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import signal
import socketserver
import stat
import struct
import sys
import threading
import time

from common import (
    DAY, SNAPSHOT, SNAPSHOT_LIMIT, SOCKET, boot_clock, boot_id, decode_object, exact,
    number, project_snapshot_response, read_regular,
)

PATH = b"/api/relay-status/v1"
AUTH = re.compile(rb"(?i:Bearer) ([A-Za-z0-9_-]{43})")
HEX = re.compile(r"[0-9a-f]{64}")
HEADER_NAME = re.compile(rb"[!#$%&'*+.^_`|~0-9A-Za-z-]+")
HEADER_LIMIT = 8192
DEADLINE = 2
WORKERS = 4
ERRORS = {
    400: ("Bad Request", "bad_request", ()),
    401: ("Unauthorized", "unauthorized", (("WWW-Authenticate", "Bearer"),)),
    405: ("Method Not Allowed", "method_not_allowed", (("Allow", "GET"),)),
    429: ("Too Many Requests", "rate_limited", (("Retry-After", "30"),)),
    503: ("Service Unavailable", "service_unavailable", ()),
}
INVALID = (OSError, ValueError, RecursionError, OverflowError)


@dataclass(frozen=True)
class Credentials:
    active: bytes
    previous: bytes
    rotated_at: float
    previous_until: float
    has_previous: bool

    @classmethod
    def from_document(cls, doc):
        if not exact(doc, "active_sha256 previous_sha256 rotated_at previous_until"):
            raise ValueError("invalid credential shape")
        active, old = doc["active_sha256"], doc["previous_sha256"]
        start, stop = doc["rotated_at"], doc["previous_until"]
        if type(active) is not str or not HEX.fullmatch(active):
            raise ValueError("invalid active digest")
        if old is None and start is None and stop is None:
            return cls(bytes.fromhex(active), bytes(32), 0, 0, False)
        if (type(old) is not str or not HEX.fullmatch(old) or old == active
                or not number(start) or not number(stop) or not 0 < stop - start <= DAY
                or start <= 0):
            raise ValueError("invalid previous digest")
        return cls(bytes.fromhex(active), bytes.fromhex(old), start, stop, True)

    def allows(self, authorization, now):
        match = AUTH.fullmatch(authorization)
        if not match:
            return False
        token = match[1]
        decoded = base64.urlsafe_b64decode(token + b"=")
        if base64.urlsafe_b64encode(decoded).rstrip(b"=") != token:
            return False
        digest = hashlib.sha256(token).digest()
        current = hmac.compare_digest(digest, self.active)
        previous = hmac.compare_digest(digest, self.previous)
        return current or (previous and self.has_previous and self.rotated_at <= now < self.previous_until)


def credential_access(fd, st):
    # systemd can deliver an owner-only file or grant this specific UID a
    # read ACL. On Linux the group mode bits then describe the ACL mask,
    # not the owning group's actual permission. Inspect the ACL on this fd.
    mode = stat.S_IMODE(st.st_mode)
    if mode not in (0o400, 0o600, 0o440, 0o640):
        raise ValueError("credential permissions")
    try:
        acl = os.getxattr(fd, "system.posix_acl_access")
    except OSError as exc:
        if exc.errno not in (errno.ENODATA, errno.ENOTSUP) or mode & 0o070:
            raise ValueError("credential ACL unavailable") from exc
        return
    undefined = 0xFFFFFFFF
    expected = [
        (0x01, mode >> 6, undefined),       # owner (root or API UID)
        (0x02, 4, os.getuid()),             # named API UID, read only
        (0x04, 0, undefined),              # owning group: no access
        (0x10, 4, undefined),              # mask
        (0x20, 0, undefined),              # others: no access
    ]
    if (not mode & 0o040 or len(acl) != 4 + 8 * len(expected)
            or acl[:4] != struct.pack("<I", 2)
            or list(struct.iter_unpack("<HHI", acl[4:])) != expected):
        raise ValueError("credential ACL permissions")


def load_credentials():
    path = Path(os.environ["CREDENTIALS_DIRECTORY"]) / "verify.json"
    raw, _ = read_regular(path, 1024, owners=(0, os.getuid()), check_fd=credential_access)
    return Credentials.from_document(decode_object(raw))

def snapshot():
    raw, _ = read_regular(SNAPSHOT, SNAPSHOT_LIMIT, mode=0o640)
    return project_snapshot_response(decode_object(raw), boot_id(), boot_clock())


def response(code, payload=None, head=False, *, green_for_ms=0):
    if code == 200:
        phrase, headers = "OK", (("QuotaBar-Green-For-Ms", str(green_for_ms)),)
    else:
        phrase, message, headers = ERRORS[code]
        payload = {"error": message}
    body = json.dumps(payload, allow_nan=False, separators=(",", ":")).encode("ascii") + b"\n"
    fields = [
        ("Content-Type", "application/json"), ("Cache-Control", "no-store"),
        ("Connection", "close"), ("Content-Length", str(len(body))), *headers,
    ]
    start = f"HTTP/1.1 {code} {phrase}\r\n" + "".join(f"{k}: {v}\r\n" for k, v in fields) + "\r\n"
    return start.encode("ascii") + (b"" if head else body)


def dispatch(raw, trailing, credentials, read_snapshot, now):
    lines = raw.split(b"\r\n")
    parts = lines[0].split(b" ")
    head = parts[0] == b"HEAD"
    if (len(parts) != 3 or not HEADER_NAME.fullmatch(parts[0])
            or parts[1] != PATH or parts[2] not in (b"HTTP/1.0", b"HTTP/1.1") or trailing):
        return response(400, head=head)
    values = {}
    for line in lines[1:]:
        name, sep, value = line.partition(b":")
        if (not sep or not HEADER_NAME.fullmatch(name)
                or any(c != 9 and not 32 <= c <= 126 for c in value)):
            return response(400, head=head)
        values.setdefault(name.lower(), []).append(value.strip(b" \t"))
    if (b"transfer-encoding" in values or values.get(b"content-length", [b"0"]) != [b"0"]
            or values.get(b"x-quotabar-body", [b"0"]) != [b"0"]):
        return response(400, head=head)
    if parts[0] != b"GET":
        return response(405, head=head)
    auth = values.get(b"authorization", [])
    if len(auth) != 1 or not credentials.allows(auth[0], now):
        return response(401)
    try:
        payload, green_for_ms = read_snapshot()
        return response(200, payload, green_for_ms=green_for_ms)
    except INVALID:
        return response(503)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        deadline = time.monotonic() + DEADLINE
        data = bytearray()
        reply = response(400)
        try:
            while len(data) < HEADER_LIMIT:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self.request.settimeout(remaining)
                chunk = self.request.recv(min(2048, HEADER_LIMIT - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
                raw, marker, trailing = data.partition(b"\r\n\r\n")
                if marker:
                    reply = dispatch(bytes(raw), trailing, self.server.credentials,
                                     self.server.read_snapshot, time.time())
                    break
        except TimeoutError:
            pass
        except OSError:
            return
        try:
            self.request.settimeout(0.25)
            self.request.sendall(reply)
        except OSError:
            pass


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    request_queue_size = 8

    def __init__(self, address, credentials, read_snapshot):
        self.credentials = credentials
        self.read_snapshot = read_snapshot
        self.slots = threading.BoundedSemaphore(WORKERS)
        super().__init__(str(address), Handler)

    def process_request(self, request, address):
        if self.slots.acquire(blocking=False):
            try:
                super().process_request(request, address)
            except BaseException:
                self.slots.release()
                raise
        else:
            try:
                request.setblocking(False)
                request.send(response(503))
            except OSError:
                pass
            finally:
                self.shutdown_request(request)

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()

    def handle_error(self, request, address):
        # socketserver's default dumps peer data and a traceback.
        pass


def main():
    credentials = load_credentials()
    try:
        st = SOCKET.lstat()
    except FileNotFoundError:
        pass
    else:
        if not stat.S_ISSOCK(st.st_mode) or st.st_uid != os.getuid():
            raise ValueError("unexpected socket entry")
        SOCKET.unlink()

    old = os.umask(0o117)  # socket 0660; inherits nginx group from the setgid directory
    try:
        server = Server(SOCKET, credentials, snapshot)
    finally:
        os.umask(old)
    try:
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        with server:
            server.serve_forever()
    finally:
        SOCKET.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except INVALID + (KeyError,):
        sys.exit("api: unavailable")

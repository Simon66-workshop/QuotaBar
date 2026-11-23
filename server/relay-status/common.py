"""Bounded Linux file reads and the private/public v1 snapshot contract."""
import datetime as dt
import json
import math
import os
from pathlib import Path
import re
import secrets
import stat
import time

RUN = Path("/run/quotabar-relay-status")
CONFIG = Path("/etc/quotabar-relay-status")
BOOT_ID = Path("/proc/sys/kernel/random/boot_id")
SNAPSHOT = RUN / "snapshot.json"
SOCKET = RUN / "api/status.sock"
SOURCE_LIMIT = 64 * 1024
SNAPSHOT_LIMIT = 4096
SNAPSHOT_MAX_AGE = 75
FEISHU_OK_AGE = 90
WECOM_HEARTBEAT_OK_AGE = 90
WECOM_PONG_OK_AGE = 60
CONNECTION_DOWN_AGE = 180
CLOCK_SKEW = 5
CERT_EXPIRING_DAYS = 14
DAY = 86400
BOOT_PATTERN = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
TIME_PATTERN = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
REASONS = {
    "ok": {"ready"},
    "down": {"unit_down", "paused_by_lease", "heartbeat_stale", "pong_stale"},
    "degraded": {"transitioning", "heartbeat_late", "pong_late", "reconnecting", "lease_conflict"},
    "unknown": {"source_unavailable"},
}


def checked_directory(path, owners, root_only_parents=False):
    """Pin every directory by fd; never resolve a symlink at any component."""
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts or path.anchor != "/":
        raise ValueError("absolute path required")
    flags = getattr(os, "O_PATH", os.O_RDONLY) | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    fd = os.open("/", flags)
    try:
        parts = path.parts[1:]
        for i, part in enumerate(parts):
            child = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = child
            info = os.fstat(fd)
            allowed = (0,) if root_only_parents and i < len(parts) - 1 else owners
            if info.st_uid not in allowed or info.st_mode & 0o022:
                raise ValueError("untrusted directory")
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_regular(path, limit, owners=(0,), *, parent_owners=None,
                 root_only_parents=False, mode=None, missing_ok=False, check_fd=None):
    path = Path(path)
    parent = checked_directory(path.parent, parent_owners if parent_owners is not None else owners,
                               root_only_parents)
    try:
        try:
            fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                         dir_fd=parent)
        except FileNotFoundError:
            if missing_ok:
                return None, None
            raise
        with os.fdopen(fd, "rb") as stream:
            before = os.fstat(stream.fileno())
            if (not stat.S_ISREG(before.st_mode) or before.st_uid not in owners
                    or before.st_nlink != 1 or before.st_mode & 0o022
                    or (mode is not None and stat.S_IMODE(before.st_mode) != mode)
                    or before.st_size > limit):
                raise ValueError("untrusted file")
            if check_fd is not None:
                check_fd(stream.fileno(), before)
            data = stream.read(limit + 1)
            after = os.fstat(stream.fileno())
            if (len(data) > limit or (before.st_size, before.st_mtime_ns)
                    != (after.st_size, after.st_mtime_ns)):
                raise ValueError("changing or oversized file")
            return data, after
    finally:
        os.close(parent)


def decode_object(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result

    def invalid(_):
        raise ValueError("nonfinite JSON")

    result = json.loads(data.decode("utf-8"), object_pairs_hook=pairs, parse_constant=invalid)
    if not isinstance(result, dict):
        raise ValueError("expected object")
    return result


def number(value):
    return type(value) in (int, float) and -1e15 <= value <= 1e15


def rfc3339(value):
    try:
        return dt.datetime.fromtimestamp(value, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, OverflowError, OSError):
        return None


def parse_date(value):
    if type(value) is not str or not TIME_PATTERN.fullmatch(value):
        raise ValueError("invalid timestamp")
    return dt.datetime.fromisoformat(value[:-1] + "+00:00").timestamp()


def boot_id():
    data, _ = read_regular(BOOT_ID, 64)
    value = data.decode("ascii").strip()
    if not BOOT_PATTERN.fullmatch(value):
        raise ValueError("invalid boot ID")
    return value


def boot_clock():
    return time.clock_gettime(time.CLOCK_BOOTTIME)


def atomic_write(path, data, mode, *, gid=None, owners=(0,)):
    """Create in the pinned destination directory, fsync, then replace."""
    path = Path(path)
    parent = checked_directory(path.parent, owners)
    temporary = "." + path.name + "." + secrets.token_hex(12)
    created = False
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600,
                     dir_fd=parent)
        created = True
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            if gid is not None:
                os.fchown(stream.fileno(), 0, gid)
            os.fchmod(stream.fileno(), mode)
            os.fsync(stream.fileno())
        os.replace(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent)
        created = False
    finally:
        try:
            if created:
                os.unlink(temporary, dir_fd=parent)
        finally:
            os.close(parent)


def exact(obj, keys):
    return isinstance(obj, dict) and obj.keys() == set(keys.split())


def validate_timestamp(value, observed):
    stamp = parse_date(value) if value is not None else None
    if stamp is not None and not 0 <= stamp <= observed + CLOCK_SKEW:
        raise ValueError("invalid heartbeat timestamp")
    return stamp


def project_snapshot(doc, current_boot, current_mono):
    if (not exact(doc, "schema_version observed_at boot_id observed_boottime lease_clear_for_s "
                       "feishu wecom certificate")
            or type(doc["schema_version"]) is not int or doc["schema_version"] != 1
            or not BOOT_PATTERN.fullmatch(current_boot) or doc["boot_id"] != current_boot
            or not number(doc["observed_boottime"]) or doc["observed_boottime"] < 0
            or not number(current_mono)):
        raise ValueError("invalid snapshot")
    age = current_mono - doc["observed_boottime"]
    if not 0 <= age <= SNAPSHOT_MAX_AGE:
        raise ValueError("stale snapshot")
    # The collector translates the lease cutoff using the full observation
    # time. The API only needs elapsed boot time, not wall time or the lease file.
    lease_clear_for_s = doc["lease_clear_for_s"]
    if lease_clear_for_s is not None and (not number(lease_clear_for_s) or lease_clear_for_s <= 0):
        raise ValueError("invalid lease cutoff")
    lease_expired = lease_clear_for_s is not None and age >= lease_clear_for_s
    observed = parse_date(doc["observed_at"])
    public_connections = {}
    for name, heartbeat_ok in (("feishu", FEISHU_OK_AGE), ("wecom", WECOM_HEARTBEAT_OK_AGE)):
        status = doc[name]
        keys = "state reason last_heartbeat_at"
        if not exact(status, keys + (" effective_pong_age_s" if name == "wecom" else "")):
            raise ValueError("invalid connection")
        state, reason = status["state"], status["reason"]
        if type(state) is not str or type(reason) is not str or reason not in REASONS.get(state, ()):
            raise ValueError("invalid connection enum")
        heartbeat = validate_timestamp(status["last_heartbeat_at"], observed)
        # Check green was possible at collection (times are floored to UTC
        # seconds). The effective WeCom pong cannot be younger than its sample.
        heartbeat_age = max(0, observed - heartbeat) if heartbeat is not None else None
        collection_limit = min(heartbeat_ok, WECOM_PONG_OK_AGE) if name == "wecom" else heartbeat_ok
        if state == "ok" and (heartbeat_age is None or heartbeat_age > collection_limit):
            raise ValueError("contradictory green heartbeat evidence")
        pong = status["effective_pong_age_s"] if name == "wecom" else None
        if name == "wecom":
            if (pong is not None and (not number(pong) or pong < 0)
                    or state == "ok" and (pong is None or heartbeat_age > pong + 1
                                          or pong > WECOM_PONG_OK_AGE)):
                raise ValueError("contradictory pong evidence")
        if state in ("ok", "degraded") and reason != "transitioning":
            # Only these observations establish current-instance evidence.
            # Use unrounded monotonic elapsed time and check red before yellow.
            if heartbeat_age is not None and heartbeat_age + age > CONNECTION_DOWN_AGE:
                state, reason = "down", "heartbeat_stale"
            elif pong is not None and pong + age > CONNECTION_DOWN_AGE:
                state, reason = "down", "pong_stale"
            elif state == "ok":
                if heartbeat_age + age > heartbeat_ok:
                    state, reason = "degraded", "heartbeat_late"
                elif pong is not None and pong + age > WECOM_PONG_OK_AGE:
                    state, reason = "degraded", "pong_late"
                elif lease_expired:
                    state, reason = "unknown", "source_unavailable"
        public_connections[name] = {
            "state": state, "reason": reason, "last_heartbeat_at": status["last_heartbeat_at"],
        }
    cert = doc["certificate"]
    if not exact(cert, "state expires_at days_remaining"):
        raise ValueError("invalid certificate")
    state, expiry, days = cert["state"], cert["expires_at"], cert["days_remaining"]
    if state == "unknown":
        if expiry is not None or days is not None:
            raise ValueError("invalid unknown certificate")
    elif state in ("ok", "expiring", "expired"):
        seconds = parse_date(expiry) - observed
        expected = ("expired" if seconds <= 0 else
                    "expiring" if seconds <= CERT_EXPIRING_DAYS * DAY else "ok")
        # Snapshot observation truncates fractional seconds; tolerate this
        # sub-second ambiguity only, not fabricated days or state.
        if (state != expected or type(days) is not int
                or days not in (seconds // DAY, (seconds - 1) // DAY)):
            raise ValueError("invalid certificate lifetime")
    else:
        raise ValueError("invalid certificate state")
    return {
        "schema_version": 1, "observed_at": doc["observed_at"],
        "snapshot_age_s": math.floor(age), **public_connections, "certificate": cert,
    }

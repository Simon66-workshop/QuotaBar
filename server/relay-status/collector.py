"""Root oneshot; never send requests to the relays or mutate their state."""
from dataclasses import dataclass
import grp
import json
from pathlib import Path
import pwd
import re
import socket
import ssl
import subprocess
import sys
import time

from common import (
    CERT_EXPIRING_DAYS, CLOCK_SKEW, CONFIG, CONNECTION_DOWN_AGE, DAY, FEISHU_OK_AGE,
    SNAPSHOT, SNAPSHOT_LIMIT, SOURCE_LIMIT, WECOM_HEARTBEAT_OK_AGE, WECOM_PONG_OK_AGE,
    atomic_write, boot_clock, boot_id, decode_object, exact, number, parse_date,
    project_snapshot, read_regular, rfc3339,
)

FEISHU_FILE = Path("/var/lib/66-relay/feishu/heartbeat.json")
WECOM_FILE = Path("/var/lib/66-relay/wecom/heartbeat.json")
LEASE_FILE = Path("/var/lib/66-relay-control/direct-ecs13-lease.json")
POLICY_FILE = CONFIG / "source-policy.json"
FEISHU_UNIT = "relay-feishu.service"
WECOM_UNIT = "relay-wecom.service"
UNITS = (FEISHU_UNIT, WECOM_UNIT)
HOST = "66workshop.cn"
TRANSITIONING = {"activating", "reloading", "deactivating"}
UNAVAILABLE = (OSError, ValueError, RecursionError, OverflowError, subprocess.SubprocessError)
WITH_KEY_ERROR = UNAVAILABLE + (KeyError,)


@dataclass(frozen=True)
class Policy:
    feishu_ack: bool = False
    wecom_clock: bool = False
    reconnect_states: frozenset = frozenset()
    absent_lease_clear: bool = False
    expired_lease_clear: bool = False


@dataclass(frozen=True)
class Unit:
    state: str
    pid: int
    started: float
    invocation: str


def source(path, **kwargs):
    try:
        raw, info = read_regular(path, SOURCE_LIMIT, **kwargs)
        return (decode_object(raw), info.st_mtime) if raw is not None else (None, None)
    except UNAVAILABLE:
        return None, -1  # unreadable is not equivalent to absent


def read_policy():
    doc, _ = source(POLICY_FILE, mode=0o600)
    if not exact(doc, "feishu_ack_confirmed wecom_clock_confirmed wecom_reconnect_states "
                      "absent_lease_is_clear expired_lease_is_clear"):
        return Policy()
    flags = [doc[key] for key in ("feishu_ack_confirmed", "wecom_clock_confirmed",
                                 "absent_lease_is_clear", "expired_lease_is_clear")]
    states = doc["wecom_reconnect_states"]
    if (any(type(flag) is not bool for flag in flags) or type(states) is not list
            or len(states) > 16 or any(type(s) is not str or s == "subscribed"
                                      or not re.fullmatch(r"[a-z_]{1,32}", s) for s in states)):
        return Policy()
    return Policy(flags[0], flags[1], frozenset(states), flags[2], flags[3])


def load_units():
    try:
        result = subprocess.run(
            ["/usr/bin/systemctl", "--system", "--no-pager", "show",
             "--property=Id,LoadState,ActiveState,MainPID,ExecMainStartTimestampMonotonic,InvocationID",
             *UNITS],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=1,
        )
        if len(result.stdout) > 4096:
            return {}
        units = {}
        for group in result.stdout.decode("ascii").strip().split("\n\n"):
            try:
                fields = dict(line.split("=", 1) for line in group.splitlines())
                name = fields.get("Id")
                if name in UNITS and fields.get("LoadState") == "loaded":
                    # Transitional/stopped units need not have an invocation or start time.
                    units[name] = Unit(fields["ActiveState"], int(fields.get("MainPID") or "0"),
                                       int(fields.get("ExecMainStartTimestampMonotonic") or "0") / 1e6,
                                       fields.get("InvocationID", ""))
            except (KeyError, ValueError, OverflowError):
                continue
        return units
    except UNAVAILABLE:
        return {}


def lease_status(sample, now, policy):
    doc, mtime = sample
    if doc is None:
        return "clear" if mtime is None and policy.absent_lease_clear else "unknown"
    if doc.get("state") != "LEASE" or type(doc.get("ecs_stopped")) is not bool:
        return "unknown"
    expiry = doc.get("expires_at")
    if not number(expiry):
        try:
            expiry = parse_date(expiry)
        except UNAVAILABLE:
            return "unknown"
    if not 0 < expiry or not rfc3339(expiry):
        return "unknown"
    if expiry <= now:
        return "clear" if policy.expired_lease_clear else "unknown"
    return "stopped" if doc["ecs_stopped"] else "clear"


def connection(name, unit, sample, lease, now, mono, policy):
    doc, mtime = sample
    timestamp = (doc.get("timestamp") if name == "feishu" else mtime) if doc is not None else None
    history = (rfc3339(timestamp)
               if number(timestamp) and 0 <= timestamp <= now + CLOCK_SKEW else None)

    pong = None

    def status(state, reason):
        result = {"state": state, "reason": reason, "last_heartbeat_at": history}
        if name == "wecom":
            result["effective_pong_age_s"] = pong
        return result

    def unknown():
        return status("unknown", "source_unavailable")

    if unit is None:
        return unknown()
    if unit.state in ("failed", "inactive"):
        return status("down", "paused_by_lease" if lease == "stopped" else "unit_down")
    if unit.state in TRANSITIONING:
        return status("degraded", "transitioning")
    if (unit.state != "active" or history is None or unit.pid <= 0
            or type(doc.get("pid")) is not int or doc["pid"] != unit.pid
            or not re.fullmatch(r"[0-9a-f]{32}", unit.invocation)
            or unit.invocation == "0" * 32
            or not 0 < unit.started <= mono):
        return unknown()
    wall_start = now - (mono - unit.started)
    if timestamp < wall_start:
        return unknown()
    age = max(0, now - timestamp)
    heartbeat_ok = FEISHU_OK_AGE if name == "feishu" else WECOM_HEARTBEAT_OK_AGE
    if name == "feishu":
        # A copied, clock-shifted or pre-start sample is not current evidence.
        if (not number(mtime) or not wall_start <= mtime <= now + CLOCK_SKEW
                or abs(mtime - timestamp) > CLOCK_SKEW):
            return unknown()
    else:
        source_mono = doc.get("monotonic")
        if (not policy.wecom_clock or not number(source_mono)
                or not unit.started <= source_mono <= mono + CLOCK_SKEW
                or abs((mono - source_mono) - (now - timestamp)) > CLOCK_SKEW):
            return unknown()

    if name == "wecom":
        pong_age = doc.get("last_pong_age")
        # Both timestamps use the same monotonic clock. A pre-start or
        # unprovable pong is missing evidence, not a reconnect/lease signal.
        if (not number(pong_age) or pong_age < 0
                or source_mono - pong_age < unit.started):
            return unknown()
        # Skew tolerance admits consistent samples; it must not add green time.
        pong = pong_age + max(age, mono - source_mono)
    if age > CONNECTION_DOWN_AGE:
        return status("down", "heartbeat_stale")
    if name == "wecom":
        if pong > CONNECTION_DOWN_AGE:
            return status("down", "pong_stale")
        value = doc.get("state")
        reconnecting = type(value) is str and value in policy.reconnect_states
        ready = value == "subscribed"
    else:
        value = doc.get("connection_ready")
        reconnecting = value is False
        ready = value is True and policy.feishu_ack and doc.get("connection_event") == "heartbeat_ack"
    if age > heartbeat_ok:
        return status("degraded", "heartbeat_late")
    if reconnecting:
        return status("degraded", "reconnecting")
    if name == "wecom" and pong > WECOM_PONG_OK_AGE:
        return status("degraded", "pong_late")
    if lease == "stopped":
        return status("degraded", "lease_conflict")
    if not ready or lease == "unknown":
        return unknown()
    return status("ok", "ready")


def leaf_expiry():
    # This is inspection of the presented public leaf, not a trust check.
    # It also obtains notAfter for already expired certificates.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with socket.create_connection(("127.0.0.1", 443), timeout=0.75) as tcp:
        with context.wrap_socket(tcp, server_hostname=HOST) as tls:
            leaf = tls.getpeercert(binary_form=True)
    if not leaf or len(leaf) > SOURCE_LIMIT:
        raise ValueError("missing or oversized leaf")
    result = subprocess.run(
        ["/usr/bin/openssl", "x509", "-noout", "-enddate"],
        input=ssl.DER_cert_to_PEM_cert(leaf).encode("ascii"),
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True, timeout=0.75,
        env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
    )
    if not result.stdout.startswith(b"notAfter=") or len(result.stdout) > 128:
        raise ValueError("invalid certificate date")
    return ssl.cert_time_to_seconds(result.stdout[9:].decode("ascii").strip())


def certificate(expiry, now):
    when = rfc3339(expiry) if number(expiry) and expiry >= 0 else None
    if when is None:
        return {"state": "unknown", "expires_at": None, "days_remaining": None}
    remaining = expiry - now
    state = ("expired" if remaining <= 0 else
             "expiring" if remaining <= CERT_EXPIRING_DAYS * DAY else "ok")
    return {"state": state, "expires_at": when, "days_remaining": int(remaining // DAY)}


def collect():
    current_boot = boot_id()
    observed_boottime = boot_clock()
    policy = read_policy()
    try:
        uid = pwd.getpwnam("relay66").pw_uid
        if uid == 0:
            raise KeyError
    except KeyError:
        uid = None
    try:
        expiry = leaf_expiry()
    except UNAVAILABLE:
        expiry = None
    before = load_units()
    samples = [source(path, owners=(uid,), parent_owners=(0, uid), mode=0o600)
               for path in (FEISHU_FILE, WECOM_FILE)]
    lease_sample = source(LEASE_FILE, mode=0o644, missing_ok=True)
    after = load_units()
    now, mono = time.time(), time.monotonic()
    lease = lease_status(lease_sample, now, policy)
    doc = {"schema_version": 1, "boot_id": current_boot, "observed_boottime": observed_boottime,
           "observed_at": rfc3339(now), "certificate": certificate(expiry, now)}
    for name, service, sample in zip(("feishu", "wecom"), UNITS, samples):
        unit = after.get(service) if before.get(service) == after.get(service) else None
        doc[name] = connection(name, unit, sample, lease, now, mono, policy)
    project_snapshot(doc, current_boot, boot_clock())
    data = json.dumps(doc, allow_nan=False, separators=(",", ":")).encode("ascii") + b"\n"
    if len(data) > SNAPSHOT_LIMIT:
        raise ValueError("oversized snapshot")
    atomic_write(SNAPSHOT, data, 0o640, gid=grp.getgrnam("quotabar-status").gr_gid)


if __name__ == "__main__":
    try:
        collect()
    except WITH_KEY_ERROR:
        sys.exit("collector: snapshot unavailable")

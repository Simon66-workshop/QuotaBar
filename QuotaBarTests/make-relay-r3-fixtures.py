#!/usr/bin/env python3
"""Emit public-only regression fixtures from the pinned local server Git object."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SERVER = "0cdf242d42fdf92db5a40f6b3a0d3d71a574d7b4"
SOURCE = "server/relay-status/common.py"
source = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{SERVER}:{SOURCE}"])
common = {}
exec(compile(source, SOURCE, "exec"), common)

BOOT = "00000000-0000-0000-0000-000000000001"
WALL = common["parse_date"]("2026-11-22T17:15:00Z")
MONO = 1000


def link(age, state="ok", reason="ready"):
    return {"state": state, "reason": reason,
            "last_heartbeat_at": common["rfc3339"](WALL - age)}


def case(name, ages, feishu, wecom, pong, *, lease=None, local=None):
    private = {
        "schema_version": 1, "boot_id": BOOT, "observed_boottime": MONO,
        "observed_at": common["rfc3339"](WALL), "lease_clear_for_s": lease,
        "feishu": feishu, "wecom": {**wecom, "effective_pong_age_s": pong},
        "certificate": {"state": "unknown", "expires_at": None, "days_remaining": None},
    }
    points = []
    for age in ages:
        server = common["project_snapshot"](private, BOOT, MONO + age)
        point = {"elapsed": age - ages[0], "server": server}
        if local and age in local:
            # Private data can change the server color before v1 clients can
            # infer it. Explicitly record that limit, not a made-up deadline.
            point["localReasons"] = local[age]
        points.append(point)
    if ages[-1] < 75:
        try:
            common["project_snapshot"](private, BOOT, MONO + 75.25)
        except ValueError as error:
            assert str(error) == "stale snapshot"
        else:
            raise AssertionError("expected snapshot expiry")
        points.append({"elapsed": 75.25 - ages[0], "server": None})
    return {"name": name, "points": points}


cases = [
    case("APP-V2-R3-01", [0, 4.75, 5, 5.25, 20, 35, 35.25, 74.75],
         link(0), link(55), 55),
    case("APP-V2-R3-02", [0, 9.75, 10, 10.25, 20, 74.75],
         link(170, "degraded", "heartbeat_late"), link(0), 0),
    case("nonzero snapshot age; heartbeat red takes priority",
         [4, 5, 9, 9.25, 20], link(0),
         link(171, "degraded", "heartbeat_late"), 171),
    case("transitioning and unknown times are history", [0, 20, 74.75],
         link(170, "degraded", "transitioning"), link(170, "unknown", "source_unavailable"), None),
    case("lease pause stays red while the other heartbeat ages", [0, 30, 50.25],
         link(170, "down", "paused_by_lease"), link(130, "degraded", "heartbeat_late"), 130),
    case("periodic aging preserves existing yellow reasons", [0, 50, 74.75],
         link(80, "degraded", "lease_conflict"), link(85, "degraded", "reconnecting"), 85),
    case("private lease cutoff", [0, 9.75, 10, 20], link(0), link(0), 0, lease=10,
         local={10: ["ready", "ready"], 20: ["ready", "ready"]}),
    case("private lease cutoff; fresh yellow takes priority over expired lease",
         [0, 5, 5.25, 10, 15, 15.25, 20], link(75), link(55), 55, lease=10,
         local={10: ["ready", "pong_late"], 15: ["ready", "pong_late"]}),
    case("private pong offset can advance yellow", [0, 5.25, 15, 15.25, 20],
         link(0), link(45), 55, local={5.25: ["ready", "ready"], 15: ["ready", "ready"]}),
    case("private pong offset can advance red", [0, 5, 5.25, 20, 50.25],
         link(0), link(130, "degraded", "heartbeat_late"), 175,
         local={5.25: ["ready", "heartbeat_late"], 20: ["ready", "heartbeat_late"]}),
]
print("[\n" + ",\n".join(json.dumps(case, separators=(",", ":")) for case in cases) + "\n]")

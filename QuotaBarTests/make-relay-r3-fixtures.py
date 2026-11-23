#!/usr/bin/env python3
"""Emit public-only regression fixtures from the local server candidate."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--common", type=Path, default=ROOT.parent / "repo-server/server/relay-status/common.py")
source = parser.parse_args().common
common = {}
exec(compile(source.read_bytes(), str(source), "exec"), common)

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
        server, green = common["project_snapshot_response"](private, BOOT, MONO + age)
        point = {"elapsed": age - ages[0], "server": server, "greenForMs": green}
        if local and age in local:
            # The aggregate green window deliberately does not time yellow
            # to red transitions based solely on private evidence.
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
    case("private lease cutoff", [0, 9.75, 10, 20], link(0), link(0), 0, lease=10),
    case("private lease cutoff; fresh yellow takes priority over expired lease",
         [0, 5, 5.25, 10, 15, 15.25, 20], link(75), link(55), 55, lease=10),
    case("private pong offset can advance yellow", [0, 4.75, 5, 5.25, 15, 15.25, 20],
         link(0), link(45), 55),
    case("private pong offset can advance red", [0, 5, 5.25, 20, 50.25],
         link(0), link(130, "degraded", "heartbeat_late"), 175,
         local={5.25: ["ready", "heartbeat_late"], 20: ["ready", "heartbeat_late"]}),
]
print("[\n" + ",\n".join(json.dumps(case, separators=(",", ":")) for case in cases) + "\n]")

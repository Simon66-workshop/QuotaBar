"""Local rollback witness: reject cleanup while a pre-reload worker lives."""
import json
from pathlib import Path
import re
import secrets
import subprocess
import sys

if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import CONFIG

def generation(path):
    # PID plus kernel start ticks, not PID alone. comm in /proc stat may
    # contain spaces/parens, so split only after its final closing paren.
    return f"{path.name}:{(path / 'stat').read_text().rsplit(')', 1)[1].split()[19]}"


def workers():
    result = subprocess.run(
        ["/usr/bin/systemctl", "show", "--property=MainPID", "--value", "nginx.service"],
        capture_output=True, check=True, timeout=5,
    ).stdout.strip()
    if not re.fullmatch(rb"[1-9][0-9]*", result):
        raise ValueError
    master = Path("/proc") / result.decode()
    first = generation(master)
    title = (master / "cmdline").read_bytes()
    if not title.startswith(b"nginx: master process "):
        raise ValueError
    running = set()
    children = (master / "task" / master.name / "children").read_text().split()
    for child in children:
        path = Path("/proc") / child
        try:
            child_title = (path / "cmdline").read_bytes()
            if child_title.startswith(b"nginx: worker process"):
                running.add(generation(path))
        except FileNotFoundError:
            continue  # already drained
    if not running or first != generation(master):
        raise ValueError
    return first, running


def validate(previous, current):
    master, running = current
    if previous["master"] != master or not running or running.intersection(previous["workers"]):
        raise ValueError


def review_id():
    # An attestation cannot be reused under a new approved baseline/report.
    from hashlib import sha256
    return sha256((CONFIG / "nginx-review.json").read_bytes()).hexdigest()


def main(action, baseline_path, arg=None):
    path = Path(baseline_path)
    if action == "record" and arg is None:
        master, running = workers()
        with path.open("x") as f:
            json.dump({"master": master, "workers": sorted(running), "receipt": secrets.token_hex(16),
                       "review": review_id()}, f)
    elif action == "receipt" and arg is None:
        print(json.loads(path.read_text())["receipt"])
    elif action == "verify" and arg is not None:
        previous = json.loads(path.read_text())
        if (not re.fullmatch(r"[0-9a-f]{32}", arg) or previous["receipt"] != arg
                or previous["review"] != review_id()):
            raise ValueError
        validate(previous, workers())
    else:
        raise ValueError


if __name__ == "__main__":
    try:
        main(*sys.argv[1:])
    except (OSError, ValueError, KeyError, TypeError, IndexError, subprocess.SubprocessError):
        sys.exit("nginx workers: live verification unavailable or pre-reload workers have not drained")

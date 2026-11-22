#!/usr/bin/env python3
"""Generate an offline bundle; never print the raw token or digest."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import sys
import time

from api import Credentials
from common import DAY, checked_directory, decode_object, read_regular


def generate(directory, previous_path=None, overlap=0):
    owner = os.getuid()
    previous = None
    rotated = until = None
    if previous_path is not None:
        raw, _ = read_regular(previous_path, 1024, owners=(owner,), parent_owners=(0, owner), mode=0o600)
        previous = Credentials.from_document(decode_object(raw)).active.hex()
        rotated = int(time.time())
        until = rotated + overlap * 3600
    token = secrets.token_urlsafe(32).encode("ascii")
    doc = {
        "active_sha256": hashlib.sha256(token).hexdigest(),
        "previous_sha256": previous, "rotated_at": rotated, "previous_until": until,
    }
    Credentials.from_document(doc)
    fd = checked_directory(directory, (0, owner))
    created = []
    try:
        info = os.fstat(fd)
        if info.st_uid != owner or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError("output directory must be owned by caller and mode 0700")
        for name, contents in (("token", token + b"\n"),
                               ("verify.json", json.dumps(doc).encode("ascii") + b"\n")):
            handle = os.open(name, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW,
                             0o600, dir_fd=fd)
            created.append(name)
            with os.fdopen(handle, "wb") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(contents)
                stream.flush()
                os.fsync(stream.fileno())
    except BaseException:
        for name in created:
            os.unlink(name, dir_fd=fd)
        raise
    finally:
        os.close(fd)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True, help="existing private absolute directory")
    parser.add_argument("--previous-credential", type=Path, help="previous verify.json, not the raw token")
    parser.add_argument("--overlap-hours", type=int, choices=range(1, DAY // 3600 + 1))
    args = parser.parse_args()
    if bool(args.previous_credential) != bool(args.overlap_hours):
        parser.error("rotation requires both --previous-credential and --overlap-hours")
    try:
        generate(args.output_dir, args.previous_credential, args.overlap_hours or 0)
    except (OSError, ValueError, RecursionError):
        sys.exit("token bundle not generated; check directory, credential and existing files")

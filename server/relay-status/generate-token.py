#!/usr/bin/env python3
"""Provision the Mac login Keychain; write only the server's verification file."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import subprocess
import sys
import time

from api import Credentials
from common import DAY, checked_directory, decode_object, read_regular


def generate(directory, keychain_writer, previous_path=None, overlap=0):
    owner = os.getuid()
    previous = None
    rotated = until = None
    if previous_path is not None:
        raw, _ = read_regular(previous_path, 1024, owners=(owner,), parent_owners=(0, owner), mode=0o600)
        previous = Credentials.from_document(decode_object(raw)).active.hex()
        rotated = int(time.time())
        until = rotated + overlap * 3600
    fd = checked_directory(directory, (0, owner))
    name = "verify.json"
    created = False
    try:
        info = os.fstat(fd)
        if info.st_uid != owner or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError("output directory must be owned by caller and mode 0700")
        token = secrets.token_urlsafe(32).encode("ascii")
        doc = {
            "active_sha256": hashlib.sha256(token).hexdigest(),
            "previous_sha256": previous, "rotated_at": rotated, "previous_until": until,
        }
        Credentials.from_document(doc)
        # Reserve the digest path before changing the Keychain. An existing
        # verification file must not cause an accidental Keychain rotation.
        handle = os.open(name, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW,
                         0o600, dir_fd=fd)
        created = True
        with os.fdopen(handle, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(json.dumps(doc).encode("ascii") + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        # Do not pass the token via argv or environment. Neither output stream
        # is surfaced, and the child never needs to read the old password.
        subprocess.run([str(keychain_writer)], input=token, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except BaseException:
        if created:
            os.unlink(name, dir_fd=fd)
        raise
    finally:
        os.close(fd)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True, help="existing private absolute directory")
    parser.add_argument("--keychain-writer", type=Path, required=True,
                        help="absolute path to the locally built write-login-keychain helper")
    parser.add_argument("--previous-credential", type=Path, help="previous verify.json, not the raw token")
    parser.add_argument("--overlap-hours", type=int, choices=range(1, DAY // 3600 + 1))
    args = parser.parse_args()
    if bool(args.previous_credential) != bool(args.overlap_hours):
        parser.error("rotation requires both --previous-credential and --overlap-hours")
    if sys.platform != "darwin" or not args.keychain_writer.is_absolute():
        parser.error("run on the target Mac with an absolute path to the trusted Keychain writer")
    try:
        generate(args.output_dir, args.keychain_writer, args.previous_credential, args.overlap_hours or 0)
    except (OSError, ValueError, RecursionError, subprocess.CalledProcessError, KeyboardInterrupt):
        sys.exit("provisioning failed; verify the output directory and login Keychain before retrying")

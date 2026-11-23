"""Run the offline suite with a short, production-trusted temporary path."""
import os
from pathlib import Path
import sys
import tempfile
import unittest

TESTS = Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS.parent))

from common import checked_directory


def fixture_directory():
    # Linux /tmp (1777) cannot host positive reader fixtures. Prefer an
    # explicit trusted TMPDIR; otherwise use a short private test dir in HOME.
    for candidate in (os.environ.get("TMPDIR"), Path.home()):
        if not candidate:
            continue
        try:
            parent = Path(candidate).resolve(strict=True)
            # Account for this runner's and the socket fixture's mkdtemp
            # suffixes, and the Darwin sockaddr_un trailing NUL.
            if len(os.fsencode(parent / "qb-12345678/qb-12345678/s")) >= 104:
                continue
            if TESTS.parents[2] in (parent, *parent.parents):
                continue
            os.close(checked_directory(parent, (0, os.getuid())))
            return tempfile.TemporaryDirectory(prefix="qb-", dir=parent)
        except (OSError, ValueError, RuntimeError):
            continue
    raise SystemExit("set TMPDIR to a short, writable path outside the repo with trusted ancestors")


if __name__ == "__main__":
    with fixture_directory() as directory:
        os.environ["TMPDIR"] = directory
        tempfile.tempdir = None
        suite = unittest.defaultTestLoader.discover(str(TESTS))
        success = unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful()
    sys.exit(0 if success else 1)

"""Root-managed isolated entrypoint for the installed api."""
import runpy
import sys

sys.path.insert(0, "/opt/quotabar-relay-status")
runpy.run_module("api", run_name="__main__")

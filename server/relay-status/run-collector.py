"""Root-managed isolated entrypoint for the installed collector."""
import runpy
import sys

sys.path.insert(0, "/opt/quotabar-relay-status")
runpy.run_module("collector", run_name="__main__")

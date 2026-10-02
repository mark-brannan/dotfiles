"""Shared helpers for the Python hooks. Imported, never run directly.

The bash hooks' answer to "where does durable state live on this machine?"
is lib-state.sh's state_repo. This module asks that same function rather
than keeping a second copy of its search path: two lists would drift, and a
Python hook would then write state somewhere the bash hooks never read.
"""
import json
import os
import subprocess
import sys

HOOK_DIR = os.path.dirname(os.path.abspath(__file__))


def state_repo():
    """The private state repo's working tree, or None if it isn't here."""
    try:
        out = subprocess.run(
            ["bash", "-c", '. "$1" && state_repo', "_", os.path.join(HOOK_DIR, "lib-state.sh")],
            capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout if out.returncode == 0 and out.stdout else None


def state_dir():
    """Where state files go: the repo's state/global, else the local fallback."""
    repo = state_repo()
    if repo:
        return os.path.join(repo, "state", "global")
    return os.path.join(os.path.expanduser("~"), ".claude", "state", "global")


def event():
    """The hook's event JSON from stdin, or {} when it is absent or malformed."""
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        return {}
    return data if isinstance(data, dict) else {}

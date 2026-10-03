#!/usr/bin/env python3
"""Stop hook: run stop-continuity.sh, then metrics-live.sh's Stop readout.

Claude Code runs every matching hook in parallel. Run as two entries, the
📦 notice computed its own "archivable" while stop-continuity.sh was still
salvaging and committing, so the checkpoint and the notice could answer the
same question two ways in one Stop. In sequence there is one verdict:
stop-continuity.sh writes it to the metrics record, and metrics-live.sh reads
it back, refusing one older than STOP_VERDICT_SINCE, the moment this started.

Fails open, like both hooks it runs: a timeout or crash in the first still
lets the second speak, and the second then reports that no verdict came.
Only metrics-live.sh's stdout is passed through; it is the one that emits
the notice and the block.
"""
import os
import subprocess
import sys
import time

HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
# Inside settings.json's 330s for the entry, so the readout always gets its turn.
CONTINUITY_SECS = int(os.environ.get("STOP_CONTINUITY_SECS", "290"))
READOUT_SECS = 30


def run(argv, payload, timeout, env=None, keep_stdout=False):
    try:
        return subprocess.run(
            argv, input=payload, timeout=timeout, env=env,
            stdout=subprocess.PIPE if keep_stdout else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).stdout
    except (subprocess.TimeoutExpired, OSError):
        return b""


def main():
    payload = sys.stdin.buffer.read()
    since = str(int(time.time()))
    run(["bash", os.path.join(HOOK_DIR, "stop-continuity.sh")], payload, CONTINUITY_SECS)
    env = dict(os.environ, STOP_VERDICT_SINCE=since)
    out = run(["bash", os.path.join(HOOK_DIR, "metrics-live.sh"), "stop", "0", "show"],
              payload, READOUT_SECS, env=env, keep_stdout=True)
    sys.stdout.buffer.write(out or b"")
    return 0


if __name__ == "__main__":
    sys.exit(main())

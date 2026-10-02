#!/usr/bin/env python3
"""UserPromptSubmit: append the user's prompt, verbatim, to the roll of the
curia this session is sitting in.

The curia skill writes state/global/curia/<id>/LIVE at the start of a sitting,
holding the session id and a timestamp. A session named in some LIVE file is
sitting in that curia, and every prompt it receives is appended to that
folder's roll.md as one entry:

    ### 2026-10-02T05:41:07Z 3554281d
    ````
    <the prompt, byte for byte>
    ````

The fence is one backtick longer than the longest run of backticks in the
prompt (three at least), so a heading or a ``` inside the prompt stays inside
the entry. A newline is always added after the prompt before the closing
fence: strip exactly one to get the prompt back.

The roll is append-only (one-entry-point curia, 2026-10-02, the words log):
nothing here reads, edits or reorders what is already in it. Until a curia's
folder is moved to the roll/digest layout, roll.md is still the curated
document, so a folder without digest.md is skipped.

Always exits 0 and prints nothing: a roll failure must never block a prompt,
and UserPromptSubmit stdout would land in the model's context.
"""
import datetime
import fcntl
import glob
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib_state  # noqa: E402


def entry(prompt, session_id, now):
    longest = max((len(r) for r in re.findall(r"`+", prompt)), default=0)
    fence = "`" * max(3, longest + 1)
    stamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    return f"\n### {stamp} {session_id[:8]}\n{fence}\n{prompt}\n{fence}\n"


def sittings(state_dir, session_id):
    """Every curia folder whose LIVE file names this session."""
    for live in sorted(glob.glob(os.path.join(state_dir, "curia", "*", "LIVE"))):
        try:
            with open(live, encoding="utf-8", errors="replace") as f:
                tokens = f.read().split()
        except OSError:
            continue
        if session_id in tokens:
            yield os.path.dirname(live)


def append(roll, text):
    # One write under an exclusive lock: two sessions sitting in the same
    # curia on this machine interleave whole entries, never bytes.
    fd = os.open(roll, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, text.encode("utf-8", "surrogatepass"))
    finally:
        os.close(fd)


def main():
    ev = lib_state.event()
    session_id = ev.get("session_id")
    # The live 2.1.x payload names it `prompt`; the hooks reference page
    # names it `user_input`. Read both rather than bet on one.
    prompt = ev.get("prompt", ev.get("user_input"))
    if not isinstance(session_id, str) or not session_id or not isinstance(prompt, str):
        return
    now = datetime.datetime.now(datetime.timezone.utc)
    for folder in sittings(lib_state.state_dir(), session_id):
        if os.path.isfile(os.path.join(folder, "digest.md")):
            append(os.path.join(folder, "roll.md"), entry(prompt, session_id, now))


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 -- never block a prompt
        pass
    sys.exit(0)

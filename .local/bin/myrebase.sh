#!/usr/bin/env sh
# Kept for the habit: fetch every top-level clone now and fast-forward the ones
# that can move. No stash, rebase or checkout; anything else is reported.
# Not claude_prompts_scratch: its own hook syncs it. The rules are in clone-ff.
exec "$HOME/.local/bin/clone-ff" --now

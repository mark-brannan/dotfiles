#!/bin/sh
# Blocks `git reset --hard` outright. Mark ran one on a shared checkout to
# unwind his own bad commit and only found out afterwards; a hard reset
# discards uncommitted work in a worktree that other sessions and a running
# signalk-server may be sitting on, and nothing about it is recoverable
# through the harness. If it genuinely needs doing, Mark runs it himself.
#
# This is a GATE, so it fails closed: no stdin, no jq, unreadable payload ->
# block and say why. The permissions.deny rule in settings.json covers the
# plain `git reset --hard ...` prefix; this exists for the forms a prefix
# rule cannot see -- compound commands (`foo && git reset --hard`), `git -C
# <dir> reset --hard`, and the flag trailing the ref (`git reset HEAD~1
# --hard`).
set -u

REASON='`git reset --hard` is blocked at user scope. It discards uncommitted work, and on a shared checkout that work may not be yours. Ask Mark to run it himself, or reach for a reversible move instead: `git revert`, a new branch off the good commit, `git stash`, or `git reset --soft`/`--mixed` if the working tree should survive.'

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$REASON" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
  exit 0
}

command -v jq >/dev/null 2>&1 || deny
cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null) || deny

# Nothing to inspect is not the same as nothing to block, but an empty
# command cannot be a reset either -- let it through rather than jamming
# every Bash call if the payload shape ever changes.
[ -n "$cmd" ] || exit 0

# Both halves must match: a `git ... reset` invocation anywhere in the
# command, and a `--hard` flag anywhere in it. Requiring both keeps
# `git reset --soft` and a bare `--hard` in unrelated prose out of it.
printf '%s' "$cmd" | grep -Eq \
  '(^|[^A-Za-z0-9_./-])git([[:space:]]+(-[cC][[:space:]]+[^[:space:]]+|--[^[:space:]]+))*[[:space:]]+reset([[:space:]]|$)' \
  || exit 0
printf '%s' "$cmd" | grep -Eq -- '(^|[[:space:]])--hard([[:space:]=]|$)' || exit 0

deny

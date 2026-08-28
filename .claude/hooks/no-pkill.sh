#!/bin/sh
# Blocks `pkill` outright. In this sandbox, invoking `pkill` gets the
# process itself killed by signal 16 within the same call -- confirmed even
# for a pattern that matches nothing (`pkill -f nonexistent-xyz` still dies
# exit 144). It isn't a risky command here, it's a broken one: any command
# chain that runs it (including one meant to clear a stale process before
# backgrounding a new one) can take the whole chain down with it. `pgrep`
# and plain `kill` are unaffected.
#
# This is a GATE, so it fails closed: no stdin, no jq, unreadable payload ->
# block and say why.
set -u

REASON='`pkill` is blocked at user scope: in this sandbox it kills itself with signal 16 the instant it runs, even matching nothing -- it is not usable here, not just risky. Use `pgrep -f '"'"'<strong regex>'"'"'` to list matching pids, then `kill` those pids directly.'

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$REASON" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
  exit 0
}

command -v jq >/dev/null 2>&1 || deny
cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null) || deny

# Nothing to inspect is not the same as nothing to block, but an empty
# command cannot invoke pkill either -- let it through rather than jamming
# every Bash call if the payload shape ever changes.
[ -n "$cmd" ] || exit 0

# Word-boundary match: `pkill` as its own token anywhere in the command
# (start of string or after a non-identifier char, e.g. `;`, `&&`, `|`,
# whitespace), not part of a longer name.
printf '%s' "$cmd" | grep -Eq '(^|[^A-Za-z0-9_./-])pkill([[:space:]]|$)' || exit 0

deny

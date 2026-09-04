#!/bin/sh
# Refuses `yadm checkout <branch>` (or `git checkout <branch>` run against
# the yadm repo) whenever the command's cwd is $HOME.
#
# $HOME is the yadm worktree every shell on this machine sits in. A session
# that checks its branch out directly there, instead of in a worktree,
# leaves it checked out for every other session on the machine to see until
# someone checks main back out. A session's branch work belongs in a
# worktree instead —
#
#   yadm worktree add -b <branch> ~/.claude/worktrees/<name> main
#
# then cd into it and work there. `yadm worktree remove
# ~/.claude/worktrees/<name>` cleans up when done. This has no bearing on
# editing dotfiles directly in $HOME on main -- the hook only ever fires on
# a `checkout` invocation, never on an edit.
#
# File-restore forms are not a branch switch and stay allowed: anything with
# a `--` pathspec separator (`checkout -- <file>`, `checkout <ref> -- <file>`).
# `-b`/`-B` (create-and-switch) count as a branch switch same as a
# plain `checkout <branch>`, since the effect on $HOME is identical — a new
# branch left checked out there is exactly the failure mode this blocks.
# `checkout .` (discarding edits) is also caught by no-git-footguns.sh; this
# hook denies it too since it isn't a pathspec-restore it can single out —
# redundant, not wrong. `checkout HEAD --` with no pathspec after `--` is a
# whole-tree discard neither hook catches — a pre-existing gap in
# no-git-footguns.sh, out of scope here.
#
# `yadm` is treated as `git`, since on dotfiles that is what it is. Matching
# is a command-word regex, not a full parser (no-git-footguns.sh strips
# quotes and heredocs first; this doesn't): a command that merely mentions
# "yadm checkout" in a quoted string, or buries the real call behind unusual
# quoting, isn't handled. Accepted imprecision, not a bypass anyone would
# reach for.
#
# This is a GATE, so it fails closed: no jq, unreadable payload -> block.
set -u

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"} {print}' | sed 's/\\n$//; s/^/"/; s/$/"/'; }
deny() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(json_str "$1")"; exit 0; }

command -v jq >/dev/null 2>&1 || deny "no-checkout-home: jq is missing, so the command can't be inspected."
payload=$(cat) || deny "no-checkout-home: could not read the hook payload."
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || deny "no-checkout-home: unreadable hook payload."
[ -n "$cmd" ] || exit 0

# Must be a yadm/git checkout invocation.
printf '%s' "$cmd" | grep -Eq \
  '(^|[^A-Za-z0-9_./-])(yadm|git)([[:space:]]+(-[cC][[:space:]]+[^[:space:]]+|--[^[:space:]]+))*[[:space:]]+checkout([[:space:]]|$)' \
  || exit 0

# Only cwd == $HOME matters. Resolve both sides so a trailing slash or a
# symlinked $HOME doesn't false-negative.
payload_cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$payload_cwd" ] || exit 0
home=$(cd "$HOME" 2>/dev/null && pwd -P) || exit 0
cwd=$(cd "$payload_cwd" 2>/dev/null && pwd -P) || exit 0
[ "$cwd" = "$home" ] || exit 0

# A `--` pathspec separator anywhere means this restores files, not a branch.
printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])--([[:space:]]|$)' && exit 0

deny "no-checkout-home: \`checkout\` in \$HOME switches the branch every shell and session on this machine sees until someone checks main back out. Use a worktree instead:
  yadm worktree add -b <branch> ~/.claude/worktrees/<name> main
then cd into it and work there."

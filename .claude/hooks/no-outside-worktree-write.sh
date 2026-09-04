#!/bin/sh
# When a session is running in an isolated git worktree (a path under
# ~/.claude/worktrees/<name>), Edit/Write/NotebookEdit must stay inside it.
# Without this, a tool call that names an absolute path outside the
# worktree -- e.g. the real $HOME/dotfiles instead of this copy of it --
# writes straight into Mark's live checkout, invisible to the diff this
# session thinks it's producing. Reproduced 2026-09-04: an Edit call in a
# dotfiles worktree session landed in ~/dotfiles/RUNBOOK.md instead.
#
# Only fires when the payload's own cwd is under .claude/worktrees/ -- a
# normal session (no worktree) is untouched. Fails open on a missing
# dependency or unreadable payload: this is a footgun guard, not a security
# boundary, and false-blocking every edit in every session is worse than
# missing the rare case where jq or awk isn't installed.
set -u

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
  exit 0
}

command -v jq >/dev/null 2>&1 || exit 0
payload=$(cat) || exit 0

cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
case $cwd in
  */.claude/worktrees/*) ;;
  *) exit 0 ;;
esac

# The worktree root is cwd up to and including its trailing worktrees/<name>
# path segment -- a session may cd deeper inside it, so match on prefix.
worktree_root=$(printf '%s\n' "$cwd" | awk -F'/.claude/worktrees/' '{
  split($2, parts, "/")
  print $1 "/.claude/worktrees/" parts[1]
}')
[ -n "$worktree_root" ] || exit 0

file_path=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$file_path" ] || exit 0

case $file_path in
  /*) ;;
  *) file_path="$cwd/$file_path" ;;
esac

case $file_path in
  "$worktree_root"/*|"$worktree_root") exit 0 ;;
esac

deny "no-outside-worktree-write: $file_path is outside this session's worktree ($worktree_root). Edit the copy inside the worktree, not the real checkout."

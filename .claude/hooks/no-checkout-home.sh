#!/bin/sh
# Refuses `yadm checkout <branch>` (or `git checkout <branch>` run against
# the yadm repo) whenever it would switch the branch checked out in $HOME —
# either because the command's cwd is $HOME, or because it points there
# itself with `-C`.
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
# The command is split into segments on shell separators (&&, ||, ;, |) and
# each segment is truncated at its first `#`, then every check below runs
# per segment. Two things this closes:
#   - a `--` in one clause could otherwise exempt a checkout in another,
#     e.g. `yadm checkout some-branch && ls --` or the sneakier
#     `yadm checkout some-branch # --`, where the `#` is a real shell
#     comment: the command Bash actually runs is just the checkout, but a
#     whole-string `--` search would still see the trailing `--` and wave
#     it through as a file restore.
#   - a `-C <path>` naming $HOME (literally `$HOME`/`${HOME}`/`~`, or a
#     path that resolves to it) is treated the same as cwd being $HOME,
#     so `git -C "$HOME" checkout <branch>` run from inside a worktree is
#     still caught. Quoting inside the `-C` value (`-C '$HOME'`, where the
#     shell would NOT expand it) isn't distinguished from the unquoted form
#     that would — a known imprecision, not a silent hole: it only makes
#     the hook deny a couple of cases that were actually safe, never the
#     reverse. `--git-dir`/`--work-tree` are not checked; on a repo whose
#     `-C` target isn't recognized this hook still fails safe as long as
#     cwd is what's read, since only $HOME's cwd matters here, not $HOME's
#     git-dir.
#
# `yadm` is treated as `git`, since on dotfiles that is what it is. This is
# still a command-word regex, not a full parser (no-git-footguns.sh strips
# quotes and heredocs first; this doesn't): a command that merely mentions
# "yadm checkout" in a quoted string, or buries the real call behind
# unusual quoting, isn't handled. Accepted imprecision, not a bypass anyone
# would reach for.
#
# This is a GATE, so it fails closed: no jq/awk, unreadable payload -> block.
set -u

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"} {print}' | sed 's/\\n$//; s/^/"/; s/$/"/'; }
deny() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(json_str "$1")"; exit 0; }

command -v jq >/dev/null 2>&1 || deny "no-checkout-home: jq is missing, so the command can't be inspected."
command -v awk >/dev/null 2>&1 || deny "no-checkout-home: awk is missing, so the command can't be inspected."
payload=$(cat) || deny "no-checkout-home: could not read the hook payload."
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || deny "no-checkout-home: unreadable hook payload."
[ -n "$cmd" ] || exit 0

payload_cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$payload_cwd" ] || exit 0
home=$(cd "$HOME" 2>/dev/null && pwd -P) || exit 0
cwd=$(cd "$payload_cwd" 2>/dev/null && pwd -P) || exit 0

checkout_re='(^|[^A-Za-z0-9_./-])(yadm|git)([[:space:]]+(-[cC][[:space:]]+[^[:space:]]+|--[^[:space:]]+))*[[:space:]]+checkout([[:space:]]|$)'

segments=$(printf '%s\n' "$cmd" | awk '
{ buf = buf $0 "\n" }
END {
  n = split(buf, raw, /(&&|\|\||;|\|)/)
  for (i = 1; i <= n; i++) {
    seg = raw[i]
    h = index(seg, "#")
    if (h > 0) seg = substr(seg, 1, h - 1)
    print seg
  }
}')

# A heredoc, not a pipe: a pipeline forks the loop into a subshell, and
# deny()'s `exit` would then only end that subshell, not the hook.
while IFS= read -r seg; do
  printf '%s' "$seg" | grep -Eq "$checkout_re" || continue

  hit=0
  [ "$cwd" = "$home" ] && hit=1
  if [ "$hit" = 0 ]; then
    for cpath in $(printf '%s' "$seg" | grep -oE '(^|[[:space:]])-C[[:space:]]+[^[:space:]]+' | sed -E 's/^[[:space:]]*-C[[:space:]]+//; s/^["'\'']//; s/["'\'']$//'); do
      case "$cpath" in
        '$HOME'|'${HOME}'|'~') hit=1 ;;
        /*) r=$(cd "$cpath" 2>/dev/null && pwd -P); [ "$r" = "$home" ] && hit=1 ;;
        *) r=$(cd "$payload_cwd/$cpath" 2>/dev/null && pwd -P); [ "$r" = "$home" ] && hit=1 ;;
      esac
      [ "$hit" = 1 ] && break
    done
  fi
  [ "$hit" = 1 ] || continue

  # A `--` pathspec separator within this segment means a file restore.
  printf '%s' "$seg" | grep -Eq '(^|[[:space:]])--([[:space:]]|$)' && continue

  deny "no-checkout-home: \`checkout\` in \$HOME switches the branch every shell and session on this machine sees until someone checks main back out. Use a worktree instead:
  yadm worktree add -b <branch> ~/.claude/worktrees/<name> main
then cd into it and work there."
done <<EOF
$segments
EOF

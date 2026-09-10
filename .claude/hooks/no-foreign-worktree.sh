#!/bin/sh
# Refuses to let a session reach into a git worktree that is not its own.
#
# The scar (2026-09, PR #162): a session was handed nothing but "continue
# <issue> see <PR>". It found the branch already checked out in a sibling
# worktree, decided that working there with `git -C <that path>` was the
# clean move, and did. When the session that actually owned that worktree
# was archived -- correctly, by its own git state -- the directory went
# away underneath the second session mid-turn. It survived only because its
# commit happened to already be pushed.
#
# The mistake was not the pickup skill and not the archival check. It was
# treating another session's working directory as a place to work. A
# hand-off carries a branch, an issue and a PR; it does not carry a
# directory. Everything a leaving session wants handed over is on the
# remote -- if it isn't pushed, it isn't handed over, and reaching into
# their worktree to get it is racing a process that is still running.
#
# So: any path inside a linked worktree other than this session's own is
# refused, in any command, read or write. The alternatives are all local:
#
#   inspect a branch      git log/diff/show <branch>, git show <branch>:<path>
#                         -- every worktree of a repo shares its objects and
#                         refs, so nothing about another branch requires
#                         standing in another directory.
#   work on a branch      EnterWorktree(name=...) for your own worktree, then
#                         `git checkout <branch>` inside it. If git refuses
#                         because the branch is checked out elsewhere, that
#                         is a live claim by another session: report it and
#                         stop. Do not take it away from them.
#   worktree hygiene      the user's, not a session's.
#
# `EnterWorktree(path=...)` is refused outright: the tool enters an existing
# worktree with no ownership check of any kind (verified in its own
# documentation -- the only requirement is that the path appear in `git
# worktree list`), and every legitimate use of it is reachable via
# `EnterWorktree(name=...)` plus a checkout.
#
# What counts as foreign: git is asked, nothing is assumed from the path.
# A candidate resolves to a toplevel (`rev-parse --show-toplevel`) that
#   - differs from this session's own toplevel, and
#   - is a LINKED worktree -- its `.git` is a file, not a directory.
# The second test is what keeps `~/dotfiles`, `$HOME` (yadm's own worktree)
# and every other clone allowed: those are main worktrees, shared by every
# session on the machine and no session's private space. Sibling worktrees
# of the current repo sit *inside* the repo root by path
# (`<repo>/.claude/worktrees/<name>`), so a textual "is it under my
# toplevel" shortcut would wrongly allow exactly the case this exists for.
# There is no shortcut here for that reason: every candidate path gets asked.
#
# Known gap, deliberate: the shared scanner drops redirections, so
# `cmd > /other/worktree/file` is not seen. Words are seen, redirection
# targets are not. Closing it means reimplementing redirection tracking for
# one exotic spelling; the ordinary routes (a cd, a `-C`, an Edit, a
# `sed -i`, a `cp`) are all words.
#
# Prose is not a command: a path mentioned inside a quoted string that holds
# whitespace stays one unresolvable word, and the scanner only queues such a
# string for a nested scan when its segment could execute it -- so a commit
# message, an issue body or a card that names a worktree path passes.
#
# Scanning is shared with no-git-footguns.sh/no-checkout-home.sh/
# no-rm-tree.sh: lib-shell-words.awk (read its header).
#
# This is a GATE, so it fails closed: no jq, no awk, no library, unreadable
# payload -> deny.
set -u

# Parameter expansion, not `dirname`: this hook must still emit valid JSON
# when PATH is broken, and that is when an external tool is least available.
HERE=${0%/*}
[ "$HERE" = "$0" ] && HERE=.
LIB="$HERE/lib-shell-words.awk"
# Asking git costs two processes per candidate path; a command with hundreds
# of path-shaped words is pathological, not a use case. Cap and move on.
MAX_CANDIDATES=48

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"} {print}' | sed 's/\\n$//; s/^/"/; s/$/"/'; }
deny() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(json_str "$1")"; exit 0; }
# The reasons that fire when a tool this hook needs is missing cannot go
# through json_str -- it needs sed and awk, which is what may be missing.
# printf is a shell builtin, so this one always emits valid JSON. Keep the
# message free of double quotes, backslashes and newlines.
deny_literal() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no-foreign-worktree: %s This is a gate and fails closed."}}\n' "$1"; exit 0; }

deny_path() {
  deny "no-foreign-worktree: \`$1\` is inside $2, a git worktree this session does not own. A hand-off carries a branch, an issue and a PR -- never a directory; another session may still be running in there, and it may be archived out from under you mid-turn (that is how PR #162 lost its worktree).
To read that branch, stay here: \`git log/diff/show <branch>\`, \`git show <branch>:<path>\` -- worktrees of a repo share objects and refs.
To work on it, take your own worktree: EnterWorktree(name=<name>), then \`git checkout <branch>\` inside it. If git refuses because the branch is checked out elsewhere, another session holds it: report that and stop.
Worktree hygiene is the user's call, not a session's."
}

command -v jq  >/dev/null 2>&1 || deny_literal 'jq is missing, so the command cannot be inspected.'
command -v awk >/dev/null 2>&1 || deny_literal 'awk is missing, so the command cannot be inspected.'
command -v sed >/dev/null 2>&1 || deny_literal 'sed is missing, so the command cannot be inspected.'
[ -r "$LIB" ] || deny_literal 'lib-shell-words.awk is missing from the hooks directory, so the command cannot be inspected. Run dotsync (or cloud-session-setup.sh) and retry.'
payload=$(cat) || deny_literal 'the hook payload could not be read.'
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || deny_literal 'the hook payload is unreadable.'

payload_cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$payload_cwd" ] || exit 0
home=$(cd "$HOME" 2>/dev/null && pwd -P) || exit 0

# This session's own worktree root. Empty when the cwd is not in a repo at
# all -- then every linked worktree is someone else's, which is the answer
# this hook would give anyway.
own_top=$(git -C "$payload_cwd" rev-parse --show-toplevel 2>/dev/null)

# EnterWorktree with a `path` is refused whatever the path: the tool does no
# ownership check, and `name` plus a checkout covers every honest use.
case "$tool" in
  EnterWorktree)
    p=$(printf '%s' "$payload" | jq -r '.tool_input.path // empty' 2>/dev/null)
    [ -n "$p" ] || exit 0
    deny "no-foreign-worktree: EnterWorktree(path=...) enters a worktree that already exists, with no check on whose it is -- the tool only requires that the path appear in \`git worktree list\`. That is how PR #162 lost its worktree mid-turn: the session that owned it was archived and the directory went away underneath the session that had attached to it.
Take your own instead: EnterWorktree(name=<name>), then \`git checkout <branch>\` inside it to put the branch you are resuming in your own directory. If git refuses because the branch is checked out in another worktree, another session holds it: report that and stop.
Nothing needs the other directory -- worktrees of a repo share objects and refs, so \`git log/diff/show <branch>\` and \`git show <branch>:<path>\` read it from here."
    ;;
esac

# Resolves one raw word against $home/$payload_cwd the way the shell would
# if the literal text were left unquoted, then walks up to its nearest
# existing directory (a write to a file that does not exist yet still names
# the worktree it would land in). Echoes that directory, or nothing.
resolve_dir() {
  raw=$1
  # These case patterns match a literal leading "~"/"$HOME" -- nothing here
  # expands one.
  # shellcheck disable=SC2088
  case "$raw" in
    '$HOME'|'${HOME}'|'~') r="$home" ;;
    '$HOME'/*) r="$home/${raw#\$HOME/}" ;;
    '${HOME}'/*) r="$home/${raw#\$\{HOME\}/}" ;;
    '~/'*) r="$home/${raw#\~/}" ;;
    /*) r="$raw" ;;
    *) r="$payload_cwd/$raw" ;;
  esac
  # An unexpandable word ($VAR, a brace expansion, a glob) can't be judged;
  # the walk up would land on a real ancestor and answer about the wrong
  # path, so refuse to resolve it at all.
  case "$r" in *'$'*|*'*'*|*'?'*|*'{'*) return 0 ;; esac
  while [ -n "$r" ] && [ "$r" != "/" ] && [ ! -d "$r" ]; do
    case "$r" in */*) r=${r%/*}; [ -n "$r" ] || r=/ ;; *) return 0 ;; esac
  done
  [ -d "$r" ] || return 0
  (cd "$r" 2>/dev/null && pwd -P)
}

# Prints the foreign worktree root a directory belongs to, or nothing.
foreign_top() {
  t=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$t" ] || return 0
  [ "$t" = "$own_top" ] && return 0
  # A linked worktree keeps a `.git` FILE pointing at its admin dir; a main
  # worktree (a clone, $HOME under yadm) keeps a directory. Only the former
  # is a session's private space.
  [ -f "$t/.git" ] || return 0
  printf '%s' "$t"
}

check_word() {
  d=$(resolve_dir "$1")
  [ -n "$d" ] || return 0
  ft=$(foreign_top "$d")
  [ -n "$ft" ] && deny_path "$1" "$ft"
}

case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    fp=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
    [ -n "$fp" ] || exit 0
    check_word "$fp"
    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# awk prints every path-shaped word of the command, deduplicated: any word
# holding a "/", plus `~`/`$HOME` on its own, with a leading `--flag=` or
# `VAR=` stripped so `--work-tree=<path>` and `GIT_WORK_TREE=<path>` are
# seen. Words are taken from the top-level text and from every quoted string
# the scanner judges executable, in every position -- not just command
# position: the target of the move this hook exists to stop is always an
# argument (`cd <path>`, `git -C <path>`, `sed -i <path>`).
words=$(printf '%s\n' "$cmd" | awk "$(cat "$LIB")"'
function pathish(t) {
  sub(/^--?[A-Za-z0-9][A-Za-z0-9-]*=/, "", t)
  sub(/^[A-Za-z_][A-Za-z0-9_]*=/, "", t)
  if (t == "~" || t == "$HOME" || t == "${HOME}") return t
  return (index(t, "/") ? t : "")
}
{ buf = buf $0 "\n" }
END {
  buf = strip_heredocs(buf)
  nt = texts_of(buf, texts, nested)
  for (x = 1; x <= nt; x++) {
    n = scan(texts[x], w, k, q)
    for (i = 1; i <= n; i++) {
      if (k[i] != "w") continue
      t = pathish(w[i])
      if (t == "" || t in seen) continue
      seen[t] = 1
      print t
    }
  }
}') || deny "no-foreign-worktree: awk failed, cannot inspect the command"

[ -n "$words" ] || exit 0

seen_count=0
while IFS= read -r word; do
  [ -n "$word" ] || continue
  seen_count=$((seen_count + 1))
  [ "$seen_count" -gt "$MAX_CANDIDATES" ] && break
  check_word "$word"
done <<EOF
$words
EOF
exit 0

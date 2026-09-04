#!/bin/sh
# Refuses a `yadm`/`git` `checkout`/`switch` that would switch the branch
# checked out in $HOME.
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
# a `checkout`/`switch` invocation, never on an edit.
#
# `yadm` and `git` are NOT symmetric here, unlike the rest of this repo's
# "yadm is git" shorthand: yadm hardcodes `--work-tree=$HOME` into every
# invocation regardless of cwd (verified: `cd /tmp && yadm rev-parse
# --show-toplevel` prints $HOME) -- it is yadm's whole reason to exist, and
# it means `yadm checkout <branch>` is dangerous from ANY directory,
# including a `~/.claude/worktrees/<name>` worktree, which is exactly the
# place a session runs it from most often. So any `yadm checkout`/`yadm
# switch` that isn't a file-restore is an automatic hit, cwd ignored
# entirely. Plain `git`, in contrast, only ever touches $HOME's worktree if
# the repo it discovers from cwd (or a `-C`/`--git-dir`/`--work-tree` target,
# flag or `GIT_DIR=`/`GIT_WORK_TREE=` inline env assignment) actually
# resolves to $HOME -- checked by asking git directly (`rev-parse
# --show-toplevel`), not by testing whether the path is textually under
# $HOME: a nested repo (a `~/.claude/worktrees/<name>` worktree,
# `~/dotfiles`, any other clone under $HOME) sits under $HOME by path but
# git's own upward search stops at its own `.git` long before reaching
# $HOME's, so it never resolves there. A textual prefix check would wrongly
# deny every one of those.
#
# `switch` is covered alongside `checkout`: `git switch <branch>` is the
# same branch-switch-in-$HOME footgun and has no file-restore form to
# exempt, so a `switch` hit denies unconditionally -- no `--` check.
# `checkout`'s file-restore forms (`checkout -- <file>`, `checkout <ref> --
# <file>`) stay allowed, and `-b`/`-B` (create-and-switch) counts as a
# branch switch same as plain `checkout <branch>`. `checkout .` (discarding
# edits) is also caught by no-git-footguns.sh; this hook denies it too
# since it isn't a pathspec-restore it can single out -- redundant, not
# wrong. `checkout HEAD --` with no pathspec after `--` is a whole-tree
# discard neither hook catches -- a pre-existing gap in no-git-footguns.sh,
# out of scope here.
#
# Scanning is shared with no-git-footguns.sh/no-rm-tree.sh:
# lib-shell-words.awk (read its header). Heredoc bodies are dropped; quotes
# are removed and escapes applied; redirections vanish; comments are
# stripped to end of line; the text is split into segments on shell
# separators, and the body of a quoted string with whitespace (`sh -c
# '...'`, `eval "..."`) is scanned too, there by command position only. This
# closes the bypass classes a plain command-word regex kept missing across
# three review rounds on this file: a real shell comment hiding a `--`
# (`yadm checkout foo # --`), a `-C`/`--work-tree` value with an unexpected
# amount of whitespace, an absolute-path invocation (`/usr/bin/git
# checkout`), and a checkout mentioned only inside a quoted string handed to
# `echo` (the library's prose-consumer list already knows `git`/`yadm`
# themselves count as one, so a segment like `echo git checkout x` is never
# mistaken for a real invocation).
#
# `checkout`/`switch` is looked for ANYWHERE after the git/yadm command
# word in a segment, not only in the immediate next position -- so a
# leading global option this hook doesn't specifically parse (an unknown
# `--flag`, `-c key=val`, a wrapper) can never push the subcommand out of
# reach the way a fixed-width flag-skipping regex could. The cost is a
# false deny on the rare command whose git/yadm invocation happens to pass
# a bare word "checkout"/"switch" as a value to some other flag (not a
# branch or file), never a false allow -- the tradeoff this hook has always
# taken (see the whole-tree-discard/`checkout .` note above).
#
# `-C`/`--git-dir`/`--work-tree` (flag or `GIT_DIR=`/`GIT_WORK_TREE=` env
# form) are collected from anywhere in the segment, same reasoning: a
# missed one is a bypass, a spurious one just adds a resolution check that
# comes back empty. Quoting inside any of these values (`-C '$HOME'`, which
# the shell would NOT expand) isn't distinguished from the unquoted form
# that would -- a known imprecision that only makes the hook deny a couple
# of cases that were actually safe, never the reverse.
#
# This is a GATE, so it fails closed: no jq/awk, no library, unreadable
# payload -> deny. settings.json adds one more layer: if this file is
# missing or crashes, the wrapper there denies.
set -u

HERE=$(dirname "$0")
LIB="$HERE/lib-shell-words.awk"

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"} {print}' | sed 's/\\n$//; s/^/"/; s/$/"/'; }
deny() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(json_str "$1")"; exit 0; }
deny_generic() {
  deny "no-checkout-home: \`checkout\`/\`switch\` in \$HOME switches the branch every shell and session on this machine sees until someone checks main back out. Use a worktree instead:
  yadm worktree add -b <branch> ~/.claude/worktrees/<name> main
then cd into it and work there."
}

command -v jq  >/dev/null 2>&1 || deny "no-checkout-home: jq is missing, so the command can't be inspected."
command -v awk >/dev/null 2>&1 || deny "no-checkout-home: awk is missing, so the command can't be inspected."
[ -r "$LIB" ] || deny "no-checkout-home: $LIB missing, so the command can't be inspected."
payload=$(cat) || deny "no-checkout-home: could not read the hook payload."
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || deny "no-checkout-home: unreadable hook payload."
[ -n "$cmd" ] || exit 0

payload_cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$payload_cwd" ] || exit 0
home=$(cd "$HOME" 2>/dev/null && pwd -P) || exit 0
cwd=$(cd "$payload_cwd" 2>/dev/null && pwd -P) || exit 0

# True if plain `git` run from directory $1 would actually operate on
# $HOME's worktree -- not "is $1 textually under $HOME", which a nested
# repo (a `~/.claude/worktrees/<name>` worktree, `~/dotfiles`, any other
# clone under $HOME) would wrongly trip: git stops walking up at the
# nearest .git, so it never reaches $HOME's from inside one of those. Ask
# git directly what it would resolve to.
git_targets_home() {
  [ "$1" = "$home" ] && return 0
  t=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$t" ] && [ "$t" = "$home" ]
}

# Resolves a raw -C/--git-dir/--work-tree/GIT_DIR/GIT_WORK_TREE value (as it
# appeared, unquoted by the scanner) against $home/$payload_cwd, the same
# way the shell would if the literal text were left unquoted. Echoes the
# resolved absolute path, or nothing if it doesn't exist.
resolve_path_arg() {
  cpath=$1
  # These are case patterns matching a literal leading "~"/"$HOME", not
  # quoted strings -- nothing here expands it.
  # shellcheck disable=SC2088
  case "$cpath" in
    '$HOME'|'${HOME}'|'~') resolved="$home" ;;
    '$HOME'/*) resolved="$home/${cpath#\$HOME/}" ;;
    '${HOME}'/*) resolved="$home/${cpath#\$\{HOME\}/}" ;;
    '~/'*) resolved="$home/${cpath#\~/}" ;;
    /*) resolved="$cpath" ;;
    *) resolved="$payload_cwd/$cpath" ;;
  esac
  (cd "$resolved" 2>/dev/null && pwd -P)
}

# awk tokenises with the shared scanner and prints one line per segment that
# is a real git/yadm checkout/switch and isn't exempted by a `--` pathspec
# separator:
#   "DENY"                    -- a yadm invocation: always a hit, decided
#                                 here since it needs no path resolution.
#   "G\t<KIND>\t<value>"      -- a git invocation: sh resolves KIND (CWD,
#                                 the payload cwd with no value; C, a `-C`
#                                 target; WORKTREE/GITDIR, a
#                                 --work-tree/--git-dir or
#                                 GIT_WORK_TREE=/GIT_DIR= value) and denies
#                                 if any of them targets $HOME.
out=$(printf '%s\n' "$cmd" | awk "$(cat "$LIB")"'
function segment(a, b, nested,   g, i, sidx, kind, is_yadm, dashdash) {
  g = cmd_index(w, k, a, b, "(^|/)(git|yadm)$", nested, "")
  if (!g) return
  is_yadm = (w[g] ~ /(^|\/)yadm$/)

  kind = ""
  for (i = g + 1; i <= b; i++) {
    if (k[i] != "w") continue
    if (w[i] == "checkout") { kind = "CO"; sidx = i; break }
    if (w[i] == "switch")   { kind = "SW"; sidx = i; break }
  }
  if (kind == "") return

  # A bare `--` pathspec separator after the subcommand means a file
  # restore (checkout only -- switch has no such form).
  if (kind == "CO") {
    dashdash = 0
    for (i = sidx + 1; i <= b; i++) if (k[i] == "w" && w[i] == "--") { dashdash = 1; break }
    if (dashdash) return
  }

  if (is_yadm) { print "DENY"; return }

  for (i = a; i <= b; i++) {
    if (k[i] != "w") continue
    if (w[i] == "-C") { if (i + 1 <= b && k[i + 1] == "w") print "G\tC\t" w[i + 1]; continue }
    if (w[i] == "--git-dir")        { if (i + 1 <= b && k[i + 1] == "w") print "G\tGITDIR\t" w[i + 1]; continue }
    if (w[i] ~ /^--git-dir=/)       { print "G\tGITDIR\t" substr(w[i], index(w[i], "=") + 1); continue }
    if (w[i] == "--work-tree")      { if (i + 1 <= b && k[i + 1] == "w") print "G\tWORKTREE\t" w[i + 1]; continue }
    if (w[i] ~ /^--work-tree=/)     { print "G\tWORKTREE\t" substr(w[i], index(w[i], "=") + 1); continue }
    if (w[i] ~ /^GIT_DIR=/)         { print "G\tGITDIR\t" substr(w[i], index(w[i], "=") + 1); continue }
    if (w[i] ~ /^GIT_WORK_TREE=/)   { print "G\tWORKTREE\t" substr(w[i], index(w[i], "=") + 1); continue }
  }
  print "G\tCWD\t"
}
{ buf = buf $0 "\n" }
END {
  buf = strip_heredocs(buf)
  nt = texts_of(buf, texts, nested)
  for (x = 1; x <= nt; x++) {
    n = scan(texts[x], w, k, q)
    a = 1
    for (i = 1; i <= n + 1; i++) {
      if (i <= n && k[i] != ";") continue
      if (a < i) segment(a, i - 1, nested[x])
      a = i + 1
    }
  }
}') || deny "no-checkout-home: awk failed, cannot inspect the command"

[ -n "$out" ] || exit 0
tab=$(printf '\t')
while IFS="$tab" read -r tag kind value; do
  case "$tag" in
    DENY) deny_generic ;;
    G)
      case "$kind" in
        CWD) git_targets_home "$cwd" && deny_generic ;;
        C)
          r=$(resolve_path_arg "$value")
          [ -n "$r" ] && git_targets_home "$r" && deny_generic
          ;;
        WORKTREE)
          r=$(resolve_path_arg "$value")
          [ -n "$r" ] && [ "$r" = "$home" ] && deny_generic
          ;;
        GITDIR)
          r=$(resolve_path_arg "$value")
          [ -n "$r" ] && [ "$r" = "$home/.git" ] && deny_generic
          ;;
      esac
      ;;
  esac
done <<EOF
$out
EOF
exit 0

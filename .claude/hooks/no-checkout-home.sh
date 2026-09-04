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
# the repo it discovers from cwd (or a `-C` target) actually resolves to
# $HOME -- checked by asking git directly (`rev-parse --show-toplevel`),
# not by testing whether the path is textually under $HOME: a nested repo
# (a `~/.claude/worktrees/<name>` worktree, `~/dotfiles`, any other clone
# under $HOME) sits under $HOME by path but git's own upward search stops
# at its own `.git` long before reaching $HOME's, so it never resolves
# there. A textual prefix check would wrongly deny every one of those.
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
# The command is split into segments on shell separators (&&, ||, ;, |) and
# each segment is truncated at its first `#`, then every check below runs
# per segment -- so a `--` in one clause, or hidden behind a real shell
# comment (`yadm checkout foo # --`, where Bash only ever runs the part
# before the `#`), can never launder an earlier real checkout.
#
# For `git`, a `-C <path>` naming $HOME or a subdirectory of it (literally
# `$HOME`/`${HOME}`/`~`[/...], or a path that resolves to one) is treated
# the same as cwd being there. `--git-dir`/`--work-tree` are checked the
# same way, in both their flag form and their `GIT_DIR=`/`GIT_WORK_TREE=`
# inline-env-assignment form: a `--work-tree`/`GIT_WORK_TREE` resolving to
# $HOME, or a `--git-dir`/`GIT_DIR` resolving to $HOME/.git, is a hit
# regardless of cwd -- these override cwd-based repo discovery entirely, so
# `GIT_DIR=$HOME/.git GIT_WORK_TREE=$HOME git checkout <branch>` run from
# anywhere is exactly as dangerous as running it from $HOME. Quoting inside
# any of these values (`-C '$HOME'`, which the shell would NOT expand)
# isn't distinguished from the unquoted form that would -- a known
# imprecision that only makes the hook deny a couple of cases that were
# actually safe, never the reverse.
#
# Still a command-word regex, not a full parser (no-git-footguns.sh strips
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

# Resolves a raw -C/--git-dir/--work-tree value (as it appeared, unquoted by
# this hook) against $home/$payload_cwd, the same way the shell would if the
# literal text were left unquoted. Echoes the resolved absolute path, or
# nothing if it doesn't exist.
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

# Extracts the values of a `--flag value` / `--flag=value` git option from a
# command segment, stripping surrounding quotes.
extract_flag_values() {
  flag=$1
  printf '%s' "$seg" \
    | grep -oE "(^|[[:space:]])${flag}(=|[[:space:]]+)[^[:space:]]+" \
    | sed -E "s/^[[:space:]]*${flag}(=|[[:space:]]+)//; s/^[\"']//; s/[\"']\$//"
}

# Extracts the values of a `NAME=value` inline env assignment (e.g.
# `GIT_DIR=$HOME/.git git checkout ...`) from a command segment -- these
# override git's repo discovery exactly like the equivalent flag does.
extract_env_values() {
  name=$1
  printf '%s' "$seg" \
    | grep -oE "(^|[[:space:]])${name}=[^[:space:]]+" \
    | sed -E "s/^[[:space:]]*${name}=//; s/^[\"']//; s/[\"']\$//"
}

flags='([[:space:]]+(-[cC][[:space:]]+[^[:space:]]+|--(git-dir|work-tree)[[:space:]]+[^[:space:]]+|--[^[:space:]]+))*[[:space:]]+'
# The command word itself may be prefixed by a path (`/usr/bin/yadm`,
# `./yadm`): only exclude what could extend the word (alnum/_/-), not `/`,
# so a leading path segment doesn't suppress the match.
yadm_checkout_re="(^|[^A-Za-z0-9_-])yadm${flags}checkout([[:space:]]|\$)"
git_checkout_re="(^|[^A-Za-z0-9_-])git${flags}checkout([[:space:]]|\$)"
yadm_switch_re="(^|[^A-Za-z0-9_-])yadm${flags}switch([[:space:]]|\$)"
git_switch_re="(^|[^A-Za-z0-9_-])git${flags}switch([[:space:]]|\$)"

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
  is_checkout=0; is_switch=0; is_yadm=0
  if printf '%s' "$seg" | grep -Eq "$yadm_checkout_re"; then is_checkout=1; is_yadm=1
  elif printf '%s' "$seg" | grep -Eq "$git_checkout_re"; then is_checkout=1
  fi
  if printf '%s' "$seg" | grep -Eq "$yadm_switch_re"; then is_switch=1; is_yadm=1
  elif printf '%s' "$seg" | grep -Eq "$git_switch_re"; then is_switch=1
  fi
  [ "$is_checkout" = 1 ] || [ "$is_switch" = 1 ] || continue

  if [ "$is_yadm" = 1 ]; then
    hit=1   # yadm ignores cwd entirely -- always targets $HOME's worktree.
  else
    hit=0
    # --work-tree/--git-dir (as flags, or as GIT_WORK_TREE/GIT_DIR inline
    # env assignments ahead of the command word -- both spellings override
    # repo discovery the same way) are checked ahead of cwd/-C: a
    # `--work-tree=$HOME` or `GIT_WORK_TREE=$HOME` makes the invocation
    # target $HOME regardless of cwd.
    for cpath in $(extract_flag_values --work-tree) $(extract_env_values GIT_WORK_TREE); do
      r=$(resolve_path_arg "$cpath")
      [ -n "$r" ] && [ "$r" = "$home" ] && hit=1 && break
    done
    if [ "$hit" = 0 ]; then
      for cpath in $(extract_flag_values --git-dir) $(extract_env_values GIT_DIR); do
        r=$(resolve_path_arg "$cpath")
        [ -n "$r" ] && [ "$r" = "$home/.git" ] && hit=1 && break
      done
    fi
    [ "$hit" = 0 ] && git_targets_home "$cwd" && hit=1
    if [ "$hit" = 0 ]; then
      for cpath in $(extract_flag_values -C); do
        r=$(resolve_path_arg "$cpath")
        if [ -n "$r" ] && git_targets_home "$r"; then hit=1; fi
        [ "$hit" = 1 ] && break
      done
    fi
  fi
  [ "$hit" = 1 ] || continue

  if [ "$is_checkout" = 1 ]; then
    # A `--` pathspec separator within this segment means a file restore.
    printf '%s' "$seg" | grep -Eq '(^|[[:space:]])--([[:space:]]|$)' && continue
  fi

  deny "no-checkout-home: \`checkout\`/\`switch\` in \$HOME switches the branch every shell and session on this machine sees until someone checks main back out. Use a worktree instead:
  yadm worktree add -b <branch> ~/.claude/worktrees/<name> main
then cd into it and work there."
done <<EOF
$segments
EOF

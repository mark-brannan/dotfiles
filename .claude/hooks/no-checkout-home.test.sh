#!/usr/bin/env bash
# Tests for no-checkout-home.sh. Run: bash .claude/hooks/no-checkout-home.test.sh
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/no-checkout-home.sh"
# A cwd used in a check must exist on disk -- the hook's `cd` resolution
# fails open (allow) on a path it can't enter, same as it would for any
# other unreadable cwd, so a fabricated path silently passes "allow" tests
# for the wrong reason. Use this session's own worktree, which is real.
WORKTREE_CWD="$(cd "$(dirname "$0")/../.." && pwd)"
pass=0
fail=0

# check <expect deny|allow> <description> <cwd> <command>
check() {
  local want=$1 desc=$2 cwd=$3 cmd=$4 out got json
  json=$(jq -n --arg c "$cmd" --arg d "$cwd" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  out=$(printf '%s' "$json" | bash "$HOOK" 2>&1)
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
    got=deny
  else
    got=allow
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL (want %s, got %s): %s\n' "$want" "$got" "$desc"
    [ -n "$out" ] && printf '  hook output: %s\n' "$out"
  fi
}

# --- must deny: a branch switch with cwd == $HOME --------------------------
check deny 'yadm checkout <branch> in $HOME' "$HOME" 'yadm checkout some-branch'
check deny 'git checkout <branch> in $HOME'  "$HOME" 'git checkout some-branch'
check deny 'create-and-switch -b in $HOME'   "$HOME" 'yadm checkout -b new-branch'
check deny 'create-and-switch -B in $HOME'   "$HOME" 'yadm checkout -B new-branch'
check deny 'compound command'                "$HOME" 'echo hi && yadm checkout some-branch'

# --- must deny: yadm ignores cwd entirely -----------------------------------
# yadm hardcodes --work-tree=$HOME regardless of cwd -- verified empirically
# (cd /tmp && yadm rev-parse --show-toplevel prints $HOME). A worktree is
# exactly where a session runs this from most often, so this is the
# critical case: no `-C`, no cwd==$HOME, still dangerous.
check deny 'yadm checkout from a worktree'    "$WORKTREE_CWD" 'yadm checkout some-branch'
check deny 'yadm checkout from an unrelated dir' /tmp 'yadm checkout some-branch'
check deny 'yadm switch from a worktree'      "$WORKTREE_CWD" 'yadm switch some-branch'

# --- must deny: `git switch` is the same footgun as `checkout` -------------
check deny 'git switch <branch> in $HOME'   "$HOME" 'git switch some-branch'
check deny 'git switch -c <branch> in $HOME' "$HOME" 'git switch -c new-branch'
check deny 'git switch <branch>, -C $HOME from a worktree' "$WORKTREE_CWD" 'git -C "$HOME" switch some-branch'
# switch has no file-restore form, so a trailing -- doesn't exempt it.
check deny 'git switch with a trailing --' "$HOME" 'git switch some-branch --'

# --- must deny: plain git from a subdirectory of $HOME, not just $HOME -----
# On THIS machine $HOME has no .git for plain git to discover, so a real
# `git checkout` from a $HOME subdirectory is already harmless here -- it
# errors "not a git repository" before ever reaching the hook's decision.
# Build a fixture with a real .git at a fake $HOME to prove the mechanism
# (git_targets_home's `rev-parse --show-toplevel` check) actually catches
# the case where one exists, rather than relying on this machine's
# incidental state.
FAKE_HOME="$(mktemp -d)"
mkdir -p "$FAKE_HOME/subdir" "$FAKE_HOME/.claude/worktrees/fake-task"
git -C "$FAKE_HOME" init -q -b main
git -C "$FAKE_HOME/.claude/worktrees/fake-task" init -q -b main   # a nested, unrelated repo
trap 'rm -rf "$FAKE_HOME"' EXIT

check_home() {
  local want=$1 desc=$2 cwd=$3 cmd=$4 out got json
  json=$(jq -n --arg c "$cmd" --arg d "$cwd" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  out=$(printf '%s' "$json" | HOME="$FAKE_HOME" bash "$HOOK" 2>&1)
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then got=deny; else got=allow; fi
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL (want %s, got %s): %s\n' "$want" "$got" "$desc"
    [ -n "$out" ] && printf '  hook output: %s\n' "$out"
  fi
}

check_home deny  'git checkout from a real $HOME subdirectory'      "$FAKE_HOME/subdir" 'git checkout some-branch'
check_home deny  'git checkout at fake $HOME itself'                "$FAKE_HOME"        'git checkout some-branch'
check_home allow 'git checkout inside a nested repo under $HOME'    "$FAKE_HOME/.claude/worktrees/fake-task" 'git checkout some-branch'

# --- must deny: the earlier review round's bypasses ------------------------
check deny 'trailing clause with --, after &&' "$HOME" 'yadm checkout some-branch && ls --'
check deny 'trailing shell comment holding --' "$HOME" 'yadm checkout some-branch # --'
check deny '-C "$HOME" from a worktree'  "$WORKTREE_CWD" 'git -C "$HOME" checkout some-branch'
check deny '-C $HOME (unquoted) from a worktree' "$WORKTREE_CWD" 'git -C $HOME checkout some-branch'
check deny '-C ~ from a worktree' "$WORKTREE_CWD" 'git -C ~ checkout some-branch'
check deny '-C <absolute $HOME path> from a worktree' "$WORKTREE_CWD" "git -C $HOME checkout some-branch"
check deny 'absolute-path yadm invocation in $HOME' "$HOME" '/usr/bin/yadm checkout some-branch'
check deny 'relative-path yadm invocation in $HOME' "$HOME" './yadm checkout some-branch'
check deny 'absolute-path git invocation in $HOME'  "$HOME" '/usr/bin/git checkout some-branch'
check deny '--work-tree=$HOME from an unrelated cwd' "/tmp" "git --work-tree=$HOME checkout some-branch"
check deny '--git-dir and --work-tree both set to $HOME' "/tmp" "git --git-dir=$HOME/.git --work-tree=$HOME checkout some-branch"
check deny '--work-tree $HOME (space form)' "/tmp" "git --work-tree $HOME checkout some-branch"
check deny '--git-dir and --work-tree, space form' "/tmp" "git --git-dir $HOME/.git --work-tree $HOME checkout some-branch"

# --- must allow: file-restore forms, even in $HOME --------------------------
check allow 'checkout -- <file> in $HOME'       "$HOME" 'yadm checkout -- .npmrc'
check allow 'checkout <ref> -- <file> in $HOME' "$HOME" 'yadm checkout main -- .npmrc'
check allow '-- in the same segment as the checkout' "$HOME" 'yadm checkout -- .npmrc && ls'
# checkout . has no ref token to route as a branch switch or a pathspec, so
# this hook denies it too -- redundant with no-git-footguns.sh, not a bug.
check deny 'checkout . (also caught by no-git-footguns.sh)' "$HOME" 'yadm checkout .'

# --- must allow: plain git, outside $HOME, nothing pointing back at it -----
check allow 'git checkout <branch> in a worktree' "$WORKTREE_CWD" 'git checkout some-branch'
check allow 'git switch <branch> in a worktree'   "$WORKTREE_CWD" 'git switch some-branch'
check allow '-C to a worktree, not $HOME' "$WORKTREE_CWD" "git -C $WORKTREE_CWD checkout some-branch"
check allow '--git-dir to a worktree, not $HOME' "/tmp" "git --git-dir=$WORKTREE_CWD/.git checkout some-branch"

# --- must allow: unrelated commands -----------------------------------------
check allow 'not a checkout at all' "$HOME" 'yadm status'

if [ "$fail" -eq 0 ]; then
  printf 'no-checkout-home: %d/%d passed\n' "$pass" "$pass"
else
  printf 'no-checkout-home: %d passed, %d FAILED\n' "$pass" "$fail"
  exit 1
fi

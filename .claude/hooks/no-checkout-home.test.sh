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

# --- must deny: the CodeRabbit/claude-review bypasses -----------------------
# A `--` in a later clause must not exempt an earlier real checkout.
check deny 'trailing clause with --, after &&' "$HOME" 'yadm checkout some-branch && ls --'
# `#` starts a real shell comment -- Bash only ever runs the part before it,
# so the hook must judge the command on that part alone.
check deny 'trailing shell comment holding --' "$HOME" 'yadm checkout some-branch # --'
# `-C "$HOME"` points the invocation at $HOME even when cwd is a worktree.
check deny '-C "$HOME" from a worktree'  "$WORKTREE_CWD" 'git -C "$HOME" checkout some-branch'
check deny '-C $HOME (unquoted) from a worktree' "$WORKTREE_CWD" 'git -C $HOME checkout some-branch'
check deny '-C ~ from a worktree' "$WORKTREE_CWD" 'git -C ~ checkout some-branch'
check deny '-C <absolute $HOME path> from a worktree' "$WORKTREE_CWD" "git -C $HOME checkout some-branch"

# --- must allow: file-restore forms, even in $HOME --------------------------
check allow 'checkout -- <file> in $HOME'       "$HOME" 'yadm checkout -- .npmrc'
check allow 'checkout <ref> -- <file> in $HOME' "$HOME" 'yadm checkout main -- .npmrc'
check allow '-- in the same segment as the checkout' "$HOME" 'yadm checkout -- .npmrc && ls'
# checkout . has no ref token to route as a branch switch or a pathspec, so
# this hook denies it too -- redundant with no-git-footguns.sh, not a bug.
check deny 'checkout . (also caught by no-git-footguns.sh)' "$HOME" 'yadm checkout .'

# --- must allow: branch switch outside $HOME, no -C pointing at it ---------
check allow 'checkout <branch> in a worktree' "$WORKTREE_CWD" 'yadm checkout some-branch'
check allow '-C to a worktree, not $HOME' "$WORKTREE_CWD" "git -C $WORKTREE_CWD checkout some-branch"

# --- must allow: unrelated commands -----------------------------------------
check allow 'not a checkout at all' "$HOME" 'yadm status'

if [ "$fail" -eq 0 ]; then
  printf 'no-checkout-home: %d/%d passed\n' "$pass" "$pass"
else
  printf 'no-checkout-home: %d passed, %d FAILED\n' "$pass" "$fail"
  exit 1
fi

#!/usr/bin/env bash
# Tests for no-checkout-home.sh. Run: bash .claude/hooks/no-checkout-home.test.sh
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/no-checkout-home.sh"
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

# --- must allow: file-restore forms, even in $HOME --------------------------
check allow 'checkout -- <file> in $HOME'       "$HOME" 'yadm checkout -- .npmrc'
check allow 'checkout <ref> -- <file> in $HOME' "$HOME" 'yadm checkout main -- .npmrc'
# checkout . has no ref token to route as a branch switch or a pathspec, so
# this hook denies it too -- redundant with no-git-footguns.sh, not a bug.
check deny 'checkout . (also caught by no-git-footguns.sh)' "$HOME" 'yadm checkout .'

# --- must allow: branch switch outside $HOME --------------------------------
check allow 'checkout <branch> in a worktree' "$HOME/.claude/worktrees/some-task" 'yadm checkout some-branch'

# --- must allow: unrelated commands -----------------------------------------
check allow 'not a checkout at all' "$HOME" 'yadm status'

if [ "$fail" -eq 0 ]; then
  printf 'no-checkout-home: %d/%d passed\n' "$pass" "$pass"
else
  printf 'no-checkout-home: %d passed, %d FAILED\n' "$pass" "$fail"
  exit 1
fi

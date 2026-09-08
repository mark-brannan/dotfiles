#!/usr/bin/env bash
# Tests for prose-budget-commit.sh. Run: bash .claude/hooks/prose-budget-commit.test.sh
# Set AWK_PATH to a directory whose `awk` is another implementation to test
# the shared scanner under it, as hook-tests.yml does.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/prose-budget-commit.sh"
export PROSE_BUDGET="$HERE/../../.local/bin/prose-budget"
[ -n "${AWK_PATH:-}" ] && PATH="$AWK_PATH:$PATH"
pass=0; fail=0

# check <deny|allow> <description> <command> [cwd]
check() {
  local want=$1 desc=$2 cmd=$3 dir=${4:-$DIRTY} out got
  out=$(jq -n --arg c "$cmd" --arg d "$dir" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | timeout 20 bash "$HOOK" 2>&1)
  if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then got=deny; else got=allow; fi
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL (want %s, got %s): %s\n  cmd: %s\n' "$want" "$got" "$desc" "$cmd"
    [ -n "$out" ] && printf '  hook output: %s\n' "$out"
  fi
  LAST=$out
}

# A repo whose staged README adds too much prose, and one whose staging is clean.
mkrepo() {
  local d; d=$(mktemp -d)
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@example.com; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  printf '{}\n' > "$d/.prose-budgets.json"
  printf 'seed\n' > "$d/README.md"
  git -C "$d" add .prose-budgets.json README.md; git -C "$d" commit -qm seed
  echo "$d"
}
DIRTY=$(mkrepo)
{ echo '## A'; echo; for _ in $(seq 60); do printf 'word '; done; echo; } > "$DIRTY/README.md"
git -C "$DIRTY" add README.md
CLEAN=$(mkrepo)
printf 'seed plus one\n' > "$CLEAN/README.md"; git -C "$CLEAN" add README.md
NOCONF=$(mktemp -d); git -C "$NOCONF" init -q -b main; printf 'x\n' > "$NOCONF/a.md"; git -C "$NOCONF" add a.md
mkdir -p "$DIRTY/sub"
trap 'rm -rf "$DIRTY" "$CLEAN" "$NOCONF"' EXIT

check deny  'plain commit'                    'git commit -m "docs: more"'
check deny  'after a separator'               'git add README.md && git commit -m x'
check deny  'yadm commit'                     'yadm commit -m x'
check deny  'git -C dir commit'               "git -C $DIRTY commit -m x" "$CLEAN"
check deny  'cd dir && git commit'            "cd $DIRTY && git commit -m x" "$CLEAN"
check deny  'commit from a subdirectory'      'git commit -m x' "$DIRTY/sub"
printf '%s' "$LAST" | grep -q 'delta' || { fail=$((fail + 1)); echo 'FAIL: deny reason lacks the findings'; }
printf '%s' "$LAST" | grep -q 'Do not ask the user' || { fail=$((fail + 1)); echo 'FAIL: deny reason lacks the retry instruction'; }

check allow 'clean staging'                   'git commit -m x' "$CLEAN"
check allow 'no config in the repo'           'git commit -m x' "$NOCONF"
check allow 'not a commit'                    'git status'
check allow 'commit mentioned in a message'   'git add x && git commit -m "git commit -m later"' "$CLEAN"
check allow 'commit as prose'                 'echo "run git commit -m x"'
check allow 'commit in a heredoc body'        $'cat <<EOF\ngit commit -m x\nEOF'
check allow 'a different tool'                'gh pr create --title x'

# Fail-open: no jq, and no engine.
BARE=$(mktemp -d); for t in bash sh awk cat cut dirname git timeout; do p=$(command -v $t) && ln -s "$p" "$BARE/$t"; done
out=$(jq -n --arg d "$DIRTY" '{tool_name:"Bash",tool_input:{command:"git commit -m x"},cwd:$d}' | PATH=$BARE bash "$HOOK" 2>&1)
if [ -z "$out" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: without jq the hook should be silent, got: $out"; fi
out=$(jq -n --arg d "$DIRTY" '{tool_name:"Bash",tool_input:{command:"git commit -m x"},cwd:$d}' | PROSE_BUDGET=/nonexistent bash "$HOOK" 2>&1)
if [ -z "$out" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: without the engine the hook should be silent, got: $out"; fi
rm -rf "$BARE"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

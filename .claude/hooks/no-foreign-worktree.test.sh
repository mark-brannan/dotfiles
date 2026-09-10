#!/usr/bin/env bash
# Tests for no-foreign-worktree.sh. Run: bash .claude/hooks/no-foreign-worktree.test.sh
# Set AWK_PATH to a directory whose `awk` is another implementation (mawk,
# nawk, busybox) to check portability; CI runs it under Ubuntu's mawk.
#
# The fixture is a throwaway repo with two linked worktrees, not this
# machine's real ones: the hook asks git what a path is, so the checks are
# only meaningful against paths git really answers about, and naming a
# sibling worktree that exists today would rot the moment it is archived.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/no-foreign-worktree.sh"
[ -n "${AWK_PATH:-}" ] && PATH="$AWK_PATH:$PATH"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# `pwd -P` inside the hook resolves symlinks (/tmp is one on macOS), so the
# fixture paths must be resolved here too or every comparison misses.
TMP=$(cd "$TMP" && pwd -P)

setup() (
  set -e
  cd "$TMP"
  git init -q --initial-branch=main repo
  cd repo
  git -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
  mkdir -p .claude/worktrees
  git worktree add -q --no-checkout -b mine .claude/worktrees/mine >/dev/null 2>&1 || git worktree add -q -b mine .claude/worktrees/mine
  git -C .claude/worktrees/mine checkout -q mine 2>/dev/null || true
  git worktree add -q -b theirs .claude/worktrees/theirs
  mkdir -p .claude/worktrees/theirs/sub
  : > .claude/worktrees/theirs/sub/file.txt
  # A second, unrelated clone: a MAIN worktree, shared by every session and
  # nobody's private space, so it must stay allowed.
  cd "$TMP"
  git clone -q repo other-clone
)
setup || { echo "fixture setup failed"; exit 1; }

REPO="$TMP/repo"
MINE="$REPO/.claude/worktrees/mine"
THEIRS="$REPO/.claude/worktrees/theirs"
CLONE="$TMP/other-clone"

pass=0
fail=0

# check <deny|allow> <description> <json payload>
check_json() {
  local want=$1 desc=$2 json=$3 out got
  out=$(printf '%s' "$json" | bash "$HOOK" 2>&1)
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then got=deny; else got=allow; fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL (want %s, got %s): %s\n' "$want" "$got" "$desc"
    [ -n "$out" ] && printf '  hook output: %s\n' "$out"
  fi
}

# bash <deny|allow> <description> <command> [cwd]
bash_check() {
  check_json "$1" "$3" "$(jq -n --arg c "$3" --arg d "${4:-$MINE}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
}

# --- must deny: attaching to another session's worktree --------------------
bash_check deny 'git -C <foreign worktree>'        "git -C $THEIRS status"
bash_check deny 'git -C a subdir of one'           "git -C $THEIRS/sub log"
bash_check deny 'cd into one'                      "cd $THEIRS && git commit -m x"
bash_check deny '--work-tree=<foreign>'            "git --work-tree=$THEIRS status"
bash_check deny 'GIT_WORK_TREE=<foreign>'          "GIT_WORK_TREE=$THEIRS git status"
bash_check deny 'a relative path into one'         "git -C ../theirs status"
bash_check deny 'writing a file in one'            "sed -i s/a/b/ $THEIRS/sub/file.txt"
bash_check deny 'a file that does not exist yet'   "echo hi | tee $THEIRS/sub/new.txt"
bash_check deny 'reading a file in one'            "cat $THEIRS/sub/file.txt"
bash_check deny 'removing one'                     "git worktree remove $THEIRS"
bash_check deny 'inside sh -c'                     "sh -c \"cd $THEIRS && ls\""
bash_check deny 'from the main worktree'           "git -C $THEIRS status" "$REPO"
bash_check deny 'from an unrelated cwd'            "git -C $THEIRS status" /tmp

# --- must allow: everywhere that is not a private working directory --------
bash_check allow 'the main worktree of the repo'   "git -C $REPO status"
bash_check allow 'an unrelated clone'              "git -C $CLONE status"
bash_check allow 'this session own worktree'       "git -C $MINE status"
bash_check allow 'a path inside own worktree'      "cat $MINE/nothing-here.txt"
bash_check allow 'a plain relative path'           'cat README.md'
bash_check allow 'the worktrees parent directory'  "ls $REPO/.claude/worktrees/"
bash_check allow 'a ref, not a path'               'git log origin/main'
bash_check allow 'no path at all'                  'git status --porcelain'
# The whole point of the alternative the deny message offers.
bash_check allow 'reading a branch from here'      'git show theirs:sub/file.txt'

# --- must allow: prose that mentions a foreign path -----------------------
# A quoted string holding whitespace is one unresolvable word, and the
# scanner only queues it for a nested scan when the segment could execute
# it -- git and gh are prose consumers, so a message or an issue body passes.
bash_check allow 'a commit message naming one'     "git commit -m \"worktree $THEIRS is stale\""
bash_check allow 'an issue body naming one'        "gh issue comment 1 -b \"old work is in $THEIRS\""
bash_check allow 'an echo naming one'              "echo \"see $THEIRS for the old work\""

# --- must allow: an unresolvable word is not judged ------------------------
bash_check allow 'an unexpanded variable'          'git -C "$SOME_DIR" status'
bash_check allow 'a glob'                          "ls $REPO/.claude/worktrees/*/"

# --- file-editing tools ---------------------------------------------------
for tool in Edit Write MultiEdit; do
  check_json deny "$tool into a foreign worktree" \
    "$(jq -n --arg p "$THEIRS/sub/file.txt" --arg d "$MINE" --arg t "$tool" \
      '{tool_name:$t,tool_input:{file_path:$p},cwd:$d}')"
  check_json allow "$tool inside own worktree" \
    "$(jq -n --arg p "$MINE/file.txt" --arg d "$MINE" --arg t "$tool" \
      '{tool_name:$t,tool_input:{file_path:$p},cwd:$d}')"
done
check_json deny 'NotebookEdit into a foreign worktree' \
  "$(jq -n --arg p "$THEIRS/sub/nb.ipynb" --arg d "$MINE" \
    '{tool_name:"NotebookEdit",tool_input:{notebook_path:$p},cwd:$d}')"

# --- EnterWorktree -------------------------------------------------------
# `path` is refused whatever it names: the tool does no ownership check, so
# there is no path value that makes it safe. `name` creates a fresh one.
check_json deny 'EnterWorktree(path=foreign)' \
  "$(jq -n --arg p "$THEIRS" --arg d "$MINE" '{tool_name:"EnterWorktree",tool_input:{path:$p},cwd:$d}')"
check_json deny 'EnterWorktree(path=own)' \
  "$(jq -n --arg p "$MINE" --arg d "$MINE" '{tool_name:"EnterWorktree",tool_input:{path:$p},cwd:$d}')"
check_json allow 'EnterWorktree(name=...)' \
  "$(jq -n --arg d "$MINE" '{tool_name:"EnterWorktree",tool_input:{name:"fresh"},cwd:$d}')"

# --- other tools are none of this hook business --------------------------
check_json allow 'Read of a foreign path is not gated here' \
  "$(jq -n --arg p "$THEIRS/sub/file.txt" --arg d "$MINE" '{tool_name:"Read",tool_input:{file_path:$p},cwd:$d}')"

# --- fails closed --------------------------------------------------------
check_json deny 'unreadable payload' 'not json at all'
# An absolute interpreter, since PATH is what is being taken away. The
# fail-closed reasons must not need sed or awk to be serialised, so this
# checks the output is valid JSON, not merely that it says deny.
out=$(printf '%s' "$(jq -n --arg c "git -C $THEIRS status" --arg d "$MINE" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')" \
  | env -i PATH=/nonexistent HOME="$HOME" /bin/sh "$HOOK" 2>/dev/null)
if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  printf 'FAIL: no jq/awk on PATH must fail closed with valid JSON\n  hook output: %s\n' "$out"
fi

printf '%s\n' "no-foreign-worktree: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1

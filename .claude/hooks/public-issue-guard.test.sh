#!/usr/bin/env bash
# Tests for public-issue-guard.sh. Run: bash .claude/hooks/public-issue-guard.test.sh
# Set AWK_PATH to a directory whose `awk` is another implementation to run
# the same cases under it (CI does mawk, gawk, original-awk).
#
# What matters: a private term is caught wherever the body travels -- a
# flag value, a file, a heredoc, an MCP field, a different case -- the
# private repo is never scanned, reads are never touched, and the gate is
# loud when it cannot see the text or the denylist.
# shellcheck disable=SC2016  # the commands under test contain $(...) and $VAR on purpose
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/public-issue-guard.sh"
[ -n "${AWK_PATH:-}" ] && PATH="$AWK_PATH:$PATH"
pass=0; fail=0
SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
export HOME="$SCRATCH/home"; mkdir -p "$HOME"
export TMPDIR="$SCRATCH/tmp"; mkdir -p "$TMPDIR"

# A fake state repo with a denylist. The terms here are invented: the real
# list is private and only ever read by path.
STATE="$SCRATCH/state"
mkdir -p "$STATE/.git" "$STATE/state/global"
cat > "$STATE/state/global/private-terms.txt" <<'EOF'
# private terms -- lines starting with # are comments

Wanderlust
gateway.home.example
  acct-4471
EOF
export CLAUDE_STATE_REPO="$STATE"
PRIVATE=mark-brannan/claude_prompts_scratch

# Two checkouts to resolve a cwd through: one whose origin is the private
# repo, one whose origin is public.
mkrepo() { mkdir -p "$1"; git -C "$1" init -q; git -C "$1" remote add origin "$2"; }
mkrepo "$SCRATCH/private" "git@github.com:$PRIVATE.git"
mkrepo "$SCRATCH/public" "https://github.com/mark-brannan/colregs.git"
mkdir -p "$SCRATCH/nogit"

LAST=""
# check <deny|allow> <desc> <json>
check() {
  local want=$1 desc=$2 json=$3 out got
  out=$(printf '%s' "$json" | sh "$HOOK" 2>&1)
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then got=deny
  elif [ -z "$out" ]; then got=allow
  else got=invalid; fi
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL (want %s, got %s): %s\n' "$want" "$got" "$desc"
    [ -n "$out" ] && printf '  hook output: %s\n' "$out"
  fi
  LAST=$out
}
reason() { if printf '%s' "$LAST" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -Fq -- "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL (reason lacks [%s]): %s\n  %s\n' "$2" "$1" "$LAST"; fi; }
no_reason() { if printf '%s' "$LAST" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -Fq -- "$2"; then fail=$((fail + 1)); printf 'FAIL (reason has [%s]): %s\n  %s\n' "$2" "$1" "$LAST"; else pass=$((pass + 1)); fi; }

# bash_in <cwd> <command>
bash_in() { jq -n --arg d "$1" --arg c "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
# mcp_in <tool> <tool_input json>
mcp_in() { jq -n --arg t "$1" --argjson i "$2" '{tool_name:$t,cwd:"/x",tool_input:$i}'; }
PUB="$SCRATCH/public"

# --- a term in the body, wherever it travels -----------------------------------
check deny 'term in --body'          "$(bash_in "$PUB" 'gh issue create --title "Log rotation" --body "seen on Wanderlust last night"')"
reason 'names the term'              'Wanderlust'
no_reason 'never the surrounding text' 'last night'
reason 'points at the private repo'  "--repo $PRIVATE"
reason 'or rewrite'                  'rewrite the body'
check deny 'term in --title'         "$(bash_in "$PUB" 'gh issue create -t "Wanderlust: AIS drops" -b "details below"')"
check deny 'term in -b glued'        "$(bash_in "$PUB" 'gh pr comment 12 -b"tested on Wanderlust"')"
check deny 'term in --body= form'    "$(bash_in "$PUB" 'gh issue edit 3 --body="host is gateway.home.example"')"
check deny 'term in pr review body'  "$(bash_in "$PUB" 'gh pr review 9 --approve --body "ok from acct-4471"')"
check deny 'term in issue close -c'  "$(bash_in "$PUB" 'gh issue close 3 -c "moved to Wanderlust log"')"
check deny 'term in pr merge -b'     "$(bash_in "$PUB" 'gh pr merge 5 --squash -b "tested on wanderlust"')"
check deny 'term after &&'           "$(bash_in "$PUB" 'git push && gh pr create --title x --body "cf Wanderlust"')"
check deny 'term escaped mid-word'   "$(bash_in "$PUB" 'gh issue create -t x -b Wander\lust')"
check deny 'term split across quotes' "$(bash_in "$PUB" "gh issue create -t x -b 'Wander'\"lust\"")"
check deny 'term in sh -c'           "$(bash_in "$PUB" "sh -c 'gh issue create -t x -b \"on Wanderlust\"'")"
check deny 'term in a heredoc'       "$(bash_in "$PUB" 'gh issue create -t x -F - <<'"'"'EOF'"'"'
Steps:
1. ssh to gateway.home.example
EOF')"
check deny 'term in a heredoc via variable' "$(bash_in "$PUB" 'body=$(cat <<EOF
crew of Wanderlust
EOF
)
gh issue create -t x -b "$body"')"

printf 'reproduced aboard Wanderlust\n' > "$SCRATCH/body.md"
printf 'nothing private here\n' > "$SCRATCH/clean.md"
check deny 'term in --body-file'     "$(bash_in "$PUB" "gh issue create -t x --body-file $SCRATCH/body.md")"
check deny 'term in -F, relative path' "$(bash_in "$SCRATCH" 'gh pr create -t x -F body.md')"
check deny 'term in --body-file=~ path' "$(cp "$SCRATCH/body.md" "$HOME/b.md"; bash_in "$PUB" 'gh issue comment 4 --body-file=~/b.md')"
check allow 'clean --body-file'      "$(bash_in "$PUB" "gh issue create -t x -F $SCRATCH/clean.md")"
# The path is read, not posted: a term in the directory name is not a hit,
# while a term in the file at that path still is.
mkdir -p "$SCRATCH/Wanderlust"; cp "$SCRATCH/clean.md" "$SCRATCH/body.md" "$SCRATCH/Wanderlust/"
check allow 'term in --body-file path only'   "$(bash_in "$PUB" "gh issue create -t x --body-file $SCRATCH/Wanderlust/clean.md")"
check allow 'term in --body-file= path only'  "$(bash_in "$PUB" "gh pr comment 4 --body-file=$SCRATCH/Wanderlust/clean.md")"
check allow 'term in api @file path only'     "$(bash_in "$PUB" "gh api repos/o/r/issues -f title=x -F body=@$SCRATCH/Wanderlust/clean.md")"
check deny  'term in file under such a path'  "$(bash_in "$PUB" "gh issue create -t x --body-file $SCRATCH/Wanderlust/body.md")"
check deny  'term elsewhere, path masked'     "$(bash_in "$PUB" "gh issue create -t Wanderlust --body-file $SCRATCH/Wanderlust/clean.md")"

# --- case-insensitive, fixed strings ------------------------------------------
check deny 'upper-case body, lower-case list' "$(bash_in "$PUB" 'gh issue create -t x -b "ACCT-4471 again"')"
check deny 'mixed case'              "$(bash_in "$PUB" 'gh issue create -t x -b "WANDERLUST"')"
check allow 'dot is literal, not any char' "$(bash_in "$PUB" 'gh issue create -t x -b "gatewayXhomeXexample"')"

# --- MCP ------------------------------------------------------------------------
check deny 'MCP create_issue body'   "$(mcp_in mcp__github__create_issue '{"owner":"mark-brannan","repo":"colregs","title":"x","body":"seen on Wanderlust"}')"
check deny 'MCP add_issue_comment'   "$(mcp_in mcp__github__add_issue_comment '{"owner":"o","repo":"r","issue_number":3,"body":"ping gateway.home.example"}')"
check deny 'MCP issue_write title'   "$(mcp_in mcp__github__issue_write '{"method":"create","owner":"o","repo":"r","title":"Wanderlust AIS"}')"
check deny 'MCP review comment nested' "$(mcp_in mcp__github__create_pull_request_review '{"owner":"o","repo":"r","pullNumber":1,"event":"COMMENT","comments":[{"path":"a.ts","body":"acct-4471"}]}')"
check allow 'MCP clean body'         "$(mcp_in mcp__github__create_issue '{"owner":"o","repo":"r","title":"x","body":"see mark-brannan/colregs#12"}')"
check allow 'MCP private repo'       "$(mcp_in mcp__github__create_issue "{\"owner\":\"mark-brannan\",\"repo\":\"claude_prompts_scratch\",\"title\":\"x\",\"body\":\"Wanderlust\"}")"
check allow 'MCP read tool ignored'  "$(mcp_in mcp__github__get_issue '{"owner":"o","repo":"r","issue_number":3}')"

# --- gh api -------------------------------------------------------------------------
check deny 'api POST issues -f body' "$(bash_in "$PUB" 'gh api repos/o/r/issues -f title=x -f body="aboard Wanderlust"')"
check deny 'api -X PATCH'            "$(bash_in "$PUB" 'gh api -X PATCH repos/o/r/issues/3 -f body=gateway.home.example')"
check deny 'api pulls review'        "$(bash_in "$PUB" 'gh api repos/o/r/pulls/3/reviews -f event=COMMENT -f body="acct-4471"')"
check deny 'api graphql addComment'  "$(bash_in "$PUB" "gh api graphql -f query='mutation { addComment(input:{subjectId:\"I_1\", body:\"from Wanderlust\"}) { clientMutationId } }'")"
check deny 'api -F body=@file'       "$(bash_in "$PUB" "gh api repos/o/r/issues/3/comments -F body=@$SCRATCH/body.md")"
check allow 'api GET issues'         "$(bash_in "$PUB" 'gh api repos/o/r/issues --jq ".[].title"')"
check allow 'api graphql read'       "$(bash_in "$PUB" "gh api graphql -f query='{ repository(owner:\"o\",name:\"r\"){ issue(number:3){ title } } }'")"
check allow 'api private repo path'  "$(bash_in "$PUB" "gh api repos/$PRIVATE/issues -f title=x -f body=Wanderlust")"

# --- the private repo is never scanned ------------------------------------------
check allow '--repo private'         "$(bash_in "$PUB" "gh issue create --repo $PRIVATE -t x -b 'aboard Wanderlust'")"
check allow '-R private, mixed case' "$(bash_in "$PUB" "gh issue create -R Mark-Brannan/Claude_Prompts_Scratch -t x -b Wanderlust")"
check allow '--repo= URL form'       "$(bash_in "$PUB" "gh issue comment 3 --repo=https://github.com/$PRIVATE -b Wanderlust")"
check allow 'GH_REPO= private'       "$(bash_in "$PUB" "GH_REPO=$PRIVATE gh issue create -t x -b Wanderlust")"
check allow 'cwd origin is private'  "$(bash_in "$SCRATCH/private" 'gh issue create -t x -b "aboard Wanderlust"')"
check deny 'cwd private but cd elsewhere' "$(bash_in "$SCRATCH/private" "cd $PUB && gh issue create -t x -b Wanderlust")"
check deny 'cwd public'              "$(bash_in "$PUB" 'gh issue create -t x -b Wanderlust')"
check deny 'cwd not a repo'          "$(bash_in "$SCRATCH/nogit" 'gh issue create -t x -b Wanderlust')"
check deny 'one private, one public target' "$(bash_in "$PUB" "gh issue create --repo $PRIVATE -t x -b Wanderlust && gh issue comment 3 --repo o/r -b Wanderlust")"

# --- reads and clean bodies pass ------------------------------------------------
check allow 'gh issue list'          "$(bash_in "$PUB" 'gh issue list --label ready')"
check allow 'gh pr view'             "$(bash_in "$PUB" 'gh pr view 12 --comments')"
check allow 'gh pr checks'           "$(bash_in "$PUB" 'gh pr checks 12 --watch')"
check allow 'clean body, public names and URLs' "$(bash_in "$PUB" 'gh issue create -t "Ruling: Q-14" -b "Argument in mark-brannan/colregs requirements.md; see https://github.com/mark-brannan/colregs-engine/pull/25 and claude_prompts_scratch#3"')"
check allow 'no scannable text'      "$(bash_in "$PUB" 'gh pr merge 12 --squash --delete-branch')"
check allow 'echo mentioning a gh write' "$(bash_in "$PUB" 'echo "gh issue create --body hi"')"
check allow 'unrelated command'      "$(bash_in "$PUB" 'ls -la')"
check allow 'empty command'          "$(jq -n '{tool_name:"Bash",tool_input:{}}')"
check allow 'other tool'             "$(jq -n '{tool_name:"Read",tool_input:{file_path:"/x"}}')"

# --- the gate is loud when it cannot see ------------------------------------------
check deny '-F - with no heredoc'    "$(bash_in "$PUB" 'cat notes.md | gh issue create -t x -F -')"
reason 'says stdin'                  'stdin'
check allow '-F - with a clean heredoc' "$(bash_in "$PUB" 'gh issue create -t x -F - <<EOF
all public
EOF')"
check deny 'body from $(...)'        "$(bash_in "$PUB" 'gh issue create -t x -b "$(cat notes.md)"')"
reason 'says it is built at run time' 'run time'
check deny 'body from $VAR, no heredoc' "$(bash_in "$PUB" 'gh pr comment 3 --body "$body"')"
check allow '$VAR body fed by a clean heredoc' "$(bash_in "$PUB" 'b=$(cat <<EOF
public text
EOF
); gh pr comment 3 --body "$b"')"
check deny 'opaque $(...) beside an unrelated heredoc' "$(bash_in "$PUB" 'cat <<EOF
hello
EOF
gh issue create -t x --body "$(cat notes.md)"')"
reason 'says no heredoc feeds it'  'no heredoc in this command feeds it'
check deny '$VAR from a file, heredoc elsewhere' "$(bash_in "$PUB" 'body=$(cat notes.md); cat <<EOF
hi
EOF
gh pr comment 3 --body "$body"')"
check deny 'missing --body-file'     "$(bash_in "$PUB" "gh issue create -t x -F $SCRATCH/absent.md")"
reason 'names the file'              'absent.md'
check allow 'missing --body-file, private repo' "$(bash_in "$PUB" "gh issue create --repo $PRIVATE -t x -F $SCRATCH/absent.md")"

# denylist missing: a state repo with no private-terms.txt, and no repo at all
EMPTY="$SCRATCH/empty"; mkdir -p "$EMPTY/.git" "$EMPTY/state/global"
out=$(bash_in "$PUB" 'gh issue create -t x -b "all public"' | CLAUDE_STATE_REPO=$EMPTY sh "$HOOK" 2>&1); LAST=$out
if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: denylist missing should deny: $out"; fi
reason 'says the denylist is unreadable' 'denylist is unreadable'
reason 'asks about the state repo'   'state repo checked out'
reason 'offers the private repo'     "--repo $PRIVATE"
out=$(bash_in "$PUB" 'gh issue create -t x -b "all public"' | CLAUDE_STATE_REPO='' sh "$HOOK" 2>&1)
if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: no state repo anywhere should deny: $out"; fi
out=$(bash_in "$PUB" "gh issue create --repo $PRIVATE -t x -b Wanderlust" | CLAUDE_STATE_REPO=$EMPTY sh "$HOOK" 2>&1)
if [ -z "$out" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: private repo needs no denylist: $out"; fi
out=$(bash_in "$PUB" 'gh issue list' | CLAUDE_STATE_REPO=$EMPTY sh "$HOOK" 2>&1)
if [ -z "$out" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: a read needs no denylist: $out"; fi

# denylist present but empty: a readable file with no terms matches nothing,
# which would let every post through looking exactly like a check that ran.
BLANK="$SCRATCH/blank"; mkdir -p "$BLANK/.git" "$BLANK/state/global"
printf '# comments only\n\n   \n' > "$BLANK/state/global/private-terms.txt"
out=$(bash_in "$PUB" 'gh issue create -t x -b "all public"' | CLAUDE_STATE_REPO=$BLANK sh "$HOOK" 2>&1); LAST=$out
if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: empty denylist should deny: $out"; fi
reason 'says the denylist has no terms' 'no terms in it'
out=$(bash_in "$PUB" "gh issue create --repo $PRIVATE -t x -b Wanderlust" | CLAUDE_STATE_REPO=$BLANK sh "$HOOK" 2>&1)
if [ -z "$out" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: private repo needs no denylist terms: $out"; fi

# comment and blank lines in the denylist are not terms
check allow 'comment line is not a term' "$(bash_in "$PUB" 'gh issue create -t x -b "private terms -- lines starting"')"

# no awk: deny, do not crash quiet
mkdir -p "$SCRATCH/noawk"; for b in jq cat dirname mktemp rm sed grep tr git head; do ln -s "$(command -v $b)" "$SCRATCH/noawk/$b"; done
out=$(bash_in "$PUB" 'gh issue create -t x -b hi' | PATH="$SCRATCH/noawk" /bin/sh "$HOOK" 2>&1); LAST=$out
if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: awk absent should deny: $out"; fi
reason 'names awk as missing'        'awk missing'

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

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
# check <deny|allow> <desc> <json> [state-repo]
# An "allow" can come back empty (nothing to say) or as an explicit
# permissionDecision:allow carrying updatedInput (the home-path sanitizer) --
# both count as allow.
check() {
  local want=$1 desc=$2 json=$3 state=${4:-$CLAUDE_STATE_REPO} out got
  out=$(printf '%s' "$json" | CLAUDE_STATE_REPO="$state" sh "$HOOK" 2>&1)
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then got=deny
  elif [ -z "$out" ] || printf '%s' "$out" | grep -q '"permissionDecision":"allow"'; then got=allow
  else got=invalid; fi
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL (want %s, got %s): %s\n' "$want" "$got" "$desc"
    [ -n "$out" ] && printf '  hook output: %s\n' "$out"
  fi
  LAST=$out
}
reason() { if printf '%s' "$LAST" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -Fq -- "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL (reason lacks [%s]): %s\n  %s\n' "$2" "$1" "$LAST"; fi; }
no_reason() { if printf '%s' "$LAST" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -Fq -- "$2"; then fail=$((fail + 1)); printf 'FAIL (reason has [%s]): %s\n  %s\n' "$2" "$1" "$LAST"; else pass=$((pass + 1)); fi; }
updated_field() { printf '%s' "$LAST" | jq -r ".hookSpecificOutput.updatedInput$1 // empty"; }

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

# --- labels a session may not apply -----------------------------------------------
# churn-ok waives the churn gate, so it is a human's to apply. Denied as
# a label, never as prose, and `gh api` is a second parsing path of its
# own.
check deny 'add-label churn-ok'      "$(bash_in "$PUB" 'gh pr edit 12 --add-label churn-ok')"
reason 'names the label'             'churn-ok'
# The one bypass a review actually found: the compare folds case, and
# GitHub label names are unique case-insensitively, so CHURN-OK reaches it.
check deny 'add-label CHURN-OK'      "$(bash_in "$PUB" 'gh pr edit 12 --add-label CHURN-OK')"
check deny 'churn-ok through gh api' "$(bash_in "$PUB" 'gh api repos/mark-brannan/dotfiles/issues/12/labels -f "labels[]=churn-ok"')"
check allow 'another label is fine'  "$(bash_in "$PUB" 'gh pr edit 12 --add-label ready')"
check allow 'the label named in a body' "$(bash_in "$PUB" 'gh pr comment 12 -b "this needs the churn-ok label"')"

# --- the gate is loud when it cannot see ------------------------------------------
check deny '-F - with no heredoc'    "$(bash_in "$PUB" 'cat notes.md | gh issue create -t x -F -')"
reason 'says stdin'                  'stdin'
check allow '-F - with a clean heredoc' "$(bash_in "$PUB" 'gh issue create -t x -F - <<EOF
all public
EOF')"
check deny 'body from $(...)'        "$(bash_in "$PUB" 'gh issue create -t x -b "$(cat notes.md)"')"
reason 'says it is built at run time' 'run time'
check deny 'body from $VAR, no heredoc' "$(bash_in "$PUB" 'gh pr comment 3 --body "$body"')"
check allow 'inline $(cat <<EOF) clean' "$(bash_in "$PUB" 'gh pr create -t x --body "$(cat <<'"'"'EOF'"'"'
nothing private
EOF
)"')"
check deny 'inline $(cat <<EOF) with a term' "$(bash_in "$PUB" 'gh pr create -t x --body "$(cat <<'"'"'EOF'"'"'
seen aboard Wanderlust
EOF
)"')"
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
# Single quotes make $ and ` ordinary characters: a body with markdown code
# spans or a literal $(...) is text the gate read, not a value it cannot see.
check allow 'backticks in a single-quoted body'  "$(bash_in "$PUB" "gh pr comment 3 -b 'Fixed in \`abc123\`, see \`prose-budget\`.'")"
check allow 'literal $(...) single-quoted'       "$(bash_in "$PUB" "gh issue create -t x -b 'run \$(date) yourself'")"
check deny  'backticks in a double-quoted body'  "$(bash_in "$PUB" 'gh pr comment 3 -b "Fixed in `git rev-parse HEAD`"')"
check deny  'term inside a single-quoted body'   "$(bash_in "$PUB" "gh pr comment 3 -b 'Fixed on \`Wanderlust\`.'")"

check deny 'missing --body-file'     "$(bash_in "$PUB" "gh issue create -t x -F $SCRATCH/absent.md")"
reason 'names the file'              'absent.md'
check allow 'missing --body-file, private repo' "$(bash_in "$PUB" "gh issue create --repo $PRIVATE -t x -F $SCRATCH/absent.md")"

# A file the same command writes from a heredoc does not exist yet, but its
# text does: the heredoc body is in the command the gate scanned. Denying it
# forced every session to split the write and the post into two Bash calls.
check allow 'heredoc writes the --body-file it posts' "$(bash_in "$PUB" "cat > $SCRATCH/later.md <<'EOF'
all public here
EOF
gh api -X POST repos/mark-brannan/dotfiles/pulls/1/comments -F body=@$SCRATCH/later.md")"
check deny  'heredoc-written --body-file still scanned' "$(bash_in "$PUB" "cat > $SCRATCH/later2.md <<'EOF'
hello from Wanderlust
EOF
gh api -X POST repos/mark-brannan/dotfiles/pulls/1/comments -F body=@$SCRATCH/later2.md")"
reason 'names the term'              'Wanderlust'
check allow 'heredoc tees the --body-file it posts' "$(bash_in "$PUB" "tee $SCRATCH/later3.md <<'EOF' >/dev/null
all public here
EOF
gh issue create -t x --body-file $SCRATCH/later3.md")"
check deny  'heredoc writes some other path' "$(bash_in "$PUB" "cat > $SCRATCH/other.md <<'EOF'
all public here
EOF
gh issue create -t x --body-file $SCRATCH/absent.md")"
reason 'names the file'              'absent.md'

# The exemption is the gate's weakest point: it says "that file will hold the
# heredoc body I read". Two ways that stops being true, both denied.
# 1. `<<` inside a heredoc BODY is body text, not a redirect: content the
#    command merely quotes must never be able to name a path as vouched for.
check deny 'decoy <<  inside a heredoc body' "$(bash_in "$PUB" "cat > $SCRATCH/dummy.txt <<'EOF'
noop > $SCRATCH/payload.md <<X
EOF
printf 'aboard Wanderlust' > $SCRATCH/payload.md
gh issue create -t test --body-file $SCRATCH/payload.md")"
reason 'names the file'              'payload.md'
# 2. A genuine heredoc write, then mutated again before the post: the gate
#    read the body, not the append.
check deny 'heredoc write then appended to' "$(bash_in "$PUB" "cat > $SCRATCH/mut.md <<'EOF'
public safe text
EOF
echo 'seen on Wanderlust' >> $SCRATCH/mut.md
gh pr comment 5 --body-file $SCRATCH/mut.md")"
reason 'names the file'              'mut.md'

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

# --- narrow scan: a path in the command is read, never posted -------------------
# Three false positives found in transcripts (2026-09-12): a `cd` prefix, a
# --body-file under a scratchpad path, and an unrecognised --comment-file --
# all denied because the raw command line, not just what gets posted, used
# to be scanned wholesale, and a scratchpad path under $HOME collides with
# the home-directory denylist term. A denylist naming the real $HOME proves
# the fix -- without it these commands never would have tripped either way.
HOMETERMS="$SCRATCH/hometerms"; mkdir -p "$HOMETERMS/.git" "$HOMETERMS/state/global"
printf '%s\n' "$HOME" > "$HOMETERMS/state/global/private-terms.txt"

check allow 'cd prefix: the path is not posted text' \
  "$(bash_in "$PUB" "cd $HOME/worktrees/xyz && gh issue comment 3 -b 'ready for review'")" "$HOMETERMS"

printf 'a clean scratchpad body\n' > "$HOME/scratch-body.md"
check allow '--body-file under a scratchpad path: content is read, path is not' \
  "$(bash_in "$PUB" "gh issue create -t x --body-file $HOME/scratch-body.md")" "$HOMETERMS"

printf 'a clean scratchpad comment\n' > "$HOME/scratch-comment.md"
check allow '--comment-file is now a recognised file flag' \
  "$(bash_in "$PUB" "gh issue comment 3 --comment-file $HOME/scratch-comment.md")" "$HOMETERMS"
check deny '--comment-file with a term in its content still denies' \
  "$(printf 'seen aboard Wanderlust\n' > "$SCRATCH/comment-term.md"; bash_in "$PUB" "gh issue comment 3 --comment-file $SCRATCH/comment-term.md")"
reason 'names the term' 'Wanderlust'

# --- fail closed: an unrecognised flag that looks like it carries text ----------
check deny 'unrecognised body/comment/message-shaped flag refuses loudly' \
  "$(bash_in "$PUB" 'gh issue comment 3 --response-body-file /tmp/x')"
reason 'names the flag' '--response-body-file'
reason 'says it does not recognise the shape' "doesn't recognise its shape"
check deny 'unrecognised flag, gh api'          "$(bash_in "$PUB" 'gh api repos/o/r/issues -f title=x --long-comment-blob=hi')"
check allow 'a boolean flag with no text is not "unrecognised"' \
  "$(bash_in "$PUB" 'gh pr merge 12 --squash --delete-branch')"
check allow 'an unrecognised text-shaped flag on the private repo is not scanned' \
  "$(bash_in "$PUB" "gh issue comment 3 --repo $PRIVATE --response-body-file /tmp/x")"

# --- home path in genuinely-posted text: sanitize and allow, not deny -----------
check allow 'home path in a posted body is rewritten to ~, not denied' \
  "$(bash_in "$PUB" "gh issue comment 3 -b 'repro: cd $HOME/project && make'")" "$HOMETERMS"
newcmd=$(updated_field '.command')
case "$newcmd" in
  *"$HOME"*) fail=$((fail + 1)); echo "FAIL: updatedInput still carries the literal home path: $newcmd" ;;
  *'~/project'*) pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); echo "FAIL: updatedInput missing the ~ substitution: $newcmd" ;;
esac

check allow 'MCP: home path in a posted body is rewritten to ~' \
  "$(mcp_in mcp__github__add_issue_comment "{\"owner\":\"o\",\"repo\":\"r\",\"issue_number\":3,\"body\":\"repro under $HOME/project\"}")" "$HOMETERMS"
newbody=$(updated_field '.body')
case "$newbody" in
  *"$HOME"*) fail=$((fail + 1)); echo "FAIL: MCP updatedInput still carries the literal home path: $newbody" ;;
  *'~/project'*) pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); echo "FAIL: MCP updatedInput missing the ~ substitution: $newbody" ;;
esac

# a body-file's own content is not fixable by rewriting the command -- the
# file on disk still carries the real path -- so that stays a denial.
printf 'repro under %s/project\n' "$HOME" > "$SCRATCH/home-in-file.md"
check deny 'home path inside a --body-file stays a denial' \
  "$(bash_in "$PUB" "gh issue create -t x --body-file $SCRATCH/home-in-file.md")" "$HOMETERMS"

# a longer path that merely starts with $HOME is not $HOME: a substring
# replace would corrupt it (~2 resolves to a different user at execution
# time). Scar: caught in PR review on dotfiles#184.
check deny 'a longer path starting with $HOME is not sanitized' \
  "$(bash_in "$PUB" "gh issue comment 3 -b 'see ${HOME}2/notes for details'")" "$HOMETERMS"
reason 'still cites the term, unfixed -- ~2 is a different user, not $HOME' "$HOME"

# same failure mode with a hyphenated sibling directory instead of a digit --
# '-' must be in the "still part of the same name" class too, not just
# alnum/underscore. Scar: caught in PR review on dotfiles#184, round 2.
check deny 'a hyphenated sibling path starting with $HOME is not sanitized' \
  "$(bash_in "$PUB" "gh issue comment 3 -b 'see ${HOME}-backup/notes for details'")" "$HOMETERMS"
reason 'still cites the term, unfixed -- a hyphenated sibling is not $HOME' "$HOME"

# home path plus an unrelated real private term: still denied -- fixing the
# home path alone would not make the post safe.
MIXEDTERMS="$SCRATCH/mixedterms"; mkdir -p "$MIXEDTERMS/.git" "$MIXEDTERMS/state/global"
printf '%s\nWanderlust\n' "$HOME" > "$MIXEDTERMS/state/global/private-terms.txt"
check deny 'home path plus another private term: still denied' \
  "$(bash_in "$PUB" "gh issue comment 3 -b 'seen aboard Wanderlust, path $HOME/x'")" "$MIXEDTERMS"
reason 'still names the other term' 'Wanderlust'

# no awk: deny, do not crash quiet
mkdir -p "$SCRATCH/noawk"; for b in jq cat dirname mktemp rm sed grep tr git head; do ln -s "$(command -v $b)" "$SCRATCH/noawk/$b"; done
out=$(bash_in "$PUB" 'gh issue create -t x -b hi' | PATH="$SCRATCH/noawk" /bin/sh "$HOOK" 2>&1); LAST=$out
if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: awk absent should deny: $out"; fi
reason 'names awk as missing'        'awk missing'

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

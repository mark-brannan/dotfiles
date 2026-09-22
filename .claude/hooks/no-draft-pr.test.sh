#!/usr/bin/env bash
# Tests for no-draft-pr.sh. Run: bash .claude/hooks/no-draft-pr.test.sh
#
# The cases that matter are the false positives: this guard blocked PR #34
# twice for commit messages and PR bodies that merely mentioned --draft.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/no-draft-pr.sh"
pass=0
fail=0

# check <expect deny|allow> <description> <json input>
check() {
  local want=$1 desc=$2 json=$3 out got
  out=$(printf '%s' "$json" | bash "$HOOK" 2>&1)
  if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then
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

bash_input() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

# --- must deny -------------------------------------------------------------
check deny 'long flag' "$(bash_input 'gh pr create --draft --title x')"
check deny 'short flag' "$(bash_input 'gh pr create -d -t x')"
check deny 'shorthand cluster' "$(bash_input 'gh pr create -dw')"
check deny '--draft=true' "$(bash_input 'gh pr create --draft=true')"
check deny 'after a separator' "$(bash_input 'git push && gh pr create --draft')"
check deny 'flag after quoted body' \
  "$(bash_input 'gh pr create --body "some body text" --draft')"
check deny 'MCP tool draft:true' \
  "$(jq -n '{tool_name:"github__create_pull_request",tool_input:{draft:true}}')"

# --- must allow ------------------------------------------------------------
check allow 'plain create' "$(bash_input 'gh pr create --title x --body y')"
check allow 'gh pr ready' "$(bash_input 'gh pr ready 34')"
check allow 'MCP tool draft:false' \
  "$(jq -n '{tool_name:"github__create_pull_request",tool_input:{draft:false}}')"
check allow 'MCP tool no draft key' \
  "$(jq -n '{tool_name:"github__create_pull_request",tool_input:{title:"x"}}')"

# The regressions: --draft as prose, not as a flag.
check allow 'commit message mentioning the flag' \
  "$(bash_input 'git commit -m "hook: block gh pr create --draft"')"
check allow 'PR body documenting the guard' \
  "$(bash_input 'gh pr create --title "guard" --body "denies --draft PRs"')"
check allow 'single-quoted body' \
  "$(bash_input "gh pr create --body 'we never use --draft here'")"
check allow 'body-file value named like the flag' \
  "$(bash_input 'gh pr create -F --draft-notes.md')"
check allow 'title value is literally --draft' \
  "$(bash_input 'gh pr create --title --draft')"
check allow '--draft=false' "$(bash_input 'gh pr create --draft=false')"
check allow 'value-taking shorthand cluster (-bd is body=d)' \
  "$(bash_input 'gh pr create -bd')"
check allow 'draft flag belongs to a different command' \
  "$(bash_input 'gh pr create --title x; some-other-tool --draft')"
check allow 'echoing the flag name' \
  "$(bash_input 'echo "gh pr create --draft is blocked"')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

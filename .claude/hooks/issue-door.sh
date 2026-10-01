#!/bin/sh
# One GitHub issue create, transfer or delete per human turn; never two in
# one call, never one in a loop. An issue number is an identifier things link
# to where no agent can see, so minting or moving one is a one-way door
# (Solace, 2026-09-30). `issue-door.sh prompt` on UserPromptSubmit opens the
# door; the next identifier write spends it. A gate: it fails closed.
set -u
p=$(cat)
deny() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"issue-door: %s"}}\n' "$1"; exit 0; }
command -v jq >/dev/null 2>&1 || { case $p in *[Ii]ssue*) deny "jq is missing, so this call could not be checked" ;; esac; exit 0; }
door="${TMPDIR:-/tmp}/claude-issue-door.$(printf '%s' "$p" | jq -r '.session_id // "none"' | tr -c 'A-Za-z0-9_\n-' _)"
[ "${1:-}" = prompt ] && { : > "$door"; exit 0; }
tool=$(printf '%s' "$p" | jq -r '.tool_name // ""')
cmd=$(printf '%s' "$p" | jq -r '.tool_input.command // ""'); cl=$(printf '%s\n' "$cmd" | tr ';&|(`' '\n')
gh='^[[:space:]]*((do|then|else|time|command|exec|xargs.*)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*gh[[:space:]]+'
case $tool in
  Bash)
    n=$(printf '%s\n' "$cl" | grep -cE "${gh}issue[[:space:]]+(create|new|transfer|delete)([[:space:]]|\$)")
    r=$(printf '%s\n' "$cl" | grep -E "${gh}api[[:space:]].*repos/[^/[:space:]]+/[^/[:space:]]+/issues/?([\"'[:space:]]|\$)" | grep -vE -- '(-X|--method)[[:space:]=]*GET' \
      | grep -cE -- '(-X|--method)[[:space:]=]*POST|[[:space:]](-f|-F|--field|--raw-field|--input)([[:space:]=]|$)')
    g=0; printf '%s\n' "$cl" | grep -qE "${gh}api[[:space:]]+graphql" && g=$(printf '%s\n' "$cmd" | grep -oE '(create|transfer|delete)Issue[[:space:]]*\(' | wc -l)
    n=$((n + r + g)) ;;
  mcp__*__create_issue|mcp__*__transfer_issue|mcp__*__delete_issue) n=1 ;;
  mcp__*__issue_write) n=$(printf '%s' "$p" | jq -r 'if .tool_input.method == "create" then 1 else 0 end') ;;
  *) n=0 ;;
esac
[ "$n" -gt 0 ] || exit 0
[ "$n" -gt 1 ] && deny "$n issue creates, transfers or deletes in one call. One per human turn, never a batch."
printf '%s\n' "$cl" | grep -qE '(^|[[:space:]])(for|while|until|xargs|parallel)([[:space:]]|$)' && deny "an issue create, transfer or delete inside a loop. One per human turn, never a batch."
rm "$door" 2>/dev/null || deny "the door is shut. One issue create, transfer or delete per human turn, and this turn's is spent or the human has not spoken since. Show the human the draft and wait for their yes."

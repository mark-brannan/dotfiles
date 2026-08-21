#!/usr/bin/env bash
# Denies creating a pull request in draft state, whichever tool creates it.
#
# Why: the cloud harness's own system prompt says "create the pull request
# as a draft", so prose in CLAUDE.md/rules is a rule competing with the
# harness's rule and loses often enough to matter. Drafts get no automated
# review (CodeRabbit and claude-review both skip them) and stall waiting for
# a manual ready-flip that keeps not happening. The rule lives in
# ~/.claude/rules/code.md ("PR ownership: never a draft, never red"); this
# hook is its enforcement.
#
# Deny, don't rewrite: a deny reason is fed back to the model, which retries
# the same call with draft off. That works identically for the GitHub MCP
# tool (draft parameter) and gh CLI (--draft flag).
set -euo pipefail

input=$(cat)

# Without jq we cannot parse the request. Fail open: this guard protects a
# convenience (review latency), not a secret -- a draft that slips through is
# visible and repairable with `gh pr ready`, unlike the gates that fail
# closed. Denying every PR creation because jq is missing would be worse.
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')

jq_deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r}}'
  exit 0
}

case "$tool" in
  *__create_pull_request)
    draft=$(printf '%s' "$input" | jq -r '.tool_input.draft // false')
    if [ "$draft" = "true" ]; then
      jq_deny "Blocked by ~/.claude/hooks/no-draft-pr.sh: PRs are never opened as drafts (see ~/.claude/rules/code.md, 'PR ownership'). Drafts skip CodeRabbit/claude-review and stall waiting for a ready-flip. Retry the same create_pull_request call with draft:false (or omit draft). Do not ask the user; this is settled."
    fi
    ;;
  Bash)
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
    case "$cmd" in
      *"gh pr create"*)
        case "$cmd" in
          *--draft*|*"-d "*)
            jq_deny "Blocked by ~/.claude/hooks/no-draft-pr.sh: PRs are never opened as drafts (see ~/.claude/rules/code.md, 'PR ownership'). Rerun the same gh pr create without --draft. Do not ask the user; this is settled."
            ;;
        esac
        ;;
      *"gh pr ready"*)
        # Allowed: this is the repair path for a draft that slipped through.
        ;;
    esac
    ;;
esac

exit 0

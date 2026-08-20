#!/usr/bin/env bash
# Blocks subscribe_pr_activity once this session's context has grown past the
# point where watching is cheaper than starting fresh.
#
# Why: subscribing is free while idle, but every wake re-sends the session's
# whole accumulated context as cache-read input, and the session only grows
# from there. A watcher armed at 30k tokens is cheap; the same watcher armed
# at 150k pays that 150k back on every comment, every check, for the life of
# the PR. Past the threshold the fire-and-forget path is strictly cheaper:
# push, open the PR, end the turn, archive the chat, pick the PR up fresh.
#
# This is the enforcement half of the "Babysitting a PR is cheap; polling for
# it is not" rule in ~/.claude/rules/code.md, which was prose-only and so was
# only followed when it happened to be in context.
#
# Token count is not passed to hooks directly. It is derived the same way
# statusline-metrics.sh derives it: the last assistant `usage` block in the
# transcript, whose input + cache_read + cache_creation is the context that
# request actually carried. Only the tail is scanned -- transcripts run to
# tens of MB and the newest usage record is always near the end.
set -uo pipefail

LIMIT=${CLAUDE_PR_WATCH_TOKEN_LIMIT:-100000}

input=$(cat)

# No jq means no measurement; fail open rather than blocking blind.
command -v jq >/dev/null 2>&1 || exit 0

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null)
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

ctx=$(tail -n 500 "$transcript" 2>/dev/null | jq -s -r '
  [ .[] | select(.type == "assistant") | .message.usage
    | select(. != null)
    | ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
       + (.cache_creation_input_tokens // 0)) ]
  | (max // 0)' 2>/dev/null) || exit 0

case "$ctx" in ''|*[!0-9]*) exit 0 ;; esac
[ "$ctx" -ge "$LIMIT" ] || exit 0

k=$((ctx / 1000))
limk=$((LIMIT / 1000))

jq -n --arg r "Blocked by ~/.claude/hooks/no-late-pr-subscribe.sh: this session is at ~${k}k tokens, at or over the ~${limk}k watch threshold. Every wake on this subscription would re-send that whole context, and it only grows from here. Take the fire-and-forget path instead: push, open the PR (draft, no reviewer), then end the turn with the follow-up prompt that would resume the work, plus \"You should archive this chat now. It's at ~${k}k tokens.\" No webhook, no wake -- pick the PR up fresh in a new session." '
  {hookSpecificOutput: {
     hookEventName: "PreToolUse",
     permissionDecision: "deny",
     permissionDecisionReason: $r}}'
exit 0

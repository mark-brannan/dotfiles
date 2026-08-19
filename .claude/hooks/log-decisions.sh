#!/usr/bin/env bash
# Appends the session's report line to a decision log, on Stop.
#
# Why: CLAUDE.md's Gates section asks for one fenced line at genuine gates
# and checkpoints -- `⛁ <tokens left> · <decisions this session> · gate:
# <type>` -- so decision load can be counted from a file instead of
# reconstructed from memory (the Decision load section is explicit that
# memory is unreliable here). This hook is the enforcement half; the prose
# rule alone gives nothing to count.
#
# Reads only the LAST assistant message in the transcript, so a marker from
# an earlier turn in the same session is never re-logged on a later Stop.
set -euo pipefail

input=$(cat)
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')

[ -z "$tp" ] && exit 0
[ -f "$tp" ] && : || exit 0

line=$(jq -rs '
  [.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text]
  | last // ""
' "$tp" 2>/dev/null | grep -o '⛁.*' | tail -1 || true)

[ -z "$line" ] && exit 0

tokens=$(printf '%s' "$line" | sed -E 's/^⛁ *([^·]*)·.*/\1/' | sed -E 's/^ +| +$//g')
decisions=$(printf '%s' "$line" | sed -E 's/^⛁[^·]*· *([^·]*)·.*/\1/' | sed -E 's/^ +| +$//g')
gate=$(printf '%s' "$line" | sed -E 's/.*gate: *//' | sed -E 's/^ +| +$//g')

[ -z "$gate" ] && exit 0

# Land the log in the private state repo when it's cloned, since decision
# summaries are session content and dotfiles is public. Fall back to
# ~/.claude/journal (gitignored) so a machine without the repo still keeps
# its own copy rather than dropping the line.
log_dir="$HOME/claude_prompts_scratch/state/global"
[ -d "$HOME/claude_prompts_scratch/.git" ] || log_dir="$HOME/.claude/journal"
mkdir -p "$log_dir"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -nc \
  --arg ts "$ts" --arg sid "$sid" --arg gate "$gate" \
  --arg summary "$decisions" --arg tokens "$tokens" \
  '{ts:$ts, session_id:$sid, gate:$gate, summary:($summary | .[0:140]), tokens_remaining:$tokens}' \
  >> "$log_dir/decisions.jsonl"

exit 0

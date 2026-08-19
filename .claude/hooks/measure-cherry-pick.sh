#!/usr/bin/env bash
# Logs cherry-picks, one JSON line each, so the cost of shuttling commits
# between branches can be counted instead of guessed.
#
# Fires on PostToolUse for Bash and returns immediately unless the command
# actually committed something. The matcher is the tool NAME -- an earlier
# version used "Bash(git commit.*)", which is permission-rule syntax, so as
# a regex it required a tool literally named "Bashgit commit..." and the
# hook never fired once. Filter on the command here, not in the matcher.
#
# Only real cherry-picks are logged. Logging every commit would make this a
# commit log wearing a cherry-pick label, and the signal is the whole point.
set -euo pipefail

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')
[ "$tool" = "Bash" ] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
printf '%s' "$cmd" | grep -qE '\bgit\b.*\b(commit|cherry-pick)\b' || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

commit=$(git rev-parse HEAD 2>/dev/null || echo "")
[ -n "$commit" ] || exit 0

msg=$(git log -1 --format=%B "$commit" 2>/dev/null || echo "")
printf '%s' "$msg" | grep -q "^(cherry picked from commit" || exit 0

original=$(printf '%s' "$msg" | sed -n 's/^(cherry picked from commit \([a-f0-9]*\).*/\1/p' | head -1)
repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "$cwd")")
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# Same placement rule as log-decisions.sh: metrics are session content, and
# dotfiles is public. Fall back to a gitignored local dir when the private
# state repo isn't cloned on this machine.
log_dir="$HOME/claude_prompts_scratch/state/global"
[ -d "$HOME/claude_prompts_scratch/.git" ] || log_dir="$HOME/.claude/metrics"
mkdir -p "$log_dir"

jq -nc \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg repo "$repo" --arg branch "$branch" \
  --arg commit "$commit" --arg original "$original" \
  '{ts:$ts, repo:$repo, branch:$branch, commit:$commit, original_commit:$original}' \
  >> "$log_dir/cherry-picks.jsonl"

exit 0

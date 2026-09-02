#!/usr/bin/env bash
# Appends a timestamped line for any Bash command containing "ssh " to the
# private claude_prompts_scratch state repo, so a host touched over ssh
# leaves a durable trail even if the session never writes it up elsewhere.
#
# An ssh command can carry a real hostname, IP, or flag worth keeping out of
# a public repo's tracked files -- same reasoning as log-commit.sh, which
# this mirrors. Written per-repo under state/hosts/ so it's still obvious
# which project a line came from.
#
# Fires on PostToolUse for Bash. Best-effort: never blocks the session.
set -euo pipefail

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')
[ "$tool" = "Bash" ] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
printf '%s' "$cmd" | grep -q 'ssh ' || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$cwd")
repo=$(basename "$root")

# Same placement rule as log-commit.sh: this is potentially sensitive
# content, and the project repo it came from may be public. Fall back to a
# gitignored local dir when the private state repo isn't cloned here.
log_dir="$HOME/claude_prompts_scratch/state/hosts"
[ -d "$HOME/claude_prompts_scratch/.git" ] || log_dir="$HOME/.claude/journal/hosts"
mkdir -p "$log_dir"

printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$cmd" >> "$log_dir/$repo-commands.log"

exit 0

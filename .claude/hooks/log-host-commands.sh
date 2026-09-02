#!/usr/bin/env bash
# Appends a timestamped line for any Bash command containing "ssh " to
# intermediate_files/claude_slop/host-commands.log in the current repo, so a
# host touched over ssh leaves a durable trail even if the session never
# writes it up elsewhere.
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
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

log_dir="$root/intermediate_files/claude_slop"
mkdir -p "$log_dir"

printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$cmd" >> "$log_dir/host-commands.log"

exit 0

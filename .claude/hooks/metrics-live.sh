#!/usr/bin/env bash
# Recompute the session's metrics NOW and cache them where the statusline can
# read them without paying for the computation itself.
#
# Why a cache file at all: `session-metrics.jq` slurps the whole transcript,
# which is fine once at Stop but not on every statusline render (those fire
# several times a second). So the expensive part runs only on the events that
# actually change the numbers -- a prompt, a question put to Mark, a git
# event -- and the statusline just prints what is already on disk.
#
# One file per session, keyed by session_id: parallel sessions are normal
# here, and per-session paths mean two of them never write the same file.
# The rollup that merges them (`metrics/metrics.json`) is *generated*, never
# hand-merged, so a push can't conflict on it in a way that needs resolving.
#
# stdin: any hook payload carrying transcript_path/session_id/cwd.
# Always exits 0.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-state.sh
. "$HOOK_DIR/lib-state.sh"

command -v jq >/dev/null 2>&1 || exit 0

EVENT="${1:-tool}"          # prompt | question | git | stop | statusline
MAX_AGE="${2:-0}"           # seconds; >0 means "skip if cache is fresher"

input=$(cat 2>/dev/null || echo '{}')
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // .workspace.current_dir // empty')
[ -n "$tp" ] && [ -f "$tp" ] && [ -n "$sid" ] || exit 0
[ -n "$cwd" ] || cwd=$PWD

# A git event means an actual git-state change, not every Bash call: the jq
# pass is too expensive to run after `ls`.
if [ "$EVENT" = git ]; then
  printf '%s' "$input" \
    | jq -r '.tool_input.command // .tool_name // ""' \
    | grep -qE '\bgit\s+(commit|push|merge|rebase|cherry-pick|checkout|switch|tag)\b|create_pull_request' \
    || exit 0
fi

JQPROG="$HOOK_DIR/session-metrics.jq"
[ -f "$JQPROG" ] || exit 0

LIVE="$(state_dir)/metrics/live"
OUT="$LIVE/$sid.json"

# Throttle: the statusline asks constantly, events ask rarely. An event
# always recomputes; the statusline only does so if the cache has gone stale.
if [ "$MAX_AGE" -gt 0 ] && [ -f "$OUT" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$OUT" 2>/dev/null || stat -f %m "$OUT" 2>/dev/null || echo 0) ))
  [ "$age" -lt "$MAX_AGE" ] && exit 0
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
work_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "")
work_repo=$([ -n "$work_root" ] && basename "$work_root" || basename "$cwd")
work_branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

metrics=$(jq -s \
  --arg sid "$sid" --arg repo "$work_repo" --arg branch "$work_branch" \
  --arg cwd "$cwd" --arg now "$now" \
  -f "$JQPROG" "$tp" 2>/dev/null) || exit 0
[ -n "$metrics" ] || exit 0

# Git state, the part that decides whether the chat is safe to kill.
dirty=0; unpushed=0; ncommits=0
if [ -n "$work_root" ]; then
  dirty=$(git -C "$work_root" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  unpushed=$(git -C "$work_root" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
  started=$(printf '%s' "$metrics" | jq -r '.session.started_at // empty')
  ncommits=$(git -C "$work_root" rev-list --count \
    --since="${started:-1 day ago}" HEAD 2>/dev/null || echo 0)
fi

mkdir -p "$LIVE" 2>/dev/null || exit 0
tmp="$OUT.$$"
printf '%s\n' "$metrics" | jq -c \
  --arg ev "$EVENT" --arg now "$now" \
  --argjson d "${dirty:-0}" --argjson u "${unpushed:-0}" --argjson c "${ncommits:-0}" \
  '.session + {last_event: $ev, updated_at: $now,
               dirty: $d, unpushed: $u, commits: $c}' > "$tmp" 2>/dev/null \
  && mv -f "$tmp" "$OUT" 2>/dev/null || rm -f "$tmp" 2>/dev/null
exit 0

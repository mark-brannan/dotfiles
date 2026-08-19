#!/usr/bin/env bash
# Regenerate metrics/metrics.json from the per-session files.
#
# Generated, never edited: two sessions pushing at once both regenerate the
# same derived file from conflict-free per-session inputs, so a rebase can
# always take "theirs" and re-run this. That is the collision handling --
# there is no merge to get wrong.
set -uo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-state.sh
. "$HOOK_DIR/lib-state.sh"
command -v jq >/dev/null 2>&1 || exit 0

M="$(state_dir)/metrics"
[ -d "$M" ] || exit 0
files=$(ls "$M"/sessions/*.json "$M"/live/*.json 2>/dev/null) || exit 0
[ -n "$files" ] || exit 0

# A finished session (sessions/) wins over its own live snapshot.
# shellcheck disable=SC2086
jq -s '
  map(select(.session_id != null))
  | group_by(.session_id)
  | map( (map(select(.ended_at != null and .last_event == null)) | last)
         // (sort_by(.updated_at // .ts // "") | last) )
  | sort_by(.started_at // "")
  | {generated_at: (max_by(.updated_at // .ts // "").updated_at // ""),
     sessions: .,
     totals: {
       sessions: length,
       output_tokens: (map(.output_tokens // 0) | add),
       tool_calls:   (map(.tool_calls // 0) | add),
       decisions:    (map(.decisions.total // 0) | add),
       gates:        (map(.decisions.gate // 0) | add)
     }}' $files > "$M/metrics.json.$$" 2>/dev/null \
  && mv -f "$M/metrics.json.$$" "$M/metrics.json" 2>/dev/null \
  || rm -f "$M/metrics.json.$$" 2>/dev/null
exit 0

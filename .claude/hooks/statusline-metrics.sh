#!/usr/bin/env bash
# statusLine: the always-on readout. Reads the cache `metrics-live.sh` wrote;
# recomputes only when that cache has gone stale, so the jq pass over the
# transcript happens on the order of once per 15s rather than per render.
#
# Free in context terms: statusline output is never sent to the model.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-state.sh
. "$HOOK_DIR/lib-state.sh"

input=$(cat 2>/dev/null || echo '{}')
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0

printf '%s' "$input" | bash "$HOOK_DIR/metrics-live.sh" statusline 15

F="$(state_dir)/metrics/live/$sid.json"
[ -f "$F" ] || { printf '⛁ warming up'; exit 0; }

jq -r '
  def k: if . >= 1000 then "\(. / 1000 | floor)k" else "\(.)" end;
  [ "⛁ \(.repo)@\(.branch // "?")",
    "◆ \(.decisions.total) dec (\(.decisions.scoping)s/\(.decisions.inline)i/\(.decisions.gate)g)",
    "↑ \(.output_tokens | k) out · ctx \(.context_peak | k)",
    "⇢ \(.user_turns)p/\(.tool_calls)t",
    (if .commits > 0 or .dirty > 0 or .unpushed > 0
     then "⎇ \(.commits)c" + (if .dirty > 0 then " \(.dirty)~" else "" end)
                            + (if .unpushed > 0 then " \(.unpushed)↑unpushed" else "" end)
     else empty end)
  ] | join("  ")' "$F" 2>/dev/null || printf '⛁ —'

#!/usr/bin/env bash
# Recompute the session's metrics NOW and cache them where the statusline can
# read them without paying for the computation itself.
#
# Why a cache file at all: `session-metrics.jq` slurps the whole transcript,
# which is fine a few times a turn but not on every statusline render (those
# fire several times a second). The statusline just prints what is already on
# disk, and recomputes only past its own staleness age.
#
# Three wirings, and only three: UserPromptSubmit (silent readout, may carry a
# crossing line), Stop and SubagentStop. It used to be wired to nine events,
# eight of them with `show`, which meant a jq pass over the transcript after
# every single tool call and a readout that spoke often enough to be tuned
# out. That is a level-triggered nag. What replaced it is the crossing engine
# below: a line fires once, when a threshold is first crossed, and then says
# nothing until the next line.
#
# One file per session, keyed by session_id: parallel sessions are normal
# here, and per-session paths mean two of them never write the same file.
# The rollup that merges them (`metrics/metrics.json`) is *generated* and
# gitignored -- it is never committed, so there is no shared file for two
# sessions to collide on. See metrics-rollup.sh.
#
# stdin: any hook payload carrying transcript_path/session_id/cwd.
# Always exits 0.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-state.sh
. "$HOOK_DIR/lib-state.sh"

command -v jq >/dev/null 2>&1 || exit 0

EVENT_ARG="${1:-}"          # explicit override; only statusline and tests pass this now
MAX_AGE="${2:-0}"           # seconds; >0 means "skip if cache is fresher"
SHOW="${3:-}"               # "show" -> also print a systemMessage block

# ---------------------------------------------------- counters and their lines
# Every threshold in this file is here, and every one is overridable. A line
# fires once, when the counter first crosses it this session, and then says
# nothing until the next line up -- edge-triggered, not level-triggered.
#
#   context   size and a verdict; "propose stopping" from CONTEXT_STOP_AT up
#   sitting   elapsed, context, verdict -- and the clock starts over when the
#             gap between two prompts runs past SIT_GAP_MIN, because a session
#             picked up after dinner is a new sitting, not a nine-hour one
#   friction  corrections and rebukes inside a window of human turns; the one
#             line that goes to the model rather than to the screen, since the
#             standing orders' capacity rule is what it is asking for
#   gate      gate decisions pushed to the user, every GATE_EVERY
NAG_CONTEXT_LINES="${METRICS_CONTEXT_LINES:-100000 150000 200000}"
NAG_CONTEXT_STOP_AT="${METRICS_CONTEXT_STOP_AT:-150000}"
NAG_SIT_EVERY_MIN="${METRICS_SIT_EVERY_MIN:-60}"
NAG_SIT_GAP_MIN="${METRICS_SIT_GAP_MIN:-30}"
NAG_FRICTION_N="${METRICS_FRICTION_N:-3}"
NAG_FRICTION_TURNS="${METRICS_FRICTION_TURNS:-20}"
NAG_GATE_EVERY="${METRICS_GATE_EVERY:-5}"
# Local hour from which a Stop on an archivable session is worth interrupting.
NAG_STOP_HOUR="${METRICS_STOP_HOUR:-22}"

# One jq for all three fields: the statusline reaches this code on every
# render, and three spawns before the staleness check was most of its cost.
input=$(cat 2>/dev/null || echo '{}')
IFS=$'\t' read -r tp sid cwd hook_name <<<"$(printf '%s' "$input" | jq -r \
  '[(.transcript_path // ""), (.session_id // ""),
    (.cwd // .workspace.current_dir // ""),
    (.hook_event_name // "")] | @tsv')"
[ -n "$tp" ] && [ -f "$tp" ] && [ -n "$sid" ] || exit 0
[ -n "$cwd" ] || cwd=$PWD

# Default EVENT to hook_event_name verbatim, lowercased, so a new hook
# needs no matching entry here.
if [ -n "$EVENT_ARG" ]; then
  EVENT="$EVENT_ARG"
else
  EVENT=$(printf '%s' "${hook_name:-tool}" | tr '[:upper:]' '[:lower:]')
fi

# `show` on UserPromptSubmit would make the readout model context rather than
# display, every turn. The crossing lines below still reach the screen there;
# it is the whole block that stays suppressed.
case "$EVENT" in prompt|userpromptsubmit|statusline) SHOW="" ;; esac

# A git event means an actual git-state change, not every Bash call: the jq
# pass is too expensive to run after `ls`. The set is git_event_re in
# lib-state.sh -- shared with measure-git-events.sh so the counter and the
# display can never disagree about what counts. Both fields are tested, not
# one falling back to the other: an MCP tool has no `.command`, and a Bash
# call whose command does not match must not then match on the tool name.
if [ "$EVENT" = git ]; then
  printf '%s' "$input" \
    | jq -r '[(.tool_input.command // ""), (.tool_name // "")] | join("\n")' \
    | grep -qE "$(git_event_re)" \
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
dirty=0; unpushed=0; ncommits=0; start_sha=""
if [ -n "$work_root" ]; then
  dirty=$(git -C "$work_root" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  unpushed=$(git -C "$work_root" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
  # Commits counted from the SHA this session started at, not by timestamp.
  # `--since=<start>` counts everything in the window whatever wrote it, so a
  # fresh clone whose history landed today reports a session's commits as 13
  # when it made none -- and a number that is persistently wrong on screen is
  # worse than no number, because you stop reading the field.
  start_sha=$(jq -r '.start_sha // ""' "$OUT" 2>/dev/null)
  [ -n "$start_sha" ] \
    || start_sha=$(git -C "$work_root" rev-parse HEAD 2>/dev/null || echo "")
  if [ -n "$start_sha" ]; then
    ncommits=$(git -C "$work_root" rev-list --count "$start_sha..HEAD" 2>/dev/null || echo 0)
  fi
fi

mkdir -p "$LIVE" 2>/dev/null || exit 0

# --------------------------------------------------------- break-time tracking
# Store last-activity timestamp. If gap >= 25 min since last activity, auto-reset
# break timer. Else accumulate time since last break across sessions.
ACTIVITY_FILE="$(state_dir)/metrics/last_activity.json"
mkdir -p "$(dirname "$ACTIVITY_FILE")" 2>/dev/null || true
now_ts=$(date +%s)
time_since_break_seconds=0

if [ -f "$ACTIVITY_FILE" ]; then
  last_activity_ts=$(jq -r '.last_activity_timestamp // 0' "$ACTIVITY_FILE" 2>/dev/null || echo 0)
  last_break_ts=$(jq -r '.last_break_timestamp // 0' "$ACTIVITY_FILE" 2>/dev/null || echo 0)

  # If we have a last activity time, check the gap
  if [ "$last_activity_ts" -gt 0 ]; then
    gap=$((now_ts - last_activity_ts))
    # 25 minutes = 1500 seconds
    if [ "$gap" -ge 1500 ]; then
      # Gap is long enough to count as a break -- reset the timer
      last_break_ts=$now_ts
    fi
  fi

  # Calculate time since last break
  if [ "$last_break_ts" -gt 0 ]; then
    time_since_break_seconds=$((now_ts - last_break_ts))
  fi
fi

# Update activity file with new timestamps. Both fields take the max of what
# we computed and whatever is on disk now: parallel sessions on this machine
# read and write this file independently, so between the read above and this
# write another session may have recorded newer activity or a later break.
# Taking the max makes concurrent writers idempotent instead of letting the
# last one to finish drag the break timer backwards.
cur_json=$(jq -c '{last_activity_timestamp, last_break_timestamp}' \
  "$ACTIVITY_FILE" 2>/dev/null) || cur_json='{}'
[ -n "$cur_json" ] || cur_json='{}'
jq -n --argjson la "$now_ts" --argjson lb "${last_break_ts:-0}" \
  --argjson c "$cur_json" \
  '{last_activity_timestamp: ([$la, ($c.last_activity_timestamp // 0)] | max),
    last_break_timestamp:    ([$lb, ($c.last_break_timestamp    // 0)] | max)}' \
  > "$ACTIVITY_FILE.$$" 2>/dev/null \
  && mv -f "$ACTIVITY_FILE.$$" "$ACTIVITY_FILE" 2>/dev/null || rm -f "$ACTIVITY_FILE.$$" 2>/dev/null

tmp="$OUT.$$"
printf '%s\n' "$metrics" | jq -c \
  --arg ev "$EVENT" --arg now "$now" \
  --argjson d "${dirty:-0}" --argjson u "${unpushed:-0}" --argjson c "${ncommits:-0}" \
  --arg sha "$start_sha" --argjson tsb "$time_since_break_seconds" \
  '.session + {last_event: $ev, updated_at: $now, start_sha: $sha,
               dirty: $d, unpushed: $u, commits: $c, time_since_break_seconds: $tsb}' > "$tmp" 2>/dev/null \
  && mv -f "$tmp" "$OUT" 2>/dev/null || rm -f "$tmp" 2>/dev/null

# =========================================================== crossing engine
# Edge-triggered. State lives in one small file per session next to the cache;
# it is NOT the cache, because stop-continuity.sh deletes the cache at the end
# of a session and the crossings have to outlive it.
NAGF="$LIVE/$sid.nag.json"
CROSSD="$(state_dir)/metrics/crossings"

ctx_line=0; time_line=0; gate_line=0; fric_tripped=0
sit_start=0; last_prompt=0; since_nag=0; resume_ts=0; nag_pending=0
if [ -f "$NAGF" ]; then
  IFS=$'\t' read -r ctx_line time_line gate_line fric_tripped \
                    sit_start last_prompt since_nag resume_ts nag_pending \
    <<<"$(jq -r '[(.context_line // 0), (.time_line // 0), (.gate_line // 0),
                  (if .friction_tripped then 1 else 0 end),
                  (.sitting_start // 0), (.last_prompt // 0),
                  (if .since_nag then 1 else 0 end),
                  (.resume_ts // 0),
                  (if .nag_pending then 1 else 0 end)] | @tsv' "$NAGF" 2>/dev/null)"
fi
for v in ctx_line time_line gate_line fric_tripped sit_start last_prompt \
         since_nag resume_ts nag_pending; do
  [ -n "${!v}" ] || eval "$v=0"
done

save_nag() {
  jq -n --argjson cl "$ctx_line" --argjson tl "$time_line" --argjson gl "$gate_line" \
        --argjson ft "$fric_tripped" --argjson ss "$sit_start" --argjson lp "$last_prompt" \
        --argjson sn "$since_nag" --argjson rt "$resume_ts" --argjson np "$nag_pending" \
    '{context_line: $cl, time_line: $tl, gate_line: $gl,
      friction_tripped: ($ft == 1), sitting_start: $ss, last_prompt: $lp,
      since_nag: ($sn == 1), resume_ts: $rt, nag_pending: ($np == 1)}' \
    > "$NAGF.$$" 2>/dev/null \
    && mv -f "$NAGF.$$" "$NAGF" 2>/dev/null || rm -f "$NAGF.$$" 2>/dev/null
}

# Only the three wired events drive the engine. The statusline reaches this
# file too, several times a minute, and must never consume a crossing.
is_prompt=0; run_engine=0
case "$EVENT" in
  prompt|userpromptsubmit)   is_prompt=1; run_engine=1 ;;
  stop|subagentstop)         run_engine=1 ;;
esac

kfmt() { awk -v n="$1" 'BEGIN { if (n >= 1000) printf "%dk", int(n / 1000); else printf "%d", n }'; }
hm()   { awk -v m="$1" 'BEGIN { if (m >= 60) printf "%dh%02d", int(m / 60), m % 60; else printf "%dm", m }'; }
hhmm() { date -d "@$1" +%H:%M 2>/dev/null || date -r "$1" +%H:%M 2>/dev/null || echo "??:??"; }

sys_lines=""; model_line=""
add_line() { sys_lines="${sys_lines:+$sys_lines
}$1"; }
record_crossing() {
  mkdir -p "$CROSSD" 2>/dev/null || return 0
  jq -nc --arg sid "$sid" --arg now "$now" --arg kind "$1" \
         --argjson at "$2" --arg text "$3" \
    '{session_id: $sid, ts: $now, kind: $kind, at: $at, text: $text}' \
    >> "$CROSSD/$sid.jsonl" 2>/dev/null || true
}

if [ "$run_engine" -eq 1 ]; then
  # The sitting clock. Only a prompt moves it: the gap that matters is the one
  # between two things the user typed, not between two tool calls.
  if [ "$is_prompt" -eq 1 ]; then
    if [ "$last_prompt" -gt 0 ] \
       && [ $((now_ts - last_prompt)) -gt $((NAG_SIT_GAP_MIN * 60)) ]; then
      sit_start=$now_ts
      time_line=0
    fi
    last_prompt=$now_ts
  fi
  [ "$sit_start" -gt 0 ] || sit_start=$now_ts

  IFS=$'\t' read -r ctx gates fric_win <<<"$(printf '%s\n' "$metrics" | jq -r \
    --argjson w "$NAG_FRICTION_TURNS" \
    '(.session.user_turns // 0) as $t
     | [ (.session.context_peak // 0),
         (.session.decisions.gate // 0),
         ([ .friction[]?
            | select(.type == "correction" or .type == "rebuke")
            | select((.turn_ordinal // 0) > ($t - $w)) ] | length) ] | @tsv')"
  [ -n "${ctx:-}" ] || ctx=0
  [ -n "${gates:-}" ] || gates=0
  [ -n "${fric_win:-}" ] || fric_win=0

  # context -- lines ascending, so a jump past two of them reports both, in order
  for L in $NAG_CONTEXT_LINES; do
    if [ "$ctx" -ge "$L" ] && [ "$L" -gt "$ctx_line" ]; then
      if [ "$L" -ge "$NAG_CONTEXT_STOP_AT" ]; then verdict="propose stopping"
      else verdict="still room"; fi
      t="⛁ context $(kfmt "$ctx") — past $(kfmt "$L"): $verdict."
      add_line "$t"; record_crossing context "$L" "$t"
      ctx_line=$L; since_nag=1
    fi
  done

  # sitting clock
  if [ "$NAG_SIT_EVERY_MIN" -gt 0 ]; then
    sit_min=$(( (now_ts - sit_start) / 60 ))
    n=$(( sit_min / NAG_SIT_EVERY_MIN * NAG_SIT_EVERY_MIN ))
    if [ "$n" -ge "$NAG_SIT_EVERY_MIN" ] && [ "$n" -gt "$time_line" ]; then
      if [ "$n" -ge $((NAG_SIT_EVERY_MIN * 2)) ]; then verdict="stop here"
      else verdict="stand up"; fi
      t="⏱ sitting $(hm "$n") — context $(kfmt "$ctx"): $verdict."
      add_line "$t"; record_crossing time "$n" "$t"
      time_line=$n; since_nag=1
    fi
  fi

  # gate decisions
  if [ "$NAG_GATE_EVERY" -gt 0 ]; then
    n=$(( gates / NAG_GATE_EVERY * NAG_GATE_EVERY ))
    if [ "$n" -ge "$NAG_GATE_EVERY" ] && [ "$n" -gt "$gate_line" ]; then
      t="⚖ $gates gate decisions this session — front-load or card the rest."
      add_line "$t"; record_crossing gate "$n" "$t"
      gate_line=$n
    fi
  fi

  # friction -- measured in human turns, so only a prompt can trip it, and it
  # is addressed to the model, which is the thing the capacity rule asks of.
  if [ "$is_prompt" -eq 1 ] && [ "$fric_tripped" -ne 1 ] \
     && [ "$fric_win" -ge "$NAG_FRICTION_N" ]; then
    model_line="$fric_win corrections or rebukes in the last $NAG_FRICTION_TURNS turns. Apply the capacity rule from the standing orders, once."
    record_crossing friction "$fric_win" "$model_line"
    fric_tripped=1; since_nag=1
  fi
fi

# ---------------------------------------------------------------- Stop nag
# Fires on a real Stop only -- hook_event_name, not the event argument, so a
# preview or a test harness asking for the `stop` readout never blocks a turn.
#
# "archivable" is the verdict that the chat can be closed without losing
# anything: clean worktree, nothing unpushed, the state repo's own commits
# pushed, and the branch either has an open PR or is named by a pointer card.
_to() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }
archivable() {
  [ "${dirty:-0}" -eq 0 ] || return 1
  [ "${unpushed:-0}" -eq 0 ] || return 1
  local sr n c
  sr=$(state_repo 2>/dev/null) || sr=""
  if [ -n "$sr" ]; then
    n=$(git -C "$sr" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    [ "${n:-0}" -eq 0 ] || return 1
  fi
  [ -n "$work_root" ] || return 1
  case "$work_branch" in main|master|HEAD|"") return 0 ;; esac
  if command -v gh >/dev/null 2>&1; then
    c=$( (cd "$work_root" 2>/dev/null \
          && _to 10 gh pr list --head "$work_branch" --state open --json number \
               --jq 'length') 2>/dev/null )
    [ "${c:-0}" -gt 0 ] 2>/dev/null && return 0
  fi
  [ -n "$sr" ] && grep -qF -- "$work_branch" "$sr/state/global/kanban.md" 2>/dev/null \
    && return 0
  return 1
}

if [ "$hook_name" = Stop ]; then
  if [ "$nag_pending" -eq 1 ]; then
    # The block above has been answered; the resume block exists now.
    resume_ts=$now_ts; nag_pending=0; since_nag=0; save_nag
    add_line "Archivable. Resume block written $(hhmm "$resume_ts"). Next time: \`/resume\`."
  elif archivable; then
    local_hour=$(date +%H); local_hour=${local_hour#0}
    late=0
    [ "${local_hour:-0}" -ge "$NAG_STOP_HOUR" ] && late=1
    # since_nag is armed by a context or time crossing and by the friction
    # counter tripping, and disarmed by the nag. The hour arms it only while
    # no resume block exists yet -- otherwise every Stop after 22:00 would
    # block again, which is the level-triggered nag this replaced.
    if [ "$since_nag" -eq 1 ] \
       || { [ "$late" -eq 1 ] && [ "$resume_ts" -eq 0 ]; }; then
      nag_pending=1; save_nag
      printf '{"decision":"block","reason":%s}\n' \
        "$(json_str "Write the resume block.")"
      exit 0
    fi
    # Nothing new to say. Later Stops carry the block's age and nothing else.
    if [ "$resume_ts" -gt 0 ]; then
      add_line "Resume block $(hm $(( (now_ts - resume_ts) / 60 ))) old."
    fi
  fi
fi

[ "$run_engine" -eq 1 ] && save_nag

# The crossing lines reach the user on every wired event; the friction line is
# the one that reaches the model, and only on UserPromptSubmit, where a hook
# can add context at all.
if [ -n "$sys_lines" ] || [ -n "$model_line" ]; then
  if [ "$is_prompt" -eq 1 ]; then
    jq -nc --arg s "$sys_lines" --arg a "$model_line" \
      '(if $s == "" then {} else {systemMessage: $s} end)
       + (if $a == "" then {}
          else {hookSpecificOutput: {hookEventName: "UserPromptSubmit",
                                     additionalContext: $a}} end)'
    exit 0
  fi
fi

# ------------------------------------------------------------ event block
# Shown to the user at the end of a turn -- never sent to the model, so the
# running decision count costs nothing to display. Any crossing line rides on
# the front of it rather than arriving as a second message.
if [ "$SHOW" = show ] && [ -f "$OUT" ]; then
  # night_nag needs Pacific time, not the host's TZ -- an ephemeral/cloud
  # session usually runs UTC, which read as "LATE!" all evening. Compute the
  # US/Pacific UTC offset here (handles PST/PDT) and hand it to jq as seconds,
  # since jq has no timezone database of its own.
  TZOFF=$(TZ="America/Los_Angeles" date +%z | awk '{
    sign = (substr($0,1,1) == "-") ? -1 : 1
    hh = substr($0,2,2) + 0
    mm = substr($0,4,2) + 0
    print sign * (hh * 3600 + mm * 60)
  }')
  export TZOFF
  jq -c -L "$HOOK_DIR" --arg x "$sys_lines" \
    'include "lib-metrics-fmt";
     {systemMessage: (if $x == "" then block else $x + "\n" + block end)}' \
    "$OUT" 2>/dev/null
elif [ -n "$sys_lines" ]; then
  jq -nc --arg s "$sys_lines" '{systemMessage: $s}'
fi
exit 0

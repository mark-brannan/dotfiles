#!/usr/bin/env bash
# PreToolUse hook: when a Bash call runs `npm publish`, run it here instead
# and hand Solace the browser auth URL directly -- push notification, or the
# terminal when there's no notifier -- rather than have Claude relay the
# command back for her to run by hand.
#
# Why this exists: her npm account uses browser passkey 2FA (see
# ~/.claude/rules/code.md, "Publishing"). `npm publish` prints the approval
# URL to stdout mid-run, and that's one of the strings the harness redacts
# before a Bash tool result reaches Claude -- so today Claude can only hand
# her the bare command and ask her to run it herself. This hook runs the
# real shell command itself, outside that channel, and sees the URL
# unredacted the moment npm prints it.
#
# Convenience, not a gate: any doubt at all (jq/awk/lib missing, payload
# unreadable, can't background the process) falls through to `exit 0` and
# Claude runs `npm publish` itself exactly as before -- URL redacted, manual
# rule intact. Nothing here ever blocks a publish that this hook can't
# handle; it only ever short-circuits ones it *can*.
#
# One publish in flight per working directory. A second `npm publish`
# detected from the same cwd while the first hasn't returned (npm is still
# waiting on browser approval, most likely) is denied again pointing at the
# same pid/log rather than started a second time. The lock is a pidfile;
# dead pid or older than LOCK_STALE_SECS and it's reclaimed as stale.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LIB="$HERE/lib-shell-words.awk"
STATE_DIR="${CLAUDE_NPM_PUBLISH_STATE:-$HOME/.local/state/claude-npm-publish}"
POLL_SECS="${CLAUDE_NPM_PUBLISH_POLL_SECS:-12}"
LOCK_STALE_SECS="${CLAUDE_NPM_PUBLISH_STALE_SECS:-1800}"

command -v jq  >/dev/null 2>&1 || exit 0
command -v awk >/dev/null 2>&1 || exit 0
[ -r "$LIB" ] || exit 0

input=$(cat) || exit 0
[ "$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)" = Bash ] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -n "$cmd" ] || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd=$PWD

# Structural match, not a substring test: any segment -- top level, or
# nested inside a quoted `sh -c`/`eval` body -- whose command word is npm
# and whose first non-flag argument is `publish`. Reuses the scanner
# no-draft-pr.sh's family already fixed false positives on (a commit
# message or PR body that merely *mentions* "npm publish" doesn't match).
match=$(printf '%s\n' "$cmd" | awk "$(cat "$LIB")"'
function is_publish(a, b,   i) {
  for (i = a; i <= b; i++) {
    if (k[i] != "w") return 0
    if (w[i] ~ /^-/) continue
    return w[i] == "publish"
  }
  return 0
}
function segment(a, b, nested,   c) {
  c = cmd_index(w, k, a, b, "(^|/)npm$", nested, "")
  if (c && is_publish(c + 1, b)) { print "MATCH"; exit }
}
{ buf = buf $0 "\n" }
END {
  buf = strip_heredocs(buf)
  nt = texts_of(buf, texts, nested)
  for (x = 1; x <= nt; x++) {
    n = scan(texts[x], w, k, q)
    a = 1
    for (i = 1; i <= n + 1; i++) {
      if (i <= n && k[i] != ";") continue
      if (a < i) segment(a, i - 1, nested[x])
      a = i + 1
    }
  }
}' 2>/dev/null)
[ "$match" = MATCH ] || exit 0

deny() {
  jq -cn --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# Key the lock on cwd, not the command text -- two differently-worded
# publish commands from the same directory still hit the same npm account's
# browser 2FA prompt, and running both at once serves nobody.
key=$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)
pidfile="$STATE_DIR/$key.pid"
logfile="$STATE_DIR/$key.log"

running_pid() {
  [ -f "$pidfile" ] || return 1
  local p age mtime
  p=$(cat "$pidfile" 2>/dev/null) || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null || return 1
  mtime=$(stat -c %Y "$pidfile" 2>/dev/null || stat -f %m "$pidfile" 2>/dev/null || echo 0)
  age=$(( $(date +%s) - mtime ))
  [ "$age" -le "$LOCK_STALE_SECS" ]
}

if running_pid; then
  deny "npm publish for $cwd is already running in the background (pid $(cat "$pidfile"), log $logfile), started by an earlier call this hook intercepted. Don't run it again -- tail $logfile for progress, or check \`npm view <pkg> dist-tags\` once it's had time to land. If a browser approval was needed, the URL already went to Solace directly."
fi

: > "$logfile"
( setsid bash -c "$cmd" >"$logfile" 2>&1 </dev/null & echo $! > "$pidfile" ) &
disown 2>/dev/null || true

# Give npm a little time to print the auth URL before we return control --
# this window is not the whole publish, just the part where npm decides
# whether it needs browser approval and prints the URL if so. The upload
# and the approval itself proceed after we return, in the background.
url=""
end=$(( $(date +%s) + POLL_SECS ))
while [ "$(date +%s)" -lt "$end" ]; do
  url=$(grep -Eo 'https://[^[:space:]]+' "$logfile" 2>/dev/null | head -n1)
  [ -n "$url" ] && break
  sleep 0.5
done

# Best-effort on every channel available: a desktop notifier if one exists,
# and -- because that's the one channel guaranteed not to be redacted or
# routed back through Claude -- the controlling terminal directly. Silently
# a no-op on a cloud/headless session with no tty and no notifier; that's
# fine, this account's 2FA implies a human at a machine to begin with.
notify() {
  local msg=$1
  command -v notify-send >/dev/null 2>&1 && notify-send "npm publish" "$msg" 2>/dev/null
  command -v osascript >/dev/null 2>&1 &&
    osascript -e "display notification \"$msg\" with title \"npm publish\"" >/dev/null 2>&1
  { printf '\n\a[npm publish] %s\n' "$msg" >/dev/tty; } 2>/dev/null
  true
}

if [ -n "$url" ]; then
  notify "Approve at: $url"
  deny "npm publish for $cwd is running in the background (pid $(cat "$pidfile"), log $logfile). The auth URL was pushed to Solace directly (notification/terminal) -- it never reaches you, by design; don't ask her for it or try to print it yourself. Wait for her to approve in the browser, then confirm with \`npm view <pkg> dist-tags\`."
else
  notify "publish started, no auth URL seen in ${POLL_SECS}s -- check $logfile"
  deny "npm publish for $cwd is running in the background (pid $(cat "$pidfile"), log $logfile); no auth URL showed up within ${POLL_SECS}s -- it may not need one this time, or be slow to print. Don't re-run it -- tail $logfile, or ask Solace to check her notifications/terminal."
fi

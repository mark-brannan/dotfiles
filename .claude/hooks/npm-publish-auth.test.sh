#!/usr/bin/env bash
# Tests for npm-publish-auth.sh. Run: bash .claude/hooks/npm-publish-auth.test.sh
#
# A stub `npm` on PATH stands in for the real CLI: it prints an auth URL (or
# not) and exits, so the round trip -- background, poll the log, deny with
# the right reason -- is exercised without touching a real registry.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/npm-publish-auth.sh"
pass=0
fail=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STUBBIN="$WORK/bin"
mkdir -p "$STUBBIN"
export PATH="$STUBBIN:$PATH"
export CLAUDE_NPM_PUBLISH_POLL_SECS=2
export CLAUDE_NPM_PUBLISH_STALE_SECS=1800

stub_npm() {  # stub_npm <url-or-empty>
  local url=${1:-}
  cat >"$STUBBIN/npm" <<EOF
#!/bin/sh
if [ "\$1" = publish ]; then
  sleep 0.2
$([ -n "$url" ] && printf '  echo "Authenticate at: %s"\n' "$url")
fi
exit 0
EOF
  chmod +x "$STUBBIN/npm"
}
stub_npm 'https://www.npmjs.com/auth/cli/deadbeef'

bash_input() {  # bash_input <command> <cwd>
  jq -n --arg c "$1" --arg d "$2" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}'
}

decision() {
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null
}
reason() {
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null
}

check_allow() {
  local desc=$1 json=$2 out
  export CLAUDE_NPM_PUBLISH_STATE="$WORK/state-$RANDOM"
  out=$(printf '%s' "$json" | bash "$HOOK" 2>&1)
  if [ -z "$out" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL (want allow, got output): %s\n  hook output: %s\n' "$desc" "$out"
  fi
}

check_deny() {  # check_deny <desc> <json> [grep-pattern for the reason]
  local desc=$1 json=$2 want_grep=${3:-} out d
  export CLAUDE_NPM_PUBLISH_STATE="$WORK/state-$RANDOM"
  out=$(printf '%s' "$json" | bash "$HOOK" 2>&1)
  d=$(decision "$out")
  if [ "$d" != deny ]; then
    fail=$((fail + 1))
    printf 'FAIL (want deny, got %s): %s\n  hook output: %s\n' "$d" "$desc" "$out"
    return
  fi
  if [ -n "$want_grep" ] && ! printf '%s' "$(reason "$out")" | grep -qi "$want_grep"; then
    fail=$((fail + 1))
    printf 'FAIL (deny reason missing %s): %s\n  reason: %s\n' "$want_grep" "$desc" "$(reason "$out")"
    return
  fi
  pass=$((pass + 1))
}

# --- must not match: not npm publish at all --------------------------------
check_allow 'npm install' "$(bash_input 'npm install' "$WORK/proj-1")"
check_allow 'npm run publish (script name, not the subcommand)' \
  "$(bash_input 'npm run publish' "$WORK/proj-2")"
check_allow 'prose mentioning it in a commit message' \
  "$(bash_input 'git commit -m "docs: explain npm publish flow"' "$WORK/proj-3")"
check_allow 'other tool' \
  "$(jq -n --arg d "$WORK/proj-4" '{tool_name:"Read",tool_input:{file_path:"/x"},cwd:$d}')"

# --- must match and run in the background ----------------------------------
check_deny 'plain npm publish' "$(bash_input 'npm publish' "$WORK/proj-5")" 'running in the background'
check_deny 'npm publish with flags' \
  "$(bash_input 'npm publish --access public' "$WORK/proj-6")" 'running in the background'
check_deny 'compound command ending in npm publish' \
  "$(bash_input 'cd pkg && npm publish' "$WORK/proj-7")" 'running in the background'
check_deny 'npm publish inside sh -c' \
  "$(bash_input 'sh -c "npm publish"' "$WORK/proj-8")" 'running in the background'

# --- the auth URL reaches the log and the deny reason, never the model ----
d="$WORK/proj-9"
export CLAUDE_NPM_PUBLISH_STATE="$WORK/state-url"
out=$(bash_input 'npm publish' "$d" | bash "$HOOK" 2>&1)
sleep 0.3
key=$(printf '%s' "$d" | cksum | cut -d' ' -f1)
log="$WORK/state-url/$key.log"
if grep -q 'https://www.npmjs.com/auth/cli/deadbeef' "$log" 2>/dev/null; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  printf 'FAIL: auth URL never reached the background log\n  log: %s\n' "$(cat "$log" 2>/dev/null)"
fi
if printf '%s' "$(reason "$out")" | grep -q 'https://'; then
  fail=$((fail + 1))
  printf 'FAIL: the deny reason handed back to the model contains the raw URL\n  reason: %s\n' "$(reason "$out")"
else
  pass=$((pass + 1))
fi

# --- a second call while the first is still running is denied, not doubled -
stub_npm ''  # this run never prints a URL and never exits on its own signal;
             # replaced below with a long sleep so the lock is still held.
cat >"$STUBBIN/npm" <<'EOF'
#!/bin/sh
[ "$1" = publish ] && sleep 30
exit 0
EOF
chmod +x "$STUBBIN/npm"
d2="$WORK/proj-10"
export CLAUDE_NPM_PUBLISH_STATE="$WORK/state-lock"
out1=$(bash_input 'npm publish' "$d2" | bash "$HOOK" 2>&1)
out2=$(bash_input 'npm publish' "$d2" | bash "$HOOK" 2>&1)
if [ "$(decision "$out2")" = deny ] && printf '%s' "$(reason "$out2")" | grep -qi 'already running'; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  printf 'FAIL: a second publish from the same cwd was not recognized as already running\n  reason: %s\n' "$(reason "$out2")"
fi
# clean up the long-sleeping stub so it doesn't outlive the test run
pkill -f 'npm publish' 2>/dev/null || true

echo "npm-publish-auth: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Tests for npm-publish-bg. Run: bash .local/bin/npm-publish-bg.test.sh
#
# A stub `npm` on PATH stands in for the real CLI -- it prints whatever the
# case needs and exits -- so the round trip (background, watch the log,
# notify out of band, report the pid) runs without touching a registry.
# A stub `notify-send` records what the notifier was handed, which is how
# the "the URL goes out of band and never to stdout" claim is checked.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/npm-publish-bg"
pass=0
fail=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STUB="$WORK/bin"
mkdir -p "$STUB"
export PATH="$STUB:$PATH"
export NPM_PUBLISH_BG_WAIT=3

NOTIFY_LOG="$WORK/notified"
cat >"$STUB/notify-send" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$NOTIFY_LOG"
EOF
chmod +x "$STUB/notify-send"

stub_npm() {  # stub_npm <script body for the publish case>
  cat >"$STUB/npm" <<EOF
#!/bin/sh
[ "\$1" = publish ] || exit 0
$1
EOF
  chmod +x "$STUB/npm"
}

ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); printf 'FAIL: %s\n  %s\n' "$1" "${2-}"; }

run() {  # run <cwd> [args...] -> sets OUT, RC; fresh state + notify log
  local dir=$1; shift
  : >"$NOTIFY_LOG"
  export NPM_PUBLISH_BG_STATE="$WORK/state"
  mkdir -p "$dir"
  OUT=$(cd "$dir" && "$SCRIPT" "$@" 2>&1)
  RC=$?
}

# --- an auth URL is pushed out of band, never returned on stdout ----------
URL='https://www.npmjs.com/auth/cli/deadbeef-0000'
stub_npm "sleep 0.2; echo 'npm notice Authenticate your account at:'; echo '$URL'; sleep 5"
run "$WORK/pkg-a"
[ "$RC" = 0 ] || bad "publish with auth URL should exit 0" "rc=$RC out=$OUT"
[ "$RC" = 0 ] && ok

if grep -q "$URL" <<<"$OUT"; then
  bad "the auth URL must never reach stdout" "$OUT"
else ok; fi

if grep -q "$URL" "$NOTIFY_LOG"; then ok
else bad "the auth URL should reach the notifier" "$(cat "$NOTIFY_LOG")"; fi

if grep -q 'running in the background' <<<"$OUT"; then ok
else bad "stdout should report the background run" "$OUT"; fi

# --- npm's own domain wins over an unrelated URL printed first ------------
stub_npm "echo 'npm notice registry https://registry.example.invalid/'; echo '$URL'; sleep 5"
run "$WORK/pkg-b"
if grep -q "$URL" "$NOTIFY_LOG" && ! grep -q 'example.invalid' "$NOTIFY_LOG"; then ok
else bad "npmjs.com URL should be preferred over an earlier unrelated one" "$(cat "$NOTIFY_LOG")"; fi

# --- no URL at all: still reports, does not hang past the wait window -----
stub_npm "sleep 0.2; echo '+ pkg@1.0.0'"
run "$WORK/pkg-c"
if [ "$RC" = 0 ]; then ok; else bad "a publish needing no approval should exit 0" "rc=$RC"; fi
if grep -q 'No approval URL' <<<"$OUT"; then ok
else bad "stdout should say no approval URL appeared" "$OUT"; fi

# --- one publish per directory -------------------------------------------
stub_npm "sleep 30"
run "$WORK/pkg-d"
if [ "$RC" = 0 ]; then ok; else bad "first publish should start" "rc=$RC"; fi
first_pid=$(cat "$NPM_PUBLISH_BG_STATE"/*.pid 2>/dev/null | head -n1)

run "$WORK/pkg-d"
if [ "$RC" != 0 ] && grep -q 'already running' <<<"$OUT"; then ok
else bad "a second publish from the same cwd should be refused" "rc=$RC out=$OUT"; fi
[ -n "$first_pid" ] && kill "$first_pid" 2>/dev/null

# --- a dead pid's lock is reclaimed --------------------------------------
stub_npm "sleep 0.2; echo '+ pkg@1.0.0'"
run "$WORK/pkg-e"
sleep 1  # let it finish so its pid is gone
run "$WORK/pkg-e"
if [ "$RC" = 0 ]; then ok
else bad "a lock whose process has died should be reclaimed" "rc=$RC out=$OUT"; fi

# --- a different directory is not blocked by another's lock --------------
stub_npm "sleep 30"
run "$WORK/pkg-f"
held=$(cat "$NPM_PUBLISH_BG_STATE"/*.pid 2>/dev/null | head -n1)
run "$WORK/pkg-g"
if [ "$RC" = 0 ]; then ok
else bad "a lock is per-directory, not global" "rc=$RC out=$OUT"; fi
[ -n "$held" ] && kill "$held" 2>/dev/null

# --- extra arguments reach npm -------------------------------------------
ARGS_LOG="$WORK/args"
stub_npm "printf '%s\n' \"\$*\" >'$ARGS_LOG'; echo '+ pkg@1.0.0'"
run "$WORK/pkg-h" --access public --tag next
sleep 0.5
if grep -q -- '--access public --tag next' "$ARGS_LOG" 2>/dev/null; then ok
else bad "arguments should be passed through to npm publish" "$(cat "$ARGS_LOG" 2>/dev/null)"; fi

# --- no npm on PATH: a clear failure, not a silent success ----------------
rm -f "$STUB/npm"
mkdir -p "$WORK/pkg-i"
OLD=$PATH
PATH=$STUB:/nonexistent-for-this-test
OUT=$( cd "$WORK/pkg-i" && "$SCRIPT" 2>&1 )
RC=$?
PATH=$OLD
if [ "$RC" != 0 ] && grep -q 'not on PATH' <<<"$OUT"; then ok
else bad "missing npm should fail loudly" "rc=$RC out=$OUT"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

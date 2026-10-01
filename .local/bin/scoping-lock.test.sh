#!/usr/bin/env bash
# Tests for scoping-lock. Run: bash .local/bin/scoping-lock.test.sh
# What matters: a second session refuses and names the holder, on this
# machine and from another; the holder's own re-take refreshes; a stale lock
# is taken over and says whose it was; release never removes another's lock.
set -uo pipefail
SL="$(cd "$(dirname "$0")" && pwd)/scoping-lock"
pass=0; fail=0
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
export HOME="$S/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

assert() { local m=$1; shift; if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $m"; fi; }
eq() { assert "$1: expected [$2], got [$3]" test "$2" = "$3"; }
has() { assert "$1: [$3] lacks [$2]" grep -qF -- "$2" <<<"$3"; }

git init -q --bare -b main "$S/origin.git"
git clone -q "$S/origin.git" "$S/a" 2>/dev/null
mkdir -p "$S/a/state/global/curia/q"; echo record > "$S/a/state/global/curia/q/roll.md"
git -C "$S/a" add . && git -C "$S/a" commit -qm init && git -C "$S/a" push -q origin HEAD:main 2>/dev/null
git -C "$S/a" branch -q -u origin/main
git clone -q "$S/origin.git" "$S/b" 2>/dev/null
D=state/global/curia/q

A() { CLAUDE_STATE_REPO="$S/a" sh "$SL" "$@"; }
B() { CLAUDE_STATE_REPO="$S/b" sh "$SL" "$@"; }

read_at=$(A read-of "$S/a/$D/roll.md")
assert 'read-of prints a short sha' grep -qE '^[0-9a-f]{7,}$' <<<"$read_at"
echo edit >> "$S/a/$D/roll.md"
has 'read-of marks an edited record' '+dirty' "$(A read-of "$S/a/$D/roll.md")"
git -C "$S/a" checkout -q -- "$D/roll.md"

eq 'free before anyone takes it' free "$(A read "$D")"
has 'first session takes it' 'taken:' "$(A take "$D" sid-one "$S/a/$D/roll.md")"
line=$(cat "$S/a/$D/LOCK")
assert 'the lock is one line: session, time, the record commit taken after the sync' grep -qE "^sid-one [0-9T:-]+Z $read_at\$" <<<"$line"
eq 'the lock reached origin' "$line" "$(git -C "$S/a" show origin/main:"$D/LOCK")"
has 'read says live' "live sid-one" "$(A read "$D")"

out=$(A take "$D" sid-two x); rc=$?
eq 'a second session on this machine refuses' 1 "$rc"
has 'and names the holder' 'held: sid-one' "$out"

out=$(B take "$D" sid-three x); rc=$?
eq 'a session on another machine refuses' 1 "$rc"
has 'and names the holder' 'held: sid-one' "$out"

out=$(A take "$D" sid-one "$read_at"); rc=$?
eq "the holder's own re-take refreshes" 0 "$rc"

out=$(B release "$D" sid-three); rc=$?
eq "release of another's lock is refused" 1 "$rc"
assert '... and the lock stays' test -f "$S/a/$D/LOCK"

out=$(SCOPING_LOCK_STALE_SECS=0 B take "$D" sid-three x); rc=$?
eq 'a stale lock is taken over' 0 "$rc"
has 'and says whose it was' 'stale: sid-one' "$out"

has 'the holder releases' 'released:' "$(B release "$D" sid-three)"
git -C "$S/a" pull -q --rebase 2>/dev/null
eq 'released everywhere' free "$(A read "$D")"

out=$(CLAUDE_STATE_REPO="$S/none" sh "$SL" take "$D" s x 2>&1); rc=$?
eq 'no state repo fails closed' 2 "$rc"
git -C "$S/a" remote set-url origin "$S/gone.git"
out=$(A take "$D" sid-four x 2>&1); rc=$?
eq 'an unreachable origin fails closed' 2 "$rc"

echo "scoping-lock: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

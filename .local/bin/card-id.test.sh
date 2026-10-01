#!/usr/bin/env bash
# Tests for card-id. Run: bash .local/bin/card-id.test.sh
# What matters: an id is epoch seconds then the session's eight hex; a second
# mint in the same second bumps rather than repeats, including after its card
# leaves the board; show resolves an id from any section and nothing else.
set -uo pipefail
CID="$(cd "$(dirname "$0")" && pwd)/card-id"
pass=0; fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset CLAUDE_CODE_SESSION_ID
export XDG_STATE_HOME="$T/state" TMPDIR="$T" CARD_ID_BOARD="$T/kanban.md"
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL: %s\n  want [%s]\n  got  [%s]\n' "$1" "$2" "$3"; fi; }

now=$(date -u +%s)
printf '## Needs ruling\n### global\n- [ ] **Q** -- ask ([l](https://x.invalid/q)) id: %s077c62eb\n\n## Claude'"'"'s\n- [ ] **Do** -- it\n      ([l](https://x.invalid/d)) id: 1790000000aaaaaaaa\n' "$now" > "$CARD_ID_BOARD"

a=$(sh "$CID" mint 077c62eb-2979-4277-b798-0d0fd9e9bb8d); ok 'a board collision bumps the second' "$((now + 1))077c62eb" "$a"
b=$(sh "$CID" mint 077c62eb-2979); ok 'a ledger collision bumps again' "$((now + 2))077c62eb" "$b"
c=$(CLAUDE_CODE_SESSION_ID=d654192b-0000 sh "$CID" mint); ok 'another session takes its own hex' 1 "$(printf '%s' "$c" | grep -cE '^[0-9]{10}d654192b$')"
sh "$CID" mint "" >/dev/null 2>&1; ok 'no session id refuses' 2 $?
sh "$CID" mint zzzzzzzz >/dev/null 2>&1; ok 'a non-hex session refuses' 2 $?
mkdir "$TMPDIR/claude-board.lock.d"; printf 'pid=%s\nhostname=%s\n' "$$" "$(uname -n)" > "$TMPDIR/claude-board.lock.d/meta"
ok 'a live lock holder is waited on, not ignored' 124 "$(timeout 3 sh "$CID" mint 077c62eb >/dev/null 2>&1; echo $?)" 2>/dev/null
rm -rf "$TMPDIR/claude-board.lock.d"

ok 'show finds a folded card with its section' "Claude's" "$(sh "$CID" show 1790000000aaaaaaaa | cut -f1)"
ok 'show finds a ruling with its group' "global" "$(sh "$CID" show "${now}077c62eb" | cut -f2)"
sh "$CID" show 1790000000aaaaaaab >/dev/null 2>&1; ok 'an unknown id is not found' 1 $?
sh "$CID" show 179000000 >/dev/null 2>&1; ok 'a malformed id is refused' 2 $?

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

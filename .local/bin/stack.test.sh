#!/usr/bin/env bash
# Tests for stack. Run: bash .local/bin/stack.test.sh
# What matters: a push lands as a file under its own session's item; newest
# is on top and --oldest reverses it; a taken item leaves the default view
# but stays findable; nothing is ever dropped for being uncheckable.
set -uo pipefail
[ -n "${AWK_PATH:-}" ] && PATH="$AWK_PATH:$PATH"
ST="$(cd "$(dirname "$0")" && pwd)/stack"
pass=0; fail=0
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
export HOME="$S/home"; mkdir -p "$HOME"
SR="$S/state"; STACK="$SR/state/global/stack"; mkdir -p "$SR/.git" "$STACK"
export CLAUDE_STATE_REPO="$SR" CLAUDE_CODE_SESSION_ID=deadbeef-1111-2222

assert() { local m=$1; shift; if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $m"; fi; }
eq() { assert "$1: expected [$2], got [$3]" test "$2" = "$3"; }
item() {  # item <id> <updated> <status> <parent> <text>
  printf 'kind: work\nstatus: %s\nupdated: %s\nparent: %s\nsession: x\nmodel: claude-sonnet-5\nbranch: r b (1 ahead, clean)\npr: none\nwhere: w\nprompt: %s\n---\n%s\n' \
    "$3" "$2" "$4" "$5" "$5" > "$STACK/$1.md"
}
ids() { sh "$ST" "$@" | grep -oE '^ +[0-9]{4}-[0-9-]+T[0-9-]+-[0-9a-f]+$' | tr -d ' '; }

eq 'empty stack says so' 'Stack: empty' "$(sh "$ST")"

item 2026-09-01T10-00-aaaaaaaa 2026-09-01T10:00:00Z open none "oldest work"
item 2026-09-02T10-00-bbbbbbbb 2026-09-02T10:00:00Z open none "middle work"
item 2026-09-03T10-00-deadbeef 2026-09-03T10:00:00Z open none "this session's work"
eq 'newest first' '2026-09-03T10-00-deadbeef' "$(ids | head -1)"
eq '--oldest reverses' '2026-09-01T10-00-aaaaaaaa' "$(ids --oldest | head -1)"

q=$(sh "$ST" push question "is the floor enough?")
assert 'push writes a file' test -f "$STACK/$q.md"
eq 'push parents to its own session item' '2026-09-03T10-00-deadbeef' "$(sed -n 's/^parent: //p' "$STACK/$q.md")"
eq 'push text is the body' 'is the floor enough?' "$(awk 'f{print} /^---$/{f=1}' "$STACK/$q.md")"
eq 'a child prints under its parent' "$q" "$(ids | sed -n 2p)"
assert 'a bad kind is refused' bash -c "! sh '$ST' push ruling 'x' 2>/dev/null"
assert 'empty text is refused' bash -c "! sh '$ST' push said '   ' 2>/dev/null"

sh "$ST" take "$q" >/dev/null
eq 'taken leaves the default view' '' "$(ids | grep -F "$q" || true)"
eq 'taken is still there with --closed' "$q" "$(ids --closed | grep -F "$q")"
eq 'taken is findable' "$q" "$(ids find floor)"
eq 'status is written' taken "$(sed -n 's/^status: //p' "$STACK/$q.md")"
sh "$ST" open "$q" >/dev/null
eq 'open puts it back' "$q" "$(ids | grep -F "$q")"

for i in 1 2 3 4 5 6; do item "2026-09-1${i}T10-00-cccccc0$i" "2026-09-1${i}T10:00:00Z" open none "filler $i"; done
eq 'default shows five' 5 "$(ids | wc -l | tr -d ' ')"
assert 'and says how many more' bash -c "sh '$ST' | grep -q ' more '"
eq '--all shows every open item' 10 "$(ids --all | wc -l | tr -d ' ')"
assert 'show prints the file' bash -c "sh '$ST' show '$q' | grep -q '^kind: question'"
assert 'show of a missing id fails' bash -c "! sh '$ST' show nope 2>/dev/null"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

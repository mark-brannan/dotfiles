#!/usr/bin/env bash
# Tests for work-item. Run: bash .local/bin/work-item.test.sh
# What matters: an item is created in open and never twice; the six statuses
# move only along the pen transitions; a claim is refused while another live
# session holds the item and allowed once the holder has gone quiet; cost
# lines fold to a per-item total; points live on the brief.
set -uo pipefail
WI="$(cd "$(dirname "$0")" && pwd)/work-item"
pass=0; fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export WORK_ITEM_DIR="$T/items" TMPDIR="$T"
A=077c62eb-2979-4277-b798-0d0fd9e9bb8d B=9a1b2c3d-0000-0000-0000-000000000000
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL: %s\n  want [%s]\n  got  [%s]\n' "$1" "$2" "$3"; fi; }
as() { local s=$1; shift; CLAUDE_CODE_SESSION_ID=$s sh "$WI" "$@"; }
fact() { as "$A" fold "$1" | sed -n "s/^$2=//p"; }

id=$(as "$A" create --repo mark-brannan/dotfiles --model sonnet --effort medium --points 3 \
  --brief 'Measure growth per day.' 'Size the store')
ok 'the id is epoch seconds then the session hex' 1 "$(printf '%s' "$id" | grep -cE '^[0-9]{10}077c62eb$')"
f="$WORK_ITEM_DIR/$id.md"
ok 'the file is named by the id' 1 "$([ -f "$f" ] && echo 1)"
ok 'the title heads the file' '# Size the store' "$(head -1 "$f")"
ok 'the first log line is status=open with the facts' \
  "077c62eb status=open owner=agent repo=mark-brannan/dotfiles parent=- model=sonnet effort=medium" \
  "$(sed -n '/^## Log/{n;p;}' "$f" | cut -d' ' -f2-)"
ok 'created in open' open "$(fact "$id" status)"
ok 'points come from the brief' 3 "$(fact "$id" points)"
ok 'a brief at create logs briefed' 1 "$(fact "$id" briefed)"
ok 'the brief text is in the Brief section' 'Measure growth per day.' "$(sed -n '/^## Brief/,/^## Log/p' "$f" | sed -n 3p)"

as "$A" create --id "$id" 'Again' >/dev/null 2>&1; ok 'a second create of one id is refused' 1 $?
ok 'the refused create left the file alone' '# Size the store' "$(head -1 "$f")"
as "$A" create --points 4 'Bad points' >/dev/null 2>&1; ok 'points outside fibonacci refuse' 2 $?
as "$A" create --owner boss 'Bad owner' >/dev/null 2>&1; ok 'an unknown owner refuses' 2 $?
CLAUDE_CODE_SESSION_ID='' sh "$WI" create 'No session' >/dev/null 2>&1; ok 'no session id refuses' 2 $?

as "$A" claim "$id" >/dev/null 2>&1; ok 'an open item cannot be claimed' 1 $?
as "$A" log "$id" status=done >/dev/null 2>&1; ok 'open -> done is not a transition' 1 $?
as "$A" log "$id" status=ready; ok 'open -> ready' ready "$(fact "$id" status)"
n=$(wc -l < "$f"); CLAUDE_CODE_SESSION_ID='' sh "$WI" claim "$id" >/dev/null 2>&1; ok 'a claim with no session id refuses' 2 $?
ok 'the refused claim wrote no line' "$n" "$(wc -l < "$f")"

as "$B" claim "$id"; ok 'a ready item is claimed' claimed "$(fact "$id" status)"
ok 'the claimer holds it' 9a1b2c3d "$(fact "$id" holder)"
err=$(as "$A" claim "$id" 2>&1); ok 'a claim is refused while held' 1 $?
ok 'the refusal names the holder' 1 "$(printf '%s' "$err" | grep -c 'held by 9a1b2c3d')"
as "$A" log "$id" status=done >/dev/null 2>&1; ok 'a non-holder cannot move a held item' 1 $?
as "$A" release "$id" >/dev/null 2>&1; ok 'a non-holder cannot release' 1 $?
as "$A" log "$id" note=looked; ok 'a line without a status changes nothing' claimed "$(fact "$id" status)"

as "$B" log "$id" status=blocked until=dotfiles#1; ok 'claimed -> blocked keeps the holder' 9a1b2c3d "$(fact "$id" holder)"
ok 'until is a fact' dotfiles#1 "$(fact "$id" until)"
as "$A" claim "$id" >/dev/null 2>&1; ok 'a blocked item is still held' 1 $?
as "$B" release "$id"; ok 'release hands it back ready' ready "$(fact "$id" status)"
ok 'release clears the holder' '' "$(fact "$id" holder)"

as "$A" claim "$id"
as "$A" log "$id" cost tokens=812340 usd=1.42 by=grind
as "$A" log "$id" status=done home=mark-brannan/dotfiles#481
as "$B" claim "$id"; ok 'done -> claimed when acceptance finds it wanting' 9a1b2c3d "$(fact "$id" holder)"
as "$B" log "$id" cost tokens=100000 usd=0.58 by=pickup
as "$B" log "$id" status=done
as "$B" log "$id" status=closed; ok 'done -> closed' closed "$(fact "$id" status)"
ok 'cost lines fold to a token total' 912340 "$(fact "$id" cost_tokens)"
ok 'cost lines fold to a dollar total' 2 "$(fact "$id" cost_usd)"
ok 'every cost line counts' 2 "$(fact "$id" costs)"
ok 'home is a fact' mark-brannan/dotfiles#481 "$(fact "$id" home)"
as "$A" log "$id" status=ready >/dev/null 2>&1; ok 'closed -> ready is not a transition' 1 $?
as "$A" claim "$id"; ok 'closed -> claimed' 077c62eb "$(fact "$id" holder)"

# A holder that wrote nothing on the item for two hours has let go.
# Its own id: the minted one is epoch seconds, and a fast run is still in the
# second that minted $id.
old=$(as "$A" create --id 1700000000077c62eb 'Stale one')
as "$A" log "$old" status=ready
printf '2020-01-01T00:00:00Z 9a1b2c3d status=claimed\n' >> "$WORK_ITEM_DIR/$old.md"
ok 'an old claim folds stale' yes "$(fact "$old" holder_stale)"
as "$A" claim "$old"; ok 'a stale claim can be taken' 077c62eb "$(fact "$old" holder)"
ok 'a fresh claim is not stale' no "$(fact "$old" holder_stale)"

as "$A" brief "$id" 'Rewritten.'; ok 'a brief change logs briefed' 2 "$(fact "$id" briefed)"
ok 'a brief change keeps the points' 3 "$(fact "$id" points)"
ok 'a brief change keeps the log' 1 "$(grep -c 'status=closed' "$WORK_ITEM_DIR/$id.md")"
printf 'line one\n## Log\n' | as "$A" brief "$id" - >/dev/null 2>&1; ok 'a brief cannot carry a section heading' 2 $?

as "$A" show 1790000000ffffffff >/dev/null 2>&1; ok 'an unknown id is not found' 1 $?
as "$A" fold 179000 >/dev/null 2>&1; ok 'a malformed id is refused' 2 $?

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

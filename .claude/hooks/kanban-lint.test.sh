#!/usr/bin/env bash
# Tests for kanban-lint.sh. Run: bash .claude/hooks/kanban-lint.test.sh
# Set AWK_PATH to a directory whose `awk` is another implementation (mawk,
# original-awk) to run the same cases under it; CI does this for each.
#
# What matters: every rule fires by id on the right line and stays quiet on
# the lookalikes (a merged PR cited as provenance, "closed" vs "close",
# "unmerged" vs "merged"); a card's indented continuation lines count as the
# card; --file tolerates legacy headings already in HEAD; --diff judges only
# the lines this checkout added; the hook mode blocks with the same lines.
set -uo pipefail
[ -n "${AWK_PATH:-}" ] && PATH="$AWK_PATH:$PATH"

LINT="$(cd "$(dirname "$0")" && pwd)/kanban-lint.sh"
pass=0; fail=0
SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
export HOME="$SCRATCH/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# run <want rc> <desc> <args...>  -- LAST holds stdout+stderr
run() {
  local want=$1 desc=$2; shift 2
  LAST=$(sh "$LINT" "$@" 2>&1); local rc=$?
  if [ "$rc" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL (want rc %s, got %s): %s\n  %s\n' "$want" "$rc" "$desc" "$LAST"; fi
}
has()   { if printf '%s\n' "$LAST" | grep -Eq -- "$2"; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL (output lacks /%s/): %s\n  %s\n' "$2" "$1" "$LAST"; fi; }
lacks() { if printf '%s\n' "$LAST" | grep -Eq -- "$2"; then fail=$((fail+1)); printf 'FAIL (output has /%s/): %s\n  %s\n' "$2" "$1" "$LAST"; else pass=$((pass+1)); fi; }
eq()    { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL: %s\n  want [%s]\n  got  [%s]\n' "$1" "$2" "$3"; fi; }

gitq() { git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "${@:2}" >/dev/null 2>&1; }
mkrepo() { mkdir -p "$1"; gitq "$1" init -q; }
commit_board() { gitq "$1" add -- "$2"; gitq "$1" commit -q -m "board"; }

# --- --file: a clean board is silent ------------------------------------------
cat > "$SCRATCH/clean.md" <<'EOF'
# Open loops — global

Prose in the preamble is not a card.

## Claude's
- [ ] **Teach colregs-mcp the `overridden` field** — once the engine returns it
      ([o/r#40](https://github.com/o/r/pull/40))
- [ ] **D: bump engine to 0.2.2** — lockfile bump ([pr](https://github.com/o/r/pull/50))
- [ ] Ruled 2026-09-08, kept ([o/r#1](https://github.com/o/r/pull/1)) — the red sidelight text
- [ ] **Add the check** — done, landed as [o/r#59](https://github.com/o/r/pull/59), merged 2026-09-08
- [ ] **Reviewer notes** — write them up ([log](log/2026-09-08-notes.md))
- [ ] Closed 2026-09-08: the check exists ([log](../log/x.md)) — carry the finding
- [ ] **Watch list** — the reading list ([list](https://example.invalid/list))
- [ ] Merge conflicts in the harness: rework the encoder ([log](log/x.md))
EOF
run 0 'clean board, --file' --file "$SCRATCH/clean.md"
eq 'clean board prints nothing' '' "$LAST"

# --- every rule, by id and line ----------------------------------------------
cat > "$SCRATCH/bad.md" <<'EOF'
# Open loops

- [ ] **Stray** — above the heading ([log](log/x.md))

## Claude's
- [ ] **Review and merge [o/r#44](https://github.com/o/r/pull/44)** — the publish workflow
- [x] **Add the check** — done ([o/r#59](https://github.com/o/r/pull/59))
- [ ] **Rule on [o/r#32](https://github.com/o/r/issues/32)** — does 26(a) reach a vessel aground
- [ ] **Foo** — merge the fix once it passes
      ([pr](https://github.com/o/r/pull/7))
- [ ] Card with no link at all
- [ ] **Bar** — needs a link
      but only says so over two lines
- [ ] REVIEW the ADR ([o/r#9](https://github.com/o/r/issues/9))
- [ ] **Baz**: answer the question on [o/r#3](https://github.com/o/r/issues/3)
- [ ] **Qux** -- decide the shape ([o/r#5](https://github.com/o/r/pull/5))
- [ ] **Watch the release** ([run](https://github.com/o/r/actions/runs/1))
- [ ] **Answer** — the ADR text, no PR ([log](log/adr.md))
EOF
run 1 'bad board, --file' --file "$SCRATCH/bad.md"
has 'L2 on the stray bullet'            '^3: L2 '
has 'L4 review in the short name'       '^6: L4 "review"'
has 'L1 on the ticked line'             '^7: L1 '
has 'L4 two-word verb "rule on"'        '^8: L4 "rule on"'
has 'L4 verb after the em-dash separator, link on the continuation line' '^9: L4 "merge"'
has 'L6 on the linkless card'           '^11: L6 '
has 'L6 spans continuation lines'       '^12: L6 '
has 'L4 case-insensitive'               '^14: L4 "review"'
has 'L4 after a colon separator'        '^15: L4 "answer"'
has 'L4 after a -- separator'           '^16: L4 "decide"'
lacks 'watch + actions link is not a PR/issue' '^17: L4'
lacks 'answer with only a log link'     '^18: '
lacks 'no L5 in --file mode'            ' L5 '
eq 'violations sorted by line' "$(printf '%s\n' "$LAST" | cut -d: -f1)" "$(printf '%s\n' "$LAST" | cut -d: -f1 | sort -n)"
eq 'format is <line>: <rule> <message>' "$(printf '%s\n' "$LAST" | grep -cvE '^[0-9]+: L[1-6] .+')" 0

# --- L3 and the transition: legacy headings already in HEAD pass --------------
R="$SCRATCH/legacy"; mkrepo "$R"
cat > "$R/kanban.md" <<'EOF'
# Open loops

## Solace's
- [ ] **Run the review session** — the memos ([log](log/memos.md)) why you: learn

## Deferred — pre-1.0
- [ ] Later thing ([log](log/later.md))

## Claude's
- [ ] **Fix the awk** — drops the first bullet ([log](log/awk.md))
EOF
commit_board "$R" kanban.md
run 0 'legacy headings in HEAD pass --file' --file "$R/kanban.md"
cat >> "$R/kanban.md" <<'EOF'

## Yours
- [ ] Another section ([log](log/x.md))
EOF
run 1 'a heading not in HEAD fails --file' --file "$R/kanban.md"
has 'L3 names the heading' '^12: L3 new heading "## Yours"'
lacks 'the legacy heading still passes' '^3: '
cp "$R/kanban.md" "$SCRATCH/norepo-kanban.md"
run 0 'outside a repo, --file skips L3' --file "$SCRATCH/norepo-kanban.md"
: > "$R/untracked.md"; printf '## Deferred\n- [ ] x ([log](log/x.md))\n' > "$R/untracked.md"
run 1 'a file not in HEAD: every unknown heading is new' --file "$R/untracked.md"
has 'L3 on the untracked file' '^1: L3 '

# --- ## Needs ruling: the second allowed section ------------------------------
NR="$SCRATCH/ruling"; mkrepo "$NR"
cat > "$NR/kanban.md" <<'EOF'
# Open loops

## Claude's
- [ ] **Fix the awk** — drops the first bullet ([log](log/awk.md))
EOF
commit_board "$NR" kanban.md
cat >> "$NR/kanban.md" <<'EOF'

## Needs ruling
### colregs
- [ ] **Board sections** — decide whether cards or issues own a question ([o/r#90](https://github.com/o/r/pull/90)) default: cards undo: a revert, one session until: the next migration risk: another 60 issues
EOF
run 0 'an added ## Needs ruling heading passes L3' --diff "$NR" kanban.md
run 0 'a grouped decide + PR link card under ## Needs ruling passes L4, L7 and L8' --file "$NR/kanban.md"
gitq "$NR" checkout -- kanban.md

# L8: a ruling card carries the agent's evaluation, every field.
cat >> "$NR/kanban.md" <<'EOF'

## Needs ruling
### colregs
- [ ] **Bare question** — decide the pin ([o/r#91](https://github.com/o/r/pull/91))
- [ ] **Half evaluated** — decide the pin ([o/r#92](https://github.com/o/r/pull/92)) default: pin it
      undo: unpin, one line RISK: none
EOF
run 1 'a ruling card without its fields fails L8' --diff "$NR" kanban.md
has 'L8 names every missing field' '^8: L8 ruling card missing default:, undo:, until:, risk:'
has 'L8 names only the missing ones, across a continuation line, any case' '^9: L8 ruling card missing until: '
lacks 'L8 does not name a present field' '^9: L8 ruling card missing [^\n]*(default|undo|risk)'
gitq "$NR" checkout -- kanban.md

# L7: a ruling card needs a "### <project>" group above it.
cat >> "$NR/kanban.md" <<'EOF'

## Needs ruling
- [ ] **Ungrouped** — decide the pin ([o/r#91](https://github.com/o/r/pull/91))
EOF
run 1 'an ungrouped ruling card fails L7' --diff "$NR" kanban.md
has 'L7 names the line'        '^7: L7 ruling card with no'
has 'L7 names the global group' '### global'
lacks 'L7 alone, no L3 on the group-less section' 'L3'
gitq "$NR" checkout -- kanban.md

# "### " groups belong only under ## Needs ruling.
cat >> "$NR/kanban.md" <<'EOF'
### dotfiles
- [ ] **Grouped under the wrong section** — chase the awk ([log](log/awk.md))
EOF
run 1 'a ### group under ## Claude'"'"'s fails L3' --diff "$NR" kanban.md
has 'L3 names the group heading' '^5: L3 group heading "### dotfiles"'
lacks 'no L7 outside the ruling section' 'L7'
gitq "$NR" checkout -- kanban.md

# The same card under ## Claude's is still the user's turn written down.
cat >> "$NR/kanban.md" <<'EOF'
- [ ] **Board sections** — decide whether cards or issues own a question ([o/r#90](https://github.com/o/r/pull/90))
EOF
run 1 'the same card under ## Claude'"'"'s still fails L4' --diff "$NR" kanban.md
has 'L4 names the verb'            '^5: L4 "decide"'
has 'L4 points at the ruling section' '## Needs ruling'
gitq "$NR" checkout -- kanban.md

# ## Solace's is the third section: click work, with its two proofs (L9).
cat >> "$NR/kanban.md" <<'EOF'

## Solace's
- [ ] **Install the App** — consent screen ([org](https://github.com/o)) why you: no API installs an App on an org why this: the workflow's 403 names the missing installation ([run](https://github.com/o/r/actions/runs/1))
- [ ] **Rocq in the IDE** — set up the extension ([doc](https://example.invalid/rocq)) why you: learn
- [ ] **Rotate the key** — on the boat ([log](log/key.md))
- [ ] **Update the secret** — in GitHub ([log](log/secret.md)) why you: the value exists only in the user's password manager
- [ ] **Half learn** — the setup ([log](log/l.md)) Why You: learner
EOF
run 1 'a ## Solace'"'"'s section: proofs pass, missing proofs fail L9' --diff "$NR" kanban.md
lacks 'no L3 on the third section'          'L3'
lacks 'both proofs present passes'          '^7: '
lacks 'a learn card needs no why this'      '^8: '
has 'L9 missing why you'                    '^9: L9 click-work card missing why you:'
has 'L9 missing why this'                   '^10: L9 click-work card missing why this:'
has 'L9: "learner" is not "learn"'          '^11: L9 click-work card missing why this:'
eq 'exactly three L9 violations' 3 "$(printf '%s\n' "$LAST" | grep -c ' L9 ')"
gitq "$NR" checkout -- kanban.md

# A fourth heading is still refused.
cat >> "$NR/kanban.md" <<'EOF'

## Yours
- [ ] Another section ([log](log/x.md))
EOF
run 1 'a ## Yours heading added fails L3' --diff "$NR" kanban.md
has 'L3 names the heading'      '^6: L3 new heading "## Yours"'
has 'L3 names the sections'     '## Needs ruling, ## Solace'"'"'s and ## Claude'"'"'s'
gitq "$NR" checkout -- kanban.md

# --- heading-only diffs: a card is re-scoped without its own line changing ---
# A "## " or "### " heading is what the diff added; the card underneath it is
# unchanged in the diff. It still has to be (re)validated against whatever
# section/group it now sits in -- that's the whole point of L7/L8/L9.
printf '# Open loops\n\n## Needs ruling\n- [ ] **Fix the awk** — drops the first bullet ([o/r#90](https://github.com/o/r/pull/90))\n' > "$NR/kanban.md"
run 1 'a heading-only diff into ## Needs ruling still validates the untouched card beneath it' --diff "$NR" kanban.md
has 'L7 fires though only the heading line was added'    '^4: L7 '
has 'L8 fires though only the heading line was added'    '^4: L8 '
gitq "$NR" checkout -- kanban.md

printf '# Open loops\n\n## Solace'"'"'s\n- [ ] **Fix the awk** — drops the first bullet ([o/r#90](https://github.com/o/r/pull/90))\n' > "$NR/kanban.md"
run 1 'a heading-only diff into ## Solace'"'"'s still validates the untouched card beneath it' --diff "$NR" kanban.md
has 'L9 fires though only the heading line was added'    '^4: L9 click-work card missing why you:'
gitq "$NR" checkout -- kanban.md

# A card two heads deep (## Needs ruling / ### <project>): a rename of the
# ### group alone -- the "## " line untouched -- must re-validate it too.
cat > "$NR/kanban.md" <<'EOF'
# Open loops

## Needs ruling
### colregs
- [ ] **Board sections** — decide the pin ([o/r#90](https://github.com/o/r/pull/90)) default: cards undo: a revert until: the next migration
EOF
commit_board "$NR" kanban.md
sed -i 's/### colregs/### colregs-v2/' "$NR/kanban.md"
run 1 'a ### group rename alone still validates the untouched card beneath it' --diff "$NR" kanban.md
lacks 'the group is present -- no L7' 'L7'
has 'L8 fires for the field the card was already missing' '^5: L8 ruling card missing risk:'
gitq "$NR" checkout -- kanban.md

# --- --diff: only added lines are judged -------------------------------------
D="$SCRATCH/diff"; mkrepo "$D"; mkdir -p "$D/state/global"
cat > "$D/state/global/kanban.md" <<'EOF'
# Open loops

## Solace's
- [x] **Merge [o/r#29](https://github.com/o/r/pull/29)** — CI green, awaiting you
- [ ] **Rule on [o/r#32](https://github.com/o/r/issues/32)** — the aground question

## Claude's
- [ ] **Old card** — merged history stays ([log](log/old.md))
EOF
commit_board "$D" state/global/kanban.md
run 0 'no diff -> clean' --diff "$D" state/global/kanban.md
eq 'no diff prints nothing' '' "$LAST"

cat >> "$D/state/global/kanban.md" <<'EOF'
- [ ] **New card** — awaiting Solace's review ([o/r#50](https://github.com/o/r/pull/50))
- [ ] **Bump engine** — CI green now ([o/r#51](https://github.com/o/r/pull/51))
- [ ] **Unmerged credit** — a fine card ([log](log/fine.md))
- [ ] **Two-line state** — the fix
      landed and is not merged yet ([log](log/two.md))
EOF
run 1 'added lines with state words' --diff "$D" state/global/kanban.md
has 'L5 awaiting on the added line'      '^9: L5 state word "awaiting"'
has 'L4 bump + PR link'                  '^10: L4 "bump"'
has 'L5 CI green'                        '^10: L5 state word "ci green"'
has 'L5 on the continuation line itself' '^13: L5 state word "not merged"'
lacks 'unmerged/credit are not whole words' '^11: '
lacks 'history above is not linted'      '^[4-8]: '
eq 'exactly four violations' 4 "$(printf '%s\n' "$LAST" | wc -l | tr -d ' ')"

gitq "$D" checkout -- state/global/kanban.md
cat >> "$D/state/global/kanban.md" <<'EOF'

## Deferred
- [ ] Later ([log](log/later.md))
EOF
run 1 'a new heading in the diff' --diff "$D" state/global/kanban.md
has 'L3 on the added heading' '^10: L3 new heading "## Deferred"'
gitq "$D" checkout -- state/global/kanban.md

# Moving an existing heading is not a new heading.
printf '# Open loops\n\n## Claude'"'"'s\n- [ ] **Old card** — merged history stays ([log](log/old.md))\n\n## Solace'"'"'s\n- [ ] **Moved card** — the aground question ([log](log/aground.md)) why you: learn\n' > "$D/state/global/kanban.md"
run 0 'reordering headings already in HEAD passes' --diff "$D" state/global/kanban.md
gitq "$D" checkout -- state/global/kanban.md

# A prose line above the first heading that is added, and a stray bullet.
sed -i '2i - [ ] stray bullet ([log](log/s.md))' "$D/state/global/kanban.md"
run 1 'added bullet above the first heading' --diff "$D" state/global/kanban.md
has 'L2 in diff mode' '^2: L2 '
gitq "$D" checkout -- state/global/kanban.md

# Untracked board: everything is added.
printf '## Claude'"'"'s\n- [x] ticked ([log](log/x.md))\n- [ ] fine ([log](log/y.md))\n' > "$D/state/global/new.md"
run 1 'untracked file: whole file is added' --diff "$D" state/global/new.md
has 'L1 on the untracked board' '^2: L1 '
rm -f "$D/state/global/kanban.md"
run 0 'deleted board: nothing added' --diff "$D" state/global/kanban.md
gitq "$D" checkout -- state/global/kanban.md
run 2 'not a repo' --diff "$SCRATCH/home" x.md

# --- --epic: state words on Status lines only ------------------------------------
cat > "$SCRATCH/epic.md" <<'EOF'
# Epic

The 2026-09-05 incident is closed and merged. Not a Status line.

## Status

- 2026-09-04 — epic opened ([#1](https://github.com/o/r/issues/1))
- 2026-09-06 — **P2.1 built** and open as [#21](https://github.com/o/r/pull/21), awaiting review
- 2026-09-06 — **#21 fixed and green again**, verified by re-running
  the harness; CI green
- 2026-09-07 — ruled, see [#26](https://github.com/o/r/pull/26)

## Sessions

- [ ] **P1.5 Triage** — merged evidence packs; awaiting Solace
EOF
run 1 'epic Status lines' --epic "$SCRATCH/epic.md"
has 'L5 open as (first phrase wins)'     '^8: L5 state word "open as"'
lacks 'bare green is not a state word'   '^9: '
has 'L5 on the wrapped Status line'      '^10: L5 state word "ci green"'
has 'epic tail names the Status shape'   'Status line = date -- slug'
lacks 'prose outside Status is not linted' '^3: '
lacks 'Sessions section is not linted'   '^1[5-9]: '
lacks 'no card rules in epic mode'       ' L[1346] '
eq 'two epic violations' 2 "$(printf '%s\n' "$LAST" | wc -l | tr -d ' ')"
printf '## Status\n\n- 2026-09-08 — slug — [#3](https://github.com/o/r/pull/3)\n' > "$SCRATCH/epic-ok.md"
run 0 'clean Status lines' --epic "$SCRATCH/epic-ok.md"

# --- cannot lint ---------------------------------------------------------------
run 2 'missing file' --file "$SCRATCH/nope.md"
run 2 'missing epic' --epic "$SCRATCH/nope.md"
run 2 'bad flag' --wat x
run 2 'missing operand' --diff "$D"

# --- hook mode ---------------------------------------------------------------
hook() { printf '%s' "$1" | sh "$LINT" 2>&1; }
edit_json() { jq -n --arg f "$1" '{tool_name:"Edit",tool_input:{file_path:$f,old_string:"a",new_string:"b"},tool_response:{}}'; }
LAST=$(hook "$(edit_json "$SCRATCH/bad.md")")
eq 'other files are ignored' '' "$LAST"
LAST=$(hook "$(edit_json "$SCRATCH/clean.md")")
eq 'a clean board is silent (basename kanban.md, but clean.md is not one)' '' "$LAST"
mkdir -p "$SCRATCH/proj"; cp "$SCRATCH/clean.md" "$SCRATCH/proj/kanban.md"
LAST=$(hook "$(edit_json "$SCRATCH/proj/kanban.md")")
eq 'clean kanban.md is silent' '' "$LAST"
cp "$SCRATCH/bad.md" "$SCRATCH/proj/kanban.md"
LAST=$(hook "$(edit_json "$SCRATCH/proj/kanban.md")")
eq 'bad kanban.md blocks' block "$(printf '%s' "$LAST" | jq -r .decision 2>/dev/null)"
reason=$(printf '%s' "$LAST" | jq -r .reason)
LAST=$reason
has 'reason names the file'             "$SCRATCH/proj/kanban.md"
has 'reason carries line and rule'      '^7: L1 '
has 'reason carries the routing row'    '## Needs ruling'
has 'reason points at card-write'       '/card-write'
mkdir -p "$SCRATCH/sr/state/global/epics"; cp "$SCRATCH/epic.md" "$SCRATCH/sr/state/global/epics/e.md"
LAST=$(hook "$(jq -n --arg f "$SCRATCH/sr/state/global/epics/e.md" '{tool_name:"Write",tool_input:{file_path:$f,content:"x"}}')")
eq 'epic path routes to --epic' block "$(printf '%s' "$LAST" | jq -r .decision 2>/dev/null)"
LAST=$(printf '%s' "$LAST" | jq -r .reason)
has 'epic reason is L5 only' '^8: L5 '
lacks 'epic reason has no card rules' ' L[1346] '
LAST=$(hook "$(edit_json "$SCRATCH/proj/missing/kanban.md")")
eq 'a path that does not exist is silent' '' "$LAST"
LAST=$(hook '')
eq 'empty payload is silent' '' "$LAST"

# Without jq the hook still finds the path and still blocks, with valid JSON.
mkdir -p "$SCRATCH/nojq"; for b in sh awk sed grep sort head tr cat dirname basename printf git; do p=$(command -v $b) && ln -s "$p" "$SCRATCH/nojq/$b"; done
LAST=$(printf '%s' "$(edit_json "$SCRATCH/proj/kanban.md")" | PATH="$SCRATCH/nojq" /bin/sh "$LINT" 2>&1)
eq 'no jq: still blocks' block "$(printf '%s' "$LAST" | jq -r .decision 2>/dev/null)"
eq 'no jq: reason survives the hand-rolled escaper' 1 "$(printf '%s' "$LAST" | jq -r .reason | grep -c '^7: L1 ')"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

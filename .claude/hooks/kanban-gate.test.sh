#!/usr/bin/env bash
# Tests for kanban-gate.sh. Run: bash .claude/hooks/kanban-gate.test.sh
# Set AWK_PATH to a directory whose `awk` is another implementation to run
# the same cases under it; CI does this for each.
#
# What matters: silent on the retry (stop_hook_active), silent with no state
# repo, silent when the board is committed or its added lines are clean;
# blocks with the lint's lines when they are not; and blocks -- never goes
# quiet -- when a dirty board cannot be linted.
set -uo pipefail
[ -n "${AWK_PATH:-}" ] && PATH="$AWK_PATH:$PATH"

HOOKS="$(cd "$(dirname "$0")" && pwd)"
GATE="$HOOKS/kanban-gate.sh"
pass=0; fail=0
SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
export HOME="$SCRATCH/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

gitq() { git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "${@:2}" >/dev/null 2>&1; }
SR="$SCRATCH/claude_prompts_scratch"; mkdir -p "$SR/state/global"; gitq "$SR" init -q
BOARD="$SR/state/global/kanban.md"
cat > "$BOARD" <<'EOF'
# Open loops

## Solace's
- [x] **Merge [o/r#29](https://github.com/o/r/pull/29)** — CI green

## Claude's
- [ ] **Old card** — history ([log](log/old.md))
EOF
gitq "$SR" add -- state/global/kanban.md; gitq "$SR" commit -q -m board
export CLAUDE_STATE_REPO="$SR"

stop_input() { jq -n --argjson a "${1:-false}" '{session_id:"s1",stop_hook_active:$a,cwd:"/x",transcript_path:"/x/t.jsonl"}'; }
# check <block|silent> <desc> <json> [gate path]
check() {
  local want=$1 desc=$2 json=$3 gate=${4:-$GATE} got
  LAST=$(printf '%s' "$json" | sh "$gate" 2>&1)
  if [ -z "$LAST" ]; then got=silent
  elif [ "$(printf '%s' "$LAST" | jq -r '.decision' 2>/dev/null)" = block ]; then got=block
  else got=invalid; fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL (want %s, got %s): %s\n  %s\n' "$want" "$got" "$desc" "$LAST"; fi
}
reason()    { if printf '%s' "$LAST" | jq -r '.reason' | grep -Eq -- "$2"; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL (reason lacks /%s/): %s\n  %s\n' "$2" "$1" "$LAST"; fi; }
no_reason() { if printf '%s' "$LAST" | jq -r '.reason' | grep -Eq -- "$2"; then fail=$((fail+1)); printf 'FAIL (reason has /%s/): %s\n' "$2" "$1"; else pass=$((pass+1)); fi; }

# --- nothing to gate -----------------------------------------------------------
check silent 'committed board, clean tree'   "$(stop_input)"
check silent 'empty payload'                 ''
CLAUDE_STATE_REPO="$SCRATCH/nowhere" check silent 'no state repo' "$(stop_input)"

# --- dirty board ---------------------------------------------------------------
printf -- '- [ ] **New card** — awaiting review ([o/r#50](https://github.com/o/r/pull/50))\n- [x] ticked ([log](log/x.md))\n' >> "$BOARD"
check silent 'retry with stop_hook_active'  "$(stop_input true)"
check block  'bad added lines block'         "$(stop_input)"
reason 'names the board'                     'state/global/kanban.md'
reason 'carries L5 with its line'            '^8: L5 state word "awaiting"'
reason 'carries L1 with its line'            '^9: L1 '
no_reason 'history in HEAD is not relitigated' '^4: '
reason 'says fix or delete'                  'Fix or delete each line'
reason 'says it fires once'                  'once per turn'

gitq "$SR" checkout -- state/global/kanban.md
printf -- '- [ ] **Fine card** — a plain agent loop ([log](log/fine.md))\n' >> "$BOARD"
check silent 'clean added lines pass'        "$(stop_input)"

# A board never committed (fresh state repo) is linted whole.
SR2="$SCRATCH/sr2"; mkdir -p "$SR2/state/global"; gitq "$SR2" init -q
: > "$SR2/README.md"; gitq "$SR2" add -- README.md; gitq "$SR2" commit -q -m init
printf '## Claude'"'"'s\n- [x] ticked ([log](log/x.md))\n- [ ] fine ([log](log/y.md))\n' > "$SR2/state/global/kanban.md"
CLAUDE_STATE_REPO="$SR2" check block 'untracked board is linted whole' "$(stop_input)"
reason 'the ticked line counts'              '^2: L1 '
gitq "$SR" checkout -- state/global/kanban.md
check silent 'restored -> clean'             "$(stop_input)"

# --- cannot lint is loud -----------------------------------------------------
printf -- '- [ ] **Another** ([log](log/a.md))\n' >> "$BOARD"
ALT="$SCRATCH/hooks"; mkdir -p "$ALT"; cp "$GATE" "$HOOKS/lib-state.sh" "$ALT/"
check block 'kanban-lint.sh missing -> block' "$(stop_input)" "$ALT/kanban-gate.sh"
reason 'says the board could not be linted'  'could not be linted'
reason 'fails closed'                        'fails closed'
gitq "$SR" checkout -- state/global/kanban.md
check silent 'lint missing but board clean -> silent' "$(stop_input)" "$ALT/kanban-gate.sh"

# No jq: stop_hook_active is still honoured, a dirty board still blocks with valid JSON.
printf -- '- [x] ticked ([log](log/x.md))\n' >> "$BOARD"
mkdir -p "$SCRATCH/nojq"; for b in sh awk sed grep sort head tr cat dirname basename printf git; do p=$(command -v $b) && ln -s "$p" "$SCRATCH/nojq/$b"; done
LAST=$(stop_input true | PATH="$SCRATCH/nojq" /bin/sh "$GATE" 2>&1)
if [ -z "$LAST" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: no jq + stop_hook_active should be silent: $LAST"; fi
LAST=$(stop_input | PATH="$SCRATCH/nojq" /bin/sh "$GATE" 2>&1)
if [ "$(printf '%s' "$LAST" | jq -r .decision 2>/dev/null)" = block ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: no jq + dirty board should block: $LAST"; fi
reason 'no jq: the lint line survives the escaper' '^8: L1 '
gitq "$SR" checkout -- state/global/kanban.md

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

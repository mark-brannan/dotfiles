#!/usr/bin/env bash
# Tests for languette-step-two-ready, against a fixture metrics directory.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/languette-step-two-ready"
pass=0; fail=0
M=$(mktemp -d); trap 'rm -rf "$M"' EXIT
mkdir -p "$M/sessions" "$M/blocked"

session() { # session <sid> <started_at> <bash calls>
  jq -cn --arg s "$1" --arg t "$2" --argjson b "$3" \
    '{session_id: $s, started_at: $t, tools: (if $b > 0 then {Bash: $b} else {Read: 1} end)}' \
    > "$M/sessions/$1.json"
}
deny() { # deny <sid> <reason>
  jq -cn --arg r "$2" '{kind: "rule", raw: "permission-rule", tool: "Bash", target: "x", reason: $r}' \
    >> "$M/blocked/$1.jsonl"
}
check() { # check <desc> <want exit> <want line> [flags...]
  local desc=$1 want=$2 line=$3 out code; shift 3
  out=$("$SCRIPT" --metrics "$M" "$@" 2>&1); code=$?
  if [ "$code" = "$want" ] && grep -qF -- "$line" <<<"$out"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL: %s (want exit %s and "%s", got %s)\n%s\n' "$desc" "$want" "$line" "$code" "$out"
  fi
}

# shellcheck disable=SC2016  # the backticks and $HOME are the literal reason text
ADD='`git add -A` is blocked: stage by path.'
session old 2026-09-01T00:00:00.000Z 3
deny old "$ADD"                                   # before --since: ignored
session a 2026-10-02T01:00:00.000Z 4
deny a "$ADD"                                     # plugin
deny a "[dotfiles copy] \`git add -A\` without a plain path is blocked"  # copy, plugin also denied this guard
session b 2026-10-02T02:00:00.000Z 1
deny b "PreToolUse:Bash hook error: \`rm -r build\` is blocked: only the scratchpad"  # plugin, harness prefix
session c 2026-10-02T03:00:00.000Z 0               # no Bash: not counted
deny c "$ADD"
session d 2026-10-02T04:00:00.000Z 2
deny d "no-unsigned-push: 1 unsigned commit(s)"    # another guard: ignored

check 'counts sessions with Bash since the date' 1 'sessions with a Bash call   3' --since 2026-10-01T00:00:00Z
check 'plugin denials, no-Bash session excluded' 1 'plugin denials              2' --since 2026-10-01T00:00:00Z
check 'copy denial matched by a plugin denial'   1 'copy denials, plugin silent 0' --since 2026-10-01T00:00:00Z
check 'ready under lowered thresholds'           0 'READY' --since 2026-10-01T00:00:00Z --min-sessions 3 --min-plugin 2

deny d "[dotfiles copy] \`rm -r src\` is blocked"                       # copy, plugin silent in d
session e 2026-10-02T05:00:00.000Z 1
# shellcheck disable=SC2016
deny e 'no-rm-tree.sh is missing from $HOME/.claude/hooks or crashed'   # copy wrapper
check 'copy-only counts tag and wrapper'         1 'copy denials, plugin silent 2' --since 2026-10-01T00:00:00Z
check 'copy-only blocks ready'                   1 'NOT READY' --since 2026-10-01T00:00:00Z --min-sessions 1 --min-plugin 1
check 'max-copy-only raises the bar'             0 'READY' --since 2026-10-01T00:00:00Z --min-sessions 1 --max-copy-only 2
check 'missing --since is a usage error'         2 'required'
check 'bad count is a usage error'               2 'not a count' --since 2026-10-01T00:00:00Z --min-plugin x
check 'missing metrics dir'                      2 'no metrics' --since 2026-10-01T00:00:00Z --metrics "$M/nope"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

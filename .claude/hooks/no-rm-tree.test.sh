#!/usr/bin/env bash
# Tests for no-rm-tree.sh. Run: bash .claude/hooks/no-rm-tree.test.sh
# shellcheck disable=SC2016  # the commands under test contain $(...) on purpose
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/no-rm-tree.sh"
pass=0; fail=0
CWD_A="$HOME/project"
CWD_B="$HOME/project/sub"

check() {
  local want=$1 desc=$2 cmd=$3 cwd=${4:-$CWD_A} out got
  out=$(jq -n --arg c "$cmd" --arg d "$cwd" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | timeout 5 sh "$HOOK" 2>&1; [ "${PIPESTATUS[1]}" = 124 ] && echo TIMEOUT)
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then got=deny; else got=allow; fi
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL (want %s, got %s): %s\n  cmd: %s\n  cwd: %s\n' "$want" "$got" "$desc" "$cmd" "$cwd"
    [ -n "$out" ] && printf '  hook output: %s\n' "$out"
  fi
}

# --- deny: misc/tracked directories, any recursive flag spelling ---
check deny  'rm -rf examples'                 'rm -rf examples'
check deny  'rm -r ./docs'                    'rm -r ./docs'
check deny  'rm -rf $HOME/foo'                'rm -rf "$HOME/foo"'
check deny  'rm -rf ~/Downloads'              'rm -rf ~/Downloads'
check deny  'rm -rf *'                        'rm -rf *'
check deny  'rm -rf dist/*'                   'rm -rf dist/*'
check deny  'rm -rf dist/../src'              'rm -rf dist/../src'
check deny  'rm -Rf src'                      'rm -Rf src'
check deny  'rm -rf public'                   'rm -rf public'
check deny  'rm -rf $DIR'                     'rm -rf "$DIR"'
check deny  'rm -rf .'                        'rm -rf .'
check deny  'rm -rf ~'                        'rm -rf ~'
check deny  'cd x && rm -rf y'                'cd x && rm -rf y'
check deny  'sudo rm -rf /srv/z'              'sudo rm -rf /srv/z'
check deny  'timeout 5 rm -r a'               'timeout 5 rm -r a'
check deny  'rm -rf node_modules examples'    'rm -rf node_modules examples'
check deny  '--recursive spelled out'         'rm --recursive build'
check deny  'rm -rf .. segment bare'          'rm -rf ..'
check deny  'rm -rf tilde-user'               'rm -rf ~mark/foo'
check deny  'rm -rf repo root via .'          'rm -rf .'                          "$HOME"

# --- allow: generated dirs, Claude'\''s own areas, non-recursive, non-rm ---
check allow 'rm -rf node_modules'             'rm -rf node_modules'
check allow 'rm -rf dist'                     'rm -rf dist'
check allow 'rm -rf ./demo-dist app-dist'     'rm -rf ./demo-dist app-dist'
check allow 'scratchpad'                      "rm -rf $HOME/.local/state/claude-tmpdir/anything"
check allow '/tmp'                            'rm -rf /tmp/whatever'
check allow 'agent worktree'                  'rm -rf ~/.claude/worktrees/foo'
check allow 'rm foo.txt'                      'rm foo.txt'
check allow 'rm -f a b'                       'rm -f a b'
check allow 'echo rm -rf x'                   'echo rm -rf x'
check allow 'heredoc body'                    $'cat <<EOF\nnever run rm -rf x\nEOF'
check allow 'git rm -r examples'              'git rm -r examples'
check allow 'yadm rm -r examples'             'yadm rm -r examples'
check allow 'generated dir, deeper cwd'       'rm -rf dist'                       "$CWD_B"
check allow 'relative target, deeper cwd'     "rm -rf $HOME/.claude/worktrees/x"  "$CWD_B"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

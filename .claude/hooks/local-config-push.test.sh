#!/usr/bin/env bash
# Tests for local-config-push.sh. Run: bash .claude/hooks/local-config-push.test.sh
#
# Builds a throwaway fake $HOME with a plain git repo standing in for yadm
# (a `yadm` shim on PATH that forwards every subcommand to `git`), so the
# hook's yadm calls exercise real git behavior without touching the real
# machine's yadm-managed $HOME.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/local-config-push.sh"
pass=0
fail=0

check() {
  local desc=$1 got=$2 want=$3
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s (want %q, got %q)\n' "$desc" "$want" "$got"
  fi
}

setup_home() {
  local d
  d=$(mktemp -d)
  local bin="$d/bin"
  mkdir -p "$bin" "$d/.claude/hooks" "$d/.claude/rules" "$d/.local/bin"
  cat > "$bin/yadm" <<'EOF'
#!/bin/sh
exec git "$@"
EOF
  chmod +x "$bin/yadm"

  git -C "$d" init -q
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name Test
  git -C "$d" config commit.gpgsign false

  cat > "$d/.local/bin/cloud-session-setup.sh" <<'EOF'
INSTALL="
.claude/settings.json
.claude/CLAUDE.md
.claude/rules/code.md
"
EOF
  echo '{}' > "$d/.claude/settings.json"
  echo '# orders' > "$d/.claude/CLAUDE.md"
  echo '# code' > "$d/.claude/rules/code.md"
  git -C "$d" add -A >/dev/null
  git -C "$d" commit -q -m init >/dev/null

  # A bare "origin" so `yadm push` has somewhere real to land.
  local origin="$d/../origin.git"
  git init -q --bare "$origin"
  git -C "$d" remote add origin "$origin"
  git -C "$d" push -q -u origin HEAD:main >/dev/null 2>&1 \
    || git -C "$d" push -q -u origin HEAD:master >/dev/null 2>&1

  echo "$d|$bin"
}

run_hook() {
  local home=$1 bin=$2; shift 2
  (cd "$home" && env -i HOME="$home" PATH="$bin:/usr/bin:/bin" "$@" bash "$HOOK")
}

# --- clean tree: no commit, nothing reported --------------------------------
IFS='|' read -r home bin <<<"$(setup_home)"
run_hook "$home" "$bin"
n=$(git -C "$home" rev-list --count HEAD)
check "clean tree makes no commit" "$n" "1"

# --- CLAUDE.md dirty: committed and pushed, excluding settings.json --------
IFS='|' read -r home bin <<<"$(setup_home)"
echo '# changed' >> "$home/.claude/CLAUDE.md"
echo '{"changed":true}' > "$home/.claude/settings.json"
run_hook "$home" "$bin"
n=$(git -C "$home" rev-list --count HEAD)
check "dirty CLAUDE.md + settings.json: exactly one new commit" "$n" "2"
staged_settings=$(git -C "$home" show --stat HEAD | grep -c 'settings.json' || true)
check "settings.json not part of the commit" "$staged_settings" "0"
still_dirty=$(git -C "$home" status --porcelain -- .claude/settings.json)
check "settings.json left uncommitted" "$([ -n "$still_dirty" ] && echo yes || echo no)" "yes"

# --- CLAUDE_CODE_REMOTE=true: hook is a no-op ------------------------------
IFS='|' read -r home bin <<<"$(setup_home)"
echo '# changed' >> "$home/.claude/CLAUDE.md"
run_hook "$home" "$bin" CLAUDE_CODE_REMOTE=true
n=$(git -C "$home" rev-list --count HEAD)
check "CLAUDE_CODE_REMOTE=true skips entirely" "$n" "1"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

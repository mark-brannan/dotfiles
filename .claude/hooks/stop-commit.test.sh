#!/usr/bin/env bash
# Tests for lib-stop-commit.sh. Run: bash .claude/hooks/stop-commit.test.sh
#
# Cut to the cases that guard an invariant: commits are signed, a shared
# checkout never gets `git add -A`'d (only configured state paths move), a
# refused commit restores the index, a conflict on origin refuses instead of
# clobbering, and --dry-run mutates nothing. Everything else here is
# scaffolding to reach those states.
#
# Everything happens under one temp dir: a private "state repo" holding the
# policy table, local bare origins, clones, worktrees, and a throwaway SSH
# signing key so the signed-commit invariant is exercised for real. No
# network, no global git config, nothing outside $T is touched.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/stop-commit-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export CLAUDE_STATE_REPO="$T/state"
unset CLAUDE_STOP_COMMIT_DRY_RUN

git init -q -b main "$T/state"
mkdir -p "$T/state/state/global"
CONF="$T/state/state/global/stop-commit.conf"
cat > "$CONF" <<'EOF'
owner/alpha   state-to-main  intermediate_files/claude_slop
owner/beta    branch
*             off
EOF

ssh-keygen -q -t ed25519 -N '' -f "$T/signkey" >/dev/null 2>&1

# shellcheck source=lib-stop-commit.sh
. "$HOOKS/lib-stop-commit.sh"

pass=0; fail=0
ok() {  # ok <description> <command...>
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL: %s\n' "$desc"; fi
}
has() { grep -q -- "$2" "$1"; }         # has <file> <pattern>
strhas() { printf '%s' "$1" | grep -q -- "$2"; }

CKPT="$T/ckpt"
run() { : > "$CKPT"; sc_run "$1" "${2:-sess0000}" "$CKPT"; }

# mkrepo <owner> <name>: bare origin + clone on main with one state file.
mkrepo() {
  local origin="$T/origins/$1/$2.git" clone="$T/$1-$2"
  git init -q --bare -b main "$origin"
  git clone -q "$origin" "$clone" 2>/dev/null
  git -C "$clone" config user.name t; git -C "$clone" config user.email t@t
  git -C "$clone" config gpg.format ssh
  git -C "$clone" config user.signingkey "$T/signkey.pub"
  git -C "$clone" config commit.gpgsign true
  mkdir -p "$clone/intermediate_files/claude_slop"
  printf 'line1\nline2\nline3\n' > "$clone/intermediate_files/claude_slop/kanban.md"
  echo readme > "$clone/README.md"
  git -C "$clone" add -A && git -C "$clone" commit -q -m init && git -C "$clone" push -q -u origin main 2>/dev/null
  printf '%s' "$clone"
}
# other <clone> <shell...>: another session lands a commit on origin/main.
other() {
  local c=$1; shift
  local w="$T/other.$$"
  rm -rf "$w"; git clone -q "$(git -C "$c" config --get remote.origin.url)" "$w" 2>/dev/null
  git -C "$w" config user.name o; git -C "$w" config user.email o@o
  (cd "$w" && eval "$*")
  git -C "$w" add -A && git -C "$w" commit -q -m other && git -C "$w" push -q origin main 2>/dev/null
  rm -rf "$w"
}
signed() { git -C "$1" cat-file commit "${2:-HEAD}" | grep -q '^gpgsig'; }
origin_tip() { git -C "$1" ls-remote -q origin "refs/heads/$2" | cut -f1; }
files_in() { git -C "$1" show --pretty=format: --name-only "$2"; }

A=$(mkrepo owner alpha)

# --- state-to-main, shared checkout: only state paths move, signed --------
old=$(git -C "$A" rev-parse HEAD)
sed -i '1s/.*/edited by session/' "$A/intermediate_files/claude_slop/kanban.md"
echo new > "$A/intermediate_files/claude_slop/new.md"
echo code > "$A/code.py"
echo changed > "$A/README.md"
run "$A" abcdef0123
tip=$(origin_tip "$A" main)
ok 's2m shared: origin/main advanced' [ "$tip" != "$old" ]
ok 's2m shared: signed' signed "$A" "$tip"
ok 's2m shared: only state paths in commit (no -A)' [ "$(files_in "$A" "$tip" | sort | tr '\n' ' ')" = "intermediate_files/claude_slop/kanban.md intermediate_files/claude_slop/new.md " ]
ok 's2m shared: other files left uncommitted' [ "$(git -C "$A" status --porcelain | sort | tr '\n' ' ')" = " M README.md ?? code.py " ]

# --- state-to-main conflict refuses -----------------------------------------
git -C "$A" checkout -q -- README.md; rm -f "$A/code.py"
W="$T/alpha-wt"
git -C "$A" worktree add -q "$W" -b claude/x origin/main 2>/dev/null
other "$A" 'sed -i "1s/.*/theirs/" intermediate_files/claude_slop/kanban.md'
moved=$(origin_tip "$A" main)
sed -i '1s/.*/ours/' "$W/intermediate_files/claude_slop/kanban.md"
run "$W"
ok 's2m conflict: origin/main untouched' [ "$(origin_tip "$A" main)" = "$moved" ]
ok 's2m conflict: refused loudly' has "$CKPT" 'NOT COMMITTED: state paths conflict'
ok 's2m conflict: worktree file untouched' [ "$(head -1 "$W/intermediate_files/claude_slop/kanban.md")" = ours ]

# --- dry run mutates nothing -------------------------------------------------
git -C "$W" checkout -q -- .
git -C "$W" fetch -q origin && git -C "$W" reset -q --hard origin/main
sed -i '1s/.*/dry/' "$W/intermediate_files/claude_slop/kanban.md"; echo d > "$W/dry.py"
moved=$(origin_tip "$A" main); bt=$(origin_tip "$A" claude/x); wh=$(git -C "$W" rev-parse HEAD)
SC_DRY=1 run "$W"
ok 'dry: origin/main untouched' [ "$(origin_tip "$A" main)" = "$moved" ]
ok 'dry: origin/branch untouched' [ "$(origin_tip "$A" claude/x)" = "$bt" ]
ok 'dry: nothing committed locally' [ "$(git -C "$W" rev-parse HEAD)" = "$wh" ]
git -C "$W" checkout -q -- .; rm -f "$W/dry.py"

# --- branch policy, worktree: sets up a pushed commit to refuse against ----
B=$(mkrepo owner beta)
WB="$T/beta-wt"
git -C "$B" worktree add -q "$WB" -b claude/y origin/main 2>/dev/null
echo a > "$WB/a.txt"
run "$WB" feedbeef00
btip=$(origin_tip "$B" claude/y)
ok 'branch wt: pushed' [ -n "$btip" ] && [ "$btip" = "$(git -C "$WB" rev-parse HEAD)" ]
ok 'branch wt: signed' signed "$WB"

# --- gitleaks refusal restores the index ------------------------------------
if command -v gitleaks >/dev/null 2>&1; then
  echo more > "$WB/README.md"; git -C "$WB" add README.md
  # An invented key, never issued; allowlisted for this file in .gitleaks.toml.
  printf 'aws_key = "AKIAQ7Z2M4X9J1B5K8T3"\n' > "$WB/creds.txt"
  run "$WB"
  ok 'gitleaks: refused' has "$CKPT" 'NOT COMMITTED: gitleaks found'
  ok 'gitleaks: nothing pushed' [ "$(origin_tip "$B" claude/y)" = "$btip" ]
  ok 'gitleaks: no commit' [ "$(git -C "$WB" rev-parse HEAD)" = "$btip" ]
  ok 'gitleaks: index restored' [ "$(git -C "$WB" diff --cached --name-only)" = "README.md" ]
  ok 'gitleaks: file left untracked' [ "$(git -C "$WB" status --porcelain creds.txt)" = "?? creds.txt" ]
  rm -f "$WB/creds.txt"; git -C "$WB" reset -q; git -C "$WB" checkout -q -- .
else
  echo "skip: gitleaks not on PATH"
fi

# --- a refusing repo hook: refusal restores the index -----------------------
hook="$(git -C "$B" rev-parse --path-format=absolute --git-path hooks)/pre-commit"
mkdir -p "$(dirname "$hook")"
printf '#!/bin/sh\necho "nope from hook"\nexit 1\n' > "$hook"; chmod +x "$hook"
echo h > "$WB/h.txt"
run "$WB"
ok 'hook: refused' has "$CKPT" 'NOT COMMITTED: commit on claude/y refused'
ok 'hook: no commit' [ "$(git -C "$WB" rev-parse HEAD)" = "$btip" ]
ok 'hook: index restored' [ "$(git -C "$WB" status --porcelain)" = "?? h.txt" ]
rm -f "$hook"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]

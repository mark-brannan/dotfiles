#!/usr/bin/env bash
# Tests for lib-stop-commit.sh. Run: bash .claude/hooks/stop-commit.test.sh
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

ssh-keygen -q -t ed25519 -N '' -f "$T/signkey" >/dev/null 2>&1

# shellcheck source=lib-stop-commit.sh
. "$HOOKS/lib-stop-commit.sh"

pass=0; fail=0
ok() {  # ok <description> <command...>
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL: %s\n' "$desc"; fi
}
not() { ! "$@"; }
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
nworktrees() { git -C "$1" worktree list | wc -l; }
leftover_tmp() { find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'stop-commit-*' | grep -q .; }

# --- policy resolution ---------------------------------------------------
A=$(mkrepo owner alpha)
ok 'key from local path' [ "$(sc_repo_key "$A")" = owner/alpha ]
K=$(mktemp -d); git init -q "$K"
for url in https://github.com/mark-brannan/symphony.git git@github.com:mark-brannan/symphony \
           ssh://git@github.com/mark-brannan/symphony.git https://x@github.com/mark-brannan/symphony/; do
  git -C "$K" remote remove origin 2>/dev/null; git -C "$K" remote add origin "$url"
  ok "key from $url" [ "$(sc_repo_key "$K")" = mark-brannan/symphony ]
done
git -C "$K" remote remove origin
ok 'no origin -> no key' not sc_repo_key "$K"

rm -f "$CONF"
ok 'no conf -> off' [ "$(sc_policy owner/alpha)" = "$(printf 'off\t')" ]
cat > "$CONF" <<'EOF'
# comment
owner/alpha   state-to-main  intermediate_files/claude_slop
owner/bad1    state-to-main
owner/bad2    state-to-main  ../etc
owner/bad3    frobnicate
owner/*       branch
*             off
EOF
ok 'first match wins' [ "$(sc_policy owner/alpha)" = "$(printf 'state-to-main\tintermediate_files/claude_slop')" ]
ok 'glob rule' [ "$(sc_policy owner/beta)" = "$(printf 'branch\t')" ]
ok 'catch-all off' [ "$(sc_policy someone/else)" = "$(printf 'off\t')" ]
ok 'state-to-main without paths -> off' [ "$(sc_policy owner/bad1)" = "$(printf 'off\t')" ]
ok 'malformed path -> off' [ "$(sc_policy owner/bad2)" = "$(printf 'off\t')" ]
ok 'unknown policy -> off' [ "$(sc_policy owner/bad3)" = "$(printf 'off\t')" ]

# --- off: nothing happens --------------------------------------------------
Z=$(mkrepo someone else)
echo x > "$Z/scratch.txt"
run "$Z"
ok 'off: nothing committed' [ "$(git -C "$Z" status --porcelain)" = "?? scratch.txt" ]
ok 'off: recorded in checkpoint' has "$CKPT" 'off for someone/else'
ok 'off: silent status' [ -z "$SC_STATUS" ]

# --- state-to-main, shared checkout on main --------------------------------
old=$(git -C "$A" rev-parse HEAD)
sed -i '1s/.*/edited by session/' "$A/intermediate_files/claude_slop/kanban.md"
echo new > "$A/intermediate_files/claude_slop/new.md"
echo code > "$A/code.py"
echo changed > "$A/README.md"
run "$A" abcdef0123
tip=$(origin_tip "$A" main)
ok 's2m shared: origin/main advanced' [ "$tip" != "$old" ]
ok 's2m shared: linear on old tip' [ "$(git -C "$A" rev-parse "$tip^")" = "$old" ]
ok 's2m shared: signed' signed "$A" "$tip"
ok 's2m shared: only state paths in commit' [ "$(files_in "$A" "$tip" | sort | tr '\n' ' ')" = "intermediate_files/claude_slop/kanban.md intermediate_files/claude_slop/new.md " ]
ok 's2m shared: message names session' strhas "$(git -C "$A" log -1 --format=%s "$tip")" 'State: owner-alpha session abcdef01'
ok 's2m shared: local main synced' [ "$(git -C "$A" rev-parse HEAD)" = "$tip" ]
ok 's2m shared: state paths clean locally' [ -z "$(git -C "$A" status --porcelain -- intermediate_files)" ]
ok 's2m shared: other files untouched' [ "$(git -C "$A" status --porcelain | sort | tr '\n' ' ')" = " M README.md ?? code.py " ]
ok 's2m shared: status line' strhas "$SC_STATUS" '2 state file(s) -> origin/main'
ok 's2m shared: shared files recorded' strhas "$SC_STATUS" '2 file(s) uncommitted in the shared checkout'
ok 's2m shared: no worktree left' [ "$(nworktrees "$A")" = 1 ]
ok 's2m shared: no tmp left' not leftover_tmp

# --- state-to-main from a worktree while origin/main moves -----------------
git -C "$A" checkout -q -- README.md; rm -f "$A/code.py"
W="$T/alpha-wt"
git -C "$A" worktree add -q "$W" -b claude/x origin/main 2>/dev/null
other "$A" 'echo other > other.txt; echo appended >> intermediate_files/claude_slop/kanban.md'
moved=$(origin_tip "$A" main)
sed -i '1s/.*/edited in worktree/' "$W/intermediate_files/claude_slop/kanban.md"
echo code > "$W/code.py"
run "$W"
tip=$(origin_tip "$A" main)
ok 's2m wt: on top of moved main' [ "$(git -C "$A" rev-parse "$tip^")" = "$moved" ]
ok 's2m wt: three-way merged' [ "$(git -C "$A" show "$tip:intermediate_files/claude_slop/kanban.md")" = "$(printf 'edited in worktree\nline2\nline3\nappended')" ]
ok 's2m wt: signed' signed "$A" "$tip"
btip=$(origin_tip "$A" claude/x)
ok 's2m wt: other files on origin/branch' [ -n "$btip" ] && [ "$(files_in "$A" "$btip")" = "code.py" ]
ok 's2m wt: branch commit signed' signed "$W"
ok 's2m wt: branch commit message' strhas "$(git -C "$W" log -1 --format=%s)" 'Stop: salvage uncommitted files'
ok 's2m wt: state file still dirty in worktree (on main, not on branch)' [ "$(git -C "$W" status --porcelain)" = " M intermediate_files/claude_slop/kanban.md" ]
ok 's2m wt: status line' strhas "$SC_STATUS" 'origin/claude/x'
ok 's2m wt: no worktree left' [ "$(nworktrees "$A")" = 2 ]

# --- state-to-main conflict refuses ---------------------------------------
other "$A" 'sed -i "1s/.*/theirs/" intermediate_files/claude_slop/kanban.md'
moved=$(origin_tip "$A" main)
sed -i '1s/.*/ours/' "$W/intermediate_files/claude_slop/kanban.md"
run "$W"
ok 's2m conflict: origin/main untouched' [ "$(origin_tip "$A" main)" = "$moved" ]
ok 's2m conflict: refused loudly' has "$CKPT" 'NOT COMMITTED: state paths conflict'
ok 's2m conflict: status says so' strhas "$SC_STATUS" 'NOT COMMITTED'
ok 's2m conflict: no worktree left' [ "$(nworktrees "$A")" = 2 ]
ok 's2m conflict: no tmp left' not leftover_tmp
ok 's2m conflict: worktree file untouched' [ "$(head -1 "$W/intermediate_files/claude_slop/kanban.md")" = ours ]

# --- state paths already on origin ----------------------------------------
git -C "$W" checkout -q -- .
git -C "$W" fetch -q origin && git -C "$W" reset -q --hard origin/main
other "$A" 'echo again >> intermediate_files/claude_slop/kanban.md'
moved=$(origin_tip "$A" main)
echo again >> "$W/intermediate_files/claude_slop/kanban.md"
run "$W"
ok 's2m same: origin/main untouched' [ "$(origin_tip "$A" main)" = "$moved" ]
ok 's2m same: noted' has "$CKPT" 'already match origin/main'

# --- dry run ---------------------------------------------------------------
git -C "$W" checkout -q -- .
sed -i '1s/.*/dry/' "$W/intermediate_files/claude_slop/kanban.md"; echo d > "$W/dry.py"
moved=$(origin_tip "$A" main); bt=$(origin_tip "$A" claude/x); wh=$(git -C "$W" rev-parse HEAD)
SC_DRY=1 run "$W"
ok 'dry: origin/main untouched' [ "$(origin_tip "$A" main)" = "$moved" ]
ok 'dry: origin/branch untouched' [ "$(origin_tip "$A" claude/x)" = "$bt" ]
ok 'dry: nothing committed locally' [ "$(git -C "$W" rev-parse HEAD)" = "$wh" ]
ok 'dry: says what would happen' has "$CKPT" 'dry-run: 1 state file(s) would go to origin/main'
ok 'dry: says branch half too' has "$CKPT" 'dry-run: 1 file(s) would go to origin/claude/x'
ok 'dry: no worktree left' [ "$(nworktrees "$A")" = 2 ]
git -C "$W" checkout -q -- .; rm -f "$W/dry.py"

# --- branch policy, shared checkout: record only ---------------------------
B=$(mkrepo owner beta)
echo x > "$B/scratch.txt"
old=$(origin_tip "$B" main)
run "$B"
ok 'branch shared: nothing pushed' [ "$(origin_tip "$B" main)" = "$old" ]
ok 'branch shared: nothing committed' [ "$(git -C "$B" status --porcelain)" = "?? scratch.txt" ]
ok 'branch shared: recorded' strhas "$SC_STATUS" '1 file(s) uncommitted in the shared checkout'

# --- branch policy, worktree: everything goes ------------------------------
WB="$T/beta-wt"
git -C "$B" worktree add -q "$WB" -b claude/y origin/main 2>/dev/null
echo a > "$WB/a.txt"; echo changed > "$WB/README.md"; git -C "$WB" rm -q intermediate_files/claude_slop/kanban.md
run "$WB" feedbeef00
btip=$(origin_tip "$B" claude/y)
ok 'branch wt: pushed' [ -n "$btip" ] && [ "$btip" = "$(git -C "$WB" rev-parse HEAD)" ]
ok 'branch wt: all files' [ "$(files_in "$B" "$btip" | sort | tr '\n' ' ')" = "README.md a.txt intermediate_files/claude_slop/kanban.md " ]
ok 'branch wt: clean after' [ -z "$(git -C "$WB" status --porcelain)" ]
ok 'branch wt: signed' signed "$WB"
ok 'branch wt: upstream set' [ "$(git -C "$WB" rev-parse --abbrev-ref '@{u}')" = origin/claude/y ]
ok 'branch wt: main untouched' [ "$(origin_tip "$B" main)" = "$old" ]
ok 'branch wt: status' strhas "$SC_STATUS" '3 file(s) -> origin/claude/y'

# --- gitleaks refusal restores the index ----------------------------------
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

# --- a refusing repo hook wins ---------------------------------------------
hook="$(git -C "$B" rev-parse --path-format=absolute --git-path hooks)/pre-commit"
mkdir -p "$(dirname "$hook")"
printf '#!/bin/sh\necho "nope from hook"\nexit 1\n' > "$hook"; chmod +x "$hook"
echo h > "$WB/h.txt"
run "$WB"
ok 'hook: refused' has "$CKPT" 'NOT COMMITTED: commit on claude/y refused'
ok 'hook: output quoted' has "$CKPT" 'nope from hook'
ok 'hook: no commit' [ "$(git -C "$WB" rev-parse HEAD)" = "$btip" ]
ok 'hook: index restored' [ "$(git -C "$WB" status --porcelain)" = "?? h.txt" ]
rm -f "$hook"

# --- a hook that refuses on the main path too ------------------------------
printf '#!/bin/sh\nexit 1\n' > "$hook"; chmod +x "$hook"
WA2="$T/alpha-wt2"; git -C "$A" worktree add -q "$WA2" -b claude/w origin/main 2>/dev/null
moved=$(origin_tip "$A" main)
sed -i '1s/.*/hooked/' "$WA2/intermediate_files/claude_slop/kanban.md"
hookA="$(git -C "$A" rev-parse --path-format=absolute --git-path hooks)/pre-commit"
cp "$hook" "$hookA"; chmod +x "$hookA"
run "$WA2"
ok 's2m hook: refused' has "$CKPT" 'NOT COMMITTED: commit on origin/main refused'
ok 's2m hook: origin untouched' [ "$(origin_tip "$A" main)" = "$moved" ]
ok 's2m hook: no worktree left' [ "$(nworktrees "$A")" = 3 ]
rm -f "$hook" "$hookA"

# --- signing failure never pushes -----------------------------------------
git -C "$WB" config user.signingkey "$T/missing.pub"
echo s > "$WB/s.txt"
run "$WB"
ok 'signing: refused' has "$CKPT" 'NOT COMMITTED'
ok 'signing: no commit' [ "$(git -C "$WB" rev-parse HEAD)" = "$btip" ]
ok 'signing: index restored' [ "$(git -C "$WB" status --porcelain | sort | tr '\n' ' ')" = "?? h.txt ?? s.txt " ]
git -C "$WB" config user.signingkey "$T/signkey.pub"

# --- unconfigured filter refuses before anything ---------------------------
F=$(mkrepo owner filt)
printf '*.enc filter=sops\n' > "$F/.gitattributes"
git -C "$F" add .gitattributes && git -C "$F" commit -q -m attrs && git -C "$F" push -q origin main 2>/dev/null
WF="$T/filt-wt"; git -C "$F" worktree add -q "$WF" -b claude/f origin/main 2>/dev/null
echo x > "$WF/x.txt"
run "$WF"
ok 'filter: refused' has "$CKPT" "git filter 'sops' is declared"
ok 'filter: nothing committed' [ "$(git -C "$WF" status --porcelain)" = "?? x.txt" ]
ok 'filter: nothing pushed' [ -z "$(origin_tip "$F" claude/f)" ]

# --- direct invocation ------------------------------------------------------
out=$(bash "$HOOKS/lib-stop-commit.sh" "$WB" 2>&1)
ok 'direct: key' strhas "$out" 'key:      owner/beta'
ok 'direct: policy' strhas "$out" 'policy:   branch'
ok 'direct: worktree' strhas "$out" 'checkout: isolated worktree'
out=$(bash "$HOOKS/lib-stop-commit.sh" --dry-run "$WB" 2>&1)
ok 'direct dry-run: rehearses' strhas "$out" 'dry-run: 2 file(s) would go to origin/claude/y'
ok 'direct dry-run: no commit' [ "$(git -C "$WB" rev-parse HEAD)" = "$btip" ]

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]

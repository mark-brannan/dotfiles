#!/usr/bin/env bash
# Tests for yadm-post-checkout.sh. Run: bash .local/bin/yadm-post-checkout.test.sh
# A yadm-shaped repo (git dir apart, core.worktree = $HOME), checked out
# without CLAUDE.md and the hook linked in, as bootstrap does: CLAUDE.md stays
# out across a pull; worktrees that existed keep it; a new worktree, from
# either route, gets it back, and $HOME stays sparse.
set -uo pipefail

HK="$(cd "$(dirname "$0")" && pwd)/yadm-post-checkout.sh"
pass=0; fail=0
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
export HOME="$S/home"; mkdir -p "$HOME/.local/bin"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
present() { [ -e "$1" ] && ok || bad "expected $1"; }
absent()  { [ -e "$1" ] && bad "did not expect $1" || ok; }

# --- origin, and a yadm-shaped clone of it ----------------------------------
O="$S/origin"; git init -q -b main "$O"; mkdir -p "$O/.claude"
echo conv > "$O/CLAUDE.md"; echo so > "$O/.claude/CLAUDE.md"; echo b > "$O/.bashrc"
git -C "$O" add CLAUDE.md .claude/CLAUDE.md .bashrc; git -C "$O" commit -q -m init
R="$S/repo.git"; git clone -q --bare "$O" "$R"
G=(git --git-dir="$R")
"${G[@]}" config core.bare false; "${G[@]}" config core.worktree "$HOME"
"${G[@]}" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
"${G[@]}" fetch -q; "${G[@]}" checkout -q -f -B main origin/main
mkdir -p "$S/bin"; printf '#!/bin/sh\nexec git --git-dir="%s" "$@"\n' "$R" > "$S/bin/yadm"; chmod +x "$S/bin/yadm"
export PATH="$S/bin:$PATH"

present "$HOME/CLAUDE.md"
yadm worktree add -q "$S/old" -b old 2>/dev/null

# --- what bootstrap does ----------------------------------------------------
ln -s "$HK" "$R/hooks/post-checkout"
(cd "$HOME" && yadm sparse-checkout set --no-cone '/*' '!/CLAUDE.md') || bad "sparse-checkout set failed"
absent "$HOME/CLAUDE.md"; present "$HOME/.claude/CLAUDE.md"; present "$HOME/.bashrc"
[ -z "$(yadm status --short -uno)" ] && ok || bad "status not clean after install"
present "$S/old/CLAUDE.md"

# --- a pull that changes CLAUDE.md keeps it out ------------------------------
echo conv2 > "$O/CLAUDE.md"; echo b2 > "$O/.bashrc"
git -C "$O" add CLAUDE.md .bashrc; git -C "$O" commit -q -m two
(cd "$HOME" && yadm fetch -q && yadm merge -q --ff-only origin/main) || bad "ff merge failed"
absent "$HOME/CLAUDE.md"; [ "$(cat "$HOME/.bashrc")" = b2 ] && ok || bad ".bashrc not updated"

# --- new worktrees, both routes, get the whole tree --------------------------
(cd "$HOME" && yadm worktree add -q "$HOME/.claude/worktrees/a" -b a) 2>/dev/null
present "$HOME/.claude/worktrees/a/CLAUDE.md"
git --git-dir="$R" worktree add -q "$S/b" -b b 2>/dev/null
present "$S/b/CLAUDE.md"
absent "$HOME/CLAUDE.md"

[ "$(git --git-dir="$R" config --get core.sparseCheckout)" = true ] && ok || bad "$HOME no longer sparse"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

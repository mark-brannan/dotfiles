#!/usr/bin/env bash
# Tests for home-sparse.sh. Run: bash .local/bin/home-sparse.test.sh
# A yadm-shaped repo (git dir apart, core.worktree = $HOME): --install drops
# CLAUDE.md from $HOME and keeps it out across a pull; worktrees that existed
# keep it; a new worktree, from either route, gets it back; a second
# --install is a no-op; a foreign post-checkout hook is left alone.
set -uo pipefail

HS="$(cd "$(dirname "$0")" && pwd)/home-sparse.sh"
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
cp "$HS" "$HOME/.local/bin/home-sparse.sh"
mkdir -p "$S/bin"; printf '#!/bin/sh\nexec git --git-dir="%s" "$@"\n' "$R" > "$S/bin/yadm"; chmod +x "$S/bin/yadm"
export PATH="$S/bin:$PATH"

present "$HOME/CLAUDE.md"
yadm worktree add -q "$S/old" -b old 2>/dev/null

# --- install ----------------------------------------------------------------
out=$(cd "$HOME" && sh "$HOME/.local/bin/home-sparse.sh" --install 2>&1) || bad "install failed: $out"
absent "$HOME/CLAUDE.md"; present "$HOME/.claude/CLAUDE.md"; present "$HOME/.bashrc"
[ -z "$(yadm status --short -uno)" ] && ok || bad "status not clean after install"
present "$S/old/CLAUDE.md"
[ "$(readlink "$R/hooks/post-checkout")" = "$HOME/.local/bin/home-sparse.sh" ] && ok || bad "hook not linked"

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

# --- idempotent; a foreign hook is left alone --------------------------------
(cd "$HOME" && sh "$HOME/.local/bin/home-sparse.sh" --install >/dev/null 2>&1) && ok || bad "second install failed"
rm "$R/hooks/post-checkout"; echo '#!/bin/sh' > "$R/hooks/post-checkout"
(cd "$HOME" && sh "$HOME/.local/bin/home-sparse.sh" --install >/dev/null 2>&1) && bad "clobbered a foreign hook" || ok
[ "$(cat "$R/hooks/post-checkout")" = '#!/bin/sh' ] && ok || bad "foreign hook changed"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

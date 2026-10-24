#!/bin/sh
# Tests for dotfiles-sync.sh: each repo pulled ff-only with autostash; a
# clean carry-over of a dirty file; a conflicted re-apply made valid again
# with the edits kept in the stash; a diverged clone left alone; a plugin
# update that fails, named. Run: sh .local/bin/dotfiles-sync.test.sh
# Fake homes and local bare repos, ~2 s wall, one core, no network.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; SYNC="$HERE/dotfiles-sync.sh"
pass=0; fail=0; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME XDG_DATA_HOME GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
G="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c init.defaultBranch=main"
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'; }
has() { printf '%s' "$2" | grep -q -- "$1" && ok || bad "expected /$1/ in: $3" "$2"; }
eq()  { [ "$1" = "$2" ] && ok || bad "$3: expected '$2', got '$1'"; }

H="$W/home"; mkdir -p "$H/.local/bin" "$H/.local/share/yadm"
# yadm and claude stand-ins; the script resets PATH to $HOME/.local/bin first
printf '#!/bin/sh\n[ "$1" = alt ] && exit 0\nexec git --git-dir="$HOME/.local/share/yadm/repo.git" --work-tree="$HOME" "$@"\n' > "$H/.local/bin/yadm"
printf '#!/bin/sh\necho "$*" >> "$HOME/claude.log"\n[ -e "$HOME/plugin-broken" ] && exit 1\nexit 0\n' > "$H/.local/bin/claude"
chmod +x "$H/.local/bin/yadm" "$H/.local/bin/claude"
Y() { HOME="$H" "$H/.local/bin/yadm" "$@"; }
seed() { # seed NAME: a bare repo with one commit, and NAME-up as a clone of it
	$G init -q --bare "$W/$1.git"; $G clone -q "$W/$1.git" "$W/$1-up" 2>/dev/null
	printf '{\n  "a": 1,\n  "b": 2,\n  "c": 3,\n  "d": 4,\n  "e": 5\n}\n' > "$W/$1-up/settings.json"
	$G -C "$W/$1-up" add -A; $G -C "$W/$1-up" commit -qm seed; $G -C "$W/$1-up" push -q origin main
}
seed dot; seed claude
Y init -q -b main; Y config core.bare false; Y config core.worktree "$H"; Y remote add origin "$W/dot.git"
Y fetch -q origin; Y reset -q --hard origin/main; Y branch -q --set-upstream-to=origin/main main
$G clone -q "$W/claude.git" "$H/.claude" 2>/dev/null
sync() { HOME="$H" sh "$SYNC" >/dev/null 2>&1; cat "$H/.local/state/dotfiles-sync/last"; }
up()   { printf '%s\n' "$2" > "$W/$1-up/settings.json"; $G -C "$W/$1-up" commit -qam up; $G -C "$W/$1-up" push -q origin main; }
C="$H/.claude"; cur() { $G -C "$W/claude-up" show HEAD:settings.json; }

# T1: level everywhere
out=$(sync); has "dotfiles: current at $($G -C "$W/dot-up" rev-parse --short HEAD); claude: current at $($G -C "$W/claude-up" rev-parse --short HEAD); languette: current" "$out" "T1 all current"
has 'plugin marketplace update languette' "$(cat "$H/claude.log")" "T1 marketplace refreshed"

# T2: both clones behind, clean: pulled
up dot "$(cur | sed 's/"e": 5/"e": 50/')"; up claude "$(cur | sed 's/"e": 5/"e": 50/')"
out=$(sync); eq "$(git -C "$C" rev-parse HEAD)" "$($G -C "$W/claude-up" rev-parse HEAD)" "T2 clone at upstream"
eq "$(Y rev-parse HEAD)" "$($G -C "$W/dot-up" rev-parse HEAD)" "T2 home at upstream"

# T3: a dirty settings.json the UI wrote (one hunk), upstream touched another: both land, no stash
cur | sed 's/"a": 1/"a": 10/' > "$C/settings.json"; up claude "$(cur | sed 's/"c": 3/"c": 30/')"
out=$(sync); has "claude: current at $($G -C "$W/claude-up" rev-parse --short HEAD)" "$out" "T3 pulled"
eq "$(cat "$C/settings.json")" "$(cur | sed 's/"a": 1/"a": 10/')" "T3 both edits live"
eq "$(git -C "$C" stash list | wc -l)" 0 "T3 nothing left in the stash"

# T4: the same hunk on both sides: upstream's valid file is live, the edit is in the stash, HEAD moved
cur | sed 's/"a": 1,/"a": 11,/' > "$C/settings.json"; up claude "$(cur | sed 's/"a": 1,/"a": 12,/')"
out=$(sync); has 'claude: skipped your edits to settings.json: they conflicted with upstream and are in git stash' "$out" "T4 named"
eq "$(cat "$C/settings.json")" "$(cur)" "T4 upstream copy live, no markers"
eq "$(git -C "$C" stash list | wc -l)" 1 "T4 edit kept in the stash"
eq "$(git -C "$C" rev-parse HEAD)" "$($G -C "$W/claude-up" rev-parse HEAD)" "T4 clone at upstream"
has '"a": 11' "$(git -C "$C" show 'stash@{0}:settings.json')" "T4 the stash holds the edit"
eq "$(git -C "$C" status --short | wc -l)" 0 "T4 tree clean"

# T5: a local commit: ff-only refuses, nothing moves, says so
echo '# local' >> "$C/CLAUDE.md"; git -C "$C" add CLAUDE.md; $G -C "$C" commit -qm local; up claude "$(cur | sed 's/"e": 50/"e": 5/')"
before=$(git -C "$C" rev-parse HEAD)
out=$(sync); has 'claude: skipped: pull failed (diverged, offline?), pull by hand' "$out" "T5 named"
eq "$(git -C "$C" rev-parse HEAD)" "$before" "T5 HEAD unmoved"
git -C "$C" reset -q --hard origin/main

# T6: a plugin update that fails is named; the other repos still report
touch "$H/plugin-broken"
out=$(sync); has 'languette: update failed, run claude plugin update languette@languette by hand' "$out" "T6 named"
has 'claude: current at' "$out" "T6 others still reported"

echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]

#!/bin/sh
# Tests for dotfiles-sync.sh keeping ~/.claude across the commit that untracks
# it. Run: sh .local/bin/dotfiles-sync.test.sh
#
# Same fixtures as dotfiles-claude-clone.test.sh (fake homes, local bare repos,
# dotfiles main going C1 tracks .claude -> C2 stops tracking it). ~2 s wall,
# one core.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SYNC="$HERE/dotfiles-sync.sh"; CLONE="$HERE/dotfiles-claude-clone.sh"
pass=0; fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME XDG_DATA_HOME GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
G="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c init.defaultBranch=main"

ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'; }
has() { printf '%s' "$2" | grep -q -- "$1" && ok || bad "expected /$1/ in: $3" "$2"; }
eq()  { [ "$1" = "$2" ] && ok || bad "$3: expected '$2', got '$1'"; }

# The script resets PATH to $HOME/.local/bin first, so the yadm stand-in lives
# in each fake home, never the real one.
cat > "$W/yadm" <<'Y'
#!/bin/sh
exec git --git-dir="$HOME/.local/share/yadm/repo.git" --work-tree="$HOME" "$@"
Y
chmod +x "$W/yadm"
ydm() { h=$1; shift; HOME="$h" "$W/yadm" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

CLAUDE="$W/claude.git"; git init -q --bare "$CLAUDE"
S="$W/seed"; mkdir -p "$S"
# A small stand-in layer: the real one left this repo (#358). settings.json
# names an executable hook and a library, as the real one does.
mkdir -p "$S/hooks" "$S/rules"
printf '#!/bin/sh\nexit 0\n' > "$S/hooks/guard.sh"; chmod +x "$S/hooks/guard.sh"
echo 'BEGIN { }' > "$S/hooks/lib-words.awk"; echo '# standing orders' > "$S/CLAUDE.md"; echo '# code' > "$S/rules/code.md"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"$HOME/.claude/hooks/guard.sh $HOME/.claude/hooks/lib-words.awk"}]}]}}\n' > "$S/settings.json"
$G -C "$S" init -q && $G -C "$S" add -A && $G -C "$S" commit -q -m "claude layer" && $G -C "$S" push -q "$CLAUDE" main
NHOOKS=$(find "$S/hooks" -type f | wc -l)

DOT="$W/dotfiles.git"; git init -q --bare "$DOT"
D="$W/dot"; mkdir -p "$D"; cp -a "$S" "$D/.claude"; rm -rf "$D/.claude/.git"; echo x > "$D/.zshrc"
$G -C "$D" init -q && $G -C "$D" add -A && $G -C "$D" commit -q -m "C1 tracks .claude" && $G -C "$D" push -q "$DOT" main
C1=$($G -C "$D" rev-parse HEAD)
$G -C "$D" rm -rq .claude && $G -C "$D" commit -q -m "C2 stop tracking .claude"
C2=$($G -C "$D" rev-parse HEAD); $G -C "$D" push -q "$DOT" "$C2:refs/heads/c2"
main_is() { git -C "$DOT" update-ref refs/heads/main "$1"; }
main_is "$C1"

home() {
	h="$W/$1"; mkdir -p "$h/.local/share/yadm" "$h/.local/bin"; cp "$W/yadm" "$h/.local/bin/yadm"
	ydm "$h" init -q && ydm "$h" config core.bare false && ydm "$h" config core.worktree "$h" && ydm "$h" config status.showUntrackedFiles no \
		&& ydm "$h" remote add origin "$DOT" && ydm "$h" fetch -q origin && ydm "$h" reset -q --hard origin/main
	mkdir -p "$h/.claude/projects/p"; echo s > "$h/.claude/projects/p/x"
}
sync()  { HOME="$W/$1" sh "$SYNC" 2>&1; cat "$W/$1/.local/state/dotfiles-sync/last"; }
move()  { HOME="$W/$1" CLAUDE_REPO="$CLAUDE" sh "$CLONE" move 2>&1; }
check() { HOME="$W/$1" CLAUDE_REPO="$CLAUDE" sh "$CLONE" check 2>&1; }
hooks() { find "$1/.claude/hooks" -type f 2>/dev/null | wc -l; }

# S1: nested clone in place, then the untrack commit arrives
home A; move A >/dev/null; main_is "$C2"; out=$(sync A)
has "kept [0-9]* .claude file" "$out" "S1 report names what it kept"
eq "$(hooks "$W/A")" "$NHOOKS" "S1 hooks survive the pull"
out=$(check A); has 'hooks: ok' "$out" "S1 check"; has 'source: clone' "$out" "S1 source"
eq "$(git -C "$W/A/.claude" status --porcelain | wc -l)" 0 "S1 clone is clean"
eq "$(ydm "$W/A" ls-files .claude | wc -l)" 0 "S1 yadm no longer tracks .claude"

# S2: no clone yet, the untrack commit arrives; settings.json and hooks stay
main_is "$C1"; home B; main_is "$C2"; out=$(sync B)
has "kept .* .claude file" "$out" "S2 report"
eq "$(hooks "$W/B")" "$NHOOKS" "S2 hooks survive the pull"
[ -f "$W/B/.claude/settings.json" ] && ok || bad "S2 settings.json kept"
x=$(cd "$S/hooks" && find . -type f -perm -u+x | head -1)
[ -n "$x" ] && [ -x "$W/B/.claude/hooks/$x" ] && ok || bad "S2 exec bit kept on ${x:-<no executable hook in seed>}"
out=$(check B); has 'hooks: ok' "$out" "S2 check"
out=$(move B); has '^done; snapshot in' "$out" "S2 move still runs after the keep"
out=$(check B); has 'source: clone' "$out" "S2 check after move"; has 'hooks: ok' "$out" "S2 hooks after move"

# S3: a pull that touches no .claude file reports no keep
main_is "$C1"; home C; out=$(sync C); has 'level with origin/main' "$out" "S3 level"
$G -C "$D" checkout -q -b side "$C1"; echo y >> "$D/.zshrc"; $G -C "$D" commit -q -am "zshrc"; git -C "$D" push -q "$DOT" side:refs/heads/main -f
out=$(sync C); has 'fast-forwarded 1 commit' "$out" "S3 plain pull"; case "$out" in *kept*) bad "S3 says kept" "$out";; *) ok;; esac

# S4: before the split, a pull that deletes one .claude file on purpose keeps it deleted
main_is "$C1"; home E; f=$(cd "$S" && find hooks -type f | head -1)
$G -C "$D" checkout -q -b drop "$C1"; $G -C "$D" rm -q ".claude/$f"; $G -C "$D" commit -q -m "drop one hook"; git -C "$D" push -q "$DOT" drop:refs/heads/main -f
out=$(sync E); has 'fast-forwarded 1 commit' "$out" "S4 pull"
[ -e "$W/E/.claude/$f" ] && bad "S4 resurrected $f" "$out" || ok

echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]

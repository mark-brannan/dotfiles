#!/bin/sh
# Tests for dotfiles-claude-clone.sh. Run: sh .local/bin/dotfiles-claude-clone.test.sh
#
# Fake homes, a local bare repo standing in for the Claude layer's repo
# (seeded with a small stand-in layer), and a local bare dotfiles whose main
# goes C1 (tracks .claude) -> C2 (stops tracking) -> C3 (reverts C2). Real
# yadm when it is on PATH; otherwise a three-line stand-in, since yadm is
# git with its repo dir and work tree fixed. ~10 s wall, one core.
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/dotfiles-claude-clone.sh"
pass=0; fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# yadm finds its repo under $XDG_DATA_HOME before $HOME: with it set, the
# script under test would act on the real $HOME.
unset XDG_CONFIG_HOME XDG_DATA_HOME GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
G="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c init.defaultBranch=main"

ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'; }
has()  { printf '%s' "$2" | grep -q -- "$1" && ok || bad "expected /$1/ in: $3" "$2"; }
eq()   { [ "$1" = "$2" ] && ok || bad "$3: expected '$2', got '$1'"; }

# yadm stand-in; also how every fixture step talks to a fake home's yadm repo.
mkdir -p "$W/bin"; cat > "$W/bin/yadm" <<'EOF'
#!/bin/sh
exec git --git-dir="$HOME/.local/share/yadm/repo.git" --work-tree="$HOME" "$@"
EOF
chmod +x "$W/bin/yadm"
command -v yadm >/dev/null 2>&1 || export PATH="$W/bin:$PATH"
ydm() { h=$1; shift; HOME="$h" "$W/bin/yadm" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

# --- the Claude layer's repo: a stand-in layer at its top level --------
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

# --- dotfiles: C1 tracks .claude, C2 stops, C3 reverts ---------------------
DOT="$W/dotfiles.git"; git init -q --bare "$DOT"
D="$W/dot"; mkdir -p "$D"; cp -a "$S" "$D/.claude"; rm -rf "$D/.claude/.git"; echo x > "$D/.zshrc"
$G -C "$D" init -q && $G -C "$D" add -A && $G -C "$D" commit -q -m "C1 tracks .claude" && $G -C "$D" push -q "$DOT" main
C1=$($G -C "$D" rev-parse HEAD)
$G -C "$D" rm -rq .claude && $G -C "$D" commit -q -m "C2 stop tracking .claude"
C2=$($G -C "$D" rev-parse HEAD)
$G -C "$D" revert --no-edit HEAD >/dev/null
C3=$($G -C "$D" rev-parse HEAD); $G -C "$D" push -q "$DOT" main
main_is() { git -C "$DOT" update-ref refs/heads/main "$1"; }
main_is "$C1"

# A fake home: yadm clone of dotfiles at main, plus Claude Code's runtime litter.
home() {
	h="$W/$1"; mkdir -p "$h/.local/share/yadm"
	ydm "$h" init -q && ydm "$h" config core.bare false && ydm "$h" config core.worktree "$h" && ydm "$h" config status.showUntrackedFiles no \
		&& ydm "$h" remote add origin "$DOT" && ydm "$h" fetch -q origin && ydm "$h" reset -q --hard origin/main
	if [ "${2:-}" != nolitter ]; then
		mkdir -p "$h/.claude/projects/p" "$h/.claude/worktrees/w"; echo t > "$h/.claude/.credentials.json"; echo s > "$h/.claude/projects/p/x"
	fi
}
cron()   { ydm "$1" fetch -q origin && ydm "$1" merge -q --ff-only origin/main 2>&1; }
run()    { h="$W/$1"; shift; HOME="$h" CLAUDE_REPO="$CLAUDE" sh "$SCRIPT" "$@" 2>&1; }
hooks()  { find "$1/.claude/hooks" -type f 2>/dev/null | wc -l; }
litter() { [ -f "$1/.claude/projects/p/x" ] && echo yes || echo no; }
cred()   { HOME=$1 git -C "$1/.claude" status --porcelain --ignored .credentials.json 2>/dev/null | cut -c1-2; }

# S1: clone set up before C2, then cron pulls C2
home A; out=$(run A move); has '^done; snapshot in' "$out" "S1 move"
eq "$(hooks "$W/A")" "$NHOOKS" "S1 hooks after move"; eq "$(cred "$W/A")" "!!" "S1 credentials ignored by clone"
main_is "$C2"; cron "$W/A"
eq "$(hooks "$W/A")" 0 "S1 pull of C2 deletes the hooks even with the clone in place"
out=$(run A check); r=$?; eq "$r" 1 "S1 check exits 1"; has 'FAIL: missing' "$out" "S1 check"
out=$(run A move); eq "$(hooks "$W/A")" "$NHOOKS" "S1 move re-run restores"
out=$(run A check); r=$?; eq "$r" 0 "S1 check exits 0"; has 'source: clone of .*claude.git, 0 local change' "$out" "S1 check source"; has 'hooks: ok' "$out" "S1 check hooks"

# S2: C2 pulled with no clone, then repaired
main_is "$C1"; home B; main_is "$C2"; cron "$W/B"
eq "$(hooks "$W/B")" 0 "S2 pull of C2 with no clone"
out=$(run B check); r=$?; eq "$r" 1 "S2 check exits 1"; has 'source: yadm, 0 file' "$out" "S2 check source"
out=$(run B move); eq "$(hooks "$W/B")" "$NHOOKS" "S2 move restores"
eq "$(litter "$W/B")" yes "S2 litter kept"; eq "$(cred "$W/B")" "!!" "S2 credentials ignored"
out=$(run B check); has 'hooks: ok' "$out" "S2 check"

# S3: fresh machine, no ~/.claude
home C nolitter; rm -rf "$W/C/.claude"
out=$(run C move); eq "$(hooks "$W/C")" "$NHOOKS" "S3 fresh move"; out=$(run C check); has 'hooks: ok' "$out" "S3 check"

# S4: re-run with an unpushed commit and an uncommitted edit in the clone
echo local > "$W/A/.claude/local.txt"; HOME=$W/A $G -C "$W/A/.claude" add -f local.txt; HOME=$W/A $G -C "$W/A/.claude" commit -q -m local
echo '# edit' >> "$W/A/.claude/CLAUDE.md"
out=$(run A move); eq "$(cat "$W/A/.claude/local.txt")" local "S4 local commit kept"; has '# edit' "$(cat "$W/A/.claude/CLAUDE.md")" "S4 uncommitted edit kept"
out=$(run A check); has '1 local change' "$out" "S4 check counts the edit"

# S5: rollback before the revert lands
out=$(run A rollback); has "untrack commit: .*/$C2" "$out" "S5 names the untrack commit"; has 'done; restored from dotfiles' "$out" "S5 rollback"
eq "$(hooks "$W/A")" "$NHOOKS" "S5 hooks"; [ -d "$W/A/.claude/.git" ] && bad "S5 clone .git still in place" || ok
has 'dot-git' "$(ls "$W/A"/claude-snapshot-*/ | tr '\n' ' ')" "S5 snapshot holds the clone's .git"
out=$(run A check); has 'source: yadm' "$out" "S5 check source"; has 'hooks: ok' "$out" "S5 check hooks"
has '^A  .claude/settings.json' "$(ydm "$W/A" status --short)" "S5 yadm shows .claude added"

# S6: revert lands; A (rolled back) pulls clean, B (clone) refuses until it rolls back
main_is "$C3"; out=$(cron "$W/A"); eq "$?" 0 "S6 rolled-back machine pulls the revert"
eq "$(ydm "$W/A" status --short | wc -l)" 0 "S6 A clean after the revert"
out=$(cron "$W/B"); has 'untracked working tree files would be overwritten' "$out" "S6 clone machine refuses the revert"
out=$(run B rollback); out=$(cron "$W/B"); eq "$?" 0 "S6 B pulls after rollback"
out=$(run B check); has 'source: yadm' "$out" "S6 B check"; has 'hooks: ok' "$out" "S6 B hooks"

# S7: rollback re-run after the revert is idempotent
out=$(run A rollback); has "restored from dotfiles $(git -C "$DOT" rev-parse --short "$C3")" "$out" "S7 restores from HEAD"
out=$(run A check); has 'hooks: ok' "$out" "S7 check"

# S8: rollback on a clone whose tracked files are all gone (nothing to snapshot)
main_is "$C2"; home E nolitter; out=$(run E move)
git -C "$W/E/.claude" ls-tree --name-only HEAD | while IFS= read -r p; do rm -rf "$W/E/.claude/$p"; done
out=$(run E rollback); r=$?; eq "$r" 0 "S8 rollback exits 0 with nothing to snapshot"
has 'dot-git' "$(ls "$W/E"/claude-snapshot-*/ | tr '\n' ' ')" "S8 snapshot holds the clone's .git"; out=$(run E check); has 'hooks: ok' "$out" "S8 check"

echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]

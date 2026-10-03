#!/bin/sh
# Which repo delivers ~/.claude: yadm (dotfiles), or its own clone.
#
#   dotfiles-claude-clone.sh move      ~/.claude becomes a clone of the Claude
#                                      layer's repo (CLAUDE_REPO overrides the
#                                      URL). Safe to re-run: restores files a
#                                      dotfiles pull deleted, keeps local work.
#   dotfiles-claude-clone.sh check     prints who delivers ~/.claude and whether
#                                      every file settings.json names exists;
#                                      exit 1 if not.
#   dotfiles-claude-clone.sh rollback  ~/.claude back to yadm's copy; the
#                                      clone's .git is moved aside, not deleted.
#
# move and rollback copy whatever they overwrite to ~/claude-snapshot-<time>
# and never push. RUNBOOK.md says when to run which. Gate: exits 1 on a
# failure it can name.
set -eu

REPO=${CLAUDE_REPO:-git@github.com:mark-brannan/claude.git}
SNAP="$HOME/claude-snapshot-$(date +%Y%m%d-%H%M%S)"

# stdin: paths relative to the current directory; copies the ones that exist.
snapshot() {
	while IFS= read -r f; do
		[ -e "$f" ] || continue
		mkdir -p "$SNAP/$(dirname "$f")" && cp -a "$f" "$SNAP/$f"
	done
}

move() {
	yadm pull -q --ff-only || echo "WARN: yadm pull failed; run dotsync, then this again" >&2
	mkdir -p "$HOME/.claude" && cd "$HOME/.claude"
	git init -q
	git remote add origin "$REPO" 2>/dev/null || git remote set-url origin "$REPO"
	git fetch -q origin main
	git ls-tree --name-only origin/main | snapshot
	# Whitelist the repo's own top-level paths; Claude Code's runtime files
	# (projects/, worktrees/, .credentials.json, ...) stay invisible to git.
	{ echo '/*'; git ls-tree --name-only origin/main | sed 's|^|!/|'; } > .git/info/exclude
	if git rev-parse -q --verify HEAD >/dev/null; then
		git ls-files -d | while IFS= read -r f; do git checkout -q -- "$f"; done
	else
		git checkout -q -f -B main --track origin/main
	fi
	echo "done; snapshot in $SNAP"
}

check() {
	cd "$HOME"
	if [ -d .claude/.git ]; then
		echo "source: clone of $(git -C .claude remote get-url origin), $(git -C .claude status --porcelain | wc -l) local change(s)"
	else
		echo "source: yadm, $(yadm ls-files .claude | wc -l) file(s)"
	fi
	[ -f .claude/settings.json ] || { echo "FAIL: missing .claude/settings.json"; exit 1; }
	python3 - <<'PY'
import json, os, re, sys
t = open(os.path.expanduser("~/.claude/settings.json")).read(); json.loads(t)
gone = sorted({f for f in re.findall(r"\$HOME/(\.claude/[\w./-]+)", t) if not os.path.exists(os.path.expanduser("~/" + f))})
if gone: sys.exit("FAIL: missing " + " ".join(gone))
print("hooks: ok, every file settings.json names is present")
PY
}

rollback() {
	cd "$HOME"
	if yadm ls-files --error-unmatch .claude/settings.json >/dev/null 2>&1; then
		SRC=HEAD
	else
		U=$(yadm log --diff-filter=D --format=%H -1 -- .claude/settings.json)
		[ -n "$U" ] || { echo "FAIL: no dotfiles commit removes .claude/settings.json"; exit 1; }
		echo "untrack commit: https://github.com/mark-brannan/dotfiles/commit/$U"
		SRC="$U^"
	fi
	yadm ls-tree --name-only "$SRC" .claude/ | snapshot
	if [ -d .claude/.git ]; then mkdir -p "$SNAP" && mv .claude/.git "$SNAP/dot-git"; fi
	yadm checkout "$SRC" -- .claude
	echo "done; restored from dotfiles $(yadm rev-parse --short "$SRC"); snapshot in $SNAP"
}

case "${1:-}" in
move|check|rollback) "$1" ;;
*) echo "usage: dotfiles-claude-clone.sh move|check|rollback" >&2; exit 1 ;;
esac

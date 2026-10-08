#!/bin/sh
# Unattended fast-forward of $HOME's dotfiles from origin/main, then of the
# ~/.claude clone, then the Claude Code plugins named in $SYNC_PLUGINS. Safe to
# run every few minutes: it never rebases, stashes or merges, so the only
# outcomes are "fast-forwarded", "nothing to do", or "skipped, here's why". Git
# refuses a fast-forward that would overwrite a dirty tracked file, atomically,
# which is the whole safety story -- see README "Why the cron sync is ff-only".
#
#   dotfiles-sync.sh            run once (what cron calls)
#   dotfiles-sync.sh --install  add the crontab line, idempotently
#   dotfiles-sync.sh --status   print the last result and exit
#
# Convenience, not a gate: always exits 0. Result goes to syslog (tag
# dotfiles-sync) and to $STATE/last, one line, for heartbeats to read.
set -u

PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
STATE="$HOME/.local/state/dotfiles-sync"
LOCK="$STATE/lock"
SELF="$HOME/.local/bin/dotfiles-sync.sh"
SYNC_PLUGINS="${SYNC_PLUGINS-languette@languette}"
CRON_LINE="*/5 * * * * $SELF # dotfiles-sync"

mkdir -p "$STATE"

report() {
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" > "$STATE/last"
	if command -v logger >/dev/null 2>&1; then logger -t dotfiles-sync "$*"; fi
}

case "${1:-}" in
--status)
	cat "$STATE/last" 2>/dev/null || echo "never run"
	exit 0 ;;
--install)
	command -v crontab >/dev/null 2>&1 || { echo "no crontab on this machine" >&2; exit 0; }
	if crontab -l 2>/dev/null | grep -Fq '# dotfiles-sync'; then
		echo "crontab line already present"
	else
		{ crontab -l 2>/dev/null; echo "$CRON_LINE"; } | crontab -
		echo "installed: $CRON_LINE"
	fi
	exit 0 ;;
'') ;;
*)	echo "usage: dotfiles-sync.sh [--install|--status]" >&2; exit 0 ;;
esac

# mkdir is the portable atomic lock (macOS has no flock). A lock older than
# ten minutes is a crashed run, not a live one.
if ! mkdir "$LOCK" 2>/dev/null; then
	if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
		rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null || exit 0
	else
		exit 0
	fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# ff_only CMD: fast-forward CMD's checkout to origin/main, or say why
# not. CMD is yadm or a function wrapping git -C. Prints one phrase; returns 0
# only when HEAD moved.
ff_only() {
	g=$1
	gitdir=$($g rev-parse --absolute-git-dir 2>/dev/null) || { echo "skipped: no repo"; return 1; }
	# A checkout mid-merge, mid-rebase or holding unmerged paths needs a
	# person; anything automatic here would compound it.
	if [ -e "$gitdir/MERGE_HEAD" ] || [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]; then
		echo "skipped: merge or rebase in progress, resolve by hand"; return 1
	fi
	unmerged=$($g diff --name-only --diff-filter=U 2>/dev/null)
	if [ -n "$unmerged" ]; then
		echo "skipped: unmerged paths, resolve by hand: $(echo "$unmerged" | tr '\n' ' ')"; return 1
	fi
	if ! $g fetch --quiet --prune origin 2>/dev/null; then
		echo "fetch failed (offline?), $($g rev-list --count HEAD..origin/main 2>/dev/null || echo '?') behind at last fetch"
		return 1
	fi
	ahead=$($g rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
	behind=$($g rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
	if [ "$behind" -eq 0 ]; then
		if [ "$ahead" -gt 0 ]; then echo "level with origin/main, $ahead local commit(s) unpushed"
		else echo "level with origin/main"; fi
		return 1
	fi
	if [ "$ahead" -gt 0 ]; then
		echo "skipped: $ahead ahead and $behind behind, not fast-forwardable, pull by hand"
		return 1
	fi
	if $g merge --ff-only --quiet origin/main >/dev/null 2>&1; then
		echo "fast-forwarded $behind commit(s) to $($g rev-parse --short HEAD)"; return 0
	fi
	# The refusal is git protecting a dirty file that an incoming commit also
	# touches. Name them so the log says what a person has to look at.
	blockers=$( { $g diff --name-only HEAD; $g diff --name-only HEAD origin/main; } 2>/dev/null | sort | uniq -d | tr '\n' ' ')
	echo "skipped: $behind behind, fast-forward refused by dirty files: ${blockers:-unknown}"
	return 1
}

# shellcheck disable=SC2317  # called through ff_only's $g
claude_git() { git -C "$HOME/.claude" "$@"; }

# installed_sha PLUGIN: the commit the installed copy was built from; empty
# when PLUGIN has no entry. Stops at the next plugin's key, so an entry
# without a sha never borrows its neighbour's.
installed_sha() {
	awk -v key="\"$1\"" '
		found && /^[[:space:]]*"[^"]*@[^"]*"[[:space:]]*:/ && !index($0, key) { exit }
		index($0, key) { found = 1 }
		found && /"gitCommitSha"/ { gsub(/.*"gitCommitSha"[[:space:]]*:[[:space:]]*"|".*/, ""); print; exit }
	' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null
}

# plugin_sync PLUGIN: update it when its marketplace's main has moved past the
# installed copy. Asks the remote first, so a quiet run costs one ls-remote and
# never starts claude. A changed install command still waits for a person:
# no --yes, so the update fails here and says so.
plugin_sync() {
	name=${1%@*}; market=${1#*@}
	clone="$HOME/.claude/plugins/marketplaces/$market"
	[ -d "$clone/.git" ] || { echo "$name: skipped, marketplace $market not cloned"; return; }
	have=$(installed_sha "$1")
	[ -n "$have" ] || { echo "$name: skipped, not installed"; return; }
	want=$(git -C "$clone" ls-remote origin refs/heads/main 2>/dev/null | cut -f1)
	[ -n "$want" ] || { echo "$name: ls-remote failed (offline?), at $(echo "${have:-?}" | cut -c1-7)"; return; }
	if [ "$have" = "$want" ]; then echo "$name: current at $(echo "$have" | cut -c1-7)"; return; fi
	command -v claude >/dev/null 2>&1 || { echo "$name: skipped, claude not on PATH"; return; }
	if ! claude plugin marketplace update "$market" >/dev/null 2>&1; then
		echo "$name: marketplace update failed, run claude plugin marketplace update $market"; return
	fi
	if ! claude plugin update "$1" </dev/null >/dev/null 2>&1; then
		echo "$name: update failed, run claude plugin update $1 by hand"; return
	fi
	echo "$name: updated to $(installed_sha "$1" | cut -c1-7), new sessions load it"
}

# The commit that untracks .claude/ makes this merge delete every file yadm
# delivered there; the hooks go with them and the fail-closed ones then deny
# every tool call. Put back what the merge removed: from ~/.claude's own clone
# when there is one, else from the commit we left, so settings.json and the
# hooks it names stay until `dotfiles-claude-clone.sh move` has run. Only that
# commit: losing settings.json marks it, as for `rollback`; any other deletion
# under .claude was meant.
restore_claude() {
	gone=$(yadm diff --name-only --diff-filter=D "$1" HEAD -- .claude 2>/dev/null)
	printf '%s\n' "$gone" | grep -qx '\.claude/settings\.json' || return 0
	n=0; rest=
	for f in $gone; do
		if [ -d "$HOME/.claude/.git" ] && git -C "$HOME/.claude" ls-files --error-unmatch "${f#.claude/}" >/dev/null 2>&1 \
			&& git -C "$HOME/.claude" checkout -q -- "${f#.claude/}" 2>/dev/null; then
			n=$((n+1))
		else
			rest="$rest $f"
		fi
	done
	# shellcheck disable=SC2086  # paths here carry no whitespace
	if [ -n "$rest" ]; then
		tarball="$STATE/restore.tar"
		if yadm archive -o "$tarball" "$1" -- $rest 2>/dev/null && tar -xf "$tarball" -C "$HOME" 2>/dev/null; then
			n=$((n+$(echo $rest | wc -w)))
		else
			echo "FAILED: could not restore from $1:$rest"
		fi
		rm -f "$tarball"
	fi
	[ "$n" -eq 0 ] || echo "$n"
}


if command -v yadm >/dev/null 2>&1; then
	old=$(yadm rev-parse HEAD 2>/dev/null)
	if msg=$(ff_only yadm); then
		yadm alt >/dev/null 2>&1
		kept=$(restore_claude "$old")
		case "$kept" in
		'') ;;
		FAILED*) msg="$msg, $kept" ;;
		*) msg="$msg, kept $kept .claude file(s) the pull removed" ;;
		esac
	fi
else
	msg="skipped: yadm not on PATH"
fi

# ~/.claude is its own clone of mark-brannan/claude once
# dotfiles-claude-clone.sh move has run; before that yadm delivers it.
if [ -d "$HOME/.claude/.git" ]; then
	msg="$msg; claude: $(ff_only claude_git)"
fi

for p in $SYNC_PLUGINS; do
	msg="$msg; $(plugin_sync "$p")"
done

report "$msg"
exit 0

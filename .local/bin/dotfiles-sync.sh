#!/bin/sh
# Unattended fast-forward of $HOME's dotfiles from origin/main. Safe to run
# every few minutes: it never rebases, stashes or merges, so the only outcomes
# are "fast-forwarded", "nothing to do", or "skipped, here's why". Git refuses
# a fast-forward that would overwrite a dirty tracked file, atomically, which
# is the whole safety story -- see README "Why the cron sync is ff-only".
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

command -v yadm >/dev/null 2>&1 || { report "skipped: yadm not on PATH"; exit 0; }

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

# A checkout mid-merge, mid-rebase or holding unmerged paths needs a person;
# anything automatic here would compound it.
gitdir=$(yadm rev-parse --git-dir 2>/dev/null) || { report "skipped: yadm has no repo"; exit 0; }
if [ -e "$gitdir/MERGE_HEAD" ] || [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]; then
	report "skipped: merge or rebase in progress, resolve by hand"; exit 0
fi
unmerged=$(yadm diff --name-only --diff-filter=U 2>/dev/null)
if [ -n "$unmerged" ]; then
	report "skipped: unmerged paths, resolve by hand: $(echo "$unmerged" | tr '\n' ' ')"; exit 0
fi

if ! yadm fetch --quiet --prune origin 2>/dev/null; then
	report "fetch failed (offline?), $(yadm rev-list --count HEAD..origin/main 2>/dev/null || echo '?') behind at last fetch"
	exit 0
fi

ahead=$(yadm rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
behind=$(yadm rev-list --count HEAD..origin/main 2>/dev/null || echo 0)

if [ "$behind" -eq 0 ]; then
	if [ "$ahead" -gt 0 ]; then report "level with origin/main, $ahead local commit(s) unpushed"
	else report "level with origin/main"; fi
	exit 0
fi
if [ "$ahead" -gt 0 ]; then
	report "skipped: $ahead ahead and $behind behind, not fast-forwardable, run dotsync by hand"
	exit 0
fi

if yadm merge --ff-only --quiet origin/main >/dev/null 2>&1; then
	yadm alt >/dev/null 2>&1
	report "fast-forwarded $behind commit(s) to $(yadm rev-parse --short HEAD)"
else
	# The refusal is git protecting a dirty file that an incoming commit also
	# touches. Name them so the log says what a person has to look at.
	blockers=$( { yadm diff --name-only HEAD; yadm diff --name-only HEAD origin/main; } 2>/dev/null | sort | uniq -d | tr '\n' ' ')
	report "skipped: $behind behind, fast-forward refused by dirty files: ${blockers:-unknown}"
fi
exit 0

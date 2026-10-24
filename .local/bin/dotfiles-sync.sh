#!/bin/sh
# Every five minutes from cron: pull $HOME (yadm), the ~/.claude clone and
# the plugins we dogfood, each `pull --ff-only --autostash`, the same command
# the dotsync and claudesync aliases run by hand. Never rebases or merges
# histories. One guard, for running with nobody watching: git exits 0 when
# the autostash re-apply conflicts and leaves the markers live, so a pull
# that ends with unmerged paths gets upstream's copy of those files checked
# out (valid) and the local edits stay in the stash, named in the status.
# A failed outcome starts with "skipped", which the brief keys on.
#
#   dotfiles-sync.sh            run once (what cron calls)
#   dotfiles-sync.sh --install  add the crontab line, idempotently
#   dotfiles-sync.sh --status   print the last result and exit
#
# Always exits 0. The result is one line in $STATE/last, which the Claude
# SessionStart brief reads, and in syslog (tag dotfiles-sync).
set -u
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
STATE="$HOME/.local/state/dotfiles-sync"; mkdir -p "$STATE"
SELF="$HOME/.local/bin/dotfiles-sync.sh"

case "${1:-}" in
--status)  cat "$STATE/last" 2>/dev/null || echo "never run"; exit 0 ;;
--install) crontab -l 2>/dev/null | grep -Fq '# dotfiles-sync' \
	|| { crontab -l 2>/dev/null; echo "*/5 * * * * $SELF # dotfiles-sync"; } | crontab -; exit 0 ;;
'') ;;
*) echo "usage: dotfiles-sync.sh [--install|--status]" >&2; exit 0 ;;
esac

# pull NAME GITCMD...: one repo's result, as a phrase
pull() {
	name=$1; shift
	"$@" pull --ff-only --autostash -q >/dev/null 2>&1 || { echo "$name: skipped: pull failed (diverged, offline?), pull by hand"; return; }
	u=$("$@" diff --name-only --diff-filter=U 2>/dev/null | paste -sd' ' -)
	if [ -n "$u" ]; then
		# shellcheck disable=SC2086  # tracked paths here carry no whitespace
		"$@" checkout -q HEAD -- $u 2>/dev/null
		echo "$name: skipped your edits to $u: they conflicted with upstream and are in git stash"
	else
		echo "$name: current at $("$@" rev-parse --short HEAD 2>/dev/null)"
	fi
}

msg=$(pull dotfiles yadm); yadm alt >/dev/null 2>&1
[ -d "$HOME/.claude/.git" ] && msg="$msg; $(pull claude git -C "$HOME/.claude")"
for p in ${SYNC_PLUGINS-languette@languette}; do
	if claude plugin marketplace update "${p#*@}" >/dev/null 2>&1 && claude plugin update "$p" </dev/null >/dev/null 2>&1
	then msg="$msg; ${p%@*}: current"; else msg="$msg; ${p%@*}: update failed, run claude plugin update $p by hand"; fi
done
printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" > "$STATE/last"
command -v logger >/dev/null 2>&1 && logger -t dotfiles-sync "$msg"
exit 0

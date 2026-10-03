#!/bin/sh
# Keeps this repo's own CLAUDE.md out of $HOME. The repo's worktree is
# $HOME, so its project instructions would land at ~/CLAUDE.md, an ancestor
# of every repo under $HOME. They belong in ~/dotfiles and in branch
# worktrees, where this repo is the project.
#
#   home-sparse.sh --install   check $HOME out without CLAUDE.md, and link
#                              this script in as the yadm repo's
#                              post-checkout hook. Idempotent.
#   (as post-checkout)         give a new linked worktree the whole tree:
#                              `git worktree add` copies the sparse patterns
#                              of the worktree it runs from, and $HOME's
#                              leave out CLAUDE.md.
#
# Undo: `yadm sparse-checkout disable`, then delete the hook link.
set -u

SELF="$HOME/.local/bin/home-sparse.sh"

if [ "${1:-}" = --install ]; then
	command -v yadm >/dev/null 2>&1 || { echo "yadm not on PATH" >&2; exit 1; }
	yadm sparse-checkout set --no-cone '/*' '!/CLAUDE.md' || exit 1
	hook="$(yadm rev-parse --path-format=absolute --git-path hooks)/post-checkout"
	if [ -e "$hook" ] || [ -L "$hook" ]; then
		if [ "$(readlink "$hook")" != "$SELF" ]; then
			echo "$hook exists and is not $SELF; left alone" >&2
			exit 1
		fi
	fi
	ln -sf "$SELF" "$hook"
	echo "CLAUDE.md is out of \$HOME; worktree hook at $hook"
	exit 0
fi

# post-checkout <old> <new> <flag>. Only a worktree add passes the null id.
case "${1:-x}" in *[!0]*) exit 0 ;; esac
[ "$(git rev-parse --absolute-git-dir)" = "$(git rev-parse --path-format=absolute --git-common-dir)" ] && exit 0
[ "$(git config --get core.sparseCheckout)" = true ] || exit 0
exec git sparse-checkout disable

#!/bin/sh
# The yadm repo's post-checkout hook, linked in by bootstrap. $HOME is checked
# out without this repo's CLAUDE.md, and `git worktree add` copies the sparse
# patterns of the worktree it runs from; a new branch worktree needs the
# whole tree, so this gives it back. Only a worktree add passes the null id.
case "${1:-x}" in *[!0]*) exit 0 ;; esac
[ "$(git rev-parse --absolute-git-dir)" = "$(git rev-parse --path-format=absolute --git-common-dir)" ] && exit 0
[ "$(git config --get core.sparseCheckout)" = true ] || exit 0
exec git sparse-checkout disable

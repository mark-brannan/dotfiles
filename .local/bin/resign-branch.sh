#!/bin/sh
# resign-branch.sh — re-sign a branch's commits with this machine's real
# signing key, then force-push it.
#
# Why this exists: Claude Code cloud/remote sessions push unsigned commits —
# there is no local signing key on an ephemeral VM, and Anthropic has no
# server-side signing (unlike Cursor or GitHub Actions' bot commits, which
# are signed by the platform itself). Filed upstream as
# https://github.com/anthropics/claude-code/issues/7711 (closed "not
# planned"). A repo whose branch protection requires signed commits will
# BLOCK any PR built from such a branch until every commit on it is signed.
#
# This script re-signs from a machine that already has real signing config
# (dotfiles' .gitconfig##default: user.signingkey, gpg.format ssh,
# commit.gpgsign) — the opposite of seeding a private key into an ephemeral,
# third-party-adjacent cloud VM, which is a worse trade than this manual step.
#
# Usage:
#   resign-branch.sh <branch> [<remote>]     remote defaults to origin
#
# Rewrites history on <branch> (rebase -S) and force-pushes. Never run this
# against main or any shared branch someone else has already pulled — this
# is for single-author PR branches only, per "never force-push" in standing
# orders: fine on your own branch, never on main.
set -eu

branch="${1:?usage: resign-branch.sh <branch> [<remote>]}"
remote="${2:-origin}"

git rev-parse --git-dir >/dev/null 2>&1 || { echo "resign-branch: not in a git repo" >&2; exit 1; }

git config user.signingkey >/dev/null 2>&1 || {
  echo "resign-branch: no user.signingkey configured on this machine — nothing to sign with" >&2
  exit 1
}

git fetch -q "$remote" "$branch"
git checkout -q -B "$branch" "$remote/$branch"

base=$(git merge-base "$branch" "$remote/HEAD" 2>/dev/null) || base=$(git rev-list --max-parents=0 "$branch")

echo "resign-branch: re-signing $(git rev-list --count "$base..$branch") commit(s) on $branch"
GIT_SEQUENCE_EDITOR=true git rebase -q -S "$base" "$branch"

echo "resign-branch: verifying signatures"
git log --pretty='%H %G?' "$base..$branch" | while read -r sha status; do
  case "$status" in
    G) : ;;
    *) echo "resign-branch: $sha did not verify locally (status $status)" >&2 ;;
  esac
done

git push --force-with-lease "$remote" "$branch"
echo "resign-branch: pushed $branch to $remote"

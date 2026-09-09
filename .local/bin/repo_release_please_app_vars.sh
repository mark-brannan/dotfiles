#!/usr/bin/env sh
# Push the release-please GitHub App's client ID and private key to every
# vended repo's Actions secrets, so each repo's release-please.yml can mint
# an installation token. Idempotent: `gh secret set` overwrites in place.
#
# Reads the app credentials from the sops-encrypted
# ~/secrets/release-please-app.sops.env (RELEASE_PLEASE_APP_CLIENT_ID,
# RELEASE_PLEASE_APP_PRIVATE_KEY_B64 — the PEM, base64'd so it survives as a
# plain env value). Decrypted only in memory for the life of this script;
# nothing plaintext touches disk.
#
# Usage: repo_release_please_app_vars.sh [--dry-run]
set -eu

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) echo "usage: $(basename "$0") [--dry-run]" >&2; exit 2 ;;
esac

SECRET_FILE="$HOME/secrets/release-please-app.sops.env"
REPO_LIST="$HOME/.local/share/vended-repos.txt"

for cmd in gh sops base64; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd not installed." >&2; exit 1; }
done

[ -f "$SECRET_FILE" ] || { echo "missing $SECRET_FILE" >&2; exit 1; }
[ -f "$REPO_LIST" ] || { echo "missing $REPO_LIST" >&2; exit 1; }

if [ ! -f "$HOME/.config/sops/age/keys.txt" ]; then
  echo "no age key at ~/.config/sops/age/keys.txt — restore it before running this." >&2
  exit 1
fi
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"

# Decrypt straight into shell variables, never a file. Two separate `sops -d`
# calls rather than one piped through a `while read` loop: POSIX sh runs the
# read side of a pipe in a subshell, so variables set there don't survive
# past `done` — and some shells implement heredocs via a real temp file,
# which is exactly the on-disk exposure this script exists to avoid.
CLIENT_ID=$(sops -d "$SECRET_FILE" | sed -n 's/^RELEASE_PLEASE_APP_CLIENT_ID=//p')
KEY_B64=$(sops -d "$SECRET_FILE" | sed -n 's/^RELEASE_PLEASE_APP_PRIVATE_KEY_B64=//p')

[ -n "$CLIENT_ID" ] || { echo "RELEASE_PLEASE_APP_CLIENT_ID missing from $SECRET_FILE" >&2; exit 1; }
[ -n "$KEY_B64" ] || { echo "RELEASE_PLEASE_APP_PRIVATE_KEY_B64 missing from $SECRET_FILE" >&2; exit 1; }

FAILED=""
while IFS= read -r repo || [ -n "$repo" ]; do
  [ -n "$repo" ] || continue
  full="mark-brannan/$repo"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would set RELEASE_PLEASE_APP_CLIENT_ID and RELEASE_PLEASE_APP_PRIVATE_KEY on $full"
    continue
  fi
  echo "==> $full"
  if ! gh secret set RELEASE_PLEASE_APP_CLIENT_ID --repo "$full" --body "$CLIENT_ID"; then
    FAILED="$FAILED $full(client_id)"
    continue
  fi
  if ! printf '%s' "$KEY_B64" | base64 -d | gh secret set RELEASE_PLEASE_APP_PRIVATE_KEY --repo "$full"; then
    FAILED="$FAILED $full(private_key)"
  fi
done < "$REPO_LIST"

# Best-effort scrub of the decrypted key from this process's environment;
# the variable still lived in memory for the run, which is the accepted
# trade-off for never writing it to disk.
unset KEY_B64 CLIENT_ID

if [ -n "$FAILED" ]; then
  echo "failed on:$FAILED" >&2
  exit 1
fi

echo "==> done"

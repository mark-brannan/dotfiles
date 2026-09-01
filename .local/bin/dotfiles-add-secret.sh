#!/bin/sh
# Add a sops-encrypted secret to the dotfiles.
#
#   dotfiles-add-secret.sh <name> [--no-commit]
#
# Opens $EDITOR on $HOME/secrets/<name>.sops.env, encrypts it in place,
# refuses to go further unless the result is really ciphertext, then commits
# it with yadm and runs the bootstrap so the plaintext lands in
# $HOME/.config/secrets/<name>.env.
#
# This is a gate, not a convenience: it exits non-zero on anything it can't
# verify, and it never leaves an unencrypted file staged.
set -eu

NAME=""
COMMIT=1
for arg in "$@"; do
  case "$arg" in
    --no-commit) COMMIT=0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *)
      [ -n "$NAME" ] && { echo "one name only" >&2; exit 2; }
      NAME="$arg" ;;
  esac
done

if [ -z "$NAME" ]; then
  echo "usage: dotfiles-add-secret.sh <name> [--no-commit]" >&2
  echo "  <name> becomes ~/secrets/<name>.sops.env and ~/.config/secrets/<name>.env" >&2
  exit 2
fi

case "$NAME" in
  *[!a-zA-Z0-9._-]*|.*|"")
    echo "bad name '$NAME': use [a-zA-Z0-9._-], not starting with a dot." >&2
    exit 2 ;;
esac

CIPHER="$HOME/secrets/$NAME.sops.env"
PLAIN="$HOME/.config/secrets/$NAME.env"

for cmd in yadm sops; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd not installed." >&2; exit 1; }
done

if [ ! -f "$HOME/.config/sops/age/keys.txt" ]; then
  echo "no age key at ~/.config/sops/age/keys.txt — restore it before adding a secret." >&2
  exit 1
fi

if [ -e "$CIPHER" ]; then
  echo "$CIPHER already exists." >&2
  echo "To change its value, edit it in place instead:  sops $CIPHER" >&2
  exit 1
fi

# The plaintext is written at its final path, never in /tmp: .sops.yaml only
# has creation rules for secrets/ and *.sops.<ext>, so encrypting anywhere
# else fails with "no matching creation rules found".
mkdir -p "$HOME/secrets"
umask 077
cat > "$CIPHER" <<'TEMPLATE'
# One KEY=value per line. No `export`, no quotes unless the value has spaces.
# Delete these comment lines before saving.
TEMPLATE

cleanup_plaintext() {
  if [ -f "$CIPHER" ] && ! grep -q '^sops_age' "$CIPHER" 2>/dev/null; then
    rm -f "$CIPHER"
    echo "removed unencrypted $CIPHER" >&2
  fi
}
trap cleanup_plaintext EXIT INT TERM

"${EDITOR:-vi}" "$CIPHER"

if ! grep -qE '^[A-Za-z_][A-Za-z0-9_]*=' "$CIPHER"; then
  echo "no KEY=value lines in $CIPHER — nothing to encrypt." >&2
  exit 1
fi

sops -e -i "$CIPHER"

# Verify before anything is staged. A file that matched no creation rule is
# committed in the clear, and that is unrecoverable once pushed.
grep -q '^sops_age__list_0__map_recipient=' "$CIPHER" \
  || { echo "no sops metadata in $CIPHER — it did NOT encrypt." >&2; exit 1; }
if grep -vE '^(sops_|#|$)' "$CIPHER" | grep -qvE '=ENC\[AES256_GCM,'; then
  echo "some values in $CIPHER are not ENC[...] — refusing to continue." >&2
  grep -vE '^(sops_|#|$)' "$CIPHER" | grep -vE '=ENC\[AES256_GCM,' >&2
  exit 1
fi
trap - EXIT INT TERM
echo "==> encrypted $CIPHER"

if [ "$COMMIT" -eq 1 ]; then
  printf 'Commit %s with yadm? [y/N] ' "$CIPHER"
  read -r reply
  case "$reply" in
    [yY]*)
      yadm add "$CIPHER"
      yadm commit -m "secrets: add $NAME"
      ;;
    *) echo "    left uncommitted; commit it with: yadm add $CIPHER && yadm commit" ;;
  esac
fi

yadm bootstrap >/dev/null
[ -f "$PLAIN" ] || { echo "bootstrap did not produce $PLAIN." >&2; exit 1; }
echo "==> decrypted to $PLAIN ($(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$PLAIN") value(s))"

echo
echo "Next: only shells started after now see it — 'exec \$SHELL -l' here,"
echo "and 'dotsync && yadm bootstrap' on every other machine."

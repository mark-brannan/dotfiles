#!/usr/bin/env bash
# Confirms every secret-bearing file is actually encrypted in what git has
# committed. This is the backstop that cannot be bypassed: the local
# pre_commit hook can be skipped with YADM_ALLOW_SECRET=1 or --no-verify (on
# a plain-git clone), but this runs in CI on every push.
#
# The file list comes straight from .sops.yaml's path_regex entries, not a
# hand-copied list here -- that's the drift symptom this exists to prevent.
# Extraction is a grep, not a YAML parser: .sops.yaml in this repo is a flat
# list of `path_regex: <value>` lines under creation_rules with no nested
# structure. If that ever stops being true, switch this to python+pyyaml
# (see symphony's scripts/sops_paths.py for the pattern) rather than
# stretching the grep.
#
# Checks `git show HEAD:<path>`, not the working tree -- dotfiles' secrets
# are whole-file ciphertext at rest (no clean/smudge filter, unlike
# symphony), so the two are the same content anyway. Needs no age key: this
# checks that ciphertext IS ciphertext, which works without decrypting it.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

SOPS_CONFIG=".sops.yaml"

# is_sops_encrypted -- reads file content on stdin, exits 0 only if it
# carries real sops metadata, in any of the three shapes sops writes:
# dotenv (sops_mac=ENC[...] + sops_version=), JSON (`"sops": {...}` with
# mac + version), or YAML (`sops:` block with mac: + version:). Not "does
# the text contain the word sops" -- a coincidental match would make every
# guard downstream treat a live credential as encrypted.
is_sops_encrypted() {
  local text
  text="$(cat)"
  if grep -Eq '^sops_mac=ENC\[' <<<"$text" && grep -Eq '^sops_version=' <<<"$text"; then
    return 0
  fi
  if grep -Eq '"sops"[[:space:]]*:[[:space:]]*\{' <<<"$text"; then
    grep -Eq '"mac"[[:space:]]*:' <<<"$text" && grep -Eq '"version"[[:space:]]*:' <<<"$text"
    return
  fi
  if grep -Eq '^sops:[[:space:]]*$' <<<"$text"; then
    grep -Eq '^[[:space:]]+mac:' <<<"$text" && grep -Eq '^[[:space:]]+version:' <<<"$text"
    return
  fi
  return 1
}

mapfile -t regexes < <(grep -oP '^\s*- path_regex:\s*\K.*' "$SOPS_CONFIG")
if [ "${#regexes[@]}" -eq 0 ]; then
  echo "verify_encrypted: no path_regex entries found in $SOPS_CONFIG -- nothing to check." >&2
  exit 1
fi

fail=0
checked=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  # The sops config itself is not a secret, but the "ends in .sops.<ext>"
  # rule structurally matches its own filename (.sops.yaml looks exactly
  # like "<name>.sops.yaml"). Exclude it explicitly rather than tightening
  # the shared regex, which .config/yadm/bootstrap also depends on as-is.
  [ "$path" = "$SOPS_CONFIG" ] && continue
  matched=0
  for re in "${regexes[@]}"; do
    if [[ "$path" =~ $re ]]; then
      matched=1
      break
    fi
  done
  [ "$matched" -eq 1 ] || continue

  blob="$(git show "HEAD:${path}" 2>/dev/null)" || continue
  if is_sops_encrypted <<<"$blob"; then
    checked=$((checked + 1))
  else
    echo "NOT ENCRYPTED: ${path}" >&2
    fail=1
  fi
done < <(git ls-files)

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "One or more secret-bearing files are not encrypted in git. This must never happen." >&2
  echo "Encrypt with sops before committing; see .config/yadm/bootstrap for how this repo reads them back." >&2
  exit 1
fi

if [ "$checked" -eq 0 ]; then
  echo "verify_encrypted: no files matched .sops.yaml's path_regex entries -- check the patterns." >&2
  exit 1
fi

echo "OK: ${checked} secret-bearing file(s) encrypted as committed."

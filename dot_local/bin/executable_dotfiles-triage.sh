#!/bin/sh
# dotfiles-triage.sh — inventory $HOME and classify dotfiles for sync policy.
# POSIX sh. No deps beyond coreutils/find/grep. Read-only: touches nothing.
# Usage: sh dotfiles-triage.sh [> report.tsv]

HOST=$(hostname 2>/dev/null || echo unknown)
OS=$(uname -s)
SCAN_ROOT="${HOME}"

# no configuration file is this big. anything larger is an installed binary or a
# vendored tree, and gets demoted out of CANDIDATE.
MAX_CONFIG_BYTES=1048576

# --- policy: first match wins -------------------------------------------------
# NEVER    : credential material or machine identity. never sync, ever.
# STATE    : churn, caches, session artifacts, installed software. no value in git.
# REVIEW   : known to sometimes carry secrets. needs per-file eyeballs.
# CANDIDATE: default. plausible sync target.
classify() {
  case "$1" in
    .ssh/id_*|.ssh/*_rsa|.ssh/*_ed25519|.ssh/known_hosts*|.ssh/authorized_keys) echo NEVER ;;
    .gnupg/*|.aws/credentials|.netrc|.pgpass|.config/gcloud/*|.docker/config.json) echo NEVER ;;
    .claude/projects/*|.claude.json|.claude.json.backup*|.config/gh/hosts.yml|.kube/config) echo NEVER ;;
    .claude/.credentials.json|.claude/backups/*) echo NEVER ;;
    .config/sops/age/*|.config/age/*|.age/*|*.agekey) echo NEVER ;;
    .config/Bitwarden*/*|.password-store/*|.local/share/keyrings/*) echo NEVER ;;
    .local/state/*|.cache/*|.npm/_*|.zcompdump*|.viminfo|.bash_history|.zsh_history) echo STATE ;;
    .lesshst|.motd_shown|.wget-hsts|.sudo_as_admin_successful|.python_history) echo STATE ;;
    .config/*/logs/*|.local/share/*/cache/*) echo STATE ;;
    .claude/cache/*|.claude/file-history/*|.claude/sessions/*|.claude/session-env/*) echo STATE ;;
    .claude/shell-snapshots/*|.claude/paste-cache/*|.claude/downloads/*|.claude/ide/*) echo STATE ;;
    .claude/tasks/*|.claude/plans/*|.claude/todos/*|.claude/statsig/*) echo STATE ;;
    .claude/plugins/marketplaces/*|.claude/remote/*) echo STATE ;;
    .claude/history.jsonl|.claude/.last-cleanup|.claude/.last-update-result.json) echo STATE ;;
    */settings.local.json|*.local.json|*.local.yml|*.local.yaml|*.local.toml) echo STATE ;;
    .npmrc|.pypirc|.wakatime.cfg|.config/rclone/*|.env|.envrc|.my.cnf) echo REVIEW ;;
    .signalk/security.json|.msmtprc|.mbsyncrc) echo REVIEW ;;
    *) echo CANDIDATE ;;
  esac
}

# --- crude secret sniff: returns HIT if file smells like it holds a credential -
sniff() {
  [ -f "$1" ] || { echo "-"; return; }
  case "$1" in *.png|*.jpg|*.gz|*.zip|*.db|*.sqlite*) echo "-"; return ;; esac
  if LC_ALL=C grep -qiE '(_authToken|api[_-]?key|secret[_-]?key|oauth_token|password|BEGIN [A-Z ]*PRIVATE KEY|xox[baprs]-|gh[pousr]_[A-Za-z0-9]{20,})' "$1" 2>/dev/null
  then echo HIT; else echo "-"; fi
}

# --- chezmoi awareness --------------------------------------------------------
MANAGED_LIST=$(mktemp) || exit 1
trap 'rm -f "$MANAGED_LIST"' EXIT INT TERM
if command -v chezmoi >/dev/null 2>&1; then
  chezmoi managed 2>/dev/null | sed "s#^#${HOME}/#" | sort > "$MANAGED_LIST"
fi

printf 'host\tos\tclass\tmanaged\tsniff\tsize\tpath\n'

# depth-1 dotfiles + depth-2 inside .config, plus a few known dot-dirs
{
  find "$SCAN_ROOT" -maxdepth 1 -name '.*' \! -name '.' \! -name '..' 2>/dev/null
  for d in .config .local/bin .claude .signalk .ssh .aws .docker .kube; do
    [ -d "$SCAN_ROOT/$d" ] && find "$SCAN_ROOT/$d" -maxdepth 3 2>/dev/null
  done
} | sort -u | while IFS= read -r p; do
  [ -e "$p" ] || continue
  [ -d "$p" ] && continue
  rel=${p#"$SCAN_ROOT"/}
  case "$rel" in .git/*|.git) continue ;; esac
  cls=$(classify "$rel")
  sz=$(wc -c < "$p" 2>/dev/null | tr -d ' ')
  if [ "$cls" = CANDIDATE ] && [ "${sz:-0}" -gt "$MAX_CONFIG_BYTES" ]; then cls=STATE; fi
  if [ -s "$MANAGED_LIST" ] && grep -qxF "$p" "$MANAGED_LIST"; then mgd=yes; else mgd=no; fi
  case "$cls" in
    NEVER|STATE) sn="skipped" ;;
    *) sn=$(sniff "$p") ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$HOST" "$OS" "$cls" "$mgd" "$sn" "${sz:-0}" "$rel"
done

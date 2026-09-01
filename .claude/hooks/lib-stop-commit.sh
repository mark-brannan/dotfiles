#!/usr/bin/env bash
# Salvage a work repo's uncommitted files at Stop, by per-repo policy.
# Sourced by stop-continuity.sh. Policy table: $(state_dir)/stop-commit.conf,
# one rule per line, first match wins, no match = off:
#
#   <owner/repo glob>  state-to-main <state path...>   state paths -> main,
#                                                       rest -> worktree branch
#   <owner/repo glob>  branch                           all -> worktree branch
#   <owner/repo glob>  off
#
# Non-state files are only committed from an isolated worktree, never a
# shared checkout. The repo's own hooks and signing run; gitleaks runs when
# present; any refusal wins and is named. The main-bound commit is built in
# a throwaway worktree so nothing here rebases, stashes or resets the
# session's checkout. Never add -A outside a worktree, never --no-verify,
# never force.
#
#   bash lib-stop-commit.sh [--dry-run] <repo>    show policy / rehearse

SC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-state.sh
. "$SC_LIB_DIR/lib-state.sh"

SC_STATUS=""
SC_REASON=""
SC_DRY="${CLAUDE_STOP_COMMIT_DRY_RUN:-0}"
SC_CKPT=""
SC_SECTION=0
SC_GATE_NOTE=""
SC_COMMIT_OUT=""

sc_conf() { printf '%s/stop-commit.conf' "$(state_dir)"; }

# owner/repo from any origin URL form (https, ssh://, scp-style, local path).
sc_repo_key() {
  local url key
  url=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  key=$(printf '%s' "$url" \
    | sed -E 's#/+$##; s#\.git$##; s#^[a-z+]+://##; s#^[^/@]*@##; s#^[^/:]*[:/]##' \
    | awk -F/ 'NF >= 2 { print $(NF-1) "/" $NF }')
  case "$key" in */*) printf '%s' "$key" ;; *) return 1 ;; esac
}

sc_path_ok() {
  case "$1" in ''|-*|/*|*..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
}

# Prints "<policy>\t<paths>". A malformed rule is off, with SC_REASON set.
sc_policy() {
  local key=$1 conf pat pol paths p
  conf=$(sc_conf)
  SC_REASON=""
  [ -f "$conf" ] || { SC_REASON="no $conf"; printf 'off\t'; return 0; }
  while read -r pat pol paths; do
    case "$pat" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2254
    case "$key" in $pat) ;; *) continue ;; esac
    case "$pol" in
      off|branch) printf '%s\t' "$pol"; return 0 ;;
      state-to-main)
        [ -n "$paths" ] || { SC_REASON="rule '$pat' names no state paths"; printf 'off\t'; return 0; }
        for p in $paths; do
          sc_path_ok "$p" || { SC_REASON="rule '$pat' has a malformed path '$p'"; printf 'off\t'; return 0; }
        done
        printf 'state-to-main\t%s' "$paths"; return 0 ;;
      *) SC_REASON="rule '$pat' has unknown policy '$pol'"; printf 'off\t'; return 0 ;;
    esac
  done < "$conf"
  SC_REASON="no rule matches $key"
  printf 'off\t'
}

sc_default_branch() {
  local b
  b=$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
  [ -n "$b" ] && { printf '%s' "${b#origin/}"; return; }
  for b in main master; do
    git -C "$1" show-ref -q --verify "refs/remotes/origin/$b" 2>/dev/null && { printf '%s' "$b"; return; }
  done
  printf 'main'
}

sc_note() {
  if [ -n "$SC_CKPT" ]; then
    [ "$SC_SECTION" = 1 ] || { printf '\n## Stop-commit\n\n' >> "$SC_CKPT"; SC_SECTION=1; }
    printf -- '- %s\n' "$1" >> "$SC_CKPT"
  fi
  SC_STATUS="${SC_STATUS:+$SC_STATUS; }$1"
}

sc_refuse() {
  SC_REASON=$1
  sc_note "NOT COMMITTED: $1"
  # shellcheck disable=SC2016
  [ -n "${2:-}" ] && [ -n "$SC_CKPT" ] && printf '\n```\n%s\n```\n' "$(printf '%s' "$2" | head -20)" >> "$SC_CKPT"
  return 0
}

# A filter declared in .gitattributes but unconfigured here would stage mangled content.
sc_filters_ok() {
  local root=$1 f
  [ -f "$root/.gitattributes" ] && grep -qE '(^|[[:space:]])filter=' "$root/.gitattributes" || return 0
  for f in $(sed -nE 's/.*[[:space:]]filter=([A-Za-z0-9_.-]+).*/\1/p' "$root/.gitattributes" | sort -u); do
    git -C "$root" config --get "filter.$f.clean" >/dev/null 2>&1 && continue
    sc_refuse "git filter '$f' is declared in .gitattributes but not configured in this clone"
    return 1
  done
}

# Exit 2 = findings; any other non-zero = scanner didn't run. Both refuse.
sc_gitleaks_ok() {
  local dir=$1 out rc
  command -v gitleaks >/dev/null 2>&1 || { SC_GATE_NOTE="gitleaks not on PATH; only the repo's own hooks ran"; return 0; }
  if gitleaks git --help >/dev/null 2>&1; then
    out=$(cd "$dir" && timeout 120 gitleaks git --pre-commit --staged --no-banner --redact --exit-code 2 . 2>&1)
  else
    out=$(cd "$dir" && timeout 120 gitleaks protect --staged --no-banner --redact --exit-code 2 -s . 2>&1)
  fi
  rc=$?
  case "$rc" in
    0) return 0 ;;
    2) sc_refuse "gitleaks found credential-shaped content in the staged diff" "$out" ;;
    *) sc_refuse "gitleaks failed to run (exit $rc)" "$out" ;;
  esac
  return 1
}

# Repo identity and signing apply; fallback identity only when the clone has none.
sc_commit() {
  local dir=$1 msg=$2
  local -a ident=()
  [ -n "$(git -C "$dir" config --get user.email 2>/dev/null)" ] \
    || ident=(-c "user.name=${GIT_AUTHOR_NAME:-Claude}" -c "user.email=${GIT_AUTHOR_EMAIL:-noreply@anthropic.com}")
  SC_COMMIT_OUT=$(timeout 120 git -C "$dir" "${ident[@]}" commit -q -m "$msg" 2>&1)
}

sc_signed_ok() {
  [ "$(git -C "$1" config --get --type=bool commit.gpgsign 2>/dev/null)" = true ] || return 0
  git -C "$1" cat-file commit HEAD 2>/dev/null | grep -q '^gpgsig' && return 0
  sc_refuse "commit.gpgsign is on but the commit carries no signature"
  return 1
}

sc_is_worktree() {
  local gd cd
  gd=$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null)
  cd=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [ -n "$gd" ] && [ -n "$cd" ] && [ "$gd" != "$cd" ]
}

# State paths -> origin/<default>: scratch commit via a temp index, cherry-picked
# (three-way) into a throwaway worktree of origin/<default>, committed there,
# pushed; rebased in the throwaway on a race. Then fast-forward the session's
# local default branch if it was at the old tip.
# shellcheck disable=SC2086
sc_state_to_main() {
  local root=$1 sid=$2 paths=$3 repo default head base tree scratch wt tmpidx
  local pending n new attempt
  default=$(sc_default_branch "$root")
  repo=$(basename "$root")

  pending=$(git -C "$root" status --porcelain -- $paths 2>/dev/null)
  [ -n "$pending" ] || return 0
  n=$(printf '%s\n' "$pending" | wc -l | tr -d ' ')
  head=$(git -C "$root" rev-parse HEAD 2>/dev/null) || { sc_refuse "no HEAD in $root"; return 1; }

  tmpidx=$(mktemp "${TMPDIR:-/tmp}/stop-commit-index.XXXXXX") || return 1
  rm -f "$tmpidx"
  if ! GIT_INDEX_FILE=$tmpidx git -C "$root" read-tree "$head" 2>/dev/null \
     || ! GIT_INDEX_FILE=$tmpidx git -C "$root" add -A -- $paths 2>/dev/null; then
    rm -f "$tmpidx"
    sc_refuse "could not stage $paths into a scratch index"
    return 1
  fi
  tree=$(GIT_INDEX_FILE=$tmpidx git -C "$root" write-tree 2>/dev/null)
  rm -f "$tmpidx"
  scratch=$(git -C "$root" -c user.name=stop-continuity -c user.email=noreply@anthropic.com \
              commit-tree --no-gpg-sign "$tree" -p "$head" -m "scratch: state paths at Stop" 2>/dev/null)
  [ -n "$scratch" ] || { sc_refuse "could not build the scratch commit"; return 1; }

  timeout 60 git -C "$root" fetch -q origin "$default" 2>/dev/null \
    || { sc_refuse "fetch of origin/$default failed; $n state file(s) left uncommitted"; return 1; }
  base=$(git -C "$root" rev-parse "refs/remotes/origin/$default" 2>/dev/null)
  [ -n "$base" ] || { sc_refuse "origin/$default does not exist"; return 1; }

  wt=$(mktemp -d "${TMPDIR:-/tmp}/stop-commit-wt.XXXXXX")/wt || return 1
  if ! git -C "$root" worktree add -q --detach "$wt" "$base" 2>/dev/null; then
    rm -rf "$(dirname "$wt")"
    sc_refuse "could not create a throwaway worktree at origin/$default"
    return 1
  fi
  sc_wt_done() {
    git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1
    rm -rf "$(dirname "$wt")"
    git -C "$root" worktree prune >/dev/null 2>&1
  }

  if ! git -C "$wt" cherry-pick -n "$scratch" >/dev/null 2>&1; then
    sc_wt_done
    sc_refuse "state paths conflict with origin/$default; merge by hand ($n file(s) left uncommitted)"
    return 1
  fi
  if git -C "$wt" diff --cached --quiet 2>/dev/null; then
    sc_wt_done
    sc_note "state paths already match origin/$default"
    return 0
  fi
  sc_gitleaks_ok "$wt" || { sc_wt_done; return 1; }
  if [ "$SC_DRY" = 1 ]; then
    sc_wt_done
    sc_note "dry-run: $n state file(s) would go to origin/$default"
    return 0
  fi

  sc_commit "$wt" "State: $repo session ${sid:0:8} ($(date -u +%Y-%m-%d))"
  if ! git -C "$wt" diff --cached --quiet 2>/dev/null || [ "$(git -C "$wt" rev-parse HEAD)" = "$base" ]; then
    sc_wt_done
    sc_refuse "commit on origin/$default refused; $n state file(s) left uncommitted" "$SC_COMMIT_OUT"
    return 1
  fi
  sc_signed_ok "$wt" || { sc_wt_done; return 1; }

  for attempt in 1 2 3; do
    timeout 60 git -C "$wt" push -q origin "HEAD:refs/heads/$default" >/dev/null 2>&1 && break
    if [ "$attempt" = 3 ]; then
      sc_wt_done
      sc_refuse "push to origin/$default rejected three times; $n state file(s) left uncommitted"
      return 1
    fi
    timeout 60 git -C "$root" fetch -q origin "$default" 2>/dev/null
    if ! git -C "$wt" rebase -q "refs/remotes/origin/$default" >/dev/null 2>&1; then
      git -C "$wt" rebase --abort >/dev/null 2>&1
      sc_wt_done
      sc_refuse "origin/$default moved and the state commit no longer rebases cleanly"
      return 1
    fi
    sc_signed_ok "$wt" || { sc_wt_done; return 1; }
  done
  new=$(git -C "$wt" rev-parse HEAD)
  sc_wt_done
  git -C "$root" fetch -q origin "$default" 2>/dev/null
  sc_note "$n state file(s) -> origin/$default @${new:0:7}"

  [ "$(git -C "$root" symbolic-ref -q --short HEAD 2>/dev/null)" = "$default" ] || return 0
  if [ "$head" = "$base" ] && git -C "$root" diff --cached --quiet -- $paths 2>/dev/null \
     && git -C "$root" update-ref -m "stop-continuity: state salvage" "refs/heads/$default" "$new" "$head" 2>/dev/null; then
    git -C "$root" add -- $paths >/dev/null 2>&1 \
      || sc_note "local $default moved to @${new:0:7} but its index could not be refreshed"
  else
    sc_note "local $default is behind origin/$default; pull --autostash"
  fi
  return 0
}

# Everything (minus $excl) -> the worktree's own branch on origin. A refusal
# restores the index as the session left it.
sc_branch() {
  local root=$1 sid=$2 excl=$3 repo default branch pending n idx bak p new
  local -a spec=(.)
  for p in $excl; do spec+=(":(exclude)$p"); done
  default=$(sc_default_branch "$root")
  repo=$(basename "$root")

  pending=$(git -C "$root" status --porcelain -- "${spec[@]}" 2>/dev/null)
  [ -n "$pending" ] || return 0
  n=$(printf '%s\n' "$pending" | wc -l | tr -d ' ')

  sc_is_worktree "$root" || { sc_note "$n file(s) uncommitted in the shared checkout (recorded, not committed)"; return 0; }
  branch=$(git -C "$root" symbolic-ref -q --short HEAD 2>/dev/null)
  [ -n "$branch" ] || { sc_note "$n file(s) uncommitted on a detached HEAD (recorded, not committed)"; return 0; }
  [ "$branch" != "$default" ] || { sc_note "$n file(s) uncommitted on $default in a worktree (recorded, not committed)"; return 0; }

  idx=$(git -C "$root" rev-parse --path-format=absolute --git-path index 2>/dev/null)
  bak="$idx.stop-continuity"
  if [ -f "$idx" ]; then
    cp -p "$idx" "$bak" 2>/dev/null || { sc_refuse "could not back up the index"; return 1; }
  fi
  sc_idx_restore() {
    if [ -f "$bak" ]; then mv -f "$bak" "$idx" 2>/dev/null; else rm -f "$idx"; fi
  }

  git -C "$root" add -A -- "${spec[@]}" >/dev/null 2>&1 || { sc_idx_restore; sc_refuse "git add failed in $root"; return 1; }
  sc_gitleaks_ok "$root" || { sc_idx_restore; return 1; }
  if [ "$SC_DRY" = 1 ]; then
    sc_idx_restore
    sc_note "dry-run: $n file(s) would go to origin/$branch"
    return 0
  fi
  sc_commit "$root" "Stop: salvage uncommitted files ($repo session ${sid:0:8})"
  if ! git -C "$root" diff --cached --quiet 2>/dev/null; then
    sc_idx_restore
    sc_refuse "commit on $branch refused; $n file(s) left uncommitted" "$SC_COMMIT_OUT"
    return 1
  fi
  rm -f "$bak"
  sc_signed_ok "$root" || return 1
  new=$(git -C "$root" rev-parse HEAD)
  if timeout 60 git -C "$root" push -q -u origin "HEAD:refs/heads/$branch" >/dev/null 2>&1; then
    sc_note "$n file(s) -> origin/$branch @${new:0:7}"
  else
    sc_refuse "$n file(s) committed on $branch @${new:0:7} but the push to origin/$branch was rejected"
    return 1
  fi
}

# sc_run <work-root> <session-id> [checkpoint-file]; result in SC_STATUS.
sc_run() {
  local root=$1 sid=$2 key pol paths repo
  SC_CKPT=${3:-}
  SC_SECTION=0; SC_STATUS=""; SC_REASON=""; SC_GATE_NOTE=""
  repo=$(basename "$root")

  [ -d "$root" ] && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if ! key=$(sc_repo_key "$root"); then
    [ -n "$SC_CKPT" ] && sc_note "off: no origin remote" && SC_STATUS=""
    return 0
  fi
  IFS=$'\t' read -r pol paths <<<"$(sc_policy "$key")"
  if [ "$pol" = off ]; then
    [ -n "$SC_CKPT" ] && sc_note "off for $key${SC_REASON:+ ($SC_REASON)}" && SC_STATUS=""
    return 0
  fi
  [ -n "$SC_CKPT" ] && sc_note "policy $pol for $key${paths:+ ($paths)}" && SC_STATUS=""
  sc_filters_ok "$root" || return 0

  case "$pol" in
    state-to-main) sc_state_to_main "$root" "$sid" "$paths"; sc_branch "$root" "$sid" "$paths" ;;
    branch)        sc_branch "$root" "$sid" "" ;;
  esac
  [ -n "$SC_GATE_NOTE" ] && sc_note "$SC_GATE_NOTE"
  [ -n "$SC_STATUS" ] && SC_STATUS="$repo -- $SC_STATUS"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  [ "${1:-}" = "--dry-run" ] && { SC_DRY=1; shift; }
  root=$(git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo: ${1:-$PWD}" >&2; exit 1; }
  echo "repo:     $root"
  echo "conf:     $(sc_conf)"
  if key=$(sc_repo_key "$root"); then
    IFS=$'\t' read -r pol paths <<<"$(sc_policy "$key")"
    echo "key:      $key"
    echo "policy:   $pol${SC_REASON:+ ($SC_REASON)}"
    [ -n "$paths" ] && echo "state:    $paths"
  else
    echo "key:      (no origin remote)"
    echo "policy:   off"
  fi
  sc_is_worktree "$root" && echo "checkout: isolated worktree" || echo "checkout: shared"
  echo "branch:   $(git -C "$root" symbolic-ref -q --short HEAD 2>/dev/null || echo detached) (default: $(sc_default_branch "$root"))"
  echo "pending:  $(git -C "$root" status --porcelain 2>/dev/null | wc -l | tr -d ' ') file(s)"
  if [ "$SC_DRY" = 1 ]; then
    ck=$(mktemp)
    sc_run "$root" "dry-run-0000" "$ck"
    echo
    sed -n '/^## Stop-commit/,$p' "$ck"
    rm -f "$ck"
  fi
fi

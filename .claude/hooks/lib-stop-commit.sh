#!/usr/bin/env bash
# Stop-time salvage of a work repo's uncommitted files.
#
# Sourced by stop-continuity.sh, which owns the Stop event, the transcript
# parse, the flock and the checkpoint. This file owns one question: given
# the repo a session was working in, where do its uncommitted files go so
# that nothing is lost when the container is reclaimed?
#
# The answer is a policy per repo, read from
#
#   $(state_dir)/stop-commit.conf        (private state repo)
#
# one rule per line, first match wins, `#` comments:
#
#   <owner/repo glob>      <policy>       [state path ...]
#   mark-brannan/symphony  state-to-main  intermediate_files/claude_slop
#   mark-brannan/*         branch
#   *                      off
#
# Policies:
#   state-to-main  The listed state paths go straight to the default branch:
#                  signed, rebased onto origin, one commit per Stop, linear.
#                  Every other change follows the `branch` rules below.
#   branch         In an isolated worktree, every uncommitted change is
#                  committed on the worktree's branch and pushed to the same
#                  branch on origin. No PR is opened. In a shared checkout
#                  nothing is committed -- the files are only listed in the
#                  checkpoint, because `git add -A` in a directory several
#                  sessions share is how the destructive-command incidents
#                  started.
#   off            Nothing is touched. No file, no matching rule, no origin
#                  remote and a malformed rule all mean off: a repo that has
#                  not opted in is never pushed to.
#
# Why the table lives in the state repo, not in each repo or in dotfiles: an
# interim choice (2026-09-01) made for blast radius and reversibility -- one
# private file, no per-repo commit to opt in, no public PR to change a
# policy, and deleting the file turns every repo off. The durable answer is
# an open card on the global board.
#
# Invariants, each of which has cost something once already:
#   - Never `git add -A` outside an isolated worktree.
#   - Never `-c commit.gpgsign=false`. The repo's own signing config applies,
#     and a commit that should be signed but isn't is not pushed.
#   - Never `--no-verify`. The repo's own commit hooks run, and gitleaks runs
#     over the staged diff whenever it is on PATH. A refusal wins.
#   - Never rebase, stash or reset in the session's checkout. The
#     default-branch commit is built in a throwaway worktree of
#     origin/<default>, so a conflict or a killed hook can only damage a
#     directory that is about to be deleted.
#   - Never force-push.
#   - Refuse loudly. Every path that declines writes why into the checkpoint
#     and into the one-line status the Stop hook shows.
#
# Run directly to see what a repo resolves to, or to rehearse a Stop without
# committing or pushing anything:
#
#   bash lib-stop-commit.sh <repo-path>
#   bash lib-stop-commit.sh --dry-run <repo-path>

SC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-state.sh
. "$SC_LIB_DIR/lib-state.sh"

# Results, read by the caller after sc_run.
SC_STATUS=""      # one line for the user: "<repo> -- a; b; c"
SC_REASON=""      # last refusal or skip reason, empty when nothing went wrong
SC_DRY="${CLAUDE_STOP_COMMIT_DRY_RUN:-0}"

sc_conf() { printf '%s/stop-commit.conf' "$(state_dir)"; }

# owner/repo from the origin URL: the last two path components, with .git
# and any scheme, user or host stripped. Works for https://, ssh://,
# scp-style git@host:owner/repo and plain paths (a local bare origin in the
# tests resolves to its last two directories).
sc_repo_key() {
  local url key
  url=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  key=$(printf '%s' "$url" \
    | sed -E 's#/+$##; s#\.git$##; s#^[a-z+]+://##; s#^[^/@]*@##; s#^[^/:]*[:/]##' \
    | awk -F/ 'NF >= 2 { print $(NF-1) "/" $NF }')
  case "$key" in
    */*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$key"
}

# A state path is a plain relative path: no magic, no `..`, no leading `-`
# or `/`. Anything else makes the rule malformed, and a malformed rule is
# `off` rather than a guess at what was meant.
sc_path_ok() {
  case "$1" in
    ''|-*|/*|*..*|*[!A-Za-z0-9_./-]*) return 1 ;;
  esac
  return 0
}

# Resolve <key> against the conf. Prints "<policy>\t<paths>"; sets SC_REASON
# when the answer is off for a reason worth telling.
sc_policy() {
  local key=$1 conf pat pol paths p
  conf=$(sc_conf)
  SC_REASON=""
  if [ ! -f "$conf" ]; then
    SC_REASON="no $conf"
    printf 'off\t'
    return 0
  fi
  while read -r pat pol paths; do
    case "$pat" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2254  # the pattern is meant to glob
    case "$key" in
      $pat) ;;
      *) continue ;;
    esac
    case "$pol" in
      off)
        printf 'off\t'
        return 0 ;;
      branch)
        printf 'branch\t'
        return 0 ;;
      state-to-main)
        if [ -z "$paths" ]; then
          SC_REASON="rule '$pat state-to-main' names no state paths"
          printf 'off\t'
          return 0
        fi
        for p in $paths; do
          if ! sc_path_ok "$p"; then
            SC_REASON="rule '$pat' has a malformed state path '$p'"
            printf 'off\t'
            return 0
          fi
        done
        printf 'state-to-main\t%s' "$paths"
        return 0 ;;
      *)
        SC_REASON="rule '$pat' has unknown policy '$pol'"
        printf 'off\t'
        return 0 ;;
    esac
  done < "$conf"
  SC_REASON="no rule matches $key"
  printf 'off\t'
}

sc_default_branch() {
  local b
  b=$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$b" ]; then
    printf '%s' "${b#origin/}"
    return
  fi
  for b in main master; do
    git -C "$1" show-ref -q --verify "refs/remotes/origin/$b" 2>/dev/null && { printf '%s' "$b"; return; }
  done
  printf 'main'
}

# --- checkpoint + status ---------------------------------------------------

SC_CKPT=""
SC_SECTION=0
sc_note() {
  if [ -n "$SC_CKPT" ]; then
    if [ "$SC_SECTION" = 0 ]; then
      printf '\n## Stop-commit\n\n' >> "$SC_CKPT"
      SC_SECTION=1
    fi
    printf -- '- %s\n' "$1" >> "$SC_CKPT"
  fi
  SC_STATUS="${SC_STATUS:+$SC_STATUS; }$1"
}

# A refusal is a note plus the reason kept for the caller. Extra detail
# (hook output) goes to the checkpoint only.
sc_refuse() {
  SC_REASON=$1
  sc_note "NOT COMMITTED: $1"
  if [ -n "${2:-}" ] && [ -n "$SC_CKPT" ]; then
    printf '\n```\n%s\n```\n' "$(printf '%s' "$2" | head -20)" >> "$SC_CKPT"
  fi
}

# --- gates -----------------------------------------------------------------

# Same check the state-repo path makes: a filter declared in .gitattributes
# but not configured in this clone would stage mangled content.
sc_filters_ok() {
  local root=$1 f
  [ -f "$root/.gitattributes" ] || return 0
  grep -qE '(^|[[:space:]])filter=' "$root/.gitattributes" || return 0
  for f in $(sed -nE 's/.*[[:space:]]filter=([A-Za-z0-9_.-]+).*/\1/p' "$root/.gitattributes" | sort -u); do
    if ! git -C "$root" config --get "filter.$f.clean" >/dev/null 2>&1; then
      sc_refuse "git filter '$f' is declared in .gitattributes but not configured in this clone; committing would mangle content"
      return 1
    fi
  done
  return 0
}

# gitleaks over the staged diff of <dir>, when gitleaks is on PATH. Exit
# code 2 is reserved for findings so a tool failure (any other non-zero) is
# distinguishable -- and both refuse, because "the scanner didn't run" is
# not "the scanner found nothing".
SC_GATE_NOTE=""
sc_gitleaks_ok() {
  local dir=$1 out rc
  if ! command -v gitleaks >/dev/null 2>&1; then
    SC_GATE_NOTE="gitleaks not on PATH; only the repo's own commit hooks ran"
    return 0
  fi
  if gitleaks git --help >/dev/null 2>&1; then
    out=$(cd "$dir" && timeout 120 gitleaks git --pre-commit --staged --no-banner --redact --exit-code 2 . 2>&1)
  else
    out=$(cd "$dir" && timeout 120 gitleaks protect --staged --no-banner --redact --exit-code 2 -s . 2>&1)
  fi
  rc=$?
  case "$rc" in
    0) return 0 ;;
    2) sc_refuse "gitleaks found credential-shaped content in the staged diff" "$out" ;;
    *) sc_refuse "gitleaks failed to run (exit $rc), so the staged diff was not scanned" "$out" ;;
  esac
  return 1
}

# Commit what is staged in <dir>. The repo's own identity and signing config
# apply; the only override is a fallback identity when the clone has none.
# Hooks run. Output is captured so a refusing hook can be quoted.
SC_COMMIT_OUT=""
sc_commit() {
  local dir=$1 msg=$2
  local -a ident=()
  if [ -z "$(git -C "$dir" config --get user.email 2>/dev/null)" ]; then
    ident=(-c "user.name=${GIT_AUTHOR_NAME:-Claude}" -c "user.email=${GIT_AUTHOR_EMAIL:-noreply@anthropic.com}")
  fi
  SC_COMMIT_OUT=$(timeout 120 git -C "$dir" "${ident[@]}" commit -q -m "$msg" 2>&1)
}

# When the repo says commits are signed, an unsigned one does not leave the
# machine. git already fails the commit when signing fails; this catches a
# config that quietly turned signing off between commit and push.
sc_signed_ok() {
  local dir=$1
  [ "$(git -C "$dir" config --get --type=bool commit.gpgsign 2>/dev/null)" = true ] || return 0
  git -C "$dir" cat-file commit HEAD 2>/dev/null | grep -q '^gpgsig' && return 0
  sc_refuse "commit.gpgsign is on but the commit carries no signature"
  return 1
}

sc_is_worktree() {
  local gd cd
  gd=$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null)
  cd=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [ -n "$gd" ] && [ -n "$cd" ] && [ "$gd" != "$cd" ]
}

# --- state-to-main ---------------------------------------------------------
#
# 1. A scratch commit of the state paths on top of the session's HEAD, built
#    through a temporary index. The session's own index and worktree are
#    never touched, and the object is never pushed.
# 2. A throwaway worktree at origin/<default>; the scratch commit is
#    cherry-picked into it without committing. That is a real three-way
#    merge, so a state file another session pushed meanwhile merges rather
#    than being overwritten, and a genuine conflict refuses.
# 3. gitleaks, then a normal `git commit` there: the repo's hooks and
#    signing run in a clean tree, so nothing is stashed and nothing needs
#    restoring if a hook dies.
# 4. Push to the default branch; if origin moved in between, rebase the one
#    commit in the throwaway worktree and push again. Linear by construction.
# 5. If the session's checkout is on the default branch and was at the old
#    tip, move its branch pointer forward and refresh the index for the
#    state paths, so the next `git status` there is clean instead of one
#    commit behind with files that look modified. Best effort: an index.lock
#    held by someone else just leaves it behind, which `git pull --autostash`
#    resolves later.
# shellcheck disable=SC2086  # $paths is a validated, space-separated pathspec list
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

  if ! timeout 60 git -C "$root" fetch -q origin "$default" 2>/dev/null; then
    sc_refuse "fetch of origin/$default failed; $n state file(s) left uncommitted"
    return 1
  fi
  base=$(git -C "$root" rev-parse "refs/remotes/origin/$default" 2>/dev/null)
  [ -n "$base" ] || { sc_refuse "origin/$default does not exist"; return 1; }

  wt=$(mktemp -d "${TMPDIR:-/tmp}/stop-commit-wt.XXXXXX")/wt || return 1
  if ! git -C "$root" worktree add -q --detach "$wt" "$base" 2>/dev/null; then
    rm -rf "$(dirname "$wt")"
    sc_refuse "could not create a throwaway worktree at origin/$default"
    return 1
  fi
  # Everything after this point cleans up through sc_wt_done.
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
  if ! sc_gitleaks_ok "$wt"; then
    sc_wt_done
    return 1
  fi
  if [ "$SC_DRY" = 1 ]; then
    sc_wt_done
    sc_note "dry-run: $n state file(s) would go to origin/$default"
    return 0
  fi

  sc_commit "$wt" "State: $repo session ${sid:0:8} ($(date -u +%Y-%m-%d))"
  if ! git -C "$wt" diff --cached --quiet 2>/dev/null || [ "$(git -C "$wt" rev-parse HEAD)" = "$base" ]; then
    sc_wt_done
    sc_refuse "commit on origin/$default refused by a hook; $n state file(s) left uncommitted" "$SC_COMMIT_OUT"
    return 1
  fi
  if ! sc_signed_ok "$wt"; then
    sc_wt_done
    return 1
  fi

  for attempt in 1 2 3; do
    if timeout 60 git -C "$wt" push -q origin "HEAD:refs/heads/$default" >/dev/null 2>&1; then
      break
    fi
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
  done
  new=$(git -C "$wt" rev-parse HEAD)
  sc_wt_done
  git -C "$root" fetch -q origin "$default" 2>/dev/null
  sc_note "$n state file(s) -> origin/$default @${new:0:7}"

  if [ "$(git -C "$root" symbolic-ref -q --short HEAD 2>/dev/null)" = "$default" ] \
     && [ "$head" = "$base" ] \
     && git -C "$root" diff --cached --quiet -- $paths 2>/dev/null; then
    if git -C "$root" update-ref -m "stop-continuity: state salvage" "refs/heads/$default" "$new" "$head" 2>/dev/null; then
      git -C "$root" add -- $paths >/dev/null 2>&1 \
        || sc_note "local $default moved to @${new:0:7} but its index could not be refreshed (index.lock held?)"
    else
      sc_note "local $default is one commit behind origin/$default; pull --autostash"
    fi
  elif [ "$(git -C "$root" symbolic-ref -q --short HEAD 2>/dev/null)" = "$default" ]; then
    sc_note "local $default is behind origin/$default; pull --autostash"
  fi
  return 0
}

# --- branch ----------------------------------------------------------------
#
# Only in an isolated worktree, only on a branch that is not the default.
# Stages everything (minus the state paths a state-to-main rule already
# routed to main), runs gitleaks, commits with the repo's hooks and signing,
# pushes to the same branch name on origin. A refusal puts the index back
# exactly as the session left it.
sc_branch() {
  local root=$1 sid=$2 excl=$3 repo default branch pending n idx bak p new
  local -a spec=(.)
  for p in $excl; do spec+=(":(exclude)$p"); done
  default=$(sc_default_branch "$root")
  repo=$(basename "$root")

  pending=$(git -C "$root" status --porcelain -- "${spec[@]}" 2>/dev/null)
  [ -n "$pending" ] || return 0
  n=$(printf '%s\n' "$pending" | wc -l | tr -d ' ')

  if ! sc_is_worktree "$root"; then
    sc_note "$n file(s) uncommitted in the shared checkout (recorded, not committed)"
    return 0
  fi
  branch=$(git -C "$root" symbolic-ref -q --short HEAD 2>/dev/null)
  if [ -z "$branch" ]; then
    sc_note "$n file(s) uncommitted on a detached HEAD (recorded, not committed)"
    return 0
  fi
  if [ "$branch" = "$default" ]; then
    sc_note "$n file(s) uncommitted on $default in a worktree (recorded, not committed)"
    return 0
  fi
  if [ "$SC_DRY" = 1 ]; then
    sc_note "dry-run: $n file(s) would go to origin/$branch"
    return 0
  fi

  idx=$(git -C "$root" rev-parse --path-format=absolute --git-path index 2>/dev/null)
  bak="$idx.stop-continuity"
  if [ -f "$idx" ]; then
    cp -p "$idx" "$bak" 2>/dev/null || { sc_refuse "could not back up the index"; return 1; }
  fi
  sc_idx_restore() {
    if [ -f "$bak" ]; then mv -f "$bak" "$idx" 2>/dev/null; else rm -f "$idx"; fi
  }

  if ! git -C "$root" add -A -- "${spec[@]}" >/dev/null 2>&1; then
    sc_idx_restore
    sc_refuse "git add failed in $root"
    return 1
  fi
  if ! sc_gitleaks_ok "$root"; then
    sc_idx_restore
    return 1
  fi
  sc_commit "$root" "Stop: salvage uncommitted files ($repo session ${sid:0:8})"
  if ! git -C "$root" diff --cached --quiet 2>/dev/null; then
    sc_idx_restore
    sc_refuse "commit on $branch refused by a hook; $n file(s) left uncommitted" "$SC_COMMIT_OUT"
    return 1
  fi
  rm -f "$bak"
  if ! sc_signed_ok "$root"; then
    return 1
  fi
  new=$(git -C "$root" rev-parse HEAD)
  if timeout 60 git -C "$root" push -q -u origin "HEAD:refs/heads/$branch" >/dev/null 2>&1; then
    sc_note "$n file(s) -> origin/$branch @${new:0:7}"
  else
    sc_refuse "$n file(s) committed on $branch @${new:0:7} but the push to origin/$branch was rejected"
    return 1
  fi
  return 0
}

# --- entry point -----------------------------------------------------------
# sc_run <work-root> <session-id> [checkpoint-file]
sc_run() {
  local root=$1 sid=$2 key pol paths repo
  SC_CKPT=${3:-}
  SC_SECTION=0
  SC_STATUS=""
  SC_REASON=""
  SC_GATE_NOTE=""
  repo=$(basename "$root")

  [ -d "$root" ] || return 0
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  if ! key=$(sc_repo_key "$root"); then
    [ -n "$SC_CKPT" ] && sc_note "off: no origin remote" && SC_STATUS=""
    return 0
  fi
  IFS=$'\t' read -r pol paths <<<"$(sc_policy "$key")"
  if [ "$pol" = off ]; then
    if [ -n "$SC_CKPT" ]; then
      sc_note "off for $key${SC_REASON:+ ($SC_REASON)}"
      SC_STATUS=""
    fi
    return 0
  fi
  [ -n "$SC_CKPT" ] && sc_note "policy $pol for $key${paths:+ ($paths)}" && SC_STATUS=""

  sc_filters_ok "$root" || return 0

  case "$pol" in
    state-to-main)
      sc_state_to_main "$root" "$sid" "$paths"
      sc_branch "$root" "$sid" "$paths"
      ;;
    branch)
      sc_branch "$root" "$sid" ""
      ;;
  esac
  [ -n "$SC_GATE_NOTE" ] && sc_note "$SC_GATE_NOTE"
  [ -n "$SC_STATUS" ] && SC_STATUS="$repo -- $SC_STATUS"
  return 0
}

# --- direct invocation -----------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  if [ "${1:-}" = "--dry-run" ]; then SC_DRY=1; shift; fi
  target=${1:-$PWD}
  root=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo: $target" >&2; exit 1; }
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
  if sc_is_worktree "$root"; then echo "checkout: isolated worktree"; else echo "checkout: shared"; fi
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

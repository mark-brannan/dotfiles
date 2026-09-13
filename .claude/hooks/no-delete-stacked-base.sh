#!/bin/sh
# Refuses to delete a remote branch that an open pull request still points at.
#
# The scar: GitHub retargets a stacked PR only when its base branch
# disappears *because the base PR merged*. A base branch deleted any other
# way -- by hand, by a cleanup pass, by a rebase that recreates it under a
# new name -- closes every PR based on it. The closure is silent, the diff
# then reads as conflicting because the base ref is gone, and the recovery
# is reopen-and-retarget, one PR at a time. Deleting the *head* branch of an
# open PR closes that PR the same way.
#
# So this hook fires on remote-branch deletion only, and asks GitHub whether
# any open PR names that branch as its base or its head. The safe path is
# never blocked: `gh pr merge --delete-branch` is the deletion GitHub
# retargets around, and it is exempt. Local deletion (`git branch -d/-D`)
# is not a trigger at all -- it takes nothing away from a PR.
#
# Not a stack? Then there is nothing here to hit. Several small changes in
# flight belong on parallel branches off main, which is what CLAUDE.md says
# to do; this hook only has something to say once one branch is another
# PR's base.
#
# Decisions, and why they are not symmetric:
#   an open PR found     -> DENY. This is the destructive case and it is
#                           known, not guessed.
#   GitHub not reachable -> ASK. A gate that fails closed here would be
#   (no gh, no auth,        unsatisfiable: with the network down there is
#    API error, timeout)    no way to prove the branch is unused, so a deny
#                           would mean no remote branch could ever be
#                           deleted again. The prompt carries the branch
#                           name and the one command that settles it.
#   command unparseable  -> DENY. Inspection failing is not the same as
#   (no jq/awk/library)     inspection coming back empty.
#
# Scanning is shared with no-git-footguns.sh/no-checkout-home.sh:
# lib-shell-words.awk (read its header). That is what makes the trigger
# survive a quoted argument, an absolute-path invocation, a nested
# `sh -c '...'`, and a trailing shell comment.
#
# What counts as a remote-branch deletion:
#   git push [<remote>] --delete|-d <ref>...   every ref after the remote
#   git push <remote> :<ref>                   the colon-prefixed refspec
#   gh api -X DELETE .../git/refs/heads/<ref>  the REST spelling
# `refs/heads/` is stripped; `gh pr merge -d`/`--delete-branch` is exempt.
#
# Known gap, deliberate: a deletion spelled through a variable
# (`git push origin --delete "$b"`) resolves to an unexpandable word, so the
# branch cannot be looked up -- it routes to ASK, not to a silent allow.
set -u

HERE=$(dirname "$0")
LIB="$HERE/lib-shell-words.awk"

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"} {print}' | sed 's/\\n$//; s/^/"/; s/$/"/'; }
decide() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}\n' "$1" "$(json_str "$2")"; exit 0; }
deny() { decide deny "$1"; }
ask()  { decide ask  "$1"; }

command -v jq  >/dev/null 2>&1 || deny "no-delete-stacked-base: jq is missing, so the command can't be inspected."
command -v awk >/dev/null 2>&1 || deny "no-delete-stacked-base: awk is missing, so the command can't be inspected."
[ -r "$LIB" ] || deny "no-delete-stacked-base: $LIB missing, so the command can't be inspected."
payload=$(cat) || deny "no-delete-stacked-base: could not read the hook payload."
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || deny "no-delete-stacked-base: unreadable hook payload."
[ -n "$cmd" ] || exit 0

# Cheap pre-filter: every spelling this hook cares about contains one of
# these. Skips the scanner (and the awk process) on the overwhelming
# majority of commands, which delete no branch at all.
case "$cmd" in
  *push*|*refs/heads/*) ;;
  *) exit 0 ;;
esac

payload_cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$payload_cwd" ] || payload_cwd=$PWD

# awk prints one branch name per line for each remote-branch deletion it
# finds. `?` marks a ref it could not resolve to a literal name (a variable,
# a glob) -- those route to ASK rather than being dropped.
branches=$(printf '%s\n' "$cmd" | awk "$(cat "$LIB")"'
function emit(ref) {
  sub(/^refs\/heads\//, "", ref)
  if (ref == "" || ref == "HEAD") return
  if (ref ~ /[$`*?\[]/) { print "?"; return }
  print ref
}

function git_push(a, b, nested,   g, i, p, del, seen_remote, wv) {
  g = cmd_index(w, k, a, b, "(^|/)(git|yadm)$", nested, "")
  if (!g) return
  p = 0
  for (i = g + 1; i <= b; i++) if (k[i] == "w" && w[i] == "push") { p = i; break }
  if (!p) return

  del = 0
  for (i = p + 1; i <= b; i++)
    if (k[i] == "w" && (w[i] == "--delete" || w[i] == "-d")) { del = 1; break }

  seen_remote = 0
  for (i = p + 1; i <= b; i++) {
    if (k[i] != "w") continue
    wv = w[i]
    # A colon-prefixed refspec is a deletion whether or not --delete is
    # given, and it is never the remote, so it is read before the
    # remote-skipping below.
    if (substr(wv, 1, 1) == ":") { emit(substr(wv, 2)); continue }
    if (substr(wv, 1, 1) == "-") continue
    if (!seen_remote) { seen_remote = 1; continue }   # the remote name
    if (del) emit(wv)
  }
}

function gh_api(a, b, nested,   g, i, is_api, is_del, wv, m) {
  g = cmd_index(w, k, a, b, "(^|/)(gh|glab)$", nested, "")
  if (!g) return
  is_api = 0; is_del = 0
  for (i = g + 1; i <= b; i++) {
    if (k[i] != "w") continue
    wv = w[i]
    if (wv == "api") is_api = 1
    if (wv == "-X" || wv == "--method") { if (i + 1 <= b && k[i + 1] == "w" && toupper(w[i + 1]) == "DELETE") is_del = 1 }
    if (toupper(wv) == "-XDELETE" || toupper(wv) == "--METHOD=DELETE") is_del = 1
  }
  if (!is_api || !is_del) return
  for (i = g + 1; i <= b; i++) {
    if (k[i] != "w") continue
    m = index(w[i], "refs/heads/")
    if (m) emit(substr(w[i], m + 11))
  }
}

# `gh pr merge --delete-branch` is the deletion GitHub retargets around.
# Its presence anywhere in the segment exempts the whole segment.
function merge_exempt(a, b,   i, has_merge, has_pr, has_del) {
  for (i = a; i <= b; i++) {
    if (k[i] != "w") continue
    if (w[i] == "pr") has_pr = 1
    if (w[i] == "merge") has_merge = 1
    if (w[i] == "--delete-branch" || w[i] == "-d") has_del = 1
  }
  return (has_pr && has_merge && has_del)
}

{ buf = buf $0 "\n" }
END {
  buf = strip_heredocs(buf)
  nt = texts_of(buf, texts, nested)
  for (x = 1; x <= nt; x++) {
    n = scan(texts[x], w, k, q)
    a = 1
    for (i = 1; i <= n + 1; i++) {
      if (i <= n && k[i] != ";") continue
      if (a < i && !merge_exempt(a, i - 1)) {
        git_push(a, i - 1, nested[x])
        gh_api(a, i - 1, nested[x])
      }
      a = i + 1
    }
  }
}') || deny "no-delete-stacked-base: awk failed, cannot inspect the command"

[ -n "$branches" ] || exit 0

advice() {
  printf '%s' "A stacked PR is retargeted only when its base disappears because the base PR merged. Merge bottom-up with \`gh pr merge --delete-branch\` (exempt from this hook), or retarget the dependents to their next base first:
  gh pr list --base $1 --json number,title
  gh pr edit <n> --base <new-base>"
}

if printf '%s\n' "$branches" | grep -qx '[?]'; then
  ask "no-delete-stacked-base: this deletes a remote branch named by a variable or a glob, so the branch can't be resolved and checked for open PRs stacked on it. Confirm no open PR names it as base or head:
  gh pr list --state open --json number,baseRefName,headRefName"
fi

command -v gh >/dev/null 2>&1 || ask "no-delete-stacked-base: this deletes a remote branch, but \`gh\` is not installed, so open PRs based on it can't be checked. Deleting a branch an open PR points at closes that PR silently."

# One query for the whole command: every branch it deletes is checked
# against the same list.
out=$(cd "$payload_cwd" 2>/dev/null && gh pr list --state open --limit 100 --json number,title,baseRefName,headRefName 2>/dev/null) || out=""
[ -n "$out" ] || ask "no-delete-stacked-base: this deletes a remote branch, but the open-PR list could not be read (no auth, no network, or not a GitHub repo), so PRs stacked on it can't be checked. Confirm by hand first:
  gh pr list --state open --json number,baseRefName,headRefName"

seen=""
for b in $branches; do
  case " $seen " in *" $b "*) continue ;; esac
  seen="$seen $b"

  based=$(printf '%s' "$out" | jq -r --arg b "$b" '.[] | select(.baseRefName == $b) | "#\(.number) \(.title)"' 2>/dev/null) \
    || ask "no-delete-stacked-base: deleting remote branch \`$b\`, but the open-PR list could not be parsed, so PRs stacked on it can't be checked."
  if [ -n "$based" ]; then
    deny "no-delete-stacked-base: \`$b\` is the base branch of open PR(s):
$based
Deleting it closes every one of them -- GitHub does not retarget a PR whose base is deleted outside a merge, and each has to be reopened and retargeted by hand.

$(advice "$b")"
  fi

  head=$(printf '%s' "$out" | jq -r --arg b "$b" '.[] | select(.headRefName == $b) | "#\(.number) \(.title)"' 2>/dev/null)
  if [ -n "$head" ]; then
    deny "no-delete-stacked-base: \`$b\` is the head branch of open PR(s):
$head
Deleting it closes them and throws the work away. Merge or close the PR first; \`gh pr merge --delete-branch\` deletes the branch the safe way."
  fi
done
exit 0

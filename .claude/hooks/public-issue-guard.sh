#!/bin/sh
# Denies posting text that names a private term to a public GitHub repo.
#
# Why: the state repo is private and the code repos are public, and the rule
# that boat names, hostnames, service URLs and account identifiers stay in the
# private one has lived in CLAUDE.md as prose. Prose has already failed here
# (pr-threads-gate.sh header). Once a term is in a public issue or PR comment
# it is in GitHub's history and every mirror of it; the undo is a support
# ticket, not an edit. So the check moves from the model's memory to the
# moment the text leaves the machine.
#
# Fires on PreToolUse for
#   - Bash: `gh issue|pr create|comment|edit|review|close|reopen|merge`, and
#     `gh api` writing to repos/*/*/issues|pulls or a graphql mutation that
#     comments or opens an issue/PR;
#   - MCP: the GitHub tools that create or edit an issue, PR, comment or
#     review (matched on the tool name's tail).
# Nothing else: a body posted from `python -c`, `curl`, or a script file is
# not inspected. The scope is Bash `gh` and the GitHub MCP tools.
# The text judged is the whole command after quote removal (so a term
# spelled `ho\stname` or split across quotes still reads whole), every
# heredoc body, the file named by --body-file/-F/--input/-F key=@file, and
# for MCP every string in tool_input. The one thing cut out is the path
# operand of those file flags: a path is read, not posted, and a scratchpad
# under $HOME would otherwise trip a term that names the home directory. It is grepped case-insensitively, as
# fixed substrings, against state/global/private-terms.txt in the state repo;
# comment and blank lines in that file are ignored. The reason names the
# term(s) that hit and nothing around them.
#
# The target repo is --repo/-R, GH_REPO=, the `gh api` path, or MCP
# owner/repo; failing those, the origin of the payload's cwd -- unless the
# command also runs `cd`, in which case it is unknown. Unknown is scanned.
# Only mark-brannan/claude_prompts_scratch is allowed unscanned.
#
# GATE, fails closed: no jq, no awk, no library, unreadable payload, a body
# the hook cannot see (--body-file it cannot read, `-F -` with no heredoc,
# a body built from `$(...)` or `$VAR` that no heredoc feeds -- a heredoc
# elsewhere in the command does not vouch for it), or a missing denylist while
# the target is not the private repo -> deny, with the fix in the reason.
set -uf

HERE=$(dirname "$0")
LIB="$HERE/lib-shell-words.awk"
PRIVATE_REPO="mark-brannan/claude_prompts_scratch"
# Labels a session may not apply, space separated. `churn-ok` waives the
# churn gate (.github/workflows/churn-guard.yml): a gate whose bypass the
# gated party can apply to its own PR is not a gate, so that label is a
# human's to add.
DENY_LABELS="churn-ok"

deny() {
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "public-issue-guard: $1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"public-issue-guard: jq missing, cannot inspect the text about to be posted"}}\n'
  fi
  exit 0
}

command -v jq  >/dev/null 2>&1 || deny 'jq missing, cannot inspect the text about to be posted'
command -v awk >/dev/null 2>&1 || deny 'awk missing, cannot inspect the text about to be posted'
[ -r "$LIB" ] || deny "$LIB missing, cannot inspect the command"
[ -r "$HERE/lib-state.sh" ] || deny "$HERE/lib-state.sh missing, cannot locate the denylist"
# shellcheck source=lib-state.sh
. "$HERE/lib-state.sh"

payload=$(cat) || deny 'unreadable hook payload'
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || deny 'unreadable hook payload'
[ -n "$tool" ] || exit 0
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd=$PWD

WORK=$(mktemp -d "${TMPDIR:-/tmp}/public-issue-guard.XXXXXX") || deny 'cannot create a scratch directory'
trap 'rm -rf "$WORK"' EXIT
TEXT="$WORK/text"      # everything that will be posted, one candidate per line
META="$WORK/meta"      # R repo | F file | STDIN | OPAQUE | HEREDOC | CD
: > "$TEXT"; : > "$META"

# owner/name in lower case from any of the spellings gh and git accept.
norm_repo() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's#^[a-z]*://[^/]*/##' -e 's#^[^@/]*@[^:]*:##' -e 's#^github\.com/##' -e 's#\.git$##' -e 's#/*$##'
}

case "$tool" in
  Bash)
    cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || deny 'unreadable hook payload'
    [ -n "$cmd" ] || exit 0
    printf '%s\n' "$cmd" | awk "$(cat "$LIB")"'
      function wv(i) { return (k[i] == "q") ? q[i] : w[i] }
      function flat(t) { gsub(/\n/, " ", t); return t }
      function file(p) { if (p == "-") print "STDIN"; else print "F\t" flat(p) }
      # Opaque = built at run time. Allowed only when the heredoc feeding it is
      # on the value itself: `$(cat <<EOF ...)` inline, or `$VAR` whose
      # assignment carries `<<`. The heredoc body is in TEXT and gets scanned.
      function fed(v,   name) {
        name = v; sub(/^\$\{?/, "", name); sub(/[^A-Za-z0-9_].*$/, "", name)
        return name != "" && orig ~ ("(^|[;&|[:space:]])" name "=[\"\047]?\\$\\([^)]*<<")
      }
      # strip_heredocs has already turned an inline `$(cat <<EOF ...)` into
      # `$(cat  HEREDOC  )`; either spelling means a heredoc feeds the value.
      function val(v) {
        if (v ~ /\$\(/ || v ~ /`/) { if (v !~ /<</ && v !~ / HEREDOC /) print "OPAQUE\t" flat(v) }
        else if (v ~ /^\$[A-Za-z_{]/) { if (!fed(v)) print "OPAQUE\t" flat(v) }
      }
      function lab(v,   n, a, i) {
        n = split(v, a, ",")
        for (i = 1; i <= n; i++) {
          gsub(/^[[:space:]]+/, "", a[i]); gsub(/[[:space:]]+$/, "", a[i])
          if (a[i] != "") print "L\t" flat(a[i])
        }
      }
      function field(v,   key) {
        key = v; sub(/=.*$/, "", key)
        sub(/^[^=]*=/, "", v)
        if (v ~ /^@/) { file(substr(v, 2)); return }
        if (key ~ /label/) lab(v)
        val(v)
      }
      { buf = buf $0 "\n" }
      END {
        orig = buf
        stripped = strip_heredocs(buf)
        if (stripped != buf) print "HEREDOC"
        buf = stripped
        ntexts = texts_of(buf, texts, nested)
        for (x = 1; x <= ntexts; x++) {
          n = scan(texts[x], w, k, q)
          for (i = 1; i <= n; i++) {
            if (k[i] == ";") continue
            if (k[i] == "w" && w[i] ~ /^(cd|pushd)$/) print "CD"
            print "T\t" flat(wv(i))
          }
          a0 = 1
          for (i = 1; i <= n + 1; i++) {
            if (i <= n && k[i] != ";") continue
            if (a0 < i) segment(a0, i - 1, nested[x])
            a0 = i + 1
          }
        }
      }
      function segment(lo, hi, nested,   g, i, t, v, repo, sub_, act) {
        g = cmd_index(w, k, lo, hi, "(^|/)gh$", nested, "")
        if (!g || g + 1 > hi) return
        repo = ""
        for (i = lo; i < g; i++) if (k[i] == "w" && w[i] ~ /^GH_REPO=/) repo = substr(w[i], 9)
        sub_ = w[g + 1]
        if (sub_ == "api") { api(g, hi, repo); return }
        if ((sub_ != "issue" && sub_ != "pr") || g + 2 > hi) return
        act = w[g + 2]
        if (act !~ /^(create|comment|edit|review|close|reopen|merge)$/) return
        for (i = g + 3; i <= hi; i++) {
          t = w[i]
          if (t == "--repo" || t == "-R") { if (i < hi) repo = wv(++i) }
          else if (t ~ /^--repo=/) repo = substr(t, 8)
          else if (t ~ /^-R./) repo = substr(t, 3)
          else if (t == "--body-file" || t == "-F") { if (i < hi) file(wv(++i)) }
          else if (t ~ /^--body-file=/) file(substr(t, 13))
          else if (t ~ /^-F./) file(substr(t, 3))
          else if (t ~ /^(--body|--title|--comment|--subject|-b|-t|-c)$/) { if (i < hi) val(wv(++i)) }
          else if (t ~ /^--(body|title|comment|subject)=/) { v = t; sub(/^[^=]*=/, "", v); val(v) }
          else if (t ~ /^-[btc]./) val(substr(t, 3))
          else if (t ~ /^(--label|--add-label|-l)$/) { if (i < hi) lab(wv(++i)) }
          else if (t ~ /^--(add-)?label=/) { v = t; sub(/^[^=]*=/, "", v); lab(v) }
          else if (t ~ /^-l./) lab(substr(t, 3))
        }
        print "R\t" (repo == "" ? "-" : flat(repo))
      }
      function api(g, hi, repo,   i, t, v, path, method, fields, p, parts, hit) {
        path = ""; method = ""; fields = 0
        for (i = g + 2; i <= hi; i++) {
          t = w[i]
          if (t == "-X" || t == "--method") { if (i < hi) method = toupper(w[++i]) }
          else if (t ~ /^--method=/) method = toupper(substr(t, 10))
          else if (t ~ /^-X./) method = toupper(substr(t, 3))
          else if (t ~ /^(-f|-F|--field|--raw-field)$/) { fields = 1; if (i < hi) field(wv(++i)) }
          else if (t ~ /^-[fF]./) { fields = 1; field(substr(t, 3)) }
          else if (t ~ /^--(field|raw-field)=/) { fields = 1; v = t; sub(/^[^=]*=/, "", v); field(v) }
          else if (t == "--input") { fields = 1; if (i < hi) file(wv(++i)) }
          else if (t ~ /^--input=/) { fields = 1; file(substr(t, 9)) }
          else if (t ~ /^(-H|--header|-q|--jq|-t|--template|-p|--preview|--hostname|--cache)$/) i++
          else if (t ~ /^-/) continue
          else if (path == "") path = t
        }
        p = path; sub(/^https?:\/\/[^\/]+\//, "", p); sub(/^\/+/, "", p)
        if (p ~ /^repos\/[^\/]+\/[^\/]+\/(issues|pulls)(\/|$)/) {
          if (method == "GET" || method == "HEAD" || (method == "" && !fields)) return
          split(p, parts, "/")
          print "R\t" parts[2] "/" parts[3]
        } else if (p == "graphql") {
          hit = 0
          for (i = g; i <= hi; i++)
            if (wv(i) ~ /(addComment|createIssue|updateIssue|createPullRequest|updatePullRequest|addPullRequestReview|submitPullRequestReview|addDiscussionComment)/) hit = 1
          if (hit) print "R\t" (repo == "" ? "-" : flat(repo))
        }
      }' > "$META" || deny 'awk failed, cannot inspect the command'
    # The tokeniser can lose a segment behind an odd construct; the raw string
    # is the backstop, so a gh write it names is scanned with the repo unknown.
    if ! grep -q '^R	' "$META" && printf '%s' "$cmd" | grep -Eq '(^|[^A-Za-z0-9_./-])gh[[:space:]]+(issue|pr)[[:space:]]+(create|comment|edit|review|close|reopen|merge)([[:space:]]|$)'; then
      printf 'R\t-\n' >> "$META"
    fi
    grep -q '^R	' "$META" || exit 0
    # Mask the file-flag path operands: the file is scanned below, the path
    # never leaves the machine. Fixed-string, every occurrence, in the raw
    # command and in the words alike (`--body-file=/p` is one word).
    sed -n 's/^F	//p' "$META" | grep -v '^$' > "$WORK/fpaths"
    { printf '%s\n' "$cmd"; sed -n 's/^T	//p' "$META"; } | awk -v pf="$WORK/fpaths" '
      FILENAME == pf { paths[++np] = $0; next }
      { for (i = 1; i <= np; i++) { out = ""; s = $0
          while ((j = index(s, paths[i])) > 0) { out = out substr(s, 1, j - 1) "<file>"; s = substr(s, j + length(paths[i])) }
          $0 = out s }
        print }' "$WORK/fpaths" - >> "$TEXT" || deny 'awk failed, cannot inspect the command'
    ;;
  mcp__*__create_issue|mcp__*__update_issue|mcp__*__issue_write|mcp__*__add_issue_comment| \
  mcp__*__create_pull_request|mcp__*__update_pull_request| \
  mcp__*__add_pull_request_review_comment|mcp__*__create_pull_request_review| \
  mcp__*__pull_request_review_write|mcp__*__add_comment_to_pending_review| \
  mcp__*__create_and_submit_pull_request_review|mcp__*__submit_pending_pull_request_review)
    repo=$(printf '%s' "$payload" | jq -r 'if (.tool_input.owner? // "") != "" and (.tool_input.repo? // "") != "" then "\(.tool_input.owner)/\(.tool_input.repo)" else "-" end' 2>/dev/null)
    printf 'R\t%s\n' "${repo:--}" >> "$META"
    printf '%s' "$payload" | jq -r '[.tool_input | .. | strings] | join("\n")' 2>/dev/null >> "$TEXT" || deny 'unreadable hook payload'
    ;;
  *) exit 0 ;;
esac

# A denied label is denied everywhere, public repo or private: the bypass it
# waives is a human's to apply.
# Matched case-insensitively: GitHub label names are unique that way, so
# `CHURN-OK` reaches the same label and must not slip past.
while IFS="$(printf '\t')" read -r kind value; do
  [ "$kind" = L ] || continue
  value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  for bad in $DENY_LABELS; do
    [ "$value" = "$bad" ] && deny "the label \`$bad\` is a human's to apply, not a session's -- it waives the churn gate, and a gate whose bypass the gated party can reach is not a gate. Split the PR instead, or say in the PR body why it has to be over budget and let the label be added by hand."
  done
done < "$META"

# Every target must be the private repo for the text to go unscanned; one
# unknown or public target among several means the scan runs.
all_private=1
# shellcheck disable=SC2094  # META is only read here
while IFS="$(printf '\t')" read -r kind repo; do
  [ "$kind" = R ] || continue
  if [ "$repo" = "-" ]; then
    if grep -q '^CD$' "$META"; then repo=""
    else repo=$(git -C "$cwd" remote get-url origin 2>/dev/null) || repo=""
    fi
  fi
  [ "$(norm_repo "$repo")" = "$PRIVATE_REPO" ] || all_private=0
done < "$META"
[ "$all_private" = 1 ] && exit 0

denylist="$(state_dir)/private-terms.txt"
[ -r "$denylist" ] || deny "the private-terms denylist is unreadable ($denylist), so text bound for a public repo cannot be checked. Is the state repo checked out? On a real machine: clone mark-brannan/claude_prompts_scratch to one of the paths lib-state.sh searches, or set CLAUDE_STATE_REPO. In a cloud session: mcp__Claude_Code_Remote__add_repo (owner mark-brannan, repo claude_prompts_scratch, access push), clone it to /workspace/claude_prompts_scratch, retry. To post without the check, target the private repo itself: --repo $PRIVATE_REPO."
sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' "$denylist" > "$WORK/terms"
[ -s "$WORK/terms" ] || deny "the private-terms denylist ($denylist) is readable but has no terms in it -- only comments and blank lines, or nothing at all. An empty list matches nothing, so every post would pass unchecked, which is indistinguishable from a check that ran. Populate it (one term per line, # for comments) and retry. To post without the check, target the private repo itself: --repo $PRIVATE_REPO."

# Bodies the hook cannot read are a hole, not a pass. awk emits OPAQUE only
# when no heredoc feeds the value, so a heredoc elsewhere does not excuse it.
opaque=$(sed -n 's/^OPAQUE	//p' "$META" | head -1)
[ -n "$opaque" ] && deny "the body or title is built at run time ($opaque) and no heredoc in this command feeds it, so its text cannot be checked before it is posted. Write it literally, in a heredoc in the same command, or in a file and pass --body-file <path>."
if ! grep -q '^HEREDOC$' "$META"; then
  grep -q '^STDIN$' "$META" && deny "the body comes from stdin (-F - / --input -) and there is no heredoc in the command, so it cannot be checked. Put the text in a heredoc in the same command, or in a file and pass --body-file <path>."
fi
sed -n 's/^F	//p' "$META" | while IFS= read -r f; do
  case "$f" in
    '~'/*) f="$HOME${f#\~}" ;;
    /*) ;;
    *) f="$cwd/$f" ;;
  esac
  [ -r "$f" ] || { printf '%s\n' "$f" > "$WORK/badfile"; continue; }
  cat "$f" >> "$TEXT"; printf '\n' >> "$TEXT"
done
[ -f "$WORK/badfile" ] && deny "--body-file $(cat "$WORK/badfile") cannot be read, so the text about to be posted cannot be checked. Create the file first, in the same command or an earlier one, then retry."

grep -q -i -F -f "$WORK/terms" "$TEXT" || exit 0

hits=""
while IFS= read -r term; do
  grep -q -i -F -e "$term" -- "$TEXT" && hits="$hits, $term"
done < "$WORK/terms"
deny "the text about to be posted to a public repo contains private term(s) from the denylist: ${hits#, }. Private detail does not go on public GitHub, ever -- it stays in GitHub's history. Either open the issue on the private state repo instead (--repo $PRIVATE_REPO) and link it from here, or rewrite the body without the term. Do not paraphrase it into something recognisable."

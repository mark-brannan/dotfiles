#!/bin/sh
# Blocks the git moves that have bitten Mark, or sit in the same class as
# ones that have, and that a session never has a good reason to make:
#
#   blanket staging   git add -A / --all / . / ./ / -u with no path,
#                     git commit -a  -> on dotfiles the worktree is $HOME;
#                     elsewhere it sweeps in a parallel session's files.
#   stash pop/drop    the stash stack is shared across worktrees, so a pop,
#                     a bare drop or a clear can take another session's
#                     entry (reproduced 2026-08-19). apply/drop by sha pass.
#   force push        bare --force / -f / +refspec anywhere; --force-with-lease
#                     to main or master; deleting main. Rebasing a session
#                     branch is the one legitimate force, and it is
#                     --force-with-lease to that branch.
#   discard           git checkout . / git restore . / git clean -f: throws
#                     away uncommitted work, same as reset --hard.
#   branch -D         throws away unmerged work; -d refuses, use that.
#
# `yadm` is treated as `git`, since on dotfiles that is what it is.
#
# Parsing, in order: heredoc bodies are dropped (a doc that *mentions*
# `git add -A` is not a git command); quotes around a single word are
# stripped so `git add '.'` is seen; remaining quoted strings are blanked so
# a commit message that mentions a flag doesn't trip it; then the command
# is split on shell separators, including parens and braces, and each
# segment whose command word is git (directly or behind sudo/env/VAR=x)
# is checked with git's global options skipped.
#
# This is a GATE, so it fails closed: no jq, no awk, unreadable payload ->
# block. `git reset --hard` has its own hook (no-git-reset-hard.sh).
set -u

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
  exit 0
}

command -v jq  >/dev/null 2>&1 || deny 'no-git-footguns: jq missing, cannot inspect the command'
command -v awk >/dev/null 2>&1 || deny 'no-git-footguns: awk missing, cannot inspect the command'
cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null) || deny 'no-git-footguns: unreadable hook payload'
[ -n "$cmd" ] || exit 0

reason=$(printf '%s\n' "$cmd" | awk '
function has(t, ch) { return t ~ ("^-[A-Za-z0-9]*" ch "[A-Za-z0-9]*$") }
function dst(t,  i) { sub(/^\+/, "", t); i = index(t, ":"); if (i) t = substr(t, i + 1); return t }
function ismain(t) { return t ~ /^(refs\/heads\/)?(main|master)$/ }
function whole(t) { return t ~ /^(\.|\.\/|\.\/\*|:\/|:\/\.|\*)$/ }
function fail(r) { print r; exit }
# Drop every heredoc body: from the end of the line carrying <<WORD to the
# line that is exactly WORD. The marker itself becomes a plain word.
function strip_heredocs(b,  d, eol, endm, tail, start) {
  while (match(b, /<<-?[ \t]*["'\'']?[A-Za-z_][A-Za-z0-9_]*["'\'']?/)) {
    start = RSTART  # match() below clobbers RSTART; keep the opener'\''s position
    d = substr(b, start, RLENGTH); sub(/^<<-?[ \t]*/, "", d); gsub(/["'\'']/, "", d)
    eol = index(substr(b, start), "\n")
    if (!eol) return substr(b, 1, start - 1) " HEREDOC "
    tail = substr(b, start + eol)
    endm = match(tail, "(^|\n)[ \t]*" d "[ \t]*(\n|$)")
    if (!endm) return substr(b, 1, start - 1) " HEREDOC "
    b = substr(b, 1, start - 1) " HEREDOC " substr(tail, endm + RLENGTH - 1)
  }
  return b
}
{ buf = buf $0 "\n" }
END {
  buf = strip_heredocs(buf)
  # Quotes around one bare word are just quotes: git add '"'"'.'"'"' is git add .
  while (match(buf, /'\''[^'\'' \t\n&|;()`{}]*'\''/) || match(buf, /"[^" \t\n&|;()`{}]*"/))
    buf = substr(buf, 1, RSTART - 1) substr(buf, RSTART + 1, RLENGTH - 2) substr(buf, RSTART + RLENGTH)
  # Anything still quoted is prose: a flag inside a commit message is not a flag.
  gsub(/'\''[^'\'']*'\''/, " Q ", buf)
  gsub(/"[^"]*"/, " Q ", buf)
  gsub(/&&|\|\||;|\||\n|[()`{}]/, "\n", buf)
  nseg = split(buf, seg, "\n")
  for (s = 1; s <= nseg; s++) {
    nt = split(seg[s], t, /[ \t]+/)
    # git must be the command word: first token, or first after a wrapper
    # (sudo, env, VAR=x, timeout 30 ...). `echo git add -A` is prose.
    g = 0
    for (i = 1; i <= nt; i++) {
      if (t[i] == "") continue
      if (t[i] ~ /(^|\/)(git|yadm)$/) { g = i; break }
      if (t[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
      if (t[i] ~ /^(sudo|env|command|exec|time|nice|nohup|timeout|doas)$/) { wrap = 1; continue }
      if (wrap && (t[i] ~ /^-/ || t[i] ~ /^[0-9]+[smhd]?$/)) continue
      break
    }
    wrap = 0
    if (!g) continue
    # Skip global options; -C/-c/--git-dir/--work-tree take a value.
    i = g + 1
    while (i <= nt && t[i] ~ /^-/) {
      if (t[i] ~ /^(-C|-c|--git-dir|--work-tree|--namespace)$/) i++
      i++
    }
    if (i > nt) continue
    sub_ = t[i]; a0 = i + 1
    delete a; na = 0
    for (i = a0; i <= nt; i++) if (t[i] != "") a[++na] = t[i]

    if (sub_ == "add") {
      paths = 0; upd = 0
      for (i = 1; i <= na; i++) {
        if (a[i] ~ /^(-A|--all|--no-ignore-removal)$/ || has(a[i], "A")) fail("`git add -A` is blocked: stage by path. On dotfiles the worktree is $HOME; elsewhere it sweeps in files a parallel session is working on.")
        if (whole(a[i])) fail("`git add " a[i] "` is blocked: stage by path, not the whole tree.")
        if (a[i] ~ /^(-u|--update)$/ || has(a[i], "u")) upd = 1
        else if (a[i] !~ /^-/) paths++
      }
      if (upd && !paths) fail("`git add -u` with no path is blocked: stage by path.")
    }
    else if (sub_ == "commit") {
      for (i = 1; i <= na; i++)
        if (a[i] == "--all" || has(a[i], "a")) fail("`git commit -a` is blocked: it is `git add -u` in disguise. Stage by path, then commit.")
    }
    else if (sub_ == "stash") {
      op = ""; refs = 0
      for (i = 1; i <= na; i++) if (a[i] !~ /^-/) { if (op == "") op = a[i]; else refs++ }
      if (op == "pop") fail("`git stash pop` is blocked: the stash stack is shared across worktrees and pop can take another session'\''s entry. Use `git stash apply <sha>` and drop the entry afterwards.")
      if (op == "clear") fail("`git stash clear` is blocked: the stash stack is shared across worktrees; it is not all yours to clear.")
      if (op == "drop" && !refs) fail("bare `git stash drop` drops stash@{0}, which may be another session'\''s. Name the entry: `git stash drop stash@{n}` after finding it by tag.")
    }
    else if (sub_ == "push") {
      force = 0; lease = 0; tomain = 0; del = 0
      for (i = 1; i <= na; i++) {
        if (a[i] ~ /^--force-with-lease(=|$)/ || a[i] ~ /^--force-if-includes$/) { lease = 1; continue }
        if (a[i] == "--force" || has(a[i], "f")) force = 1
        else if (a[i] == "--delete" || has(a[i], "d")) del = 1
        else if (a[i] ~ /^\+/) force = 1
        else if (a[i] ~ /^:/ && ismain(dst(a[i]))) { del = 1; tomain = 1 }
        else if (a[i] !~ /^-/ && ismain(dst(a[i]))) tomain = 1
      }
      if (force) fail("bare `git push --force` is blocked. Rebasing a session branch is the one legitimate force: use `--force-with-lease origin <branch>`, never to main.")
      if (tomain && (lease || del)) fail("force-pushing or deleting main is blocked. Main takes rebased branches through a PR.")
    }
    else if (sub_ == "checkout" || sub_ == "restore") {
      staged = 0; wt = 0; w = ""
      for (i = 1; i <= na; i++) {
        if (a[i] ~ /^(-S|--staged)$/ || has(a[i], "S")) staged = 1
        if (a[i] ~ /^(-W|--worktree)$/ || has(a[i], "W")) wt = 1
        if (whole(a[i])) w = a[i]
      }
      if (w != "" && !(sub_ == "restore" && staged && !wt)) fail("`git " sub_ " " w "` is blocked: it discards every uncommitted change, same as reset --hard. Restore one path at a time, or ask Mark.")
    }
    else if (sub_ == "clean") {
      force = 0; dry = 0
      for (i = 1; i <= na; i++) {
        if (a[i] == "--force" || has(a[i], "f")) force = 1
        if (a[i] == "--dry-run" || has(a[i], "n")) dry = 1
      }
      if (force && !dry) fail("`git clean -f` is blocked: it deletes untracked files, unrecoverably. `git clean -n` to list them, then remove by path.")
    }
    else if (sub_ == "branch") {
      del = 0; force = 0
      for (i = 1; i <= na; i++) {
        if (a[i] == "-D" || has(a[i], "D")) fail("`git branch -D` is blocked: it deletes unmerged work. `git branch -d` refuses when there is something to lose; if it refuses, that is the answer.")
        if (a[i] ~ /^(-d|--delete)$/ || has(a[i], "d")) del = 1
        if (a[i] ~ /^(-f|--force)$/ || has(a[i], "f")) force = 1
      }
      if (del && force) fail("`git branch --delete --force` is blocked: same as -D.")
    }
  }
}') || deny 'no-git-footguns: awk failed, cannot inspect the command'

[ -n "$reason" ] && deny "$reason"
exit 0

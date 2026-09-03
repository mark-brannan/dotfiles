#!/bin/sh
# Blocks recursive `rm` (-r, -R, --recursive, or any short cluster containing
# r/R: -rf, -fr, -rfv, -Rf) unless every target, resolved against the
# payload's cwd and normalised, is Claude's to remove.
#
# Written 2026-09-03 after session 97b9f69d ran `rm -rf examples` in
# signalk-noaa-space-weather while repointing a plugin at the core, and
# destroyed ~20 untracked aurora captures, examples/captures/, and a watch
# log Mark was using as an ongoing download area. `git rm --cached` had
# already handled the tracked files; the `rm -rf` existed only to sweep the
# rest, and the rest was his.
#
# Allowlist, not a denylist. A target is allowed only when it is:
#   1. under the session scratchpad, an agent worktree, or /tmp -- these are
#      Claude's areas, nothing of Mark's lives there;
#   2. a directory named in GENERATED_NAMES below (its final path component,
#      or an ancestor component -- so `dist` and `dist/sub` both pass).
# Everything else is denied: any other directory under $HOME (a misc
# directory in the home tree is Mark's by default, whatever it holds), any
# repo's tracked or working directories, `public/` included -- the plugin's
# generated `public/` is cleared by scripts/sync-webapp.mjs itself, in Node,
# which this hook does not see, and the core's `public/` is tracked, so the
# name stays off the list.
#
# A glob (*, ?, [), a shell variable or $(...), a `..` segment, a `~` other
# than a leading one, or a target that resolves to /, $HOME, or (by the same
# default-deny) a repo root is denied on sight: a target this hook cannot
# resolve to one allowed path is not allowed. `rm` on a single file (no
# recursive flag) passes -- where the file is tracked that is `git rm`'s
# job, and the standing "look at the target before deleting" rule otherwise.
#
# Out of scope: `find ... -delete`, `rmdir`.
#
# Parsing, same approach as no-git-footguns.sh (read that file first): a
# heredoc body is dropped (a doc that *mentions* `rm -rf` is not an `rm`
# command); quotes around a single word are stripped so `rm -rf "$HOME/foo"`
# is seen as-is; remaining quoted strings are blanked; the command is split
# on shell separators, including parens and braces, and each segment whose
# command word is `rm` (directly, by full path, or behind sudo/env/VAR=x/
# timeout/etc.) is checked. `git rm` and `yadm rm` are untouched -- `rm`
# must be the command word, not a subcommand argument.
#
# This is a GATE, so it fails closed: no jq/awk -> deny.
set -u

# Generated directories -- recursive rm on a target whose final path
# component (or an ancestor component) is one of these is allowed to be
# removed recursively. Adding a name is a PR, not a judgment call in a
# session.
#   node_modules   npm/yarn/pnpm install output, most JS repos
#   dist           tsc/vite/webpack build output
#   demo-dist      searoom demo build
#   app-dist       searoom app build
#   .hero-states   searoom hero-state capture cache
#   coverage       test coverage reports (nyc/jest/vitest)
#   .pio           PlatformIO build cache (SensESP / symphony firmware repos)
GENERATED_NAMES="node_modules dist demo-dist app-dist .hero-states coverage .pio"

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
  exit 0
}

command -v jq  >/dev/null 2>&1 || deny 'no-rm-tree: jq missing, cannot inspect the command'
command -v awk >/dev/null 2>&1 || deny 'no-rm-tree: awk missing, cannot inspect the command'

payload=$(cat) || deny 'no-rm-tree: unreadable hook payload'
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || deny 'no-rm-tree: unreadable hook payload'
[ -n "$cmd" ] || exit 0

cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
case $cwd in
  /*) : ;;
  *) cwd=$PWD ;;
esac

home=$HOME
case $home in
  /*) : ;;
  *) deny 'no-rm-tree: $HOME is not an absolute path, cannot resolve targets' ;;
esac

reason=$(printf '%s\n' "$cmd" | awk -v cwd="$cwd" -v home="$home" -v gennames="$GENERATED_NAMES" '
function has(t, ch) { return t ~ ("^-[A-Za-z0-9]*" ch "[A-Za-z0-9]*$") }
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

function is_generated(path,   n, parts, i, j) {
  n = split(path, parts, "/")
  for (i = 1; i <= n; i++) {
    if (parts[i] == "") continue
    for (j = 1; j <= ngen; j++) if (parts[i] == gnames[j]) return 1
  }
  return 0
}

function under(path, dir) { return path == dir || substr(path, 1, length(dir) + 1) == (dir "/") }

# Collapse "." segments and duplicate slashes. `..` segments are denied
# before a target ever reaches here, so none survive to resolve.
function normalize(p,   n, parts, i, out) {
  n = split(p, parts, "/")
  out = ""
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || parts[i] == ".") continue
    out = out "/" parts[i]
  }
  return (out == "") ? "/" : out
}

# Resolve one raw rm target against cwd/home. Sets global `badflag` when the
# target cannot be trusted at all (glob, variable, `..`, stray `~`).
function resolve(raw,   t) {
  t = raw
  badflag = 0
  if (t ~ /[*?\[]/) { badflag = 1; return "" }
  if (t ~ /\$/)     { badflag = 1; return "" }
  if (t == ".." || t ~ /(^|\/)\.\.(\/|$)/) { badflag = 1; return "" }
  if (t ~ /~/) {
    if (t == "~") t = home
    else if (t ~ /^~\//) t = home substr(t, 2)
    else { badflag = 1; return "" }
  }
  if (t !~ /^\//) t = cwd "/" t
  t = normalize(t)
  if (t == "/" || t == homeN) badflag = 1
  return t
}

BEGIN {
  ngen = split(gennames, gnames, " ")
  scratch = home "/.local/state/claude-tmpdir"
  worktrees = home "/.claude/worktrees"
  homeN = normalize(home)
}
{ buf = buf $0 "\n" }
END {
  buf = strip_heredocs(buf)
  # Quotes around one bare word are just quotes: rm -rf "$HOME/foo" is seen
  # with the quotes gone, $HOME/foo intact (still denied, for containing $).
  while (match(buf, /'\''[^'\'' \t\n&|;()`{}]*'\''/) || match(buf, /"[^" \t\n&|;()`{}]*"/))
    buf = substr(buf, 1, RSTART - 1) substr(buf, RSTART + 1, RLENGTH - 2) substr(buf, RSTART + RLENGTH)
  # Anything still quoted is prose or a multi-word literal.
  gsub(/'\''[^'\'']*'\''/, " Q ", buf)
  gsub(/"[^"]*"/, " Q ", buf)
  gsub(/&&|\|\||;|\||\n|[()`{}]/, "\n", buf)
  nseg = split(buf, seg, "\n")
  for (s = 1; s <= nseg; s++) {
    nt = split(seg[s], t, /[ \t]+/)
    g = 0; wrap = 0
    for (i = 1; i <= nt; i++) {
      if (t[i] == "") continue
      if (t[i] ~ /(^|\/)rm$/) { g = i; break }
      if (t[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
      if (t[i] ~ /^(sudo|env|command|exec|time|nice|nohup|timeout|doas)$/) { wrap = 1; continue }
      if (wrap && (t[i] ~ /^-/ || t[i] ~ /^[0-9]+[smhd]?$/)) continue
      break
    }
    wrap = 0
    if (!g) continue

    recursive = 0; dashdash = 0; ntgt = 0
    delete tgt
    for (i = g + 1; i <= nt; i++) {
      a = t[i]
      if (a == "") continue
      if (!dashdash && a == "--") { dashdash = 1; continue }
      if (!dashdash && a ~ /^--/) {
        if (a == "--recursive") recursive = 1
        continue
      }
      if (!dashdash && a ~ /^-./) {
        if (has(a, "r") || has(a, "R")) recursive = 1
        continue
      }
      tgt[++ntgt] = a
    }
    if (!recursive) continue

    for (i = 1; i <= ntgt; i++) {
      abs = resolve(tgt[i])
      if (badflag || !(under(abs, "/tmp") || under(abs, scratch) || under(abs, worktrees) || is_generated(abs)))
        fail("`rm -r " tgt[i] "` is blocked: only the scratchpad, /tmp, agent worktrees and the generated directories named in no-rm-tree.sh may be removed recursively. `git status --short " tgt[i] "` and `git clean -n " tgt[i] "` show what is there; `git rm` tracked files by path, and hand anything untracked to Mark -- a directory he owns can hold downloads and logs no session knows about.")
    }
  }
}') || deny 'no-rm-tree: awk failed, cannot inspect the command'

[ -n "$reason" ] && deny "$reason"
exit 0

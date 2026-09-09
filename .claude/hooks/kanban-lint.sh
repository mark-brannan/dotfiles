#!/bin/sh
# Lints a kanban.md board (or an epic file's Status lines) against the board
# contract: the board is the agent's pull queue in two sections -- ## Needs
# ruling for a question only the user can settle, ## Claude's for agent
# rabbit-trails -- with cards that carry a link and no state.
#
# Why: measured on 2026-09-08, the global board held 128 cards, 28 of them
# ticked and never deleted, 63 restating the state of a PR or issue that
# GitHub already knew, and every session in every repo paid to read the
# first screen of it. The card contract had said "delete when done" and
# "state lives in the PR" for weeks, in CLAUDE.md and in /card-write, and
# the board still grew. Prose rules already failed here once
# (pr-threads-gate.sh header); this is the same move -- the rule leaves the
# model's memory and becomes a check that runs at edit time, at Stop and
# before the state repo commits.
#
# Rules, each printed by id so the reason can be looked up:
#   L1  a "- [x]" line                  -- delete, never tick
#   L2  a bullet above the first "## "  -- cards live under a heading
#   L3  a heading other than ## Needs ruling or ## Claude's, when it is
#       not already in HEAD
#   L4  a card whose action verb is the user's (review, merge, land, bump,
#       close, approve, ship, ratify, rule on, decide, confirm, answer,
#       watch) AND that links a /pull/N or /issues/N -- the user's turn is
#       derived from the PR, never written down. Verb-keyed on purpose: a
#       card citing a merged PR as provenance is fine. Not applied under
#       ## Needs ruling, where "decide X on PR N" is exactly the card's job.
#   L5  a state word (merged, awaiting, not merged, CI green, open as) --
#       only on ADDED lines (--diff) or Status lines (--epic); bare "green"
#       and "red" are not matched ("Red Sea", "green light");
#       history already on the board is not relitigated
#   L6  a card with no link at all (http, or a relative log/ link)
#
# Modes:
#   --file <path>             whole file; L3 only for headings absent from
#                             HEAD, so a legacy "## Solace's" still in HEAD
#                             passes until the migration commit removes it
#   --diff <repo> <relpath>   only lines added in the uncommitted diff
#                             (git diff HEAD, plus an untracked file whole)
#   --epic <path>             L5 on the lines under "## Status"
#   (no args)                 PostToolUse hook: reads the tool JSON, lints
#                             tool_input.file_path when it is a kanban.md
#                             (--diff against HEAD when inside a git repo, else --file) or under
#                             state/global/epics/ (--epic),
#                             blocks with the violations; silent otherwise
#
# Exit: 0 clean, 1 violations ("<line>: <rule> <message>" per line on
# stdout), 2 cannot lint. A card spans its indented continuation lines;
# they are folded before matching, the way session-start-continuity.sh
# folds them for display.
set -u

usage() {
  printf 'usage: kanban-lint.sh --file <path> | --diff <repo-dir> <relpath> | --epic <path>\n' >&2
  printf '       no arguments: PostToolUse hook, JSON on stdin\n' >&2
  exit 2
}

command -v awk >/dev/null 2>&1 || { echo "kanban-lint: awk is missing, cannot lint" >&2; exit 2; }

# run_lint <mode> <file> <added: all | "n n n"> <l3: enforce|skip> <headings in HEAD>
# Prints violations sorted by line. Returns 0 clean, 1 violations, 2 awk failed.
run_lint() {
  out=$(KL_MODE=$1 KL_ADDED=$3 KL_L3=$4 KL_HEADS=$5 awk '
    BEGIN {
      mode = ENVIRON["KL_MODE"]
      allad = (ENVIRON["KL_ADDED"] == "all")
      n = split(ENVIRON["KL_ADDED"], a, " ")
      for (i = 1; i <= n; i++) if (a[i] != "") ad[a[i] + 0] = 1
      l3 = ENVIRON["KL_L3"]
      n = split(ENVIRON["KL_HEADS"], a, "\n")
      for (i = 1; i <= n; i++) if (a[i] != "") heads[a[i]] = 1
      claudes = "## Claude\047s"
      ruling = "## Needs ruling"
      cursec = ""
      nv = split("review merge land bump close approve ship ratify rule_on decide confirm answer watch", verbs, " ")
      for (i = 1; i <= nv; i++) gsub(/_/, " ", verbs[i])
      ns = split("not merged|ci green|open as|merged|awaiting", states, "|")
      instatus = (mode != "epic")
      seenhead = 0; cstart = 0; ctext = ""; touched = 0
    }
    function added(n) { return allad || (n in ad) }
    function report(n, id, msg) { printf "%d: %s %s\n", n, id, msg }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function l5(n, line,   bag, i, tail) {
      bag = " " tolower(line) " "
      gsub(/[^a-z0-9]+/, " ", bag)
      tail = (mode == "epic") ? " (Status line = date -- slug -- decision pointer/links)" : ""
      for (i = 1; i <= ns; i++)
        if (index(bag, " " states[i] " ")) {
          report(n, "L5", "state word \"" states[i] "\" -- work state lives in the PR/issue; carry the link, not the adjective" tail)
          return
        }
    }
    # The verb a card opens with, or "". Leading "**" is skipped so a short
    # name that is itself the action ("**Review and merge [x](...)**") counts.
    function verb_at(s,   t, i, v, rest) {
      t = tolower(s); sub(/^[ \t*]+/, "", t)
      for (i = 1; i <= nv; i++) {
        v = verbs[i]
        if (substr(t, 1, length(v)) == v) {
          rest = substr(t, length(v) + 1, 1)
          if (rest == "" || rest !~ /[a-z]/) return v
        }
      }
      return ""
    }
    function check_card(   text, t2, p, verb) {
      text = ctext
      sub(/^[ \t]*(- \[[ xX]\] |- |[0-9]+\. )/, "", text)
      if (text !~ /https?:\/\// && text !~ /\]\((\.\.\/)*log\//)
        report(cstart, "L6", "card has no link -- a card carries an http link or a relative log/ link; a loop with no home gets a log entry first")
      verb = verb_at(text)
      if (verb == "" && substr(text, 1, 2) == "**") {
        t2 = substr(text, 3); p = index(t2, "**")
        if (p) {
          t2 = substr(t2, p + 2)
          # the separator after the short name: " -- ", " - ", ": " or an em dash
          sub(/^[ \t]*(--|-|:|[^ -~]+)[ \t]*/, "", t2)
          verb = verb_at(t2)
        }
      }
      if (verb != "" && cursec != ruling && text ~ /github\.com\/[^ )]*\/(pull|issues)\/[0-9]/)
        report(cstart, "L4", "\"" verb "\" + a PR/issue link is the user\047s turn, which worklist derives from the PR/issue itself -- the default is to work around it -- decide, record the assumption where the work lands, and carry on; only a one-way door earns a card, under " ruling ". Otherwise delete the card")
    }
    function flush() {
      if (cstart && touched && mode != "epic") check_card()
      cstart = 0; ctext = ""; touched = 0
    }
    /^## / {
      flush(); h = trim($0); seenhead = 1
      if (mode == "epic") { instatus = (h == "## Status"); next }
      if (added(NR) && h != claudes && h != ruling && l3 == "enforce" && !(h in heads))
        report(NR, "L3", "new heading \"" h "\" -- the board has two sections, " ruling " and " claudes "; real work with an owner and a next action is an issue (public repo when it passes the private-terms check, else claude_prompts_scratch); deferred work is an issue on milestone 1.0")
      cursec = h
      next
    }
    /^#/ { flush(); cursec = ""; next }
    mode == "epic" && !instatus { next }
    /^[ \t]*$/ { flush(); next }
    /^(- |[0-9]+\. )/ {
      flush(); cstart = NR; ctext = $0; touched = added(NR)
      if (added(NR)) {
        if (mode != "epic") {
          if ($0 ~ /^- \[[xX]\]/) report(NR, "L1", "ticked card -- delete the line; done work lives in git log and log/, never on the board")
          if (!seenhead) report(NR, "L2", "bullet above the first \"## \" heading -- move it under " claudes)
        }
        if (mode != "file") l5(NR, $0)
      }
      next
    }
    {
      if (cstart) { ctext = ctext " " trim($0); if (added(NR)) touched = 1 }
      if (added(NR) && mode != "file") l5(NR, $0)
    }
    END { flush() }
  ' "$2") || return 2
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | sort -n
  return 1
}

# Headings in the committed copy of <file>, one per line; empty when the
# file is not in HEAD. Caller has checked we are inside a work tree.
head_headings() {
  git -C "$(dirname "$1")" show "HEAD:./$(basename "$1")" 2>/dev/null | grep '^## ' | sed 's/[[:space:]]*$//'
}

lint_file() {
  [ -f "$1" ] || { printf 'kanban-lint: %s: no such file\n' "$1" >&2; return 2; }
  if git -C "$(dirname "$1")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    run_lint file "$1" all enforce "$(head_headings "$1")"
  else
    run_lint file "$1" all skip ""
  fi
}

lint_epic() {
  [ -f "$1" ] || { printf 'kanban-lint: %s: no such file\n' "$1" >&2; return 2; }
  run_lint epic "$1" all skip ""
}

lint_diff() {
  repo=$1; rel=$2
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { printf 'kanban-lint: %s: not a git work tree\n' "$repo" >&2; return 2; }
  [ -f "$repo/$rel" ] || return 0          # deleted or never there: nothing was added
  if git -C "$repo" cat-file -e "HEAD:$rel" 2>/dev/null; then
    added=$(git -C "$repo" diff --no-ext-diff --no-color -U0 HEAD -- "$rel" 2>/dev/null | awk '
      /^@@/ { s = $3; sub(/^\+/, "", s); n = split(s, p, ",")
              cnt = (n > 1) ? p[2] : 1
              for (i = 0; i < cnt; i++) printf "%d ", p[1] + i }') || return 2
    [ -n "$added" ] || return 0
    run_lint diff "$repo/$rel" "$added" enforce "$(head_headings "$repo/$rel")"
  else
    run_lint diff "$repo/$rel" all enforce ""
  fi
}

json_str() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -Rs .
  else
    printf '"%s"\n' "$(printf '%s' "$1" | tr '\t' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{ if (NR > 1) printf "\\n"; printf "%s", $0 }')"
  fi
}

block() { printf '{"decision":"block","reason":%s}\n' "$(json_str "$1")"; exit 0; }

hook_mode() {
  payload=$(cat) || exit 0
  if command -v jq >/dev/null 2>&1; then
    fp=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  else
    fp=$(printf '%s' "$payload" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  fi
  case "$fp" in
    */state/global/epics/*.md) mode="epic" ;;
    kanban.md|*/kanban.md)     mode="file" ;;
    *) exit 0 ;;
  esac
  [ -f "$fp" ] || exit 0
  # Inside a git repo a board is linted by its DIFF, the same view the Stop
  # gate takes: the live board carries years of lines written before these
  # rules existed, and whole-file linting would block every edit to it --
  # including the edit that deletes a legacy card -- until a migration lands.
  if [ "$mode" = file ] && root=$(git -C "$(dirname "$fp")" rev-parse --show-toplevel 2>/dev/null); then
    rel=$(printf '%s' "$fp" | sed "s|^$root/||")
    out=$(lint_diff "$root" "$rel" 2>&1); rc=$?
  else
    out=$(lint_"$mode" "$fp" 2>&1); rc=$?
  fi
  case $rc in
    0) exit 0 ;;
    1) block "kanban-lint: $fp breaks the board contract. Each line below is a line number in the file, the rule it broke, and where that fact lives instead:
$out

Fix or delete each line named, then carry on. The board holds a question only the user can settle under ## Needs ruling, and agent rabbit-trails under ## Claude's; /card-write has the routing table for everything else." ;;
    *) block "kanban-lint: $fp could not be linted ($out). This check fails closed: make the file lintable (or revert the edit) before carrying on." ;;
  esac
}

case "${1:-}" in
  --file) [ $# -eq 2 ] || usage; lint_file "$2" ;;
  --diff) [ $# -eq 3 ] || usage; lint_diff "$2" "$3" ;;
  --epic) [ $# -eq 2 ] || usage; lint_epic "$2" ;;
  "")     hook_mode ;;
  *)      usage ;;
esac

#!/usr/bin/env bash
# Denies creating a pull request in draft state, whichever tool creates it.
#
# Why: the cloud harness's own system prompt says "create the pull request
# as a draft", so prose in CLAUDE.md/rules is a rule competing with the
# harness's rule and loses often enough to matter. Drafts get no automated
# review (CodeRabbit and claude-review both skip them) and stall waiting for
# a manual ready-flip that keeps not happening. The rule lives in
# ~/.claude/rules/code.md ("PR ownership: never a draft, never red"); this
# hook is its enforcement.
#
# Deny, don't rewrite: a deny reason is fed back to the model, which retries
# the same call with draft off. That works identically for the GitHub MCP
# tool (draft parameter) and gh CLI (--draft flag).
#
# Match structurally, not by substring. Matching the raw command string for
# "gh pr create" and "--draft" anywhere in it blocked commits and PR bodies
# that merely *mention* the flag as prose -- twice in one session on PR #34,
# while documenting this very guard. The command is tokenized the way a
# shell would (quotes and backslashes respected), so a --draft inside a
# quoted argument is one token's contents and never a flag.
set -euo pipefail

input=$(cat)

# Without jq we cannot parse the request. Fail open: this guard protects a
# convenience (review latency), not a secret -- a draft that slips through is
# visible and repairable with `gh pr ready`, unlike the gates that fail
# closed. Denying every PR creation because jq is missing would be worse.
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')

jq_deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r}}'
  exit 0
}

# Split a command string into shell-like words. Quoted regions become part of
# the current word rather than ending it, so their contents can never look
# like a flag. Command separators (; && || | & newline) are emitted as their
# own words so a `gh pr create` in one command is not confused with flags
# belonging to the next. Unterminated quotes are not an error here -- we are
# inspecting, not executing.
TOKENS=()
tokenize() {
  local s=$1 i=0 c n cur='' have=0 quote=''
  n=${#s}
  TOKENS=()
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}
    i=$((i + 1))
    if [ -n "$quote" ]; then
      if [ "$c" = "$quote" ]; then
        quote=''
      elif [ "$c" = '\' ] && [ "$quote" = '"' ] && [ "$i" -lt "$n" ]; then
        cur+=${s:i:1}
        i=$((i + 1))
      else
        cur+=$c
      fi
      continue
    fi
    case "$c" in
      \'|\")
        quote=$c
        have=1
        ;;
      '\')
        if [ "$i" -lt "$n" ]; then
          cur+=${s:i:1}
          i=$((i + 1))
          have=1
        fi
        ;;
      ' '|$'\t')
        if [ "$have" = 1 ]; then
          TOKENS+=("$cur")
          cur=''
          have=0
        fi
        ;;
      ';'|'&'|'|'|$'\n')
        if [ "$have" = 1 ]; then
          TOKENS+=("$cur")
          cur=''
          have=0
        fi
        # Collapse a repeated operator (&& ||) into the one separator token.
        while [ "$i" -lt "$n" ] && [ "${s:i:1}" = "$c" ]; do
          i=$((i + 1))
        done
        TOKENS+=(';')
        ;;
      *)
        cur+=$c
        have=1
        ;;
    esac
  done
  if [ "$have" = 1 ]; then
    TOKENS+=("$cur")
  fi
}

# gh pr create flags that consume the following token as their value. Without
# this, `--title --draft` would read the title's value as a flag.
takes_value() {
  case "$1" in
    -t|--title|-b|--body|-F|--body-file|-B|--base|-H|--head|-a|--assignee| \
    -l|--label|-m|--milestone|-p|--project|-r|--reviewer|-T|--template)
      return 0 ;;
  esac
  return 1
}

# A single-dash cluster of boolean shorthands containing d, e.g. -d, -dw, -wd.
# Clusters mixing in a value-taking shorthand (-bd is body="d") are not drafts.
is_draft_shorthand() {
  local t=$1
  case "$t" in
    -[dw]*) ;;
    *) return 1 ;;
  esac
  t=${t#-}
  case "$t" in
    *[!dw]*) return 1 ;;
    *d*) return 0 ;;
  esac
  return 1
}

# True when the token stream contains a `gh pr create` invocation carrying a
# draft flag among its own arguments.
creates_draft() {
  local i=0 n=${#TOKENS[@]} t
  while [ "$i" -lt "$n" ]; do
    if [ "${TOKENS[i]}" = "gh" ] && [ "${TOKENS[i + 1]:-}" = "pr" ] &&
       [ "${TOKENS[i + 2]:-}" = "create" ]; then
      i=$((i + 3))
      while [ "$i" -lt "$n" ]; do
        t=${TOKENS[i]}
        [ "$t" = ";" ] && break
        case "$t" in
          --draft|--draft=true|--draft=1) return 0 ;;
          --draft=*) ;;
          --) break ;;
          *)
            if is_draft_shorthand "$t"; then
              return 0
            elif takes_value "$t"; then
              i=$((i + 1))
            fi
            ;;
        esac
        i=$((i + 1))
      done
      continue
    fi
    i=$((i + 1))
  done
  return 1
}

case "$tool" in
  *__create_pull_request)
    draft=$(printf '%s' "$input" | jq -r '.tool_input.draft // false')
    if [ "$draft" = "true" ]; then
      jq_deny "Blocked by ~/.claude/hooks/no-draft-pr.sh: PRs are never opened as drafts (see ~/.claude/rules/code.md, 'PR ownership'). Drafts skip CodeRabbit/claude-review and stall waiting for a ready-flip. Retry the same create_pull_request call with draft:false (or omit draft). Do not ask the user; this is settled."
    fi
    ;;
  Bash)
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
    tokenize "$cmd"
    if creates_draft; then
      jq_deny "Blocked by ~/.claude/hooks/no-draft-pr.sh: PRs are never opened as drafts (see ~/.claude/rules/code.md, 'PR ownership'). Rerun the same gh pr create without --draft. Do not ask the user; this is settled."
    fi
    ;;
esac

exit 0

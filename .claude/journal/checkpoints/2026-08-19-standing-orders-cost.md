# Checkpoint — standing orders: cost, gates, rituals

Session: claude.ai/code, branch `claude/standing-orders-additions-t3k64q`,
2026-08-19. Continues from the Continuity-section commit (db8db5f).

## Shipped this session

- `.claude/CLAUDE.md` gained a **Continuity** section (chats ephemeral,
  state in files, wrap-up ritual, blocking-question rule). Committed and
  pushed. No PR opened.

## Decided (design settled in conversation, not yet written into the file)

- **Checkpoint report line** — one fenced line, fixed field order, at
  checkpoints and at genuine gates:
  `⛁ <tokens left> · <decisions this session> · gate: <type>`
  Tokens figure is the session counter (measured), not plan usage — only
  `/usage` sees plan consumption. Presence-at-computer is inferred from
  message cadence/gaps and must be labeled as inferred.
- **Cost model** (for intuition): cost ≈ context × turns. Web fetches and
  wide code reads are expensive via the multiplier; prose is cheap. Levers:
  end long sessions instead of extending, subagents for bulk retrieval,
  narrow reads.
- **Initiation ritual** — for non-trivial sessions only, one batched
  question set (AskUserQuestion, up to 4) *before* heavy retrieval:
  1. scope in/out, 2. done-state, 3. heavy retrieval inline vs subagent vs
  separate session, 4. which connectors/MCP to enable (schemas cost tens
  of k). Rationale: answers prune fetches; minute-zero context is cheapest.
- **Gate taxonomy** for "Want me to…?" questions:
  - *permission theatre* — inside the order, reversible → don't ask; delete on sight (countable metric)
  - *spend gate* — "worth more tokens/time?" → report line is load-bearing
  - *reversibility gate* — PR/push/send/delete → line as decision-log entry
  - *direction gate* — fork/pause/wrap/new session → full checkpoint
  Rule: any genuine gate gets the line; a non-genuine gate gets deleted.
- **Decision log** — hooks (settings.json), not prose: append JSONL to
  `~/.claude/journal/decisions.jsonl` with ts, session id, gate type,
  summary ≤140 chars, tokens remaining. Hold derived metrics/dashboards
  until the raw log has existed ~a month and a number was wanted twice
  (Maintenance rule).
- Formatting preference noted: whitespace, stable structure, bold skim
  anchors; reports must not dominate chat.

## Next (in order)

1. Draft the actual diff to `.claude/CLAUDE.md`: **Initiation** (~4 lines),
   **Gates** (~6 lines incl. taxonomy + report line), fold the report line
   into **Continuity**'s wrap-up bullet. Mark says go/edit on text, not ideas.
2. Wire decision-log hooks in settings.json (use the update-config skill).
   This half first — prose without the log gives nothing to count.
3. Optional: statusline showing cost persistently (enforcement beats prose).

## Open questions for Mark

- None blocking. Threshold for "non-trivial session" (when the initiation
  batch fires) is a judgment call to tune from use.

## Session 2 addendum (same day, later)

- **Shipped to main directly** (commit 416ab23, at Mark's explicit request):
  a **Frugality** value in "What this is for" and a **No unprompted asides**
  rule in Voice. Trigger: an unprompted aside about /context cost that took
  two extra turns to explain and contained an overclaim (/context is local
  and free at run time; only transcript residue costs). Named miss; trust
  damaged — rebuild is in small moments, not words.
- Corrected fact for the record: `/context` makes no model call; charges in
  this session came from me replying to its relayed output. The new Voice
  rule covers this: local-command output is not a prompt.
- Note: main and this branch have diverged edits to CLAUDE.md (main has
  Frugality + asides; branch has this journal dir). Continuity section is
  on both. Merge or rebase this branch before further CLAUDE.md drafting.
- Next steps unchanged from above: draft Initiation/Gates diff (now against
  main), then decision-log hooks.

## Session 3 addendum (2026-08-19, desktop/NucBoxK12)

Desktop synced to origin/main (CLAUDE.md, settings.json union, recovery
note); verified this checkpoint already lives on main, so the branch is
fully redundant and safe to delete per the recovery note. The transcript
retrospective this design called for has now been run — evidence in
`.claude/journal/retrospectives/2026-08-19-transcript-mining.md`.

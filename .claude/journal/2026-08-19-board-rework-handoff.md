# Handoff: board rework

Written 2026-08-18 by a prior Claude session, for the session doing the
board rework. Mark has raised this topic in several sessions today — treat
it as continuing an already-open discussion, not a new idea. Delete this
file when the rework lands.

## Context: the interaction model (already agreed)

- Chats are ephemeral executors, never storage. A healthy session could be
  killed at any moment with nothing lost.
- Durable state lives in files: kanban board files for open work, log files
  for what was done/decided.
- **Wrap-up ritual:** when Mark says "wrap up" (or "log it"), flush loose
  ends to the right board file, append decisions to the log, commit, and
  confirm the chat is safe to kill.
- **Branch heuristic — capture ≠ activation:** does *this session's* goal
  need it to finish? Yes → do it here. No but real → one line on a board at
  wrap-up. No and trivial → drop it. New sessions open only by pulling from
  a board; WIP limit (~2-3) throttles activation.
- **Blocking-question rule:** ask Mark inline only if the answer blocks the
  current task; everything else becomes a proposed backlog line at wrap-up
  for batch accept/edit/delete.

## The rework: what's decided

- Two kanban boards, for two different "teams":
  1. A **claude board** — backlog of Claude-session work (infra, SignalK,
     code, docs). Sessions pull from it and flush to it.
  2. A **human board** — high-level priorities and physical real-world
     tasks for the human team, with Claude occasionally helping manage it.
- `maintenance/priorities.md` is for humans — high-level tasks and
  priorities, treated like the runbook and the log. It is NOT the claude
  board.
- Mark explicitly wants the board files **segregated from the rest of the
  repo** in their own dedicated location — he dislikes the current
  file placement.

## The rework: open decisions (settle with Mark)

- Exact file locations/names for the two boards.
- Board structure (`maintenance/priorities.md`'s kanban shape — In
  Progress / Blocked / Backlog-ordered / Someday — is the precedent).
- Whether existing Claude-ish items in `maintenance/priorities.md` migrate
  to the claude board.
- Add ~6 lines to Mark's standing orders (`~/.claude/CLAUDE.md`) codifying
  the interaction model above; update `dotfiles/CLAUDE.md` where it says
  IoT/electrical tasks are "tracked separately" to point at the claude
  board once it exists.

## Note on memory

The prior session also wrote this content to Claude's auto-memory at
`~/.claude/projects/-home-solace-dotfiles/memory/` (files
`interaction-model.md`, `board-rework-pending.md`). If your session can
see that memory, prefer it and keep it updated; this file exists because
at least one session could not.

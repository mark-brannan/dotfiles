---
name: doc-settledness-check
description: Measure how settled one governing document is — a curia, an ADR, a design doc, or a PR that touches one — against the thirteen-row settledness rubric, and print the table and a one-line verdict. Dry run only; it gates nothing and edits nothing. Use on "/doc-settledness-check <target>", "how settled is X", "is this curia ready to promote". Not for running a sitting (/curia) or ruling (/agora).
---

# Settledness check

The directory name is a description, not a name; Solace names it later.

It **measures and gives a verdict; it gates nothing** (Solace,
2026-09-29). It applies to any governing document, not only a curia. The
rows and their meanings are in `rubric.md` beside this file.

## Never

- open a PR, file an issue, comment, label, or push to a public repo;
- edit the target, its thread, its `minted.md`, or anything it links;
- let the measuring agent spawn agents or take a worktree.

## Steps

1. **Resolve the one target.** Exactly one of:
   - **curia id** — `~/claude_prompts_scratch/state/global/curia/<id>/thread.md`
     exists. Kind `curia`. Read-set: the folder (`thread.md`, `minted.md`,
     `inputs/`, `notes.md`).
   - **path** — a file in any repo on this machine. Kind `adr` if it sits
     under an `adr/` directory or is named `*.adr.md`; otherwise `design`.
     Read-set: the file, its repo's ADR index if any, `git log` for it.
   - **PR** — `owner/repo#n` or a PR URL. Kind `pr`. Read-set:
     `gh pr view`, `gh pr diff`, review comments. The rubric reads the
     governing documents the diff touches.

   Anything else, or a target that does not resolve: say so in one line
   and stop.

2. **Send the measuring to one sub-agent.** `Agent`, `subagent_type:
   Explore` (it has no write or agent tools), `model: sonnet`, no
   isolation, foreground. Hand it facts, not steps:

   > Measure the settledness of <target> (kind <kind>) against the rubric
   > in <absolute path to rubric.md>. Read-set: <paths / gh commands>.
   > Read every file in the read-set whole, not excerpts. Rows 8 and 9
   > are curia-only and read `n/a` for other kinds. Row 12 covers open
   > curiae (`state/global/curia/*/thread.md` with `status: open`), issues
   > and PRs in the target's repo. You are read-only: no edits, no
   > commits, no agents, no comments. Return only the table in the
   > rubric's format, the one-line verdict, and the how-measured lines.
   > Where a row could not be measured, say what was missing.

3. **Print the result** — the table and verdict as returned, then the
   how-measured lines. Nothing else.

4. **Write the report.** Header: target, kind, date, model, "dry run;
   gates nothing". Then the result.
   - kind `curia`: `state/global/curia/<id>/inputs/settledness-<date>.md`
     in the state repo; commit it there by path.
   - otherwise: the session scratchpad, `settledness-<slug>-<date>.md`.

   A caller may name another destination in the state repo; never a
   public repo.

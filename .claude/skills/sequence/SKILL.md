---
name: sequence
description: Walk one decision card to a ruling, a spawned work item, or an unblocked card — a typed contract (exact question in, one of three outcomes out), not a status update. Use on "/sequence", "walk the decision cards", "what needs deciding", or when `worklist`'s `## Needs ruling` isn't empty. High-judgment, few calls — Opus, Fable for the harder calls.
---

# Sequence

A decision session, one card at a time. Where `/reconcile` is mechanical
(many cheap `gh` calls, no judgment), sequence is the opposite: few calls,
real judgment, and it only exists because a "Pending:" tail on a card is a
contract left implicit — no typed question, no typed output, so it rots
instead of resolving. Sequence makes that contract explicit and closes it.

## The contract

Every card this skill touches gets, and keeps:

- **Input** — the exact question, one sentence, answerable yes/no/a-number
  or a named choice among options. Not "figure out X" — that's not a
  decision, it's unscoped work; send it back to be scoped first.
- **Output** — exactly one of:
  - **Ruling** — Solace answers; write it to `docs/decisions.md` in the
    primary repo (see `/sweep`'s "Answered" convention — same target,
    same format) or the state repo's log if it fails the private-terms
    check.
  - **Spawned work item** — the answer was "build X to find out"; open the
    issue or card, link it here, this card closes.
  - **Card (partly) unblocked** — the ruling only removes one dependency;
    say which one, and what still blocks it.

A card that can't be stated this way isn't ready for sequence — reconcile
or `/card-write` first to give it a typed shape.

## Running a session

1. Pull the candidates: `## Needs ruling`, any card `/reconcile` flagged as
   an implicit "Pending:" tail, anything Solace names directly.
2. One card at a time. State the input question as written; if it's not
   already typed, type it now and confirm the rewrite before asking it.
3. Bring a recommendation, not a menu, per standing orders — your pick and
   why, before alternatives, then the closed-question rules apply to
   Solace's answer.
4. Apply the output per the contract above, immediately — don't batch.
5. Next card, or stop when Solace says stop. Unfinished cards keep their
   typed contract, ready for the next session with zero re-derivation.

## Output

Per card: the question, the outcome, the link. At the end, one line: how
many ruled, how many spawned, how many unblocked, how many still open.

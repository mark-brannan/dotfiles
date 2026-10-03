---
name: sweep
description: Garbage-collect the global board's ruling and click-work cards (items owned human-ruling and human-click) — find cards already ruled elsewhere or gone stale, show them with proof, retire or defer only what the user ticks, and rerank the rest by what they block. Use on "/sweep", "sweep the board", "what's stale", "prune the rulings", and before `worklist` or `/card-helper` shows the board. `--dry-run` reports and changes nothing.
---

# Sweeping the board

Garbage collection for the two kinds of card the user reads: rulings (owner
`human-ruling`, once `## Needs ruling`) and click work (owner `human-click`,
once `## Human's`). It runs before the board is shown, and on its own. Cards
owned `agent` are not swept here; that queue is yours to work, not to tidy.

The board is one file per item under `state/global/items/`, written only
through `~/.local/bin/work-item`. Read the cards to sweep with
`work-item list | awk -F'\t' '$2 != "agent"'`: columns are id, owner, status,
holder, updated, repo, then the card line. Read one item whole with
`work-item show <id>`.

`worklist` now carries the ruling counts: total, ready and waiting by `until:`, with `--waiting` and `--all` to drill.

## Modes

- **Interactive** — the default, before `worklist`, before `/card-helper`,
  and standalone: list, confirm, edit.
- **Dry run** — `--dry-run`, and always at wrap-up: the same list, no
  dialog, no edits. Wrap-up is late for extra turns; the list goes in the log
  and the next session acts on it.

## For each card, in order

1. **Ruled elsewhere?** Look where the answer would have landed: the linked
   ADR, `docs/decisions.md`, a `requirements.md` Q-nn, the issue's comments,
   the PR that implements the choice. A hit with a link is proof.
2. **Stale?** The question lost its subject: the branch merged, the repo
   archived, the feature cut, the `until:` event passed with nothing built
   on it. State the reason in one clause.
3. **Rank** the survivors: what the card blocks now, then the consequence of
   leaving it, then its `until:`. A card with no `until:` at all — a
   `## Human's` click-work card; `/card-write` allows
   one without it — ranks above every card that has one: it never expires on
   a date, so treat it as always blocking until the user clears it by hand. A
   card that blocks nothing and has no consequence is not shown; take its
   default, record it where the work lands, and propose the card for
   deletion with that as the proof.

A sweep finds proof that a question was answered or dissolved. It never
answers the question itself.

## Branches

Run `prune-branches` before the dialog; its "would delete" lines are one more
proposed item; its "keep" lines are not shown. On a tick, `prune-branches --delete`; otherwise leave it.

## The dialog

Show the list: proposed deletions, each with its proof, the branch prune's
summary line, then the reranked survivors. Then one multi-select (AskUserQuestion): tick the cards to act on.
Every ticked card gets exactly one explicit action, chosen at tick time —
the user has caught wrong deletions before; nothing leaves the board, or
changes, on a bare tick with no action attached:

- **Deleted** — the card is retired (see After the tick). A proposed deletion (rank step 3) defaults
  to this.
- **Answered** — the question is settled now; goes to `docs/decisions.md`
  (see After the tick).
- **Deferred** — not now. Push `until:` out to a date or event the user names.
  A card with no `until:` gets one for the first time here, rather than an
  existing value being rewritten.
- **Dig** — opens the conversation for that card only, right now, instead of
  picking one of the above; whatever it resolves to is then one of the three
  actions above, applied the same way.

Never a free-text question outside Dig.

A `learn` card under `## Human's` is never proposed. It drops only when
the user says they have it.

## After the tick

- **Deleted:** retire the item (below); the proof goes in its brief first.
- **Answered:** append `- YYYY-MM-DD — <short name>: <the answer> ([link])`
  to `docs/decisions.md` in the project's primary repo — the repo whose name
  the `project-<name>` topic shares, else the repo the card links — newest
  first, then retire the item. When the answer already landed as an ADR or a
  Q-nn, the line points there rather than repeating it. On a public repo the
  line must pass the private-terms check; failing that, it goes to the state
  repo's log with the same date.
- **Deferred:** write or rewrite `until:` per the rule above, in the brief
  (readers take `until:` from the brief's text): print it with `work-item
  show <id>`, change or add the `until:` field, and send the whole brief back
  with `work-item brief <id> -` on stdin. The card is not shown again before
  then.
- **Dig:** hold the conversation for that one card, then apply whichever of
  Deleted / Answered / Deferred it settles on.

**Retire** is how a card leaves the board. First write the proof into the
brief, the way `/reconcile` marks a done card: prefix `Ruled <date> — <link>`
(or the stale reason in one clause), original text kept, sent back with
`work-item brief <id> -`. Then walk the status to its end. Read it with
`work-item fold <id>` (the `status=` line) and start where the table says:

| status now | do |
|---|---|
| `open` | `log <id> status=ready`, then the `ready` row |
| `ready` | `claim <id>`, `log <id> status=done`, `log <id> status=closed` |
| `blocked` | the same three; `claim` takes a blocked item |
| `done` | `log <id> status=closed` |
| `claimed` (stale holder) | `claim <id>`, then `status=done`, `status=closed` |
| `closed` | nothing |

A ready item cannot close directly; the table has no `ready` to `closed`
move, so the sweep claims it for the length of the three calls. A refusal
(exit 1: a live session holds the item) leaves the card where it is: say who
holds it and since when, and move on. Never route around it.

The board is not committed by hand: the item files are plain files in the state
repo and the Stop hook commits and pushes them. Proofs live in the briefs.

## Output

Under 15 lines: what was retired and why, what moved and where, the
reranked list. A dry run prints the same with `would` in front.

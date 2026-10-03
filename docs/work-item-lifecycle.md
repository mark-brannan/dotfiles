# Work items: how a card ends

The technical reading of the one-entry-point curia's lifecycle rulings
(digest, Decided: "Six statuses", "Transitions", "Done-done is acceptance,
never silence"). The curia governs; where this file and the digest
disagree, the digest wins and this file is fixed. `work-item` enforces the
transitions; this file says which ones each skill writes, and what goes on
the line.

## Two words, two writers

| Status | Means | Who writes it | The log line carries |
|---|---|---|---|
| `done` | the holder says the work is finished | the claim's holder | `evidence=<link>`: the PR, commit, roll anchor or decisions line that shows it |
| `closed` | Solace accepted it | whoever records Solace's act, in the turn it happens | `accepted=<link>`: where that act is, quoted or linked |

`done` is reached only from `claimed`, so every ending starts with
`work-item claim`. `closed` is reached only from `done`. No line writes
`closed` on a clock, on silence, or on an agent's own judgment.

## What counts as Solace's acceptance

An act of hers that can be pointed at later:

- her words, verbatim in the roll, a log or a PR thread;
- her tick in `/sweep` or her ruling in `/agora`;
- her merge of the PR named as the `done` evidence. (Pencil, the agent's
  default: she merges by hand, so the merge is her act.)

## Each ending, as the skills write it

| Ending | Sequence | Written by |
|---|---|---|
| Agent work lands | claim → `done evidence=<PR>`; later `closed accepted=<merge>` | the worker; then reconcile, on seeing her merge |
| A ruling, made in agora | claim → `done evidence=<roll or decisions line>` → `closed accepted=<the same>` | agora, in the ruling's turn |
| Click work Solace confirms | claim → `done evidence=<her words>` → `closed accepted=<her words>` | card-helper, in the confirming turn |
| Stale, moot or ruled elsewhere | claim → `done evidence=<why moot>`; `closed` only on her tick | sweep (both lines on a tick); reconcile writes `done` only |
| grind retires a card | claim → `done evidence=<PR>` | grind; never `closed` |

A card left at `done` is waiting for acceptance, which is what the curia
wants: the archive window counts from `closed`, never from `done`.

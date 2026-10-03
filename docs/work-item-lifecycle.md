# Work items: how a card ends

Read from the one-entry-point curia's lifecycle rulings. The curia governs;
a disagreement goes back to it. `work-item` enforces the transitions, nothing
more.

## The rules

| Rule | Standing |
|---|---|
| `claimed` comes from `ready`, `blocked`, `done` or `closed`, never `open`: an `open` item gets a `status=ready` line first | pen: "Transitions"; `work-item` refuses `open -> claimed` |
| `done` comes only from `claimed`, written by the claim's holder | pen: "Transitions"; `work-item` refuses another session while the claim is live |
| `closed` comes only from `done`, by the user's acceptance: never on a clock or on silence | pen: "Transitions", "Done-done is acceptance, never silence" |
| The archive window counts from `closed`, never from `done`; an item left at `done` is waiting for acceptance | pen: "Done-done is acceptance, never silence" |
| A parent goes `done` and holds for `closed`; acceptance at `closed` is over the whole tree, by the agent and the user | pencil, the user's: "Pencil, maybe" |

## Two words, two writers (pencil, the agent's reading)

| Status | Means | Who writes it | The log line carries |
|---|---|---|---|
| `done` | the holder says the work is finished | the claim's holder | `evidence=<link>`: the PR, commit, roll anchor or decisions line that shows it |
| `closed` | the user accepted it | whoever records the user's act | `accepted=<link>`: where that act is, quoted or linked |

`work-item` checks neither `evidence=` nor `accepted=`; the skills write them.

## What counts as the user's acceptance (pencil, the agent's reading)

| Act | Where it is pointed at |
|---|---|
| The user's words | verbatim in the roll, a log or a PR thread |
| The user's tick in `/sweep`, or ruling in `/agora` | the roll, a log or the decisions line |
| The user's merge of the PR named as the `done` evidence | the merge; the agent's default, since only the user merges |

## Each ending, as the skills write it (pencil, the agent's reading)

| Ending | Sequence | Written by |
|---|---|---|
| Agent work lands | claim → `done evidence=<PR>`; later `closed accepted=<merge>` | the worker; then reconcile, on seeing the merge |
| A ruling, made in agora | claim → `done evidence=<roll or decisions line>` → `closed accepted=<the same>` | agora, in the ruling's turn |
| Click work the user confirms | claim → `done evidence=<their words>` → `closed accepted=<their words>` | card-helper, in the confirming turn |
| Stale, moot or ruled elsewhere | claim → `done evidence=<why moot>`; `closed` only on the user's tick | sweep (both lines on a tick); reconcile writes `done` only |
| grind retires a card | claim → `done evidence=<PR>` | grind; never `closed` |

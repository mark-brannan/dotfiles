---
name: card-write
description: Route an open loop to its one home — a GitHub issue, or a card on a kanban.md board in the house format: one line, imperative, link mandatory. Use whenever a loop is found that must be captured ("card that", "add a card", "put it on the board", "file that", a unilateral call, a finding that doesn't belong in this session). Not for walking a card or issue with the user — that is /card-helper.
---

# Writing a card

A card is capture, not activation: the work still waits for a pull. Write
it the moment the loop is found, while the comment link, timestamp and
exact wording still exist.

## Where the loop lives

One home per fact. GitHub owns work state; the board holds only what has
no GitHub home. Take the first line that fits:

- **Work state** — open, merged, closed, CI, threads — lives on the PR or
  issue and nowhere else. Never write it down; `worklist` reads it live.
- **A question only Solace can answer** → an issue labelled `needs-ruling`,
  in the repo where the ruling lands. Body: one line plus a link to where
  the argument lives (a `requirements.md` Q-nn, an ADR draft, or "context:
  private log <slug>"). Solace rules with a comment starting `Ruled`; the PR
  that lands the ruling closes the issue. The ruling itself goes in the
  repo, via that PR — the log records the link only.
- **An action only Solace can do** — install, flash, email, click → an issue
  assigned to him.
- **Public or private repo?** An issue goes on the public repo when its
  text passes the private-terms check — `state/global/private-terms.txt`
  in the state repo, read by path and never copied. When it would fail,
  the issue goes on `mark-brannan/claude_prompts_scratch` instead. The
  public-issue guard refuses the public one anyway.
- **Agent-startable work** → an issue labelled `ready`. Unlabelled is
  untriaged, and only ever a count.
- **Blocked** → label `blocked`, plus a body line `Blocked by owner/repo#N`.
- **Deferred to after 1.0** → the `1.0` milestone.
- **A launchable session** — prompt written, model and effort sized → the
  epic file's session list; a `ready` issue when no epic owns it.
- **Half-done agent work** → the log and the hand-off prompt, as bare
  links with no state adjectives. A pushed branch has a PR or is a
  finding.
- **An agent rabbit-trail** not worth a public issue, or too private for
  one → a card. That is the only thing a card is for.

## The board

Every project keeps one board: `kanban.md` at the repo root, or the path
its own CLAUDE.md names. A loop that belongs to no project, or a repo with
no board, goes to `~/claude_prompts_scratch/state/global/kanban.md`; don't
create a board unilaterally. A public repo's board never carries boats,
hosts or services — those cards go global, with a link back. Dotfiles has
no board: its cards go global.

A board has one section, `## Claude's`. `## Solace's` (older boards:
`## Yours`) is retired — Solace's loops are issues, and their GitHub
"Assigned" tab is where he sees them.

## The line

```markdown
- [ ] **Short name** — action in the imperative ([link](https://...)) blocked: <dependency>
```

- One line per card: a link, and the action in the imperative.
- **The link is never optional** — a card nobody but its author can
  resolve is not a card.
- The short name or the link must be distinctive enough for a future
  session to find the card.
- Add `blocked:` and the dependency only when the card is actually blocked.
- Sections and checkboxes, not a table.
- **Order is priority.** The top card in a section is the next one to pull.
  Place a new card where it belongs, not at the bottom by default.

## The lint

`kanban-lint.sh` checks every edit to a `kanban.md`, and checks the state
repo's uncommitted board diff again at Stop. It rejects:

1. a ticked box — `- [x]`;
2. a bullet above the first `## ` heading;
3. a heading other than `## Claude's`;
4. a card whose verb is review, merge, land, bump, close, approve, ship,
   ratify, rule on, decide, confirm, answer or watch, pointing at a
   `/pull/N` or `/issues/N` — that loop's home is the PR or issue;
5. a state word: merged, awaiting, not merged, CI green, open as;
6. a card with no link.

## Lifecycle

- **Cards die when done.** Delete the line, never tick it — this is a
  work-in-progress list, not a log; `git log` and the session logs keep
  the history.
- Keep the board short: 15 cards or fewer. Past about 20, some repo needs
  issues. A list nobody can hold in their head is a second place to lose
  things; finish or delete before adding.
- If a loop is not worth a card, it is not worth telling Solace about either.
- A sweep — "reconcile", "what's outstanding", "what's stale" — is
  `worklist` and a report. It never edits a board, epic or log.
- Commit the board in its own repo, and never stage one project's work
  under another's. The Stop hook commits the global state repo; a project
  board is committed with that project's work.

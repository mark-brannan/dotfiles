# Agent rules survey — 2026-08-19

Commissioned survey: what should move into `~/.claude/CLAUDE.md`,
`~/.claude/rules/code.md`, or user-level settings, based on the rules that
have accumulated in the project repos and on observable snafus in recent
sessions.

Sources read: dotfiles `.claude/*`; symphony `CLAUDE.md` + `.claude/settings.json`
+ hooks; signalk-noaa-space-weather and signalk-lint (`CLAUDE.md` + `AGENTS.md`
each); SignalK/signalk-server `AGENTS.md`; agentsmd/agents.md spec; recent
session titles/summaries; the 2026-08-19 session note and standing-orders
checkpoint. Cost: ~100k context for the whole survey, one session, no subagents.

Evidence convention below matches the Maintenance rule: a candidate needs two
scars. Each entry names its scars. One-scar items are listed separately as
"watch, don't write yet."

---

## Part 1 — Patterns already proven in project repos, worth hoisting

### 1.1 Commit with explicit pathspec → `rules/code.md` (Git)

Proposed text:

> Commit with an explicit pathspec: `git commit -m "..." -- path1 path2`.
> Plain `git commit` commits the whole index; with parallel sessions the index
> is shared mutable state, so `add` + `commit` is a race. `git status` first is
> an observation, not a constraint.

Scars: symphony b11b40d (unrelated SSO-SETUP.md edits rode along under the
wrong message); rule independently re-derived and written into signalk-lint
AGENTS.md. Parallel sessions are now the norm, so this belongs at user level.

### 1.2 Enumerate the destructive-git list → `rules/code.md` (Git)

code.md's current "no destructive operations without approval" is vague; the
battle-tested version in symphony enumerates. Proposed replacement:

> Never run without explicit go-ahead in the moment: `git reset --hard`,
> `git clean` (any flags), `git checkout`/`git restore` with no pathspec or a
> directory pathspec, repo-wide `git stash`, `git branch -D`, `git push
> --force*`. Each can discard work outside the target — including another
> session's. `git checkout HEAD -- file` is fine once you've read that file's
> diff.

Scars: three-plus git-hygiene/recovery sessions on 2026-08-19 alone; the
symphony pre-commit rollback incident (hook auto-fix reverting unstaged work).

### 1.3 Start-of-session freshness check → `rules/code.md` (Git)

> In any repo more than one session touches: `git fetch` before work and get
> onto the tip of the default branch first. A checkout that looked current
> yesterday usually isn't; landing work on a stale base costs a hand-resolved
> rebase in files another session has since rewritten.

Scars: symphony rule text says "multiple sessions" plural-scarred it; today's
branch litter (a dozen `claude/*` remote branches) is the same cause.

### 1.4 Branch-vs-main is a rule, not a question → `rules/code.md` (Git)

Generalize symphony's version so no session ends blocked on "want a PR?":

> In my solo repos, commit small verified commits straight to the default
> branch. Branch (and open the PR yourself, immediately — never leave a pushed
> branch without one, never ask whether to open it) only when: intermediate
> commits can't each leave the repo working; the change has blast radius if
> half-applied (infra, CI, publishing config, secrets); or I asked for review.

Scars: "Runbook procedure completion rule" session ended `needs_action: let me
know if you'd like a PR opened`; the gate-taxonomy checkpoint names
"permission theatre" as a countable recurring cost; symphony wrote the rule
after the same pattern.

### 1.5 Scope and boundary-validation kernel → `rules/code.md` (Design)

Present in signalk-server upstream and adopted deliberately in both plugin
repos — this is a preference, proven by repetition:

> Only make changes that were asked for or are clearly necessary. A bug fix
> does not clean up the surrounding code; a new feature does not need extra
> configurability. Validate at the boundaries — user input, files off disk,
> external APIs — and trust internal code in between; no error handling for
> cases that cannot happen.

Scars: adopted verbatim in two repos; complements (doesn't duplicate) the
existing "Don't expand scope" standing order, which covers pre-existing
failures rather than gold-plating.

### 1.6 Commit/PR conventions for my repos → `rules/code.md` (Git)

> Default in my repos: conventional commits (`<type>(<scope>): <subject>`,
> imperative, ≤50 chars). One logical change per commit and per PR — two
> changelog entries means two PRs. Amend a correction into the commit it
> belongs to; no "fix typo" stacking. An out-of-scope request mid-PR gets
> named and proposed as a separate PR, not quietly folded in. In repos I
> don't own, the repo's convention wins.

Scars: written independently into three repos (upstream, noaa, lint).

### 1.7 Comments and doc-state rules → `rules/code.md` + `rules/writing.md`

Two lines, both in all three project AGENTS.md files:

> Comments explain why, never what. No echo comments. (code.md)

> Docs describe current state — no version archaeology ("0.12 did X, then Y")
> outside CHANGELOG.md. A version number appears only where load-bearing. (writing.md)

Scars: noaa AGENTS.md records "that habit produced two wrong claims in one
day"; lint's test-count note went stale twice in one day.

### 1.8 Distinguishable failures get codes, not prose → `rules/code.md` (Tests)

> When a caller must tell two failure modes apart, the distinction lives in a
> code/field, never in message text. Tests assert the code; error prose is
> free to change. (Corollary of "test behavior, not presentation.")

Scars: lint's exit 1-vs-2 contract and `ConfigDirError.code` both exist
because message-matching broke or would have.

### 1.9 Session cost + wakeup discipline → user-level, two halves

The enforcement half (see also 2.1): copy symphony's
`no-persistent-polling.sh` + PreToolUse matcher into dotfiles
`.claude/hooks/` + `.claude/settings.json` so it applies in every repo, not
just symphony. Also `crossSessionInbound: "hold"`.

The prose half, into CLAUDE.md (Execution or a new short section):

> Wake on events, not timers — subscribe, don't poll; "I'll check back in a
> few minutes" is a polling loop in disguise. Never bind a scheduled wakeup to
> a live session. One watcher per task or PR: before subscribing, scheduling,
> or starting overlapping work, check whether another session already owns it.
> Long agentic loops are the real expense, not long conversations — scope
> tool-dense tasks tightly, one considered pass over iterative poking.

Scars: 2026-08-18 incident (five self-re-arming wakeups × 2.6M-token session,
two five-hour windows burned); 2026-08-19 session killed by limit; duplicate
sessions same morning (three runbook-rule, two git-hygiene, two PR-#8
watchers, four queued triggers).

---

## Part 2 — Gaps: not a pattern anywhere yet, inferred from snafus

### 2.1 dotfiles carries no `.claude/settings.json` at all

Since dotfiles is $HOME, this file *is* user-level config, and it's currently
unmanaged. Everything that "must happen" still lives in prose, which the
CLAUDE.md itself says is the wrong layer. Seed it with: the polling hook
(1.9), `crossSessionInbound: "hold"`, and a starter permissions block.

### 2.2 Branch-deletion permission now meets the two-scar bar

The 2026-08-19 session note logged cost #1 ("classifier blocked me; your own
rule says two"). The same morning's "Branch cleanup and deletion permissions"
session is cost #2. Recommend:
`{"permissions": {"allow": ["Bash(git push origin --delete *)"]}}` in the new
settings.json — remote-branch cleanup is a standing chore of the
many-parallel-sessions workflow and it keeps blocking.

### 2.3 Journal location is already inconsistent

`.claude/session-notes/` (main) vs `.claude/journal/checkpoints/` (branch),
created within hours of each other. Pick one — suggest `.claude/journal/` —
and say so in the Continuity section, one line. (This survey file assumes
that choice.)

### 2.4 The gates/checkpoint/decision-log design is decided but unlanded

The 2026-08-19 checkpoint records the full design (gate taxonomy, report
line, initiation ritual, decisions.jsonl hook) as settled-in-conversation,
next step "draft the diff." Nothing has landed. This is the
highest-leverage single item in this survey: it's the enforcement layer for
Decision load, and today's session list shows the exact gate types it names
still occurring. Land it before adding anything else from Part 1 if forced
to choose.

### 2.5 Connector schemas cost tens of k per session

Symphony denies nine irrelevant MCP servers; no other repo does, and
today's dotfiles session still carried QuickBooks/TurboTax/Gmail/Drive
schemas. Add the same `deniedMcpServers` block to the user-level
settings.json (2.1) with per-project re-enables where actually used
(Evernote in symphony).

---

## Part 3 — For new projects: the two-file split, as a template

The strongest cross-repo pattern isn't any single rule — it's the structure
noaa and lint share. Worth writing down once (a `~/.claude/rules/new-project.md`
or a template file) so new repos start this shape:

- **CLAUDE.md** — what the codebase *is*: architecture with a one-line "to
  add an X, touch exactly these files" recipe; non-obvious constraints, each
  carrying its incident ("this happened: #45"); local dev; releasing.
- **AGENTS.md** — how to behave: scope, comments, type safety, tests, the
  bar a new rule/setting/feature must clear, commits, PRs. Tool-agnostic.
- Each cross-references the other in its opening lines.
- Where the repo must differ from an upstream convention, the difference is
  called out explicitly (noaa's "Versions: this repo is the exception").
- Rules carry their scars — dates, issue numbers, commit hashes. A rule
  with a receipt survives review; one without gets pruned.
- Decisions that are settled get a file (`security_posture.md` pattern) and
  a standing instruction: read it before reporting its contents as findings;
  one-line objection max.

## Part 4 — Recommend against (for now)

- **A general AGENTS.md in dotfiles.** Nothing user-level reads `~/AGENTS.md`
  today; Claude Code reads `~/.claude/CLAUDE.md`. A second file is a sync
  burden with no reader. Revisit the day a second agent tool enters use —
  then move the tool-agnostic parts (voice, closed questions, execution),
  not a copy.
- **Importing upstream's principle lists** (SOLID/DRY/KISS as a litany).
  The standing orders already carry the operative kernel; buzzword lists are
  the "every line is a tax" case.
- **Domain rules** (NOAA fixtures, notification loudness, snapshot
  redaction). Correctly located where they are.
- **One-scar items**: dry-run distrust generalization beyond make, the
  "procedure isn't done until run verbatim" rule outside symphony, lock-file
  coordination for shared dev servers. Watch; write on the second scar.

## Suggested order

1. Land 2.4 (gates/decision log) — it makes everything else measurable.
2. Create settings.json + hooks (2.1, 1.9 enforcement half, 2.2, 2.5).
3. Add the Part 1 rule texts to code.md/writing.md in one commit — they're
   all proven, all short (~35 lines total against ~1,100 surveyed).
4. Write the new-project template (Part 3).
5. Pick a journal home (2.3), one line in Continuity.

---

## Addendum (same day) — deeper session-metadata mining

Two more pages of session metadata (58 sessions, 2026-08-15 → 08-19). All
numbers below are the API's own usage counters — measured, not guessed.
Cloud-session *transcripts* are unreachable by tooling (containers get
reclaimed); metadata is now fully mined and further paging is diminishing
returns.

**Volume and limits.** Thirty sessions in the seven hours before this one.
Three rate-limit hits in five days: the weekly limit on 08-15 (locked out
until 08-18 14:00 UTC — a two-day outage), the five-hour limit twice on
08-19. The weekly lockout predates the 08-18 polling incident, so the cost
problem is structural, not one bad day.

**Where tokens go** (cache_read ≈ context re-sent across a session's tool
calls — the "long agentic loops" multiplier): PR #8 babysitting 22.7M;
Tailscale SSH troubleshooting 13.8M; docs corrections 12.4M; git-hooks
hostname work 9.4M; PR #7 review 9.0M. One session ("Node-RED use cases",
effort xhigh) consumed 2.24M tokens of *raw input* plus 178k output —
bulk-pasted or fetched content, the single most expensive turn class
observed. PR babysitting and interactive infra troubleshooting dominate;
doc-writing sessions are cheap.

**Gate census** (needs_action strings across both pages): at least five
instances of one shape — work complete, session stalls asking whether to
open the PR / merge / re-run ("let me know if you'd like a PR opened",
"say the word", "awaiting merge decision", "confirm re-run or leave").
Legitimate direction gates: about two. This is the most repeated stall in
the data and is exactly what rule 1.4 kills.

**Duplicate and wasted sessions:** RUNBOOK formatting ×2 (haiku attempt
abandoned, retried on sonnet 14 minutes later); "Symphony PR review" ×2
started 68 seconds apart; runbook-rule ×3 and git-hygiene ×3, partly caused
by repeated init-script failures in env_...44Nw (fix or retire that
environment's setup script); PR #8 double-watch plus four queued triggers
(known); one remote session spun up for a task that needed local files and
could only answer "run this locally."

**Rule-candidate reinforcement:** 1.4 now has ≥5 scars; "one session per
task" ≥4. New candidate at exactly two scars: **task-surface check** —
before starting, confirm the task's files/hosts are reachable from this
surface (remote container vs local machine); the electrical-recovery
session and an SSH-to-thepi session both burned a container spin-up
learning they were on the wrong surface.

### Follow-up deep dive: verdict and scope

Warranted — but not here and not via this API. The unmined data is **local
transcripts** (`~/.claude/projects/` on nucboxk12 and the MacBook), which
hold the actual corrections, denials, and question-shapes for CLI/bridge
sessions. Cloud transcripts are viewable in the app but not by tooling;
accept that gap and let the decision-log hook (2.4) capture the future.
Run it on nucboxk12 first — it originated the most bridge sessions.

Prompt for that session:

```text
Deep dive on local Claude Code transcripts for behavior-correction
evidence. Continuation of the 2026-08-19 agent-rules survey: first read
.claude/journal/2026-08-19-agent-rules-survey.md (including its addendum)
in the dotfiles repo, and the gate taxonomy in
.claude/journal/checkpoints/2026-08-19-standing-orders-cost.md on branch
claude/standing-orders-additions-t3k64q. Do not re-mine remote session
metadata; that is done.

Data: local transcripts under ~/.claude/projects/ on THIS machine only.
First report: how many session files, what date range, total size. If over
~50 sessions, sample the 15 largest plus the 15 most question-dense and
say what was skipped. Use grep/jq to locate candidate turns before reading
anything whole; use subagents for bulk reads to keep the main context
lean. Report token cost per stage.

Extract, with counts and verbatim quotes:
1. Gate census — every turn that ended by asking me something. Classify:
   permission theatre / spend gate / reversibility gate / direction gate.
2. Correction census — my messages that correct, reverse, or re-instruct
   ("no", "don't", "I said", "again", "stop", "why did you"). Group into
   candidate rules; anything occurring twice or more gets proposed rule
   text and a destination (CLAUDE.md / rules/code.md / rules/writing.md /
   settings.json).
3. Denials — tool calls denied by me or by hooks, and what Claude did
   next (rerouted, asked, gave up).
4. Cross-session waste — the same intent appearing in multiple sessions.

Output: a dated file in .claude/journal/ shaped like the survey
(candidate → draft text → evidence), committed to a claude/ branch of
dotfiles and pushed. Proposals only — do not edit CLAUDE.md, the rules
files, or settings.json. End by saying whether the MacBook's transcripts
are worth the same pass.
```

### State at wrap-up (this branch)

- **Landed here:** the survey; `.claude/settings.json` (polling-guard hook
  wired, branch-deletion allow, finance/legal connector denials,
  `crossSessionInbound: hold`, desktop UI prefs carried); the hook script.
  Symphony's project-level copy of the hook is now redundant but harmless.
- **Decided, not landed:** gates/decision-log design (2.4 — still first in
  the suggested order); Part 1 rule texts; new-project template; journal
  home.
- **For Mark on the desktop:** merge the tracked settings.json with the
  app-created one — keep `signalk-registry` (and its marketplace entry),
  drop `discord` unless actually used with Claude; then commit the union
  so yadm stops seeing a diff. Fix or retire env_...44Nw's setup script.

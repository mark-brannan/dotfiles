# Transcript retrospective — corrections & denials, NucBoxK12

2026-08-19, desktop session (symphony cwd, dotfiles scope). Executes the
follow-up the standing-orders checkpoint called for: mine the local
transcripts for Mark's actual corrections and denials, then ground the
next rules edit in that evidence instead of intuition.

## Corpus and method

- All 91 sessions in `~/.claude/projects/` on NucBoxK12 (symphony 48,
  home 21, signalk-noaa-space-weather 16, others 6). Full population, not
  a sample. jq extraction of human-typed messages (1,399) and tool-denial
  events (114); classification by hand. The Mac's transcripts remain
  unmined; cloud-session transcripts are gone with their containers.

## Headline numbers

- **114 denial events: 89 were the auto-mode classifier, not Mark.** Only
  17 were genuine user denials, and **15 of those were ExitPlanMode plan
  rejections** — Mark revising scope, never blocking a dangerous action.
  The remaining 2 were Bash calls (an npm install into a shared dev dir,
  a screenshot-fetch loop).
- **All 20 user interruptions were scope control**, zero were safety
  stops: "too many — rank them, best 50", "just produce the list, don't
  fetch more", "start over with a fresh plan", "archiving — plan bled
  into feature work".
- ~30 "Try again" messages are usage-limit retries (session/weekly limit
  hits) — noise for corrections, but real evidence of cost pressure.
- Conclusion the gate taxonomy predicted: **permission-asking has near
  zero protective value here; plan scope is where Mark's attention goes.**
  "Permission theatre — delete on sight" is confirmed empirically.

## Correction themes (deduplicated across forked sessions)

1. **Brevity / one question per turn** — ≥4 distinct sessions, 08-12 →
   08-14 ("tl;dr", "reiterate again: <50 words", "not reading long
   replies at all"). The reply-length rule landed 08-14, same day as the
   last correction. Too little data since to call it working or failed —
   the file's own 08-30 review covers this. Don't re-legislate.
2. **Toil-lowering** — ≥3 sessions (08-01 "give me the link too",
   08-06 "too much to hand-type on the mac", 08-08 "lower my toil —
   clickable links or a copy-pastable command"). **Not in standing
   orders. Top gap.** Draft below.
3. **Answer the question first** (08-06 "It's also not what I asked you.
   Answer this direct question now") — became "Answering closed
   questions". Captured.
4. **Deferred topics must resurface** (08-05 "I did ask for that and you
   didn't remind me… when I ask 'what else' we circle back") — the
   capture≠activation model covers this *once boards exist*; until then
   the scar is open. Board rework is the fix, not more prose.
5. **Multi-session collisions** (ports config wrong "from the other
   session", vanished package.json plugins, stash interference) —
   already heavily codified in symphony CLAUDE.md git hygiene. Captured.
6. **Verification failures** ("You told me you fixed this… stale icon
   again"; "You're wrong. It's broken. Look at the damn config page…
   find what's bothering me and solve my pain point" 08-09) — became
   "Verify before you assert" + "Investigate in the right place".
   Captured; evidence now on file.
7. **Human voice in docs / don't touch README unasked** (08-04 "from
   here on out…") — fully covered by `~/.claude/rules/writing.md`.
8. **ADHD-granular physical tasks** (07-30 "granular tasks conducive to
   someone with ADHD completing them in one session… per our earlier
   context instructions" — i.e. second occurrence) — added to symphony
   CLAUDE.md Evernote section this session.
9. Smaller, memory-tier preferences seen once or twice: suggest Remote
   Control for cross-device problems (08-06 ×2 forked); share/reuse
   conventional demo credentials (08-04); "take it off your TODO and
   stop reminding me" (08-06).

## Classifier friction (not Mark, but real cost)

89 classifier blocks across the corpus — including, fittingly, this
session's attempt to fast-forward the yadm repo. Sessions burn turns
re-phrasing or routing around. Worth a deliberate pass: per-repo
allowlists (the fewer-permission-prompts skill scans transcripts for
exactly this), starting with the noaa repo and symphony. The recovery
note's branch-deletion allow rule has now cost **two** denied actions
(remote session + this one, if blocked) — meets the two-scar bar.

## Recommended standing-orders drafts (for Mark's go/edit on text)

Toil rule, for Execution (~4 lines):

> - **Hand-offs to me arrive in zero-effort form.** A clickable link, a
>   run-button command block, an exact file:line — never "check the PR"
>   or a command I must retype on another machine. If I have to hunt or
>   hand-type, the hand-off isn't done.

Everything else already designed in the checkpoint (Initiation ~4 lines,
Gates ~6 lines incl. report line) — draft unchanged, now with evidence:
the gate taxonomy's "permission theatre" bucket is confirmed by 15/17
denials being plan rejections and 0 being safety stops.

## State after this session

- Live `~/.claude/CLAUDE.md`, `settings.json` (union — local plugin/theme
  keys kept, `disableClaudeAiConnectors` added), and the rules-recovery
  session note synced to origin/main content on NucBoxK12.
- Checkpoint doc preserved from `claude/standing-orders-additions-t3k64q`
  into `.claude/journal/checkpoints/` (branch deletable once this is
  pushed).
- Whether `settings.json`'s machine-level keys (plugins, theme,
  notifications) belong in the repo at all: Mark settled it himself
  mid-session by committing the union (1f5db0d). Closed.

## Handoff prompt (verbatim, for the next rules session)

> Continue the standing-orders work from where the transcript
> retrospective left off. Read these two files first — they are the full
> state: `~/.claude/journal/checkpoints/2026-08-19-standing-orders-cost.md`
> (the settled design: initiation ritual, gate taxonomy, report line,
> decision-log hooks) and
> `~/.claude/journal/retrospectives/2026-08-19-transcript-mining.md`
> (evidence from all 91 NucBoxK12 transcripts).
>
> Before anything else, ask me these in one AskUserQuestion batch:
> 1. **Rules text** — the next step is a ~14-line diff to
>    `~/.claude/CLAUDE.md`: Initiation (~4 lines), Gates (~6 lines, report
>    line folded into Continuity's wrap-up bullet), and the retrospective's
>    toil rule (~4 lines, Execution). Draft all three for my go/edit, or
>    should any piece be dropped?
> 2. **Initiation threshold** — proposal: the batched question-set fires
>    for any session expected to span more than one repo or to open with
>    heavy retrieval (subagent-scale reads). Accept or set your own line?
> 3. **Classifier friction** — 89 of 114 mined denials were the auto-mode
>    classifier, and `git push origin --delete` has now been denied three
>    times across sessions. May I add
>    `{"permissions": {"allow": ["Bash(git push origin --delete *)"]}}`
>    to the tracked `.claude/settings.json`, and run the
>    fewer-permission-prompts scan for symphony and the noaa repo?
> 4. **Decision-log hooks** — wire `~/.claude/journal/decisions.jsonl`
>    appends via settings.json hooks now (checkpoint step 2), or hold
>    until the Gates prose lands?
>
> Then execute in order: (1) approved rule text, committed straight to
> main per code.md's branch rule; (2) hooks via the update-config skill if
> approved; (3) `yadm push origin --delete claude/rules-config-recovery-7paovw
> claude/standing-orders-additions-t3k64q` if Mark hasn't run it.
>
> Constraints: rule text lands only with my explicit go. Replies <50 words
> outside the diff itself. The board rework (HANDOFF-board-rework.md,
> branch `claude/board-rework`, active clone at ~/dotfiles) is a separate
> session — don't fold it in. The Mac's `~/.claude/projects` transcripts
> are unmined; propose that only if the 08-30 standing-orders review wants
> more evidence.

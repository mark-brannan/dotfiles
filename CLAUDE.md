# Working conventions — dotfiles

This repo is **public**, and its worktree is `$HOME` on every machine Mark
uses. Both facts constrain almost everything below.

Global standing orders live in `.claude/CLAUDE.md` and load in every session
everywhere; personal code and writing rules in `.claude/rules/`. Those files
happen to be tracked here, but they are not *about* this repo. This file is.

## Files

- `README.md` — the critical path for a human setting up a machine, plus the
  conventions and the design rationale.
- `RUNBOOK.md` — procedures. Machines, cloud environments, secrets,
  troubleshooting. Deliberately partial; it says so at the top.
- `.config/yadm/bootstrap` — decrypts sops-managed secrets. Idempotent.
- `.config/yadm/hooks/pre_commit` — the commit-time gate against credentials.
- `.local/bin/dotfiles-triage.sh` — read-only inventory of `$HOME` vs policy.
- `.local/bin/dotfiles-add-secret.sh` — the one command for adding a sops secret.
- `.local/bin/cloud-session-setup.sh` — seeds a subset of this repo into `$HOME`
  on an ephemeral cloud VM.
- `.claude/cloud-setup.sh` — writes `deniedMcpServers` at user scope.
- `.claude/hooks/` — session-continuity and metrics hooks.

## README.md

- **The first screen is for a human who wants a working `$HOME` and nothing
  else.** Clone, bootstrap, sync — three commands, at the top, before any
  explanation. Everything that is not on the critical path goes below it or
  out of the file. Nobody arrives here wanting the history.
- **This is where the *why* lives.** Design rationale, the scars, why the
  cloud seed is deliberately not yadm, what a guard is protecting against.
  A passage that explains rather than instructs belongs here, not in the
  runbook.
- If the README starts to bloat, the fix is to move background *out* — to a
  `reference/` file if one becomes warranted — never to compress the
  getting-started path to make room.
- Don't restructure it as a side effect of unrelated work. `.claude/rules/writing.md`
  governs; it is a human-voiced doc.

## RUNBOOK.md

- **Actions only.** Every section answers "what do I do." Commands, the order
  to run them in, and how to tell it worked. If a passage doesn't change what
  the reader does next, it belongs in `README.md` instead.
- **Every procedure ends in a verification step.** Not "it should work" — the
  actual command whose output distinguishes success from silent failure. Most
  of the failure modes in this repo are silent by construction: a hook that
  isn't seeded, a key that doesn't match, a filter that isn't wired. A
  procedure that can't tell you which one happened isn't finished.
- Include a *why* only where its absence causes the wrong action — "don't skip
  this, here's what silently breaks." One or two sentences, next to the step.
  Not a background section.
- **No point-in-time status.** Don't record which PR is open, what a session
  found last week, or which hooks were seeded on some container. That rots
  into a lie within days. Durable traps are fine; snapshots aren't.
- A procedure isn't done until it has been run once, including the transition
  path for machines that already exist. No machine here is a fresh clone.
- Keep the "Where things are" index in sync with the headings. An index that
  has drifted is worse than none — it sends the reader to a section that
  isn't there and they conclude the procedure doesn't exist.

## This repo is public

- **Never commit session state here.** Boards, checkpoints, logs and handoffs
  name boats, hosts and services. They go to the private
  `claude_prompts_scratch` repo under `state/global/`. `.gitignore` blocks the
  known paths; that is a backstop, not permission to try.
- **Dotfiles has no board of its own.** Its cards sit on the global board, and
  anything carrying a question becomes a dotfiles issue that the card links to.
- Real hostnames, boat names, service URLs and account identifiers stay out of
  tracked files, including in comments and example output. Use placeholders.

## The worktree is `$HOME`

- **Stage by path, always.** `git add -A` here means "add my entire home
  directory." The `pre_commit` hook is the last line of defense, not the first.
- Changes land in `$HOME` on every machine at the next `dotsync`. A broken
  `.zshrc` doesn't fail a test suite; it breaks the next shell Mark opens on a
  box he isn't sitting at.
- Guard machine-specific values rather than branching the file: `$HOME`,
  `command -v`, `[ -d ... ]`, `[[ "$OSTYPE" == darwin* ]]`. Reach for a yadm
  alternate only when a whole file genuinely differs per OS, and then use
  `##default`, never `##os.Linux` — yadm reports `WSL` under WSL2.
- Branch work: `yadm worktree add -b <branch> ~/.claude/worktrees/<name> main`. Never `yadm checkout <branch>` in `$HOME` (enforced by `no-checkout-home.sh`). Also never `git checkout <branch>` in `~/dotfiles` — not enforced by any hook, just don't.

## Shell scripts here

- **POSIX `sh` unless there is a reason.** `bootstrap`, `pre_commit`,
  `dotfiles-triage.sh`, `dotfiles-add-secret.sh` and `cloud-session-setup.sh` all
  run in places where
  bash may not be what `sh` points at.
- **Fail closed on a gate, exit 0 on a convenience.** `pre_commit` aborts when
  it can't inspect the commit; `cloud-session-setup.sh` always exits 0, because
  a missing dotfile must never stop a session from starting. Know which kind
  you are writing before choosing.
- **A guard that can be silently bypassed is not a guard.** `SKIP_GLOBS`,
  `PRUNE_NEVER` and the yadm-managed-`$HOME` check all refuse loudly rather
  than warn. Keep that.
- Test with `--dry-run` where the script has one. `cloud-session-setup.sh
  --dry-run` is safe on any machine, including Mark's own.

## Claude Code config in this repo

- `.claude/settings.json` is the source of truth for hooks. **Every hook it
  references must also be in the `INSTALL` list of
  `.local/bin/cloud-session-setup.sh`** — otherwise it silently no-ops in every
  cloud session, and a no-op is indistinguishable from a hook that ran.
- Adding a connector to the account does not deny it. `deniedMcpServers` is
  by name, in two places: `.claude/cloud-setup.sh` and `.claude/settings.json`.
  Update both.
- Verify a Claude Code setting exists and does what you think before writing it
  down. `disableClaudeAiConnectors` was set here for a long time and did not do
  the job it was there for.

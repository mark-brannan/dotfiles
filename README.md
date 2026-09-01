My dotfiles, managed with [yadm](https://yadm.io).

## Set up a machine

```
yadm clone git@github.com:mark-brannan/dotfiles.git
yadm bootstrap    # installs nothing; decrypts sops-managed secrets
dotsync           # the sync routine, from here on
```

That's it. `.config/yadm/bootstrap` also runs automatically right after
`yadm clone`.

Two things it needs that git can't give you:

* **`yadm`, `sops` and `age` on `PATH`.** `apt-get install yadm age` /
  `brew install yadm age sops`; sops on Linux is a
  [release binary](https://github.com/getsops/sops/releases).
* **The machine's age key at `~/.config/sops/age/keys.txt`**, restored
  out-of-band from a password manager. It is never tracked here. Without it
  everything still installs — only the secrets stay ciphertext.

`dotsync` (alias, defined in `.bashrc` and `.zsh_aliases`) is the whole
day-to-day routine:

```
yadm pull --rebase --autostash && yadm alt && yadm status --short
```

**Anything beyond this is in [RUNBOOK.md](RUNBOOK.md)** — Claude Code cloud
environment setup, secrets, and troubleshooting.

## Conventions that keep it quiet

* **Machine-specific values are guarded or substituted, never hardcoded.** Use
  `$HOME`, `command -v foo`, `[ -d ... ]`, or `[[ "$OSTYPE" == darwin* ]]`. A file
  imported wholesale from another machine will spew errors on every other one.
* **Per-OS variants use yadm alternates**, e.g. `.gitconfig##os.Darwin` plus
  `.gitconfig##default`. Use `##default`, not `##os.Linux`: yadm reports the OS as
  `WSL` under WSL2, so an `os.Linux` alternate silently misses there. Never track
  the generated target (`.gitconfig`) as a real file too — yadm relinks it after
  every command and `yadm status` then shows a permanent `typechange`.
* **Credentials are never tracked.** `.gitignore` holds the never-sync list and
  `.config/yadm/hooks/pre_commit` enforces it at commit time, blocking both
  never-sync paths and secret-shaped values in added lines. Override a false
  positive with `YADM_ALLOW_SECRET=1 yadm commit`. Run `.local/bin/dotfiles-triage.sh`
  for a full inventory of `$HOME` against the same policy.
* **Secrets are sops+age, and plaintext never lands in the worktree.**
  Ciphertext sits tracked at `secrets/<name>.sops.env`; bootstrap decrypts each
  into `~/.config/secrets/<name>.env`, which is gitignored *and* outside the git
  worktree, so a later `yadm add` cannot sweep it up. Shells source
  `~/.config/secrets/*.env` at startup.
* **Tool config that a tool rewrites lives outside git.** `~/.npmrc` is the case
  in point: npm overwrites it with an auth token on every login, so the settings
  live in `.profile`/`.zshenv` as `NPM_CONFIG_*` and the file itself is ignored.
  (A host that hasn't pulled since that change needs
  [a migration step](RUNBOOK.md#a-pull-refuses-local-changes-would-be-overwritten).)

## Session continuity hooks

`.claude/hooks/` carries the machinery that makes one session pick up where
the last left off without being asked. State lives in the private
`claude_prompts_scratch` repo; `lib-state.sh` locates it and every hook
degrades to `~/.claude/state/global` if it isn't checked out.

| hook | event | what it does |
| --- | --- | --- |
| `session-start-seed-refresh.sh` | SessionStart | re-runs the cloud seed so a reused container tracks this repo, not the commit it was provisioned from |
| `session-start-continuity.sh` | SessionStart | injects the open board, where the last three sessions left off, and the week's decision load |
| `stop-continuity.sh` | Stop | writes the session record, the decision log and an auto-checkpoint, salvages the work repo's uncommitted files per policy, then commits and pushes the state repo |
| `lib-stop-commit.sh` | (sourced by Stop) | routes a work repo's uncommitted files by the policy table in the state repo: state paths to `main`, the rest to the worktree's branch, or nothing at all |
| `measure-git-events.sh` | PostToolUse | logs branches created, PRs opened, cherry-picks |
| `no-persistent-polling.sh` | PreToolUse | denies wakeups bound to a live session, which re-send its whole context on every fire |

Two design rules, both scars:

* **Nothing depends on the assistant emitting a marker.** The predecessor,
  `log-decisions.sh`, parsed a `⛁ … gate:` line it was supposed to write
  and cited a "Gates" section of `CLAUDE.md` that never existed. It logged
  zero lines. Everything is now derived from the transcript JSONL and from
  git, both of which the harness writes whether or not anyone remembers to.
* **One state file per session, never a shared append-only log.** Parallel
  sessions are normal here; per-session paths mean two of them never write
  the same file and so never conflict on push. The Stop hook still takes a
  `flock` before rebasing, because they do share a worktree.

A third scar, added 2026-08-19: **a fresh cloud clone has no git filters
wired.** The clean/smudge programs (sops among them) are not on `PATH`, so a
`git add` through a declared-but-unconfigured filter commits mangled content
and the damage only shows up later. `stop-continuity.sh` checks
`.gitattributes` against `git config filter.<name>.clean` before staging and
refuses, recording the refusal in the checkpoint rather than skipping quietly.

A fourth, added 2026-09-01, is a set of refusals rather than a scar: **the
Stop hook never loses a file, and never touches a repo that hasn't opted
in.** Where a session's uncommitted files go is a policy per repo, held in
one private file in the state repo so that opting in is a line, not a PR,
and turning it all off is deleting the file. The routing keeps four
invariants that each cost something once elsewhere: no `git add -A` outside
an isolated worktree; the repo's own signing and commit hooks always run,
plus gitleaks when it is on `PATH`, and a refusal wins; the commit bound for
`main` is built in a throwaway worktree of `origin/main`, so a conflict or a
killed hook can only damage a directory about to be deleted; and no PR is
opened — a salvaged branch is a backup, not a handoff. The policy table is
an interim home; whether it should live in each repo instead is an open
question on the global board.

`session-metrics.jq` types each question put to Mark by what it cost him:
`scoping` (before any file was written — cheap), `inline` (a bounded choice
that blocks the current task), `gate` (open-ended, mid-flight, needs him to
reload context the session accumulated and he didn't).

## Ephemeral cloud sessions

Claude Code cloud sessions run as root on a throwaway Ubuntu VM with no
`~/.claude/settings.json`. **Project settings still load** when the repo is a
session source — confirmed 2026-08-19, a symphony `PreToolUse` hook fired in a
cloud session with no user-scope settings at all — so a repo carrying its own
`.claude/settings.json` already closes the gap for itself.

What the seed script buys is the *other* repos: standing orders, `rules/` and
the hooks in a session working on something that has no `.claude/` of its own,
plus `deniedMcpServers` at user scope. `.local/bin/cloud-session-setup.sh`
installs a chosen subset of this repo into `$HOME`.

**The procedure — the setup-script blob, the two sources, and how to verify —
is [RUNBOOK.md § Create a cloud environment](RUNBOOK.md#create-a-cloud-environment).**
The rest of this section is why it is built that way.

**Deliberately not yadm**, even though yadm manages everything else here:

* Nothing in this repo uses yadm's own encryption — secrets are sops+age, and
  the age key is never tracked, so it cannot reach a VM. There is no encrypted
  content for yadm to handle.
* The only alternate is `.gitconfig`, and installing it there is actively
  harmful: `yadm clone` replaces the VM's `.gitconfig` with a symlink to
  `.gitconfig##default`, wiping the session's own git identity, commit signing
  and proxy auth, and pointing `credential.helper` at a `gh` that isn't
  installed.
* `yadm clone` also prompts on `/dev/tty` to run the bootstrap, which would
  hang the setup window.

The setup field only clones and delegates, so the logic stays version-controlled
here rather than going stale in a web form. Measured cost on a cold VM: about
5s total, against a ~5 minute window.

Two guards make the `INSTALL` allowlist safe to expand:

* It **refuses to run where `$HOME` is yadm-managed** — every real machine has
  a yadm repo, an ephemeral VM never does — and skips entirely unless
  `CLOUD_SESSION=1` or `CLAUDE_CODE_REMOTE=true`.
* The install itself is atomic: every INSTALL entry is staged into a
  versioned `~/.claude-config/releases/<sha>/` directory, then a single
  symlink flip (`~/.claude-config/current`) is the only step that changes
  what a session actually reads — a session never sees half the old set and
  half the new one. `$HOME` paths reach that content through their own
  symlinks into `current`, created once and never touched again. A real
  file found where a symlink belongs (a leftover from before this design, or
  something else's) is copied to `~/.dotfiles-replaced/` before being
  replaced — never silently discarded. `SKIP_GLOBS` hard-blocks
  `.gitconfig*`, `.gitignore` and anything sops-shaped even if added to
  `INSTALL` by mistake. `~/.claude/.sync-status.json`, written last, records
  what actually landed — channel, sha, timestamp and whether the install
  came out complete — and a missing or `complete: false` file is what the
  SessionStart brief reports as a degraded session. A stage that came up
  short — a source missing, a copy failed — is discarded rather than
  activated, so the previous complete release keeps serving the session;
  superseded releases are removed only after a flip, never before one.

A fourth scar: **the setup script runs once, at container creation, not once
per session.** Containers are checkpointed and reused, so the seed froze at
whatever it cloned when the environment was provisioned and a rule edited here
reached only the sessions that happened to get a cold VM. The installer now
pulls the seed before installing from it, and `session-start-seed-refresh.sh`
re-runs it on every SessionStart — live rather than pinned, because a stale
standing order in an interactive session is worse than a changed one.

A fifth scar: **seeding without pruning is why a deleted hook kept running.**
The container seeded it once, the repo dropped it, and the `$HOME` copy was
still there and still won. The atomic redesign above fixes this structurally
rather than by sweeping stale files: `OWNED_DIRS` names the directories the
script wholly owns and links into `$HOME` as a whole (`.claude/hooks`,
`.claude/rules`), so a file dropped from `INSTALL` just isn't in the next
staged release — no separate prune step to keep in sync. `OWNED_NEVER` is the
tripwire for shared directories like `.claude` itself, which also holds
`state/`, `projects/`, `todos/` and `settings.local.json` that the script
never put there.

`sh .local/bin/cloud-session-setup.sh --dry-run` previews the whole thing and
is safe to run on any machine, including yadm-managed ones.

## Archive

`archive/` holds content carried over from the old chezmoi layout that isn't checked out
live into `$HOME` on any current machine — SignalK Pi plugin config (superseded by the
`signalk/` config tracked in the boat's own maintenance repo) and Mac-specific
`platformio` symlink targets. Preserved for reference, not deleted.

Refs and inspiration:
* https://yadm.io/docs/getting_started
* https://scottspence.com/posts/my-updated-zsh-config-2025
* https://dotfiles.github.io/inspiration/
* https://www.daytona.io/dotfiles/ultimate-guide-to-dotfiles
* https://thevaluable.dev/zsh-completion-guide-examples/

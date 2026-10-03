My dotfiles, managed with [yadm](https://yadm.io).

## Set up a machine

```
yadm clone git@github.com:mark-brannan/dotfiles.git
yadm bootstrap    # decrypts secrets; installs the sync cron line; keeps ~/CLAUDE.md out
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

Between those, a cron line that `bootstrap` installs runs
`.local/bin/dotfiles-sync.sh` every five minutes. It only ever fast-forwards;
see "Why the cron sync is ff-only" below.

**Anything beyond this is in [RUNBOOK.md](RUNBOOK.md)** — sync, secrets, and
troubleshooting. Claude Code — hooks, rules, tools — lives in its own repo,
[mark-brannan/claude](https://github.com/mark-brannan/claude); after bootstrap,
`~/.local/bin/dotfiles-claude-clone.sh move` makes `~/.claude` a clone of it.
Its runbook is [RUNBOOK.md there](https://github.com/mark-brannan/claude/blob/main/RUNBOOK.md).

## Conventions that keep it quiet

* **Why the cron sync is ff-only.** `dotsync` rebases with `--autostash`,
  which is right with a person watching and wrong unattended: Claude Code
  rewrote the tracked `.claude/settings.json` in its own key order, so a three-way merge
  sees a whole-file conflict, the autostash re-apply fails, `yadm pull` still
  exits 0, and `$HOME` is left with invalid JSON and a stash nobody sees. That
  happened on the boat. `dotfiles-sync.sh` therefore never rebases, stashes or
  merges: git refuses a fast-forward that would overwrite a dirty tracked file,
  atomically, so the only outcomes are "fast-forwarded", "level", or "skipped"
  with the blocking files named in the log. A skip is the machine asking for a
  `dotsync` by hand.

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
  `~/.config/secrets/*.env` at startup. A secret no shell should carry, like a
  signing key, lives in `secrets/on-demand/` instead: bootstrap never decrypts
  it, and the one script that needs it runs `sops -d` in memory.
* **Tool config that a tool rewrites lives outside git.** `~/.npmrc` is the case
  in point: npm overwrites it with an auth token on every login, so the settings
  live in `.profile`/`.zshenv` as `NPM_CONFIG_*` and the file itself is ignored.
  (A host that hasn't pulled since that change needs
  [a migration step](RUNBOOK.md#a-pull-refuses-local-changes-would-be-overwritten).)

## Session continuity hooks

[`hooks/`](https://github.com/mark-brannan/claude/blob/main/hooks) in mark-brannan/claude carries the machinery that makes
one session pick up where the last left off without being asked. State lives
in the private `claude_prompts_scratch` repo; `lib-state.sh` locates it and
every hook degrades to `~/.claude/state/global` if it isn't checked out.

| hook | event | what it does |
| --- | --- | --- |
| `session-start-seed-refresh.sh` | SessionStart | re-runs the cloud seed so a reused container tracks this repo, not the commit it was provisioned from |
| `session-start-continuity.sh` | SessionStart | injects the live `worklist --brief` (PRs ready, rulings pending, agent-ready issues, the agent's board), where the last three sessions left off, and the week's decision load |
| `stop-continuity.sh` | Stop | writes the session record, the decision log and an auto-checkpoint, then commits and pushes the state repo |
| `stop-sequence.py` | Stop | runs `stop-continuity.sh`, then `metrics-live.sh`'s 📦 notice, in that order, so the notice shows the verdict the checkpoint holds instead of computing a second one |
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

`session-metrics.jq` types each question put to the user by what it cost her:
`scoping` (before any file was written — cheap), `inline` (a bounded choice
that blocks the current task), `gate` (open-ended, mid-flight, needs her to
reload context the session accumulated and she didn't).

## The prose-budget engine

The engine is [`bin/prose-budget`](https://github.com/mark-brannan/claude/blob/main/bin/prose-budget) in mark-brannan/claude;
its rules, its config format and how it guards its own config against
weakening are documented there, in its header and in
[RUNBOOK.md § Check a repo's prose budgets](https://github.com/mark-brannan/claude/blob/main/RUNBOOK.md#check-a-repos-prose-budgets).
This repository keeps only what is its own: [`docs/budgets.json`](docs/budgets.json),
the `prose-budget` job in `ci.yml`, which calls the reusable workflow in
`mark-brannan/.github` (that fetches the engine from mark-brannan/claude
`main`, unpinned on purpose), and `.claude/hooks/prose-budget-commit.sh`, the
guard that denies a `git commit` on findings.

## Ephemeral cloud sessions

Claude Code cloud sessions run as root on a throwaway Ubuntu VM with no
`~/.claude/settings.json`. **Project settings still load** when the repo is a
session source — confirmed 2026-08-19, a symphony `PreToolUse` hook fired in a
cloud session with no user-scope settings at all — so a repo carrying its own
`.claude/settings.json` already closes the gap for itself.

What the seed script buys is the *other* repos: standing orders, `rules/` and
the hooks in a session working on something that has no `.claude/` of its own,
plus `deniedMcpServers` at user scope. The script is
[`bin/cloud-session-setup.sh`](https://github.com/mark-brannan/claude/blob/main/bin/cloud-session-setup.sh)
in mark-brannan/claude; what it installs and how is documented there, not here.

**The procedure — the setup-script blob, the two sources, and how to verify —
is [RUNBOOK.md § Create a cloud environment](https://github.com/mark-brannan/claude/blob/main/RUNBOOK.md#create-a-cloud-environment)
in that repo.** What follows is what this repo owns: why a cloud VM does not
get its `$HOME` from here.

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

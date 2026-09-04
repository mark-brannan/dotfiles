# Dotfiles runbook

Procedures for setting up and operating these dotfiles: a machine, a Claude
Code cloud environment, the sops-encrypted secrets, and the session-continuity
hooks.

**Getting started is in [README.md](README.md), not here.** If you just want a
working `$HOME` on a new box, the three commands at the top of the README are
the whole job. This file is for everything after that: the procedures that
repeat, the ones that only happen when something has gone wrong, and the Claude
Code setup that has no natural home in a dotfiles README.

**Deliberately partial.** Only procedures that have been run or read out of the
scripts they describe are written down. Age-key rotation and the two incident
responses (a secret committed in plaintext, a lost key) are known gaps — they
are the ones nobody has exercised, and a guessed procedure is worse than none.

Procedures only. For *why* the repo is shaped the way it is — the yadm
alternates trap, why the cloud seed is deliberately not yadm, the hook designs
and the scars behind them — see [README.md § Conventions](README.md).

## Where things are

**Machines**
- [Set up a new machine](#set-up-a-new-machine)
- [Keep machines in sync](#keep-machines-in-sync)

**Claude Code — cloud environments**
- [Create a cloud environment](#create-a-cloud-environment)
- [Attach the state repo to a running session](#attach-the-state-repo-to-a-running-session)
- [Add a file to the cloud seed](#add-a-file-to-the-cloud-seed)
- [Refresh the MCP connector deny list](#refresh-the-mcp-connector-deny-list)

**Claude Code — a real machine**
- [Wire the hooks on a real machine](#wire-the-hooks-on-a-real-machine)
- [Change what the metrics readouts show](#change-what-the-metrics-readouts-show)

**GitHub repository**
- [Set the auth token for the PR review workflows](#set-the-auth-token-for-the-pr-review-workflows)
- [Re-sign a branch whose commits are unsigned](#re-sign-a-branch-whose-commits-are-unsigned)

**Secrets**
- [Add a secret](#add-a-secret)
- [Rotate a secret](#rotate-a-secret)
- [Clear a pre-commit false positive](#clear-a-pre-commit-false-positive)

**Troubleshooting**
- [`yadm status` shows a permanent typechange](#yadm-status-shows-a-permanent-typechange)
- [A pull refuses: local changes would be overwritten](#a-pull-refuses-local-changes-would-be-overwritten)
- [Session state went to `~/.claude/state/global`](#session-state-went-to-claudestateglobal)
- [A hook didn't fire in a cloud session](#a-hook-didnt-fire-in-a-cloud-session)
- [A deleted hook keeps running](#a-deleted-hook-keeps-running)
- [Nothing decrypts on a new machine](#nothing-decrypts-on-a-new-machine)
- [PR checks fail immediately with an empty credential](#pr-checks-fail-immediately-with-an-empty-credential)
- [The security-review workflow cannot use an OAuth token](#the-security-review-workflow-cannot-use-an-oauth-token)
- [A dev server in WSL2 is unreachable from any other device](#a-dev-server-in-wsl2-is-unreachable-from-any-other-device)

---

## Set up a new machine

The README's three commands cover the common case. This is the same path with
the failure modes spelled out, in the order they bite.

**1 — Tooling.** `yadm` must exist before anything else; `sops` and `age` can
follow, but nothing decrypts until they do.

```bash
sudo apt-get install -y yadm age    # or: brew install yadm age sops
# sops on Linux: grab a release binary from https://github.com/getsops/sops/releases
command -v yadm age sops            # all three, before continuing
```

**2 — The age key, before the clone.** It is never in git — restore it from the
password manager. Without it the clone still works and the bootstrap still
runs; you just get plaintext-less secrets and a warning.

```bash
mkdir -p ~/.config/sops/age && chmod 700 ~/.config/sops/age
# paste the key in:
$EDITOR ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

Confirm it is the key you think it is before trusting it — a truncated paste is
the realistic failure and is otherwise invisible:

```bash
age-keygen -y ~/.config/sops/age/keys.txt   # must print the recipient in .sops.yaml
```

**3 — Clone.** `yadm clone` prompts on the terminal to run the bootstrap; say
yes, or run it yourself after.

```bash
yadm clone git@github.com:mark-brannan/dotfiles.git
yadm bootstrap      # idempotent; safe to re-run at any time
```

**4 — Verify.** The bootstrap prints `==> bootstrap done`. Check what it
produced and what yadm thinks of `$HOME`:

```bash
ls -l ~/.config/secrets/          # one .env per tracked secrets/*.sops.env
yadm status --short               # expect clean, or only files you know about
sh ~/.local/bin/dotfiles-triage.sh | head -40   # read-only inventory vs policy
```

**Special case — a host that predates the `.npmrc` change.** `.npmrc` used to be
tracked, so on such a host the pull refuses or deletes the file along with any
npm auth token in it. Save it first:

```bash
cp ~/.npmrc /tmp/npmrc.bak
yadm checkout -- .npmrc
dotsync
cp /tmp/npmrc.bak ~/.npmrc   # now gitignored; settings come from the shell
```

## Keep machines in sync

```bash
dotsync    # alias: yadm pull --rebase --autostash && yadm alt && yadm status --short
```

`--autostash` is load-bearing, not tidiness — a dirty `$HOME` is the normal
state, and without it every pull stops on "cannot pull with rebase: You have
unstaged changes."

Run `yadm alt` by hand after editing any `##`-suffixed file: yadm only relinks
alternates when it feels like it, and a stale symlink looks exactly like a
working one.

Unattended, every five minutes, cron runs a fast-forward-only sync. `yadm
bootstrap` installs the line; on a machine that predates it:

```bash
~/.local/bin/dotfiles-sync.sh --install
```

*Verify:* wait for the next five-minute mark, or run it once by hand, then:

```bash
~/.local/bin/dotfiles-sync.sh --status   # one line, timestamped within 5 min
```

`level with origin/main` or `fast-forwarded N commit(s)` means it works. Any
line starting `skipped:` names what a person has to do — dirty files blocking
a fast-forward, or a checkout mid-merge. A timestamp older than five minutes
means cron is not running the line: `crontab -l | grep dotfiles-sync`, and on
WSL `systemctl is-active cron`.

## Create a cloud environment

A Claude Code cloud environment configures exactly four things: **name, network
access, environment variables, and a setup script.** Repositories are *not*
part of the environment — they attach per session, as sources.

**1 — Setup script.** The field only takes pasted text, so every environment's
script is version-controlled here as the source of truth and pasted in by
hand — the field itself is never the record.

`Trusted` and `Full network access` take
[`cloud-session-setup.sh`](.local/bin/cloud-session-setup.sh)'s caller
verbatim. It only clones and delegates, so the logic stays in the repo rather
than going stale in a web form:

```sh
git clone -q https://github.com/mark-brannan/dotfiles \
  "$HOME/.local/share/dotfiles-seed" 2>/dev/null
CLOUD_SESSION=1 sh "$HOME/.local/share/dotfiles-seed/.local/bin/cloud-session-setup.sh"
exit 0
```

`Default (with tailscale)` needs tailscale installed before the seed exists to
delegate to, so it can't be a bare clone-and-delegate — paste
[`cloud-session-setup-tailscale.sh`](.local/bin/cloud-session-setup-tailscale.sh)
verbatim instead; it ends with the same clone-and-delegate. Neither variant is
executed by the platform — both files exist only so the pasted text has an
authoritative copy in git. Keep them in sync by hand if either changes.

Measured cost on a cold VM: about 5s, against a ~5 minute window.

Paste the matching variant into **every** environment, not just the one in
front of you. An environment created before this existed has no seed at all,
and a session started in it is indistinguishable from one that has it until
something is missing — which was the whole failure. As of 2026-08-21 that
means `Default (with tailscale)`, `Trusted` and `Full network access`.

**The setup script runs once, when the container is created**, and the
container is then checkpointed and reused. So the blob's `git clone` is the
seed's only chance to be fresh, and it is a no-op forever after. Two things
close that gap and both are in this repo, not in the web form:
`cloud-session-setup.sh` pulls the seed before installing from it, and
`session-start-seed-refresh.sh` re-runs the whole installer on every
SessionStart. A rule edited here therefore reaches the next session with no
re-provision — deliberately live rather than pinned, because these are
interactive sessions and a stale standing order is worse than a changed one.

Only `CLAUDE.md` cannot be refreshed in place: it is loaded before any hook
runs. When the refresh rewrites it, the hook emits the new copy as
`additionalContext` so the current session gets it too.

**2 — Sources.** Add **both**:

- `mark-brannan/dotfiles` — carries `.claude/settings.json`, so any session
  started on this repo gets the hooks even with no user-scope settings at all.
- `mark-brannan/claude_prompts_scratch` — the private state repo. The
  continuity hooks read the board from it and write their state back to it.
  **The setup script cannot clone this**: a VM has no credentials for a private
  repo at setup time, and the GitHub proxy 403s any repo not attached. Without
  it the hooks still run but write to `~/.claude/state/global`, which dies with
  the container.

**3 — Network access.** Outbound HTTPS goes through the environment's proxy.
Leave it at whatever policy the other environments use unless a session
actually needs a host that is being blocked; widening it is a deliberate
decision, not a default.

**4 — Environment variables.** Nothing in this repo requires one. The two the
seed script reads are set inline by the paste blob (`CLOUD_SESSION=1`) or by the
harness (`CLAUDE_CODE_REMOTE=true`), so the field stays empty.

**Verify** on the next session: `session-start-continuity.sh` prints a
`config: <channel>@<sha> (installed <timestamp>)` line, then the board. A
`config: DEGRADED` line means the installer never ran or didn't finish —
see [a deleted hook keeps running](#a-deleted-hook-keeps-running) for the
same `~/.claude/.sync-status.json` check. If it instead prints a "state repo
NOT available" notice, step 2 did not take — see [attaching it to a running
session](#attach-the-state-repo-to-a-running-session).

## Attach the state repo to a running session

Needed every cold session where `claude_prompts_scratch` was not attached as a
source. There is no environment setting that does this for you.

1. `mcp__Claude_Code_Remote__add_repo` with owner `mark-brannan`, repo
   `claude_prompts_scratch`, access `push`.
2. Clone it to `/workspace/claude_prompts_scratch` — a path `state_repo()`
   in `.claude/hooks/lib-state.sh` already searches.

The other paths it searches, in order: `$CLAUDE_STATE_REPO`,
`/home/user/claude_prompts_scratch`, `/workspace/claude_prompts_scratch`,
`~/claude_prompts_scratch`, `~/src/…`, `~/Projects/…`, `~/code/…`. Setting
`CLAUDE_STATE_REPO` wins over all of them if the clone landed somewhere else.

## Add a file to the cloud seed

Edit the `INSTALL` allowlist in `.local/bin/cloud-session-setup.sh` — repo-
relative paths, one per line, copied to the same path under `$HOME`. Expand
deliberately: every line lands in every cloud session.

```bash
$EDITOR .local/bin/cloud-session-setup.sh
sh .local/bin/cloud-session-setup.sh --dry-run   # safe on any machine, including yadm-managed
```

Two guards make expansion safe, and both will simply refuse rather than warn:

- `SKIP_GLOBS` hard-blocks `.gitconfig*`, `.gitignore` and anything sops-shaped
  even if added to `INSTALL` by mistake.
- The script refuses to run where `$HOME` is yadm-managed, and skips entirely
  unless `CLOUD_SESSION=1` or `CLAUDE_CODE_REMOTE=true`.

If the new file lives in a directory not already in `OWNED_DIRS`, decide
whether that directory is *wholly owned* by this script. Only wholly-owned leaf
directories go in `OWNED_DIRS` — the script links them into `$HOME` as a
single symlink to the staged release rather than mirroring them file by file;
`OWNED_NEVER` lists the shared ones that must never be linked that way.

**Every hook `.claude/settings.json` references must be in `INSTALL`.** A hook
wired in settings but missing from the seed is a silent no-op in every cloud
session — the settings entries are `[ -f ]`-guarded and end in `|| true`, so it
looks identical to a hook that ran and found nothing to do. After editing
either file, diff the two lists:

```bash
grep -o '\.claude/hooks/[a-z-]*\.sh' .claude/settings.json | sort -u
sed -n '/^INSTALL=/,/^"$/p' .local/bin/cloud-session-setup.sh | grep hooks/
```

## Refresh the MCP connector deny list

Cloud sessions get claude.ai connectors delivered server-side, and their tool
schemas are the largest fixed cost in the context floor. Deny is **by name**, so
a connector added to the account later is not covered until this list is
refreshed.

1. Run the `ListConnectors` tool in a session to get the live list.
2. Server names are the connector's display name with spaces replaced by
   underscores.
3. Update the `DENY` array in `.claude/cloud-setup.sh`, and mirror any addition
   into `deniedMcpServers` in `.claude/settings.json`.

`cloud-setup.sh` merges rather than clobbers — an existing `settings.json`
keeps its other keys and its existing `deniedMcpServers` entries are unioned
with the new ones — and it degrades to a non-`jq` path when `jq` is absent.

```bash
sh .claude/cloud-setup.sh
jq '.deniedMcpServers | length' ~/.claude/settings.json
```

Note `disableClaudeAiConnectors` in `.claude/settings.json` does **not** do this
job: it governs the CLI's own auto-fetch path, not the server-side delivery
cloud sessions use. `deniedMcpServers` merges across all settings sources and
beats every allowlist.

## Wire the hooks on a real machine

Nothing to do — `yadm clone` puts `.claude/settings.json` and
`.claude/hooks/` in `$HOME`, which is user scope, and every session on the
machine reads them. Hook commands resolve against `$HOME/.claude/hooks/`; the
cloud seed's whole job is to put the same files at the same path on a VM.

To confirm on a machine you have just set up:

```bash
ls ~/.claude/hooks/
bash ~/.claude/hooks/statusline-metrics.sh   # prints the status line, or nothing
```

Then start a session: `session-start-continuity.sh` injecting the board is the
end-to-end proof.

## Change what the metrics readouts show

Two readouts print session metrics: the **statusline row**, always on, and the
**event block**, shown at a question, a git event and session end. They share
one vocabulary and one set of layouts in `.claude/hooks/lib-metrics-fmt.jq`.
Edit that file, not the scripts.

| File | What it owns |
| --- | --- |
| `session-metrics.jq` | the measurement — tokens, turns, decisions, time |
| `metrics-live.sh` | writes the cache; prints the two-line event block |
| `statusline-metrics.sh` | prints the one-line statusline row |
| `lib-metrics-fmt.jq` | **every field and both layouts** |

Fields are `env`, `cost`, `time`, `dec`, `turns`, `work` (plus `split`, unused).
Layouts are `row` and `block`. Both draw from one `fields` list, so field order
cannot drift between them.

**Hooks load from `$HOME/.claude/hooks/`, not from a clone.** Edit the file
under `$HOME`, or copy it there afterwards — a change made only in another
checkout of this repo will render nothing different and give no error.

Then verify — this is the step that matters, because **every call site ends in
`2>/dev/null`**. That is correct for a hook, since a broken format must never
break a session, but it means a jq syntax error looks exactly like "no metrics
yet":

```bash
metrics-preview.sh --fields
```

It runs the real scripts — not a copy of their jq — against your newest
transcript, and prints: the compile check, the two paths that must stay silent,
the event block for all three event types, the statusline row, each field with
its width, and a column ruler. Exit status is non-zero if any check fails, so
it also works as a pre-commit or CI step:

```bash
metrics-preview.sh --quiet
```

Silent and exit 0 when everything passes; prints only the failures otherwise.

The two silence checks are there because a regression in either is invisible
during a session rather than noisy: a leak on the `prompt` event turns the
block into model context instead of display, and a leak in the git-command
filter runs a transcript-wide jq pass after every `ls`.

Widths worth knowing: the block's header pads to 30 columns, and the desktop
UI prefixes **each line** with `PostToolUse:<tool> says:` — 50 characters on
its own for a long MCP tool name — then wraps around 75. `--fields` shows which
field is eating the budget when a line wraps.

## Set the auth token for the PR review workflows

Two workflows run on every PR, and **they do not authenticate the same way.**
Check which you are fixing before touching a secret:

| workflow | action | input | secret | billing |
| --- | --- | --- | --- | --- |
| `claude-code-review.yml` | `anthropics/claude-code-action@v1` | `claude_code_oauth_token` | `CLAUDE_CODE_OAUTH_TOKEN` | subscription |
| `claude-security-review.yml` | `anthropics/claude-code-security-review@main` | `claude-api-key` | `ANTHROPIC_API_KEY` | API, metered |

The OAuth token bills against a Claude subscription rather than API credit,
which is why the review workflow uses it. **The security-review action has no
OAuth input** — its `claude-api-key` is `required: true` — so it cannot be
converted; it either gets a metered API key or it gets disabled. See
[the entry below](#the-security-review-workflow-cannot-use-an-oauth-token).

These are **GitHub repo secrets, not sops secrets.** Nothing about them lives
in this repo: `secrets/`, `.sops.yaml` and the bootstrap are not involved. They
are set once per repository, and no machine setup does it for you.

**1 — Mint the token.** From Claude Code on a machine already logged in:

```bash
claude setup-token
```

It prints a long-lived token tied to your subscription. It is not an API key
and will not work in `ANTHROPIC_API_KEY`.

**2 — Set it.** Never paste a token onto the command line — it lands in shell
history. Let `gh` prompt, or pipe it in:

```bash
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo mark-brannan/dotfiles
# reads from the prompt; nothing is echoed, nothing is stored locally
```

Without `gh`: the repo's Settings → Secrets and variables → Actions → New
repository secret. Name it exactly `CLAUDE_CODE_OAUTH_TOKEN`.

**3 — Verify.** `gh` never prints a secret's value, so the only proof is that
the name exists and that a run goes green:

```bash
gh secret list --repo mark-brannan/dotfiles     # the name, with a set date
```

Then re-run the failed checks on any open PR. **Setting a secret does not
retroactively rerun anything** — a PR that failed before it existed stays red
until something kicks it:

```bash
gh run list --repo mark-brannan/dotfiles --limit 5
gh run rerun <run-id> --failed --repo mark-brannan/dotfiles
```

`review` should now complete and comment on the PR. `security` stays red until
its own separate decision is made.

The token expires. When `review` starts failing on PRs that used to pass and
nothing about the workflow changed, re-run `claude setup-token` and set the
secret again — same procedure, no other cleanup.

This repo is public. Actions secrets are not exposed to workflows triggered by
forked PRs, and the security workflow's own comment says it should only run
against trusted PRs — true here because only the owner pushes. If that stops
being true, that workflow needs revisiting before the credential does.

CodeRabbit is configured by `.coderabbit.yaml` and authenticates as a GitHub
App. It needs no secret, so none of this affects it.

## Re-sign a branch whose commits are unsigned

**When:** a PR says *"All commits must have verified signatures"*, or the
`no-unsigned-push` hook refused a push. Commits come out unsigned from cloud
sessions (no key on the VM), from plumbing such as `git commit-tree`, and
from anything run with `-c commit.gpgsign=false`. The fix is the same for
all three, and it runs from any machine that has the signing key, never from
the cloud session.

From any checkout of the repo; it works in a throwaway worktree, so the
branch you have checked out and any uncommitted work are untouched:

```bash
resign-branch.sh <branch>
```

It resets local `<branch>` to `origin/<branch>`, rebases onto the tip of the
default branch with `-S` (which re-signs every commit and drops any "Update
branch" merge commits), verifies each one locally, and force-pushes with
lease. It also runs when the branch is merely behind the default branch, so
it doubles as a signed, linear "Update branch". Running it on a branch that
already verifies and is up to date does nothing. It refuses
if you have local commits on the branch that are not on origin, if the rebase
conflicts, or if linearizing would drop content from a hand-resolved merge
commit — in every case the branch is left as it was. Your working tree is
never touched, dirty or not: all the rewriting happens in a throwaway
worktree, so there is nothing to stash first.

Verify on GitHub — every line must say `true`:

```bash
gh api repos/<owner>/<repo>/pulls/<n>/commits --jq '.[]|"\(.sha[0:7]) \(.commit.verification.verified) \(.commit.message|split("\n")[0])"'
```

If the local verify step reports every commit as `U` or `E` instead of
`G`, `~/.ssh/allowed_signers` is missing or in the wrong column order. The
format is `<email> <key-type> <key>` — email first, unlike
`authorized_keys`. The script builds a temporary one when none is
configured, so this only matters for `git log --show-signature` by hand.

## Add a secret

```bash
dotfiles-add-secret.sh <name>
```

That is the whole procedure. `<name>` is the only thing you choose: the
ciphertext lands tracked at `~/secrets/<name>.sops.env`, and `yadm bootstrap`
decrypts it to `~/.config/secrets/<name>.env`, which is gitignored and outside
the git working tree so plaintext can never be swept up by a later `yadm add`.
`.zshrc`/`.bashrc` source everything under `~/.config/secrets/*.env` at startup.

The script opens `$EDITOR` on the new file — write `KEY=value` lines, one per
line, no `export`, no quotes unless the value contains spaces — then encrypts
in place, asks before committing, and runs the bootstrap. It refuses to stage
anything it can't prove is ciphertext, and deletes the plaintext file if you
quit the editor without writing any values. `--no-commit` stops short of the
`yadm commit`.

*Verify:* it prints `==> encrypted ...` and `==> decrypted to ... (N value(s))`
with N matching the lines you wrote. Anything else is a failure and it exits
non-zero.

The value only reaches shells started after the bootstrap:

```bash
exec $SHELL -l
```

On every other machine: `dotsync && yadm bootstrap`, then a fresh shell.

**If the script isn't there** (a cloud session, a box mid-bootstrap), the same
five steps by hand. Write the plaintext at its final path — `.sops.yaml` only
matches `secrets/` and the `.sops.<ext>` suffix, so encrypting from `/tmp`
fails with `no matching creation rules found`:

```bash
NAME=example
$EDITOR ~/secrets/$NAME.sops.env
sops -e -i ~/secrets/$NAME.sops.env
head -3 ~/secrets/$NAME.sops.env    # every value must read KEY=ENC[AES256_GCM,...]
yadm add ~/secrets/$NAME.sops.env && yadm commit -m "secrets: add $NAME" && yadm bootstrap
```

**Exception — a secret you do not want in every process.** The startup loop
exports into every shell and everything it spawns. `claude-token.env` is
excluded from that loop by name and sourced only inside the `claude` wrapper
function (see `.zshrc`). A new secret needing the same treatment gets its
basename added to the `case` in both `.zshrc` and `.bashrc` and its own
wrapper; the script does not do this for you.

## Rotate a secret

```bash
sops ~/secrets/<name>.sops.env    # decrypts to $EDITOR, re-encrypts on save
yadm diff ~/secrets/<name>.sops.env   # ciphertext changed; plaintext never shown
yadm commit -m "secrets: rotate <name>"
```

Then on every other machine: `dotsync && yadm bootstrap`, and restart shells so
the new value is sourced. Revoke the old credential at the provider *after* the
new one is confirmed working, not before.

## Clear a pre-commit false positive

`~/.config/yadm/hooks/pre_commit` blocks credential material and secret-shaped
values in added lines, and **fails closed**: if it cannot read the commit
(`YADM_HOOK_REPO`/`WORK` unset, i.e. yadm older than 3.2) it aborts rather than
waving it through.

```bash
yadm commit -m "..."                       # read exactly which path/line it named
# confirm it really is a false positive, then:
YADM_ALLOW_SECRET=1 yadm commit -m "..."
```

If the same path trips it repeatedly, fix the policy rather than the commit:
`.gitignore`, the `NEVER` class in `.local/bin/dotfiles-triage.sh`, and the
`pre_commit` hook mirror each other and should be edited together.

---

## `yadm status` shows a permanent typechange

The generated alternate target is tracked as a real file as well. yadm relinks
it after every command, so status reports a typechange forever.

```bash
yadm rm --cached .gitconfig        # stop tracking the generated target
grep -n '^\.gitconfig$' ~/.gitignore || echo '.gitconfig' >> ~/.gitignore
yadm alt && yadm status --short    # clean
```

Only `.gitconfig##os.Darwin` and `.gitconfig##default` are ever tracked.

## A pull refuses: local changes would be overwritten

Almost always a file that used to be tracked and now isn't — `.npmrc` is the
known case. Save it, drop the local copy, pull, restore.

```bash
cp ~/<file> /tmp/<file>.bak
yadm checkout -- <file>
dotsync
cp /tmp/<file>.bak ~/<file>
```

If it is not a de-tracked file, `yadm status --short` and `yadm diff <file>`
first — do not blanket-checkout a file you have not read.

## Session state went to `~/.claude/state/global`

`claude_prompts_scratch` is not checked out where `state_repo()` looks, so the
hooks degraded to a local, unpushed directory. On a cloud session it dies with
the container.

```bash
ls -d /workspace/claude_prompts_scratch/.git ~/claude_prompts_scratch/.git 2>/dev/null
```

Cloud session: [attach it](#attach-the-state-repo-to-a-running-session). Real
machine: clone it to one of the searched paths, or export
`CLAUDE_STATE_REPO=/path/to/it`. Anything already written to
`~/.claude/state/global` can be copied across by hand; nothing does that for you.

## A hook didn't fire in a cloud session

Check in this order:

```bash
ls ~/.claude/hooks/                              # did the seed run at all?
grep -n 'the-hook-name' ~/.claude/settings.json  # is it wired?
```

- Nothing in `~/.claude/hooks/` → the setup script did not run. The seed skips
  entirely unless `CLOUD_SESSION=1` or `CLAUDE_CODE_REMOTE=true`, so a paste
  blob missing the `CLOUD_SESSION=1` prefix is a silent no-op.
- Wired in settings but absent from `~/.claude/hooks/` → it is not in
  `INSTALL`. See [adding a file to the seed](#add-a-file-to-the-cloud-seed).
  This is the common one, and it is silent by design.
- Present and wired → run it by hand (`bash ~/.claude/hooks/<name>.sh`). Every
  settings entry ends in `|| true` and most redirect stderr, so a hook that
  errors every time looks identical to one that is not wired.

The seed is not the only path that works: a repo carrying its own
`.claude/settings.json` gets its project settings loaded in a cloud session even
with no user-scope settings at all. What the seed buys is the *other* repos.

## A cloud session is running an old rule

The seed checkout at `~/.local/share/dotfiles-seed` is a real clone, so ask it:

```bash
git -C ~/.local/share/dotfiles-seed log --oneline -1
```

Behind `origin/main` means the refresh is not running. Either the container
predates it — `ls ~/.claude/hooks/session-start-seed-refresh.sh` — or the pull
failed, which the installer reports rather than swallowing:
`CLOUD_SESSION=1 sh ~/.local/share/dotfiles-seed/.local/bin/cloud-session-setup.sh`
prints the reason. A blocked proxy leaves the last-known-good seed in place on
purpose; that is a stale session, not a broken one.

## A deleted hook keeps running

`$HOME/.claude/hooks` is a symlink to `~/.claude-config/current/.claude/hooks`
(and `.claude/rules` the same), so a file dropped from `INSTALL` simply isn't
in the next staged release — there is no separate prune step to fall out of
sync, unlike the per-file-copy design this replaced. If a stale hook is still
running, check first that its directory is actually in `OWNED_DIRS` in
`.local/bin/cloud-session-setup.sh` — a file outside those two directories is
linked individually and a rename can leave the old name behind:

```bash
ls -la ~/.claude/hooks   # should be a symlink -> ~/.claude-config/current/.claude/hooks
cat ~/.claude/.sync-status.json   # sha/installed_at of what's actually live
```

If the symlink target is stale (points at a release dir other than
`~/.claude-config/current`'s own target, or is missing), re-run the installer:
`CLOUD_SESSION=1 sh ~/.local/share/dotfiles-seed/.local/bin/cloud-session-setup.sh`.
If the hook's directory isn't in `OWNED_DIRS` at all, add it there — that's the
structural fix, not a one-off `rm`.

## Nothing decrypts on a new machine

```bash
command -v sops age                              # both must exist
age-keygen -y ~/.config/sops/age/keys.txt        # must match .sops.yaml's recipient
sops -d ~/secrets/<name>.sops.env | head -1      # the actual failure message
```

A key that does not match the recipient in `.sops.yaml` cannot decrypt anything
and never will — it is not a permissions problem. Restore the correct key from
the password manager, or re-encrypt from a machine that still holds the old one.

## PR checks fail immediately with an empty credential

A check goes red about 30 seconds in, on every PR, including ones that change
nothing relevant. The tell is in the job log's env group:

```bash
gh run view <run-id> --repo mark-brannan/dotfiles --log \
  | grep -iE 'ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN'
```

A name with nothing after it means that repository secret is unset or empty —
the workflow is fine, the credential is missing. Check which secret the failing
workflow actually reads before setting anything; the two workflows use different
ones, and setting the wrong one changes nothing. Then
[set it](#set-the-auth-token-for-the-pr-review-workflows) and rerun the failed
jobs; a secret does not apply retroactively.

Not this if the failure comes minutes in rather than seconds — that is a real
finding, a rate limit, or an expired token, not a missing one.

## The security-review workflow cannot use an OAuth token

`anthropics/claude-code-security-review@main` exposes no OAuth input:
`claude-api-key` is `required: true` in its `action.yml`. There is no way to
point it at a subscription token, so while `ANTHROPIC_API_KEY` is unset this
check stays red no matter what is done to `CLAUDE_CODE_OAUTH_TOKEN`.

Three ways out, all deliberate choices rather than fixes:

- **Set `ANTHROPIC_API_KEY`** and accept metered API billing for this one
  workflow.
- **Delete `.github/workflows/claude-security-review.yml`.** The general review
  pass already prompts for secrets handling, sops rules and auto-executing
  hooks, so the coverage loss is smaller than it looks.
- **Narrow when it runs** — `on: workflow_dispatch` instead of `on:
  pull_request` — so it is available on demand without gating every PR.

**Taken: `workflow_dispatch`.** No OAuth billing, and the check no longer
shows red on every PR for a credential that was never going to be set. Run it
by hand when wanted:

```bash
gh workflow run claude-security-review.yml --repo mark-brannan/dotfiles
gh run list --workflow claude-security-review.yml --repo mark-brannan/dotfiles --limit 1
```

Verify whichever you pick by re-running the check, not by reading the workflow:
a green `review` and a still-red `security` is the state that means only half
the decision has been made.

## A dev server in WSL2 is unreachable from any other device

A server started inside WSL2 answers on every address from inside WSL —
loopback, LAN, Tailscale — and times out from a phone, a tablet, or even the
Windows host it is running on. Nothing is wrong with the server. Under
mirrored networking WSL shares the Windows network namespace, so Windows
Firewall governs its inbound traffic and blocks it by default.

From the Windows host itself, `localhost` works with no change:

```text
http://localhost:<port>/
```

To reach it from another device, open the ports once, on Windows. Mirrored
mode routes this traffic through the ordinary Windows Firewall, not the
Hyper-V VM firewall — `New-NetFirewallHyperVRule` looks right but is a no-op
here; it governs NAT-mode WSL, and mirrored mode ignores it silently (the
rule shows `Enabled: True` either way, which is what makes this fail quietly
instead of erroring). `-Profile` is scoped to `Private,Domain` deliberately —
the unscoped default is `Any`, which would leave these ports open on a
`Public` profile too, e.g. the laptop on coffee-shop wifi:

**PowerShell, admin:**

```powershell
New-NetFirewallRule -DisplayName "WSL dev servers (mirrored)" -Direction Inbound -Protocol TCP -LocalPort 3010,8742 -Profile Private,Domain -Action Allow
```

Verify from a *different* device on the LAN or the tailnet — not from the
Windows host, whose `localhost` worked before the rule and proves nothing:

```shell
curl -s --connect-timeout 5 -o /dev/null -w '%{http_code}\n' http://<lan-or-tailscale-ip>:<port>/
```

`--connect-timeout` bounds the TCP handshake, not the whole transfer — a slow
response otherwise reads the same as a blocked port. Any HTTP status code
means the rule took, including `401`/`404`/`500`; only a timeout means it did
not — check `Get-NetFirewallRule -DisplayName "WSL dev servers (mirrored)"`
exists and that the ports in it match the ones actually listening.

Remove it with `Remove-NetFirewallRule -DisplayName "WSL dev servers
(mirrored)"`, and edit `-LocalPort` rather than adding a second rule when the
set of ports changes.

If `networkingMode` in `.wslconfig` is `nat` instead of `mirrored`, this rule
type is wrong for that mode — check
[`Get-NetFirewallHyperVRule`](https://learn.microsoft.com/en-us/powershell/module/netsecurity/get-netfirewallhypervrule)
and the `VMCreatorId` variant instead; not covered here because this fleet
runs mirrored.

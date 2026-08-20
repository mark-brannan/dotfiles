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

**GitHub repository**
- [Set the Anthropic API key for the PR review workflows](#set-the-anthropic-api-key-for-the-pr-review-workflows)

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
- [PR checks fail immediately with an empty API key](#pr-checks-fail-immediately-with-an-empty-api-key)

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

## Create a cloud environment

A Claude Code cloud environment configures exactly four things: **name, network
access, environment variables, and a setup script.** Repositories are *not*
part of the environment — they attach per session, as sources.

**1 — Setup script.** Paste this verbatim into the environment's setup-script
field. It only clones and delegates, so the logic stays version-controlled here
rather than going stale in a web form:

```sh
git clone -q https://github.com/mark-brannan/dotfiles \
  "$HOME/.local/share/dotfiles-seed" 2>/dev/null
CLOUD_SESSION=1 sh "$HOME/.local/share/dotfiles-seed/.local/bin/cloud-session-setup.sh"
exit 0
```

Measured cost on a cold VM: about 5s, against a ~5 minute window.

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

**Verify** on the next session: `session-start-continuity.sh` prints the board
at the top. If it instead prints a "state repo NOT available" notice, step 2
did not take — see [attaching it to a running
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

If the new file lives in a directory not already in `PRUNE_DIRS`, decide
whether that directory is *wholly owned* by this script. Only wholly-owned leaf
directories go in `PRUNE_DIRS`; `PRUNE_NEVER` lists the shared ones that must
never be pruned.

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

## Set the Anthropic API key for the PR review workflows

`.github/workflows/claude-code-review.yml` and `claude-security-review.yml` run
on every PR and both read the **repository** secret `ANTHROPIC_API_KEY`. They
pass it under different input names (`anthropic_api_key` and `claude-api-key`)
but it is one secret. Until it is set, both checks fail about 30 seconds in —
see [the troubleshooting entry](#pr-checks-fail-immediately-with-an-empty-api-key).

This is a **GitHub repo secret, not a sops secret.** Nothing about it lives in
this repo: `secrets/`, `.sops.yaml` and the bootstrap are not involved. It is
set once per repository and it is not something a machine setup can do for you.

**1 — Mint a dedicated key** at <https://console.anthropic.com/settings/keys>.
Use a separate key named for this repo rather than reusing a local one, so
revoking it later doesn't break Claude Code on your machines.

**2 — Set it.** Never paste a key onto the command line — it lands in shell
history. Pipe it in, or let `gh` prompt:

```bash
gh secret set ANTHROPIC_API_KEY --repo mark-brannan/dotfiles
# reads the value from the prompt; nothing is echoed and nothing is stored locally
```

From a file, if the key is already on disk somewhere disposable:

```bash
gh secret set ANTHROPIC_API_KEY --repo mark-brannan/dotfiles < /tmp/key.txt
shred -u /tmp/key.txt
```

Without `gh`: GitHub web UI → the repo → Settings → Secrets and variables →
Actions → New repository secret. Name it exactly `ANTHROPIC_API_KEY`.

**3 — Verify.** `gh` never prints a secret's value, so the only proof is that
the name exists and that a run goes green:

```bash
gh secret list --repo mark-brannan/dotfiles     # ANTHROPIC_API_KEY, with a set date
```

Then re-run the failed checks on any open PR — **setting the secret does not
retroactively rerun anything**, and a PR that failed before the secret existed
stays red until something kicks it:

```bash
gh run list --repo mark-brannan/dotfiles --limit 5
gh run rerun <run-id> --failed --repo mark-brannan/dotfiles
```

Both `review` and `security` should complete and post a comment on the PR.

This repo is public. Actions secrets are not exposed to workflows triggered by
forked PRs, and the security workflow's own comment says it should only run
against trusted PRs — true here because only the owner pushes. If that ever
stops being true, the security workflow needs revisiting before the key does.

CodeRabbit is configured by `.coderabbit.yaml` and authenticates as a GitHub
App. It needs no secret, so it is unaffected by any of this.

## Add a secret

Ciphertext lives tracked at `~/secrets/<name>.sops.env`; the bootstrap decrypts
each into `~/.config/secrets/<name>.env`, which is gitignored and outside the
git working tree, so plaintext can never be swept up by a later `yadm add`.
`.zshrc`/`.bashrc` source everything under `~/.config/secrets/*.env` at startup.

```bash
$EDITOR /tmp/new.env                    # KEY=value lines
sops -e /tmp/new.env > ~/secrets/new.sops.env
shred -u /tmp/new.env
yadm add ~/secrets/new.sops.env
yadm commit -m "secrets: add new"
yadm bootstrap                          # decrypts it into ~/.config/secrets/
```

`.sops.yaml` matches on `secrets/` and on `.sops.<ext>` suffixes, so both
conventions encrypt automatically. Verify before committing — a file that
matched no creation rule is committed in the clear:

```bash
head -5 ~/secrets/new.sops.env    # must be sops ciphertext, not your KEY=value
```

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

## A deleted hook keeps running

The container seeded it once, the repo dropped it, and the `$HOME` copy is
still there. Hook commands resolve against `$HOME/.claude/hooks/` and the file
is present, so it runs — removing it from the repo changed nothing about this
container.

This is what `PRUNE_DIRS` in `.local/bin/cloud-session-setup.sh` exists for: any
file in a pruned directory that is not in `INSTALL` is removed on the next seed.
If a stale hook survived, its directory is not in `PRUNE_DIRS`. Add it if the
script wholly owns that directory; delete the file by hand either way.

## Nothing decrypts on a new machine

```bash
command -v sops age                              # both must exist
age-keygen -y ~/.config/sops/age/keys.txt        # must match .sops.yaml's recipient
sops -d ~/secrets/<name>.sops.env | head -1      # the actual failure message
```

A key that does not match the recipient in `.sops.yaml` cannot decrypt anything
and never will — it is not a permissions problem. Restore the correct key from
the password manager, or re-encrypt from a machine that still holds the old one.

## PR checks fail immediately with an empty API key

Both `review` and `security` go red about 30 seconds in, on every PR, including
ones that change nothing relevant. The tell is in the job log's env group:

```bash
gh run view <run-id> --repo mark-brannan/dotfiles --log | grep -i 'ANTHROPIC_API_KEY'
```

`ANTHROPIC_API_KEY:` with nothing after it means the repository secret is unset
or empty — the workflow is fine, the credential is missing. Set it via
[the procedure above](#set-the-anthropic-api-key-for-the-pr-review-workflows),
then rerun the failed jobs; the secret does not apply retroactively.

Not this if only *one* of the two checks fails, or if the failure comes minutes
in rather than seconds — that is a real finding or a rate limit, not a missing
key.

These are my dotfiles, managed with [yadm](https://yadm.io). Secrets, where any are
tracked, are encrypted at rest with [sops](https://github.com/getsops/sops) +
[age](https://github.com/FiloSottile/age) — see `.sops.yaml`.

Use at your own risk:
```
yadm clone git@github.com:mark-brannan/dotfiles.git

yadm status
yadm diff

yadm bootstrap   # installs sops/age if missing, decrypts anything sops-managed
```

`.config/yadm/bootstrap` runs automatically after `yadm clone`, or manually via
`yadm bootstrap`. It expects the machine's own age key to already exist at
`~/.config/sops/age/keys.txt` (never tracked in this repo — restore it out-of-band, e.g.
from a password manager) before it can decrypt anything.

## Keeping machines in sync

`dotsync` (alias, defined in `.bashrc` and `.zsh_aliases`) is the whole routine:

```
yadm pull --rebase --autostash && yadm alt && yadm status --short
```

`--autostash` matters — a dirty `$HOME` is the normal state, and without it every
pull stops with "cannot pull with rebase: You have unstaged changes."

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
* **Tool config that a tool rewrites lives outside git.** `~/.npmrc` is the case
  in point: npm overwrites it with an auth token on every login, so the settings
  live in `.profile`/`.zshenv` as `NPM_CONFIG_*` and the file itself is ignored.

## Migrating a machine that predates the `.npmrc` change

`.npmrc` used to be tracked. On a host that hasn't pulled since, `yadm pull` will
refuse ("local changes would be overwritten") or delete the file along with any npm
auth token in it. Save it first:

```
cp ~/.npmrc /tmp/npmrc.bak
yadm checkout -- .npmrc
dotsync
cp /tmp/npmrc.bak ~/.npmrc   # now ignored; keeps the token, settings come from the shell
```

## Ephemeral cloud sessions

Claude Code cloud sessions run as root on a throwaway Ubuntu VM with no
`~/.claude/settings.json`, so standing orders, rules and hooks never load and
`deniedMcpServers` goes unenforced. `.local/bin/cloud-session-setup.sh` seeds a
chosen subset of this repo into `$HOME` there. Paste this into the
environment's setup-script field (Claude Code → environment settings):

```
git clone -q https://github.com/mark-brannan/dotfiles \
  "$HOME/.local/share/dotfiles-seed" 2>/dev/null
CLOUD_SESSION=1 sh "$HOME/.local/share/dotfiles-seed/.local/bin/cloud-session-setup.sh"
exit 0
```

The setup field only clones and delegates, so the logic stays version-controlled
here rather than going stale in a web form. Measured cost on a cold VM: about
5s total, against a ~5 minute window.

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

Edit the `INSTALL` allowlist in the script to add files. Two guards make that
safe to expand:

* It **refuses to run where `$HOME` is yadm-managed** — every real machine has
  a yadm repo, an ephemeral VM never does — and skips entirely unless
  `CLOUD_SESSION=1` or `CLAUDE_CODE_REMOTE=true`.
* Overwriting is necessary on a VM but never silent: identical files are a
  no-op, a symlink destination is refused as some other manager's, and a
  differing file is copied to `~/.dotfiles-replaced/` before being replaced.
  `SKIP_GLOBS` hard-blocks `.gitconfig*`, `.gitignore` and anything
  sops-shaped even if added to `INSTALL` by mistake.

`sh .local/bin/cloud-session-setup.sh --dry-run` previews the whole thing and
is safe to run on any machine, including yadm-managed ones.

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

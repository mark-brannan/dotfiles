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

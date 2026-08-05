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

# Dotfiles runbook

Procedures for the machines these dotfiles live on. Getting started and the
*why* are in [README.md](README.md); Claude Code's hooks, cloud environments and
PR workflows are in [.claude/RUNBOOK.md](.claude/RUNBOOK.md).

**Deliberately partial.** Only procedures that have been run are written down.
Age-key rotation and the two incident responses — a secret committed in
plaintext, a lost key — are known gaps; a guessed procedure is worse than none.

## Where things are

**Machines**
- [Set up a new machine](#set-up-a-new-machine)
- [Keep machines in sync](#keep-machines-in-sync)
- [Prune old local branches](#prune-old-local-branches)

**Secrets**
- [Add a secret](#add-a-secret)
- [Rotate a secret](#rotate-a-secret)
- [Clear a pre-commit false positive](#clear-a-pre-commit-false-positive)

**Troubleshooting**
- [`yadm status` shows a permanent typechange](#yadm-status-shows-a-permanent-typechange)
- [A pull refuses: local changes would be overwritten](#a-pull-refuses-local-changes-would-be-overwritten)
- [Nothing decrypts on a new machine](#nothing-decrypts-on-a-new-machine)
- [A dev server in WSL2 is unreachable from any other device](#a-dev-server-in-wsl2-is-unreachable-from-any-other-device)

---

## Set up a new machine

**1 — Tooling.**

```bash
# Linux / WSL
sudo apt-get install -y yadm age
# sops has no apt package: grab a release binary from https://github.com/getsops/sops/releases
command -v yadm age sops            # all three, before continuing
```

```zsh
# macOS
brew install yadm age sops
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

A truncated paste is the realistic failure and is otherwise invisible:

```bash
age-keygen -y ~/.config/sops/age/keys.txt   # must print the recipient in .sops.yaml
```

**3 — Clone.** `yadm clone` prompts on the terminal to run the bootstrap; say
yes, or run it yourself after.

```bash
yadm clone git@github.com:mark-brannan/dotfiles.git
yadm bootstrap      # idempotent; safe to re-run at any time
```

**4 — Verify.** The bootstrap prints `==> bootstrap done`. Then:

```bash
ls -l ~/.config/secrets/          # one .env per tracked secrets/*.sops.env
yadm status --short               # expect clean, or only files you know about
sh ~/.local/bin/dotfiles-triage.sh | head -40   # read-only inventory vs policy
```

## Keep machines in sync

```bash
dotsync    # alias: yadm pull --rebase --autostash && yadm alt && yadm status --short
```

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

## Prune old local branches

```bash
prune-branches           # preview
prune-branches --delete
```

Verify: exit 0 and a final `deleted N branch(es)` line; each deletion line
carries its undo. `prune-branches --help` has the rules.

## Add a secret

```bash
dotfiles-add-secret.sh <name>
```

`<name>` is the only thing you choose. The script opens `$EDITOR` on the new
file — write `KEY=value` lines, one per line, no `export`, no quotes unless
the value contains spaces — then encrypts it in place at
`~/secrets/<name>.sops.env`, asks before committing, and runs the bootstrap.
`--no-commit` stops short of the `yadm commit`.

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

`~/.config/yadm/hooks/pre_commit` **fails closed**: an abort naming no path
means it could not read the commit (`YADM_HOOK_REPO`/`WORK` unset — yadm older
than 3.2), not that it found something. Upgrade yadm rather than override.

```bash
yadm commit -m "..."                       # read exactly which path/line it named
# confirm it really is a false positive, then:
YADM_ALLOW_SECRET=1 yadm commit -m "..."
```

If the same path trips it repeatedly, fix the policy rather than the commit:
`.gitignore`, the `NEVER` class in `.local/bin/dotfiles-triage.sh`, and the
`pre_commit` hook mirror each other and should be edited together.

## `yadm status` shows a permanent typechange

```bash
yadm rm --cached .gitconfig        # stop tracking the generated target
grep -n '^\.gitconfig$' ~/.gitignore || echo '.gitconfig' >> ~/.gitignore
yadm alt && yadm status --short    # clean
```

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

## Nothing decrypts on a new machine

```bash
command -v sops age                              # both must exist
age-keygen -y ~/.config/sops/age/keys.txt        # must match .sops.yaml's recipient
sops -d ~/secrets/<name>.sops.env | head -1      # the actual failure message
```

A key that does not match the recipient in `.sops.yaml` cannot decrypt anything
and never will — it is not a permissions problem. Restore the correct key from
the password manager, or re-encrypt from a machine that still holds the old one.

## A dev server in WSL2 is unreachable from any other device

Nothing is wrong with the server. Under mirrored networking WSL shares the
Windows network namespace, so Windows Firewall governs its inbound traffic and
blocks it by default. Open the ports once, on Windows.

`New-NetFirewallHyperVRule` looks right and is a no-op here: it governs
NAT-mode WSL, mirrored mode ignores it silently, and the rule reports
`Enabled: True` either way. `-Profile` is scoped to `Private,Domain` because
the default `Any` would open these ports on a `Public` profile too — the
laptop on coffee-shop wifi:

**PowerShell, admin:**

```powershell
New-NetFirewallRule -DisplayName "WSL dev servers (mirrored)" -Direction Inbound -Protocol TCP -LocalPort 3010,8742 -Profile Private,Domain -Action Allow
```

*Verify* from a *different* device on the LAN or the tailnet — not from the
Windows host, whose `localhost` worked before the rule and proves nothing:

```shell
curl -s --connect-timeout 5 -o /dev/null -w '%{http_code}\n' http://<lan-or-tailscale-ip>:<port>/
```

Any HTTP status code means the rule took, including `401`/`404`/`500`; only a
timeout means it did not — check `Get-NetFirewallRule -DisplayName "WSL dev
servers (mirrored)"` exists and that the ports in it match the ones actually
listening.

Remove it with `Remove-NetFirewallRule -DisplayName "WSL dev servers
(mirrored)"`, and edit `-LocalPort` rather than adding a second rule when the
set of ports changes.

If `networkingMode` in `.wslconfig` is `nat` rather than `mirrored`, this rule
type is wrong for it — use the `Get-NetFirewallHyperVRule`/`VMCreatorId`
variant instead. Not written up here; nothing in the fleet runs `nat`.

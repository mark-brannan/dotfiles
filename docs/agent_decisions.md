# Agent decisions

Append-only. Each entry is a call an agent made in pencil: a default it took
under the one-way-door test, with its undo. Written by `agent-decision`; the
heading is the UTC stamp, so `agent_decisions.md#<stamp>` links one entry.

### 20261104t060704z
- Workshop setup in bootstrap only warns on failure, never fails bootstrap Undo: move or drop the workshop block in .config/yadm/bootstrap ([#585](https://github.com/mark-brannan/dotfiles/pull/585))

### 20261112t042442z
- hook scripts sit in .githooks/checks/, leaving the top of .githooks/ for git's event names Undo: move the files up one level ([#590](https://github.com/mark-brannan/dotfiles/pull/590))

### 20261112t042445z
- a Dependabot entry watches the gitleaks pin under .githooks/docker/gitleaks Undo: delete the docker entry in .github/dependabot.yml ([#590](https://github.com/mark-brannan/dotfiles/pull/590))

### 20261112t043241z
- the gitleaks finding on a test fixture is answered with a scoped allowlist entry Undo: drop the allowlist entry and change the fixture string ([#590](https://github.com/mark-brannan/dotfiles/pull/590))

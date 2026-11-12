# Agent decisions

Append-only. Each entry is a call an agent made in pencil: a default it took
under the one-way-door test, with its undo. Written by `agent-decision`; the
heading is the UTC stamp, so `agent_decisions.md#<stamp>` links one entry.

### 20261104t060704z
- Workshop setup in bootstrap only warns on failure, never fails bootstrap Undo: move or drop the workshop block in .config/yadm/bootstrap ([#585](https://github.com/mark-brannan/dotfiles/pull/585))

### 20261112t042442z
- hook scripts sit in .githooks/checks/, leaving the top of .githooks/ for git's event names Undo: move the files up one level ([#590](https://github.com/mark-brannan/dotfiles/pull/590))

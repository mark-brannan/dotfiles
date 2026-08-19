# Claude board — dotfiles

Backlog for Claude-session work on the dotfiles repo itself: standing
orders, rules files, hooks, journal conventions, shell/tool config.
**Dotfiles scope only.** Per-project session state lives in each project's
own designated scratch area — Symphony's is
`~/symphony/intermediate_files/claude_slop/` (kanban.md + log.md); never
park another repo's work here. (Symphony content that was staged here
2026-08-19 has been moved back; Mark settled placement that night.)

How to use this board:

- **Activate by pulling.** New sessions open only to work an item from this
  board. WIP limit ~2-3 active sessions.
- **Capture != activation.** An idea a session surfaces that its goal doesn't
  need becomes one line here at wrap-up, or gets dropped if trivial.
- **Wrap-up ritual:** on "wrap up" / "log it", flush loose ends here, write
  a checkpoint, commit, push, confirm the chat is safe to kill.
- **Blocking questions:** ask Mark inline only if the answer blocks the
  current task; everything else becomes a proposed line here for batch
  accept/edit/delete.

## Backlog

- **Cherry-pick tracking metrics** (branch `claude/cherry-pick-tracking-metrics-df8pul`) — Hook created to detect and log cherry-picks to `.claude/metrics/cherry-picks.jsonl`. Ready to merge once: (1) pattern is verified against symphony's parallel work, (2) .claude/settings.json state is resolved (PostToolUse matcher needs testing). Follow-up: broader metrics framework (token usage, screen time, decision counts).
- Reconcile standing-orders lines with the "Standing orders additions"
  session (they own that file's final form)
- Standing-orders scheduled review 2026-08-30: cut "Answering closed
  questions" and "Decision load" to four lines each if neither has visibly
  changed a session by then (per the file's own note)

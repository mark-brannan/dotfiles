# 2026-08-19 — MCP connector shutdown

## Where we landed

MCP connectors were disabled everywhere they can be:

- **Local CLI sessions** — `.claude/settings.json` on main now has both
  `"disableClaudeAiConnectors": true` and
  `"env": { "ENABLE_CLAUDEAI_MCP_SERVERS": "false" }` (commit `6221110`),
  on top of the `deniedMcpServers` list Mark's own session added.
- **Web/remote sessions** — dotfiles cannot control these (confirmed in
  docs: connectors are provisioned by the claude.ai host). Mark
  disconnected the connectors in claude.ai Settings → Connectors.
  Verified live: Gmail, Google Drive, QuickBooks, and TurboTax dropped
  out of a running session when he did it.

## Facts worth keeping

- "Disconnect" in the claude.ai connector UI is the real off switch for
  web sessions. The granular permission settings (custom/blocked) limit
  which tools a connector may use, not whether it attaches and loads
  schemas. Several connectors were fully "blocked" yet still attaching.
  Mark filed a bug report about this UX.
- MCP schemas are deferred by default (tool-search): the large numbers
  under "deferred MCP tool schemas" in `/context` are a pool, not spend.
  Only tool names + server instructions load up front.

## Open items

- Evernote and GitHub connectors were still attached to the last web
  session — confirm on the settings page whether they're disconnected too
  (GitHub may be wanted for repo access).
- If a machine has a local untracked `~/.claude/settings.json`, the next
  dotfiles checkout will collide with the tracked one; merge by hand.

# Changelog

## 3.1.0 — 2026-07-24

### Fixed
- `.mcp.json` now uses the standard `mcpServers` key with a
  `${CLAUDE_PLUGIN_ROOT}`-based server path, so the MCP server registers on a
  real plugin install; it declares only the implemented `context_budget` tool.
- First-run test failure: `tests/test_pipeline.sh` now creates the state
  directory before writing to it, so the suite passes from a clean clone.
- Version alignment: `plugin.json`, `.claude-plugin/marketplace.json`, and the
  MCP server's `serverInfo` all report `3.1.0`.

### Changed
- The `memory_scratch` soft dependency is now explicit: every hook message that
  asks for a state save offers a plain-file fallback
  (`<session dir>/session-state.md`) when the tool is absent, and the
  post-compaction resume messages point at the same fallback.

## 3.1.0 (plugin logic) — earlier
- Repaired L3/L4 announcements, L4 hard-block on subagent dispatch, persistent
  L4 reminder, dynamic-threshold poisoning fix (see `plugin.json` description).

## 3.0.0
- 4-tier escalation, dynamic threshold, token-based precision, velocity
  tracking, state-save verification, warning telemetry, compaction recovery.

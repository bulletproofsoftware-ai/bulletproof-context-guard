# bulletproof-context-guard

**A Claude Code plugin that watches your context window and warns before you run out.**

`context-guard` monitors context-window usage during a Claude Code session and
escalates through four warning tiers as you approach the limit — so compaction never
takes you by surprise. It also ships an MCP server that breaks current usage into five
compartments (system prompt, conversation, tool results, file contents, working
memory) estimated from the session transcript.

## Features

- **4-tier escalation** (L1→L4) with a dynamic threshold that adapts to your session,
  token-based precision, and 3-sample velocity tracking.
- **L4 hard-block** on subagent dispatch when you're critically close to the limit,
  plus a persistent reminder.
- **Compaction recovery** — state-save verification and post-`/compact` recovery so a
  manual compaction doesn't poison the escalation threshold.
- **MCP server** (`mcp/server.py`) exposing a 5-compartment usage breakdown.

## Install

As a Claude Code plugin, point your plugin config at this repo, or clone it into your
plugins directory. The hooks self-register via `hooks/hooks.json`
(`SessionStart`, `PreToolUse`, `PreCompact`). See `plugin.json` for the tunable
thresholds (escalation distances, velocity sample count, dynamic-threshold window).

## Configuration

Thresholds and velocity are configured in `plugin.json` under `configuration`:

- `thresholds.level_{1..4}_distance` — how close (in turns/tokens) each tier fires.
- `velocity.sample_count` / `escalation_rate` — velocity tracking sensitivity.
- `dynamic_threshold` — the adaptive-threshold window and fallback.

## License

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

# Overview — bulletproof-context-guard

`bulletproof-context-guard` is a [Claude Code](https://docs.claude.com/en/docs/claude-code)
plugin that watches your context window during a session and escalates through four
warning tiers as you approach the auto-compaction boundary — so compaction never takes
you by surprise. It also ships an MCP server that breaks current usage into five
compartments estimated from the session transcript.

## What it does

There are two cooperating parts in this repo:

1. **A hook-driven context monitor** (the plugin proper). A status-line sensor reads
   Claude Code's live context telemetry on every render, computes how close the session
   is to auto-compaction, and writes a per-session escalation flag. Three lifecycle hooks
   then act on that flag — announcing tier changes, hard-blocking risky operations at the
   critical tier, and handling save/recovery around `/compact`.

2. **An MCP server** (`mcp/server.py`) exposing the `context_budget` tool, which returns
   the current usage split across five compartments (system prompt, conversation history,
   tool results, file contents, working memory), the current escalation tier, and cost.

## The four escalation tiers

The monitor measures the **distance to compaction** — the remaining-context percentage
minus a dynamically-calibrated compaction threshold — and maps it to a tier. Default tier
distances (configurable in `plugin.json`):

| Tier | Label | Fires when distance ≤ | Guidance injected |
|------|-------|----------------------|-------------------|
| L1 | LOW | 30% | Optimize usage — delegate to subagents, use `offset`/`limit` on Read, cap Grep results, summarize instead of quoting. |
| L2 | MEDIUM | 15% | Save session state via `memory_scratch`; avoid chaining steps; summarize. |
| L3 | HIGH | 7% | Save final state; complete only the current operation; suggest a new session. |
| L4 | CRITICAL | 3% | Auto-compaction imminent — hard-block subagent dispatch, persist a reminder, complete only the single most important operation. |

Each tier fires **once** per escalation (one-shot) to avoid flooding the UI. Only L4 is
persistent: it re-emits on every tool use and mechanically blocks the `Task` tool
(subagent dispatch), because a returning subagent dumps its full output into the thread
and can tip the session straight into compaction.

## Key design properties

- **Dynamic compaction threshold.** Rather than assuming a fixed compaction point, the
  sensor keeps a rolling average of the remaining-percentage at which real
  auto-compactions fired (from `compaction.log`) and calibrates the threshold to it.
  Manual/early `/compact` events (high remaining%) are filtered out and clamped so they
  cannot inflate the threshold into false escalations.

- **Token-based precision.** When the model exposes token counts, the sensor computes
  distance in basis points (hundredths of a percent) for sub-percent tier accuracy;
  otherwise it falls back to integer percentages.

- **3-sample velocity tracking.** A moving average of the burn rate (remaining-% drop per
  turn) can bump the tier up by one when consumption is accelerating, giving earlier
  warnings during rapid sessions. Spikes are smoothed by the window so a single large
  operation does not cause a false escalation.

- **Compaction recovery.** A `PreCompact` hook records the compaction event; the next
  `SessionStart` detects the `compact` source and branches on whether a
  `state_saved` marker was written — injecting a "good recovery" or a "degraded recovery"
  resume message.

- **Telemetry for downstream consumers.** Both the MCP server and the warning hook emit
  structured JSON telemetry events under `state/telemetry/` (a `context_budget` event and
  `context_warning` events) intended for consumption by an orchestrator such as the
  conductor plugin.

## Repository layout

| Path | Purpose |
|------|---------|
| `plugin.json` / `.claude-plugin/plugin.json` | Plugin manifest + tunable `configuration` (thresholds, velocity, dynamic-threshold). |
| `.claude-plugin/marketplace.json` | Marketplace descriptor. |
| `hooks/hooks.json` | Registers the `SessionStart`, `PreToolUse`, and `PreCompact` hooks. |
| `hooks/session_start.sh` | Session bootstrap + post-compaction recovery branching. |
| `hooks/warn.sh` | PreToolUse tier announcements + L4 hard-block + persistent reminder. |
| `hooks/pre_compact.sh` | PreCompact event logging (feeds the dynamic threshold). |
| `hooks/thresholds.py` | Standalone adaptive-threshold calculator (writes `telemetry/thresholds.json`). |
| `hooks/velocity.py` | Standalone velocity detector (writes `telemetry/velocity.json`). |
| `scripts/statusline.sh` | Status-line sensor — computes tier, velocity, dynamic threshold. |
| `mcp/server.py` | MCP stdio server exposing the `context_budget` tool. |
| `.mcp.json` | MCP bundle descriptor. |
| `tests/` | Bash test suites (pipeline, threshold calibration, L4 enforcement). |

## What this repo is NOT

Scoped honestly to what exists in the tree:

- There is **no slash command** shipped — the plugin is entirely hook + MCP driven. (The
  `scripts/statusline.sh` sensor must be wired as your Claude Code status line for the
  monitor to receive telemetry; see [INSTALL](INSTALL.md).)
- There is **no build step, package registry artifact, or Docker image** — it is plain
  Bash + Python 3 (stdlib only) that runs in place.
- The MCP server implements a **single** tool, `context_budget`. See
  [HOW-TO-USE](HOW-TO-USE.md) for a note on the `.mcp.json` tool list.

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).

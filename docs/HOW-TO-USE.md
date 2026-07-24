# How to Use — bulletproof-context-guard

Once [installed](INSTALL.md), the plugin runs automatically — there is nothing to invoke.
This guide explains the day-to-day behavior you will see, and how to use the MCP tool.

## The status line

With `scripts/statusline.sh` wired as your status line, every render shows:

```
<model>  <used>% used (<tokens>)/<window>  <urgency>
```

The urgency marker reflects the current tier: `◆` (L1), `◆◆` (L2), `◆◆◆` (L3),
`CRITICAL` (L4), or nothing at L0 (normal). Before any API telemetry is available the
sensor prints `⟳ --`.

## Escalation warnings

You do not trigger these — they are injected as system messages when the session crosses
into a higher tier. Each tier fires **once**:

- **L1 (≤30% to compaction)** — a nudge to optimize: delegate exploration to subagents,
  use `offset`/`limit` on Read, cap Grep with `head_limit`, summarize instead of quoting.
- **L2 (≤15%)** — save session state with `memory_scratch` (key `session-state`), stop
  chaining steps, summarize outputs.
- **L3 (≤7%)** — save final state, complete only the current operation, consider a new
  session.
- **L4 (≤3%, CRITICAL)** — auto-compaction imminent. This tier is persistent and
  **hard-blocks subagent dispatch** (the `Task` tool). If you attempt to spawn a subagent
  at L4, the hook returns a `block` decision with an explanation; state-saving tools
  (`memory_scratch`, `Bash`, `Write`, `Edit`) stay allowed so you can still save and exit
  cleanly.

The warnings deliberately instruct the assistant **not** to mention context limits to the
user unless asked — they steer behavior silently.

### Confirming a state save

L2–L4 warnings ask the assistant to confirm a save by writing a marker file:

```bash
echo saved > state/sessions/<session_id>/state_saved
```

That marker is what lets the next post-`/compact` `SessionStart` choose the **good
recovery** path (retrieve saved state and resume) over the **degraded recovery** path
(warn that the save was unconfirmed and ask the user).

## Compaction recovery

When Claude Code compacts (auto or `/compact`):

1. `pre_compact.sh` records the event. If the remaining-% is a genuine auto-compaction
   sample (≤ `max_sample_remaining`, default 30) it is appended to `compaction.log` and
   feeds the dynamic threshold; otherwise it is routed to `compaction-skipped.log` so
   manual `/compact` events do not poison the estimate.
2. On the next `SessionStart` with `source=compact`, the escalation state is preserved
   (level/notified survive), velocity samples are discarded (invalid after compaction),
   and the recovery message is chosen based on the `state_saved` marker.

## The `context_budget` MCP tool

The MCP server exposes one tool:

### `context_budget`

Returns the current context-window usage with a 5-compartment breakdown, escalation tier,
cost, and the active thresholds.

**Input** (all optional):

| Field | Type | Description |
|-------|------|-------------|
| `session_id` | string | A specific session ID. If omitted, the most recently updated session is used. |

**Output** (abridged shape):

```json
{
  "session_id": "…",
  "model": { "id": "…", "display_name": "…" },
  "summary": {
    "window_size": 200000,
    "tokens_used": 0,
    "tokens_remaining": 200000,
    "used_percentage": 0,
    "remaining_percentage": 100
  },
  "compartments": {
    "system_prompt":        { "tokens": 0, "percentage": 0.0, "description": "…" },
    "conversation_history": { "tokens": 0, "percentage": 0.0, "description": "…" },
    "tool_results":         { "tokens": 0, "percentage": 0.0, "description": "…" },
    "file_contents":        { "tokens": 0, "percentage": 0.0, "description": "…" },
    "working_memory":       { "tokens": 0, "percentage": 0.0, "description": "…" }
  },
  "escalation": { "tier": 0, "label": "NORMAL", "distance_to_compaction": 84, "action": "…" },
  "cost": { "total_cost_usd": 0, "session_duration_ms": 0 },
  "thresholds": { "level_1_distance": 30, "level_2_distance": 15, "level_3_distance": 7, "level_4_distance": 3 },
  "estimation_method": "transcript_analysis | heuristic",
  "timestamp": "…"
}
```

**How the compartments are estimated.** Claude Code only exposes aggregate token counts,
so the server estimates the split. When a `transcript_path` is available it parses the
session transcript JSONL and categorizes each message by type (system / conversation /
tool_result / file read via the Read tool), reporting `estimation_method:
"transcript_analysis"`. When no transcript is available it falls back to fixed heuristic
ratios (`estimation_method: "heuristic"`). Treat the compartment figures as **estimates**,
not exact accounting — the summary token totals are authoritative; the per-compartment
split is indicative.

Calling `context_budget` also writes a `context_budget` telemetry event to
`state/telemetry/<session_id>.json` for downstream consumers.

### A note on the advertised tool list

`.mcp.json` lists four tool names (`context_budget`, `context_compartments`,
`context_velocity`, `context_thresholds`). The MCP server (`mcp/server.py`) implements and
advertises **only `context_budget`** in its `tools/list` response — that is the single
callable tool today. The velocity and threshold data those other names imply is produced
by the standalone `hooks/velocity.py` and `hooks/thresholds.py` helpers, which write
`state/telemetry/velocity.json` and `state/telemetry/thresholds.json` respectively rather
than being served over MCP. See [ADMINISTRATOR](ADMINISTRATOR.md).

## Tuning behavior

All tunables live in `plugin.json` under `configuration` and are read live by the sensor
and hooks — no restart of the plugin is needed, just start a fresh session:

- `thresholds.level_{1..4}_distance` — how close (in remaining-%) each tier fires.
- `velocity.sample_count` / `velocity.escalation_rate` — velocity sensitivity.
- `dynamic_threshold.fallback` / `.max_sample_remaining` / `.log_entries` — the adaptive
  compaction-threshold window and its guardrails.

The standalone Python helpers additionally honor environment variables
(`CONTEXT_VELOCITY_THRESHOLD`, `CONTEXT_HARD_FLOOR`, `CONTEXT_TIER_*`, etc.) documented in
[ADMINISTRATOR](ADMINISTRATOR.md).

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).

# Administrator Guide — bulletproof-context-guard

This guide covers operational details: configuration surface, state files, telemetry,
environment overrides, testing, and troubleshooting.

## Configuration surface (`plugin.json`)

All tunables are under the `configuration` key and are read live (per session) by
`scripts/statusline.sh`, `hooks/warn.sh`, and `hooks/pre_compact.sh` via `jq`.

```json
{
  "configuration": {
    "dynamic_threshold": { "log_entries": 10, "fallback": 16, "max_sample_remaining": 30 },
    "thresholds":        { "level_1_distance": 30, "level_2_distance": 15, "level_3_distance": 7, "level_4_distance": 3 },
    "velocity":          { "sample_count": 3, "escalation_rate": 5 }
  }
}
```

| Key | Default | Meaning |
|-----|---------|---------|
| `thresholds.level_1_distance` | 30 | Distance-to-compaction (%) at which L1 fires. |
| `thresholds.level_2_distance` | 15 | L2 threshold. |
| `thresholds.level_3_distance` | 7 | L3 threshold. |
| `thresholds.level_4_distance` | 3 | L4 (CRITICAL) threshold. |
| `velocity.sample_count` | 3 | Moving-average window for burn-rate detection (used by the standalone helpers; the sensor uses a 3-sample window). |
| `velocity.escalation_rate` | 5 | Burn rate (remaining-% drop/turn) that bumps the tier up by one. |
| `dynamic_threshold.log_entries` | 10 | How many recent `compaction.log` samples are averaged into the threshold. |
| `dynamic_threshold.fallback` | 16 | Threshold used when there is no usable `compaction.log` data. |
| `dynamic_threshold.max_sample_remaining` | 30 | Samples with remaining-% above this are rejected (and the computed threshold is clamped to it). Rejects manual/early `/compact` events. |

## The dynamic compaction threshold

The compaction point is not assumed; it is learned. `pre_compact.sh` appends
`remaining=<pct>` to `state/compaction.log` **only** when the sample is a plausible
auto-compaction (`remaining <= max_sample_remaining`). `statusline.sh` averages the last
`log_entries` of those samples and clamps the result to `max_sample_remaining`. This is
the fix for the "poisoning" failure mode: a manual `/compact` at, say, 94% remaining would
otherwise drag the threshold up and cause spurious L3/L4 escalations at high headroom.
Those events are instead routed to `state/compaction-skipped.log` for visibility.

`tests/test_threshold_calibration.sh` proves this: a polluted log cannot inflate the
threshold, while genuine near-compaction states still escalate.

## State files (all under `state/`, git-ignored)

| Path | Written by | Purpose |
|------|-----------|---------|
| `state/sessions/<id>/raw` | statusline | Latest raw hook JSON; read by `warn.sh`/`pre_compact.sh`. |
| `state/sessions/<id>/level` | statusline | One-shot flag: a new tier to announce. Consumed+deleted by `warn.sh`. |
| `state/sessions/<id>/notified` | statusline | High-water mark of the highest tier announced. |
| `state/sessions/<id>/velocity` | statusline | Up to 3 recent remaining-% samples for burn-rate. |
| `state/sessions/<id>/state_saved` | assistant (via `echo saved > …`) | Confirms a state save; drives good vs. degraded post-compaction recovery. |
| `state/compaction.log` | pre_compact | Auto-compaction samples feeding the dynamic threshold. |
| `state/compaction-skipped.log` | pre_compact | Manual/early `/compact` events (audit only, non-poisoning). |
| `state/warnings.log` | warn | Every warning: `[ts] [session] tier=N trigger=… model=…`. |
| `state/telemetry/<id>.json` | MCP server | `context_budget` telemetry event. |
| `state/telemetry/<id>-warning.json` | warn | `context_warning` telemetry event. |
| `state/telemetry/velocity.json` | `velocity.py` | Standalone velocity computation output. |
| `state/telemetry/thresholds.json` | `thresholds.py` | Standalone adaptive-threshold output. |

Session directories older than 24h are auto-pruned on `SessionStart`. The whole `state/`
tree is safe to delete; it is rebuilt on the next session.

## Standalone Python helpers

`hooks/velocity.py` and `hooks/thresholds.py` are **not** wired into `hooks.json` — they
are standalone utilities that read `state/consumption.log` (tab-separated
`<ISO-ts>\t<tokens_consumed>\t<tool_name>`, oldest first) and write telemetry. They are
the source of the `context_velocity`/`context_thresholds` data implied by `.mcp.json`.
Run them directly if you maintain a `consumption.log`:

```bash
python3 hooks/velocity.py     # -> state/telemetry/velocity.json
python3 hooks/thresholds.py   # -> state/telemetry/thresholds.json
```

Both exit 0 always and never block a caller. Environment overrides:

| Variable | Default | Used by | Effect |
|----------|---------|---------|--------|
| `CONTEXT_VELOCITY_WINDOW` | 3 | velocity.py | Samples in the burn-rate window. |
| `CONTEXT_VELOCITY_THRESHOLD` | 5.0 | velocity.py | tokens/op above which `early_escalate=true`. |
| `CONTEXT_THRESHOLD_WINDOW` | 10 | thresholds.py | Rolling window for adaptive tiers. |
| `CONTEXT_HARD_FLOOR` | 16 | thresholds.py | Absolute floor the Warning tier can never drop below. |
| `CONTEXT_TIER_WARNING` / `_ADVISORY` / `_YELLOW` / `_CRITICAL` | 30 / 15 / 7 / 3 | thresholds.py | Default tier boundaries before adaptive scaling. |

## MCP tool inventory (real)

The MCP server (`mcp/server.py`) advertises and dispatches exactly **one** tool:

| Tool | Description |
|------|-------------|
| `context_budget` | 5-compartment usage breakdown + escalation tier + cost + thresholds. Optional `session_id`. |

`.mcp.json` lists four names (`context_budget`, `context_compartments`, `context_velocity`,
`context_thresholds`), but only `context_budget` is implemented in the server's
`tools/list`. **Administrator note / known gap:** the extra three names in `.mcp.json` do
not resolve to callable MCP tools — their data is produced by the standalone helpers
above. Either trim `.mcp.json` to the single implemented tool, or implement the additional
tools in `server.py`, depending on desired direction. This is flagged for human judgment,
not silently "fixed", to avoid changing published behavior.

## Testing

```bash
bash tests/run_tests.sh
```

Three suites run:

- `test_pipeline.sh` — 15 end-to-end lifecycle assertions (all tiers, velocity, logging,
  compaction, recovery, token precision). Prints `Results: 15/15 passed, 0 failed`.
- `test_threshold_calibration.sh` — proves the dynamic-threshold poisoning fix.
- `test_warn_l4.sh` — 8 assertions for the L3/L4 announcement repair and L4 enforcement.

**Known test-runner quirk:** `test_pipeline.sh` reports all 15 assertions passing on its
own results line, but the runner may still mark the *file* as failed. This is a cleanup
exit-code artifact in that script's `trap`, not a functional failure — verify against the
`Results: 15/15 passed` line, which is authoritative. (Left as-is; fixing the trap is out
of scope for this documentation pass and would change shipped test code.)

CI (`.github/workflows/ci.yml`) runs `shellcheck -S error` over all `*.sh` files in
warn-only mode on push/PR to `main`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Status line shows `⟳ --` and stays there | No context telemetry yet, or `jq` missing. | Confirm `jq` is installed; telemetry appears after the first API call. |
| No tier warnings ever fire | Status-line sensor not wired. | Register `scripts/statusline.sh` as the Claude Code status line (see INSTALL). |
| Spurious L3/L4 at high headroom | `compaction.log` poisoned by manual `/compact` samples. | Confirm `max_sample_remaining` is set; inspect `compaction-skipped.log`; delete `state/compaction.log` to reset. |
| `context_budget` returns `No active session found` | No `state/sessions/*/raw` exists yet. | Start a session with the status line wired so `raw` is written. |
| Post-compaction resume shows "degraded" warning | `state_saved` marker was never written. | Ensure the assistant runs `echo saved > state/sessions/<id>/state_saved` after saving. |

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).

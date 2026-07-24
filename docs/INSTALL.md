# Install — bulletproof-context-guard

`bulletproof-context-guard` is a Claude Code plugin. It has **no build step** and **no
external runtime dependencies** beyond what a normal Claude Code + shell environment
already has.

## Requirements

| Requirement | Why |
|-------------|-----|
| [Claude Code](https://docs.claude.com/en/docs/claude-code) | Host for the plugin hooks and MCP server. |
| `bash` | All three lifecycle hooks and the status-line sensor are Bash. |
| `jq` | The hooks parse Claude Code's JSON hook input with `jq`. If `jq` is missing the sensor degrades to `⟳ --` and the hooks fall back to safe defaults. |
| Python **≥ 3.10** | Runs `mcp/server.py` and the standalone `hooks/thresholds.py` / `hooks/velocity.py` helpers. Standard library only — no `pip install` required. |

Verify:

```bash
bash --version
jq --version
python3 --version   # must be 3.10 or newer
```

## Install as a Claude Code plugin

Point your Claude Code plugin configuration at this repository, or clone it into your
plugins directory:

```bash
git clone https://github.com/bulletproofsoftware-ai/bulletproof-context-guard.git
```

The hooks self-register through `hooks/hooks.json`, which Claude Code discovers via the
`"hooks": "./hooks/hooks.json"` field in `plugin.json`. Three events are wired:

- `SessionStart` → `hooks/session_start.sh`
- `PreToolUse` → `hooks/warn.sh`
- `PreCompact` → `hooks/pre_compact.sh`

`${CLAUDE_PLUGIN_ROOT}` in `hooks/hooks.json` is expanded by Claude Code to the plugin's
install path, so no manual path editing is needed.

## Wire the status-line sensor (required)

The escalation logic is driven by `scripts/statusline.sh`, which must be registered as
your Claude Code **status line** so it receives the live context telemetry on every
render. In your Claude Code settings:

```json
{
  "statusLine": {
    "type": "command",
    "command": "<plugin-path>/scripts/statusline.sh"
  }
}
```

Without the status-line wiring the hooks still run, but the escalation `level`/`notified`
flags are never written, so no tier warnings fire. The sensor also writes each session's
raw telemetry to `state/sessions/<id>/raw`, which `warn.sh` and `pre_compact.sh` read.

## Register the MCP server (optional)

The `context_budget` tool is served by `mcp/server.py` over stdio. Add it to your MCP
configuration (the repo ships a bundle descriptor at `.mcp.json`):

```json
{
  "mcpServers": {
    "context-budget": {
      "command": "python3",
      "args": ["mcp/server.py"]
    }
  }
}
```

Run `args` relative to the plugin root, or use an absolute path to `mcp/server.py`.

## State directory

At runtime the plugin creates a `state/` directory under the plugin root:

- `state/sessions/<session_id>/` — per-session `raw` telemetry, `level`, `notified`,
  `velocity`, `state_saved` flags.
- `state/telemetry/` — structured JSON events for downstream consumers.
- `state/compaction.log` — auto-compaction samples feeding the dynamic threshold.
- `state/compaction-skipped.log` — manual/early `/compact` events (audit only).
- `state/warnings.log` — every warning fired, with tier + trigger.

All of `state/` is git-ignored (see `.gitignore`) and is safe to delete — it is rebuilt
on the next session. Stale per-session directories older than 24h are auto-pruned on
`SessionStart`.

## Verify the install

Run the bundled test suites (no Claude Code session required — they drive the hooks
directly via their state-file contract):

```bash
bash tests/run_tests.sh
```

Expected: the `test_warn_l4.sh` (8 assertions) and `test_threshold_calibration.sh` suites
pass, and `test_pipeline.sh` reports **15/15 passed** on its own line. See
[ADMINISTRATOR](ADMINISTRATOR.md) for a note on the test-runner exit code.

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).

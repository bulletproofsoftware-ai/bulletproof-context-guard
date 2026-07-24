# Bulletproof-Context-Guard: Comprehensive System Briefing

## Executive Summary

The **bulletproof-context-guard** is a specialized plugin for Claude Code designed to monitor context-window usage and provide a tiered escalation system as sessions approach auto-compaction boundaries. By integrating lifecycle hooks, a status-line sensor, and an Model Context Protocol (MCP) server, the system ensures that context limits do not take the user by surprise. Key features include a dynamic compaction threshold that learns from actual session behavior, token-based precision for high accuracy, and a hard-block mechanism on resource-intensive subagent dispatching at critical levels. The project maintains an "excellent" security posture with a Code Hardener score of 946/1000 and zero critical or high-severity vulnerabilities.

---

## Technical Architecture

The system is architected as a lightweight, dependency-free suite of Bash scripts and Python utilities that operate within the host Claude Code environment. It consists of three primary components:

### 1. Hook-Driven Context Monitor
The monitor utilizes Claude Code's lifecycle hooks to manage session states. These hooks are registered via `hooks/hooks.json` and include:
*   **SessionStart (`hooks/session_start.sh`):** Handles session bootstrap and determines the appropriate recovery path (good vs. degraded) after a compaction event.
*   **PreToolUse (`hooks/warn.sh`):** Manages tier announcements, enforces the L4 hard-block on specific tools, and provides persistent reminders.
*   **PreCompact (`hooks/pre_compact.sh`):** Logs compaction events to feed the dynamic threshold and filters manual compaction events to prevent data "poisoning."

### 2. Status-Line Sensor
The `scripts/statusline.sh` sensor is the core engine of the plugin. It must be registered as the Claude Code status line to receive live telemetry. It calculates the "distance to compaction," tracks burn-rate velocity, and writes escalation flags to the session state.

### 3. MCP Server
The server (`mcp/server.py`) exposes the `context_budget` tool. This tool provides a five-compartment breakdown of usage (system prompt, conversation history, tool results, file contents, and working memory) estimated from the session transcript.

### 4. Standalone Python Helpers
Two standalone utilities, `hooks/velocity.py` and `hooks/thresholds.py`, generate telemetry for burn rates and adaptive tiers. These are not wired directly into hooks but function as auxiliary data producers.

---

## The Four Escalation Tiers

The system maps the "distance to compaction"—calculated as the remaining context percentage minus the dynamic threshold—into four distinct tiers.

| Tier | Label | Distance Threshold | Operational Guidance & Behavior |
| :--- | :--- | :--- | :--- |
| **L1** | **LOW** | ≤ 30% | Nudges the assistant to optimize usage (e.g., use `head_limit` on Grep, summarize instead of quoting). |
| **L2** | **MEDIUM** | ≤ 15% | Instructs the assistant to save state via `memory_scratch` and stop chaining steps. |
| **L3** | **HIGH** | ≤ 7% | Advises completing only the current operation and suggests starting a new session. |
| **L4** | **CRITICAL** | ≤ 3% | **Hard-blocks subagent dispatch (`Task` tool).** Requires a persistent reminder; auto-compaction is imminent. |

**Note on L4 Enforcement:** While subagent dispatch is blocked to prevent massive context dumps, state-saving tools (Bash, Write, Edit, `memory_scratch`) remain allowed so the assistant can exit cleanly.

---

## Configuration Surface (plugin.json)

All operational tunables are located under the `configuration` key in `plugin.json`. These values are read live and do not require a plugin restart, though they apply to fresh sessions.

| Key | Default | Meaning |
| :--- | :--- | :--- |
| `thresholds.level_1_distance` | 30 | Distance (%) at which L1 fires. |
| `thresholds.level_2_distance` | 15 | Distance (%) at which L2 fires. |
| `thresholds.level_3_distance` | 7 | Distance (%) at which L3 fires. |
| `thresholds.level_4_distance` | 3 | Critical (L4) threshold. |
| `velocity.sample_count` | 3 | Moving-average window for burn-rate detection. |
| `velocity.escalation_rate` | 5 | Burn rate (% drop/turn) that increases the tier by one. |
| `dynamic_threshold.log_entries` | 10 | Recent samples averaged into the threshold. |
| `dynamic_threshold.fallback` | 16 | Threshold used if no log data exists. |
| `dynamic_threshold.max_sample_remaining` | 30 | Upper bound for valid auto-compaction samples. |

---

## Security and Compliance

The system underwent a comprehensive security audit using the **Code Hardener** scanner (standard profile).

*   **Security Score:** 946 / 1000 (Excellent).
*   **Vulnerability Count:** 0 Critical / 0 High.
*   **Secrets Scan:** Passed (0 secrets found across 21 files).
*   **Dependency Risks:** 0 CVEs (The project has no third-party library dependencies).
*   **Licensing:** Apache-2.0.

### Residual Findings (Low Risk)
The scan identified 7 medium-severity findings related to unused imports and locals in `mcp/server.py`. These were intentionally left in place as near-term scaffolding for the telemetry estimator. Additionally, `actions/checkout@v4` was pinned to an immutable commit SHA to improve supply-chain provenance.

---

## Key Insights and Analysis

### Dynamic Compaction Thresholding
The plugin solves the "poisoning" failure mode associated with manual compactions. If a user manually runs `/compact` while context is still high (e.g., 94% remaining), a naive system might assume that 94% is the compaction limit. The `bulletproof-context-guard` filters these samples; only samples where `remaining <= max_sample_remaining` (default 30%) are logged to `state/compaction.log`. This ensures the escalation tiers remain accurate to real auto-compaction events.

### Burn-Rate Velocity Tracking
The system uses a 3-sample moving average to detect consumption spikes. If the remaining context drops too quickly (exceeding the `escalation_rate`), the system can preemptively bump the escalation tier, providing earlier warnings during high-velocity sessions.

### Recovery Logic
The system differentiates between "good" and "degraded" recovery. If the assistant confirms a state save by writing a marker to `state/sessions/<id>/state_saved` before compaction, the subsequent session start will recognize the saved state and resume cleanly. If no marker is found, it warns the user that the recovery may be incomplete.

---

## Important Quotes

> **On the L4 Block:** "L4 (CRITICAL)... hard-blocks subagent dispatch (the Task tool). If you attempt to spawn a subagent at L4, the hook returns a block decision with an explanation; state-saving tools (memory_scratch, Bash, Write, Edit) stay allowed so you can still save and exit cleanly."

> **On User Experience:** "The warnings deliberately instruct the assistant not to mention context limits to the user unless asked — they steer behavior silently."

> **On Threshold Integrity:** "A polluted log cannot inflate the threshold, while genuine near-compaction states still escalate. This is the fix for the 'poisoning' failure mode."

---

## Actionable Insights

*   **Mandatory Wiring:** The escalation logic is dependent on `scripts/statusline.sh`. If this is not registered as the Claude Code status line, the level/notified flags will never be written, and no warnings will fire.
*   **Tooling Discrepancy:** Note that `.mcp.json` advertises four tools, but only `context_budget` is currently implemented in the server. Administrators should either implement the missing tools in `server.py` or trim `.mcp.json` to avoid client-side resolution errors.
*   **State Management:** The `state/` directory is safe to delete at any time for a reset, as it is rebuilt on the next session. Stale session directories older than 24 hours are auto-pruned.
*   **Testing Protocol:** When verifying installations, prioritize the `Results: 15/15 passed` line in `test_pipeline.sh`. The test runner may report a file failure due to cleanup exit-code artifacts, but the results line remains the authoritative measure of functional success.
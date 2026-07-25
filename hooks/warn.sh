#!/bin/bash
# Context Guard v3.1 — PreToolUse Warnings + L4 enforcement
# 4-tier actionable warnings calibrated to auto-compaction threshold.
# L1-L3 fire ONCE per escalation. L4 (EMERGENCY) additionally:
#   - HARD-BLOCKS subagent dispatch (Task tool) — a returning subagent dumps its
#     full output into this thread and tips context into compaction.
#   - Emits a persistent reminder on every other tool use.
# v3.1 fix: the NEW-ESCALATION announcement now runs BEFORE the silence gate, so
# L3/L4 are no longer swallowed (the v3.0 regression: warnings.log held only
# tier=1/tier=2 because `notified >= 3` returned early before the level flag was read).
# All warnings logged to warnings.log with tier and trigger type.
# Fast path: no session dir or no flag file = exit immediately (<3ms).

# ── Path resolution ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${PLUGIN_ROOT}/state"

# ── Warning logger + telemetry emitter ──
log_warning() {
    local tier="$1"
    local trigger="$2"
    local session="$3"
    local model="$4"
    printf '[%s] [%s] tier=%s trigger=%s model=%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$session" "$tier" "$trigger" "$model" \
        >> "${STATE_DIR}/warnings.log"

    # Emit structured telemetry event for conductor consumption
    local TELEMETRY_DIR="${STATE_DIR}/telemetry"
    mkdir -p "$TELEMETRY_DIR"
    printf '{"type":"context_warning","session_id":"%s","timestamp":"%s","tier":%s,"trigger":"%s","model":"%s"}\n' \
        "$session" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$tier" "$trigger" "$model" \
        > "${TELEMETRY_DIR}/${session}-warning.json"
}

# ── Extract session_id from stdin ──
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
SESSION_ID=${SESSION_ID:-unknown}
SESSION_ID=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
SESSION_DIR="${STATE_DIR}/sessions/${SESSION_ID}"

# ── Tool being gated (used by the L4 hard-block on subagent dispatch) ──
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)

# ── Read model and window info from last statusline raw dump ──
MODEL_DISPLAY="unknown"
WINDOW_LABEL="unknown"
if [ -f "${SESSION_DIR}/raw" ]; then
    MODEL_DISPLAY=$(jq -r '.model.display_name // "unknown"' < "${SESSION_DIR}/raw" 2>/dev/null)
    WINDOW_SIZE=$(jq -r '.context_window.context_window_size // -1' < "${SESSION_DIR}/raw" 2>/dev/null)
    if [ "$WINDOW_SIZE" != "-1" ] && [ "$WINDOW_SIZE" -gt 0 ] 2>/dev/null; then
        if [ "$WINDOW_SIZE" -ge 1000000 ]; then
            WINDOW_LABEL="$((WINDOW_SIZE / 1000000))M"
        elif [ "$WINDOW_SIZE" -ge 1000 ]; then
            WINDOW_LABEL="$((WINDOW_SIZE / 1000))K"
        else
            WINDOW_LABEL="${WINDOW_SIZE}"
        fi
    fi
fi
MODEL_CTX="${MODEL_DISPLAY} (${WINDOW_LABEL} window)"

# If session dir doesn't exist yet (first tool use before statusline runs), allow
[ ! -d "$SESSION_DIR" ] && echo '{}' && exit 0

# ── Current escalation high-water mark (set by statusline on each new tier) ──
CURRENT_NOTIFIED=0
[ -f "${SESSION_DIR}/notified" ] && CURRENT_NOTIFIED=$(cat "${SESSION_DIR}/notified" 2>/dev/null)
CURRENT_NOTIFIED=${CURRENT_NOTIFIED:-0}

# ── A. NEW-ESCALATION announcement (one-shot per tier) ──
# statusline writes a `level` flag whenever context crosses into a higher tier.
# This is consumed FIRST — before any persistent/silence gate — so the L3/L4
# announcements are never swallowed.
if [ -f "${SESSION_DIR}/level" ]; then
    LEVEL=$(cat "${SESSION_DIR}/level" 2>/dev/null)
    rm -f "${SESSION_DIR}/level"
    case "$LEVEL" in
        1)
            log_warning 1 "new-escalation" "$SESSION_ID" "$MODEL_CTX"
            printf '{"systemMessage":"CONTEXT GUARD [≤30%% to compaction] [%s]: Approaching compaction zone. Optimize remaining usage: (1) Delegate research and exploration to subagents via Task tool — use haiku model for simple lookups. (2) Use offset/limit params on Read tool for large files. (3) Use head_limit on Grep to cap results. (4) Summarize findings instead of quoting full output. Continue working normally but be efficient. Do NOT mention context limits to the user."}\n' "$MODEL_CTX"
            ;;
        2)
            log_warning 2 "new-escalation" "$SESSION_ID" "$MODEL_CTX"
            printf '{"systemMessage":"CONTEXT GUARD [≤15%% to compaction] [%s]: Getting close. All Level 1 strategies apply PLUS: (1) SILENTLY save session state via memory_scratch (key: '\''session-state'\'', content: current task, key findings, next steps, important paths/values) — or, if the memory_scratch tool is not available, Write the same state to %s/session-state.md. (2) After saving, confirm by running: echo saved > %s/state_saved (3) Finish your current step then pause for user input — do NOT chain multiple steps. (4) Summarize, do not quote. (5) Keep responses to essential information only. Do NOT mention context limits to the user."}\n' "$MODEL_CTX" "$SESSION_DIR" "$SESSION_DIR"
            ;;
        3)
            log_warning 3 "new-escalation" "$SESSION_ID" "$MODEL_CTX"
            printf '{"systemMessage":"CONTEXT GUARD [≤7%% to compaction] [%s]: Context nearly full. SILENTLY save final state via memory_scratch (key: '\''session-state'\'', content: task, all findings, exact resume steps) — or, if memory_scratch is not available, Write it to %s/session-state.md. After saving, confirm by running: echo saved > %s/state_saved. Complete only your current operation, then stop. Suggest continuing in a new session if more work remains. Do NOT mention context limits to the user."}\n' "$MODEL_CTX" "$SESSION_DIR" "$SESSION_DIR"
            ;;
        4)
            log_warning 4 "new-escalation" "$SESSION_ID" "$MODEL_CTX"
            printf '{"systemMessage":"CONTEXT GUARD [≤3%% to compaction — CRITICAL] [%s]: Auto-compaction is IMMINENT. Complete only the single most important operation. Do NOT start anything new. If you have NOT already saved state, do it NOW: memory_scratch(operation='\''write'\'', key='\''session-state'\'', content=<your state>) — or, if memory_scratch is not available, Write the state to %s/session-state.md. After saving, confirm by running: echo saved > %s/state_saved. Do NOT mention context limits to the user."}\n' "$MODEL_CTX" "$SESSION_DIR" "$SESSION_DIR"
            ;;
        *)
            echo '{}'
            ;;
    esac
    exit 0
fi

# ── B. No new escalation pending. L4 EMERGENCY persistent enforcement. ──
# Persistent behavior is scoped to L4 ONLY — the flooding concern that justifies
# silence at L1-L3 does not apply to the single most critical tier.
if [ "$CURRENT_NOTIFIED" -ge 4 ]; then
    # Hard-block subagent dispatch: a returning subagent dumps its full output
    # into THIS thread and tips context into auto-compaction. This mechanically
    # enforces the conductor-context-management "L3/L4: do NOT spawn subagent"
    # rule. State-saving tools (memory_scratch, Bash, Write, Edit) stay allowed.
    if [ "$TOOL_NAME" = "Task" ]; then
        log_warning 4 "blocked-task-dispatch" "$SESSION_ID" "$MODEL_CTX"
        printf '{"decision":"block","reason":"CONTEXT GUARD [L4 EMERGENCY — %s]: Subagent dispatch BLOCKED. Context is within ~3%% of auto-compaction; a new subagent would return its full output into this thread and trigger compaction. Instead: (1) SILENTLY save state via memory_scratch (key: session-state) if not already saved — or Write it to %s/session-state.md when memory_scratch is unavailable, (2) confirm with: echo saved > %s/state_saved, (3) finish only the current operation, (4) tell the user to continue in a fresh session. Do NOT mention context limits unless asked."}\n' "$MODEL_CTX" "$SESSION_DIR" "$SESSION_DIR"
        exit 0
    fi
    # Persistent reminder on every other tool use at L4.
    log_warning 4 "persistent-reminder" "$SESSION_ID" "$MODEL_CTX"
    printf '{"systemMessage":"CONTEXT GUARD [L4 EMERGENCY — %s]: Auto-compaction imminent. Do NOT start new work or dispatch subagents. If state is not already saved, save it NOW via memory_scratch (or Write it to %s/session-state.md when memory_scratch is unavailable) then run: echo saved > %s/state_saved. Complete only the current operation, then stop. Do NOT mention context limits to the user."}\n' "$MODEL_CTX" "$SESSION_DIR" "$SESSION_DIR"
    exit 0
fi

# ── C. L1-L3 with no pending escalation → stay quiet (avoid UI flood). ──
echo '{}'
exit 0

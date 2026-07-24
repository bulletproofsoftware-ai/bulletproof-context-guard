#!/bin/bash
# Context Guard v3.0 — PreCompact Handler
# Reads last remaining_percentage from statusline's raw JSON dump,
# logs remaining=NN to compaction.log, then cleans per-session state.

# ── Path resolution ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${PLUGIN_ROOT}/state"

# ── Max remaining% that still counts as a real AUTO-compaction sample ──
# Manual/early /compact events (high remaining) must NOT feed the dynamic
# threshold or they inflate it and cause false escalations (see statusline.sh §2a).
CONFIG="${PLUGIN_ROOT}/plugin.json"
MAX_SAMPLE=30
if [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1; then
    CFG_MAX=$(jq -r '.configuration.dynamic_threshold.max_sample_remaining // 30' "$CONFIG" 2>/dev/null)
    [ -n "$CFG_MAX" ] && [ "$CFG_MAX" -gt 0 ] 2>/dev/null && MAX_SAMPLE=$CFG_MAX
fi

# ── Extract session_id for per-session state isolation ──
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
SESSION_ID=${SESSION_ID:-unknown}
SESSION_ID=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
SESSION_DIR="${STATE_DIR}/sessions/${SESSION_ID}"

# ── Read last remaining_percentage, model, and window size from statusline's raw dump ──
REMAINING="unknown"
MODEL_DISPLAY="unknown"
WINDOW_SIZE="unknown"
if [ -f "${SESSION_DIR}/raw" ]; then
    REMAINING=$(jq -r '.context_window.remaining_percentage // "unknown"' < "${SESSION_DIR}/raw" 2>/dev/null)
    REMAINING=${REMAINING:-unknown}
    MODEL_DISPLAY=$(jq -r '.model.display_name // "unknown"' < "${SESSION_DIR}/raw" 2>/dev/null)
    MODEL_DISPLAY=${MODEL_DISPLAY:-unknown}
    RAW_WINDOW=$(jq -r '.context_window.context_window_size // -1' < "${SESSION_DIR}/raw" 2>/dev/null)
    if [ "$RAW_WINDOW" != "-1" ] && [ "$RAW_WINDOW" -gt 0 ] 2>/dev/null; then
        if [ "$RAW_WINDOW" -ge 1000000 ]; then
            WINDOW_SIZE="$((RAW_WINDOW / 1000000))M"
        elif [ "$RAW_WINDOW" -ge 1000 ]; then
            WINDOW_SIZE="$((RAW_WINDOW / 1000))K"
        else
            WINDOW_SIZE="${RAW_WINDOW}"
        fi
    fi
fi

# ── Clean this session's state files ──
rm -f "${SESSION_DIR}/level"
rm -f "${SESSION_DIR}/notified"
rm -f "${SESSION_DIR}/velocity"

# ── Log compaction event ──
# Only real auto-compaction samples (remaining<=MAX_SAMPLE) feed the dynamic
# threshold. Manual/early /compact events (high or unknown remaining) are routed
# to an audit log so they stay visible without poisoning the estimate.
LINE="[$(date '+%Y-%m-%d %H:%M:%S')] [${SESSION_ID}] remaining=${REMAINING} model=${MODEL_DISPLAY} window=${WINDOW_SIZE}"
if [ "$REMAINING" != "unknown" ] && [ "$REMAINING" -ge 0 ] 2>/dev/null && [ "$REMAINING" -le "$MAX_SAMPLE" ] 2>/dev/null; then
    echo "$LINE" >> "${STATE_DIR}/compaction.log"
else
    echo "$LINE reason=non-auto-compaction" >> "${STATE_DIR}/compaction-skipped.log"
fi

exit 0

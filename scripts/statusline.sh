#!/bin/bash
# Context Guard v3.0 — Status Line Sensor
# Dynamic compaction threshold from historical data, token-based precision
# via basis points, 3-sample moving average velocity tracking.
# Performance budget: <50ms total.

# ── Path resolution ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${PLUGIN_ROOT}/state"
mkdir -p "$STATE_DIR"

# ── Read thresholds from plugin.json (with fallback defaults) ──
CONFIG="${PLUGIN_ROOT}/plugin.json"
if [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1; then
    L1_DIST=$(jq -r '.configuration.thresholds.level_1_distance // 30' "$CONFIG")
    L2_DIST=$(jq -r '.configuration.thresholds.level_2_distance // 15' "$CONFIG")
    L3_DIST=$(jq -r '.configuration.thresholds.level_3_distance // 7' "$CONFIG")
    L4_DIST=$(jq -r '.configuration.thresholds.level_4_distance // 3' "$CONFIG")
    FALLBACK_THRESH=$(jq -r '.configuration.dynamic_threshold.fallback // 16' "$CONFIG")
    VELOCITY_RATE=$(jq -r '.configuration.velocity.escalation_rate // 5' "$CONFIG")
    LOG_ENTRIES=$(jq -r '.configuration.dynamic_threshold.log_entries // 10' "$CONFIG")
    MAX_SAMPLE=$(jq -r '.configuration.dynamic_threshold.max_sample_remaining // 30' "$CONFIG")
else
    L1_DIST=30; L2_DIST=15; L3_DIST=7; L4_DIST=3; FALLBACK_THRESH=16; VELOCITY_RATE=5; LOG_ENTRIES=10; MAX_SAMPLE=30
fi
# Basis point equivalents (distance * 100)
L1_BP=$((L1_DIST * 100)); L2_BP=$((L2_DIST * 100)); L3_BP=$((L3_DIST * 100)); L4_BP=$((L4_DIST * 100))

INPUT=$(cat)

# ── Extract session_id for per-session state isolation ──
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
SESSION_ID=${SESSION_ID:-unknown}
SESSION_ID=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
SESSION_DIR="${STATE_DIR}/sessions/${SESSION_ID}"
mkdir -p "$SESSION_DIR"

# Save raw input for debugging and pre_compact.sh consumption (per-session)
echo "$INPUT" > "${SESSION_DIR}/raw"

# ── Extract model info ──
MODEL_ID=$(echo "$INPUT" | jq -r '.model.id // "unknown"' 2>/dev/null)
MODEL_DISPLAY=$(echo "$INPUT" | jq -r '.model.display_name // "unknown"' 2>/dev/null)

# ── Extract percentages and token counts via jq ──
REMAINING=$(echo "$INPUT" | jq -r '.context_window.remaining_percentage // -1' 2>/dev/null)
USED=$(echo "$INPUT" | jq -r '.context_window.used_percentage // -1' 2>/dev/null)
TOTAL_INPUT=$(echo "$INPUT" | jq -r '.context_window.total_input_tokens // -1' 2>/dev/null)
TOTAL_OUTPUT=$(echo "$INPUT" | jq -r '.context_window.total_output_tokens // -1' 2>/dev/null)
WINDOW_SIZE=$(echo "$INPUT" | jq -r '.context_window.context_window_size // -1' 2>/dev/null)

# ── Format window size for display (e.g. 200K, 1M) ──
WINDOW_LABEL=""
if [ "$WINDOW_SIZE" != "-1" ] && [ "$WINDOW_SIZE" -gt 0 ] 2>/dev/null; then
    if [ "$WINDOW_SIZE" -ge 1000000 ]; then
        WINDOW_LABEL="$((WINDOW_SIZE / 1000000))M"
    elif [ "$WINDOW_SIZE" -ge 1000 ]; then
        WINDOW_LABEL="$((WINDOW_SIZE / 1000))K"
    else
        WINDOW_LABEL="${WINDOW_SIZE}"
    fi
fi

# ── Short model label (strip "Claude " prefix, compact) ──
MODEL_LABEL=""
case "$MODEL_DISPLAY" in
    "unknown"|"") MODEL_LABEL="" ;;
    *) MODEL_LABEL="$MODEL_DISPLAY" ;;
esac

# Fallback: compute used from remaining if used_percentage missing
if [ "$REMAINING" != "-1" ] && [ "$USED" = "-1" ]; then
    USED=$((100 - REMAINING))
fi

# No valid data yet (session just started, no API calls yet)
if [ "$REMAINING" = "-1" ] || [ -z "$REMAINING" ]; then
    echo "⟳ --"
    exit 0
fi

# ── 2a. Dynamic compaction threshold ──
# Running average of last N remaining= entries from compaction.log. The
# threshold represents the remaining% at which AUTO-compaction fires, so it must
# be LOW. Samples are filtered to remaining<=MAX_SAMPLE and the result is clamped
# to MAX_SAMPLE — this rejects manual/early /compact events (e.g. remaining=94)
# that would otherwise inflate the threshold and cause false L3/L4 escalations at
# high headroom. Falls back to 16 if no usable data.
COMPACT_THRESHOLD=$FALLBACK_THRESH
COMPACTION_LOG="${STATE_DIR}/compaction.log"
if [ -f "$COMPACTION_LOG" ]; then
    DYNAMIC_THRESH=$(tail -${LOG_ENTRIES} "$COMPACTION_LOG" | awk -F'remaining=' -v max="$MAX_SAMPLE" '{if(NF>1){v=int($2); if(v>0 && v<=max){sum+=v; n++}}} END{if(n>0) print int(sum/n); else print 0}' | tail -1)
    if [ -n "$DYNAMIC_THRESH" ] && [ "$DYNAMIC_THRESH" -gt 0 ] 2>/dev/null; then
        COMPACT_THRESHOLD=$DYNAMIC_THRESH
    fi
fi
# Defensive clamp: the threshold can never exceed MAX_SAMPLE, regardless of data.
if [ "$COMPACT_THRESHOLD" -gt "$MAX_SAMPLE" ] 2>/dev/null; then
    COMPACT_THRESHOLD=$MAX_SAMPLE
fi

# ── Distance to compaction (integer %) ──
DISTANCE=$((REMAINING - COMPACT_THRESHOLD))
[ "$DISTANCE" -lt 0 ] && DISTANCE=0

# ── 2b. Token-based precision via basis points ──
# Basis points = hundredths of a percent (10000 bp = 100%)
# Only used for tier boundary accuracy — display stays integer.
USE_TOKEN_PRECISION=0
DISTANCE_BP=0
if [ "$TOTAL_INPUT" != "-1" ] && [ "$TOTAL_OUTPUT" != "-1" ] && [ "$WINDOW_SIZE" != "-1" ] && [ "$WINDOW_SIZE" -gt 0 ] 2>/dev/null; then
    TOKENS_USED=$((TOTAL_INPUT + TOTAL_OUTPUT))
    # remaining tokens
    TOKENS_REMAINING=$((WINDOW_SIZE - TOKENS_USED))
    [ "$TOKENS_REMAINING" -lt 0 ] && TOKENS_REMAINING=0
    # remaining percentage in basis points (hundredths of %)
    REMAINING_BP=$((TOKENS_REMAINING * 10000 / WINDOW_SIZE))
    # compact threshold in basis points
    THRESHOLD_BP=$((COMPACT_THRESHOLD * 100))
    # distance in basis points
    DISTANCE_BP=$((REMAINING_BP - THRESHOLD_BP))
    [ "$DISTANCE_BP" -lt 0 ] && DISTANCE_BP=0
    USE_TOKEN_PRECISION=1
fi

# ── Determine level ──
# When token data available, use basis points for sub-percent accuracy.
# Thresholds from plugin.json (basis points = distance * 100)
if [ "$USE_TOKEN_PRECISION" -eq 1 ]; then
    if [ "$DISTANCE_BP" -le "$L4_BP" ]; then
        LEVEL=4
    elif [ "$DISTANCE_BP" -le "$L3_BP" ]; then
        LEVEL=3
    elif [ "$DISTANCE_BP" -le "$L2_BP" ]; then
        LEVEL=2
    elif [ "$DISTANCE_BP" -le "$L1_BP" ]; then
        LEVEL=1
    else
        LEVEL=0
    fi
else
    # Fallback: integer percentage tiers from plugin.json
    if [ "$DISTANCE" -le "$L4_DIST" ]; then
        LEVEL=4
    elif [ "$DISTANCE" -le "$L3_DIST" ]; then
        LEVEL=3
    elif [ "$DISTANCE" -le "$L2_DIST" ]; then
        LEVEL=2
    elif [ "$DISTANCE" -le "$L1_DIST" ]; then
        LEVEL=1
    else
        LEVEL=0
    fi
fi

# ── 2c. 3-sample moving average velocity ──
VELOCITY_FILE="${SESSION_DIR}/velocity"
BURN_RATE=0
if [ -f "$VELOCITY_FILE" ]; then
    # Read existing samples (up to 3 lines, newest last)
    SAMPLES=()
    while IFS= read -r line; do
        SAMPLES+=("$line")
    done < "$VELOCITY_FILE"

    SAMPLE_COUNT=${#SAMPLES[@]}
    if [ "$SAMPLE_COUNT" -gt 0 ]; then
        OLDEST=${SAMPLES[0]}
        # Burn rate = average change per sample over the window
        BURN_RATE=$(( (OLDEST - REMAINING) / SAMPLE_COUNT ))
    fi
fi

# Append current reading, keep max 3 lines (atomic write)
{
    if [ -f "$VELOCITY_FILE" ]; then
        tail -2 "$VELOCITY_FILE"
    fi
    echo "$REMAINING"
} > "${VELOCITY_FILE}.tmp"
mv -f "${VELOCITY_FILE}.tmp" "$VELOCITY_FILE"

# Velocity escalation: if avg burn rate >= configured rate per turn and level > 0, bump by 1
if [ "$BURN_RATE" -ge "$VELOCITY_RATE" ] && [ "$LEVEL" -gt 0 ] && [ "$LEVEL" -lt 4 ]; then
    LEVEL=$((LEVEL + 1))
fi

# ── Escalation check — only write flag on new higher level (per-session) ──
CURRENT_NOTIFIED=0
[ -f "${SESSION_DIR}/notified" ] && CURRENT_NOTIFIED=$(cat "${SESSION_DIR}/notified" 2>/dev/null)
CURRENT_NOTIFIED=${CURRENT_NOTIFIED:-0}

if [ "$LEVEL" -gt "$CURRENT_NOTIFIED" ] && [ "$LEVEL" -gt 0 ]; then
    echo "$LEVEL" > "${SESSION_DIR}/level"
    echo "$LEVEL" > "${SESSION_DIR}/notified"
fi

# ── Build prefix: model + window ──
PREFIX=""
if [ -n "$MODEL_LABEL" ] && [ -n "$WINDOW_LABEL" ]; then
    PREFIX="${MODEL_LABEL} ${WINDOW_LABEL} "
elif [ -n "$MODEL_LABEL" ]; then
    PREFIX="${MODEL_LABEL} "
elif [ -n "$WINDOW_LABEL" ]; then
    PREFIX="${WINDOW_LABEL} "
fi

# ── Format live token count ──
TOKEN_LABEL=""
if [ "$TOTAL_INPUT" != "-1" ] && [ "$TOTAL_OUTPUT" != "-1" ] 2>/dev/null; then
    TOKENS_USED=$((TOTAL_INPUT + TOTAL_OUTPUT))
    if [ "$TOKENS_USED" -ge 1000000 ]; then
        TOKEN_LABEL="$(awk "BEGIN{printf \"%.1fM\", $TOKENS_USED/1000000}")"
    elif [ "$TOKENS_USED" -ge 1000 ]; then
        TOKEN_LABEL="$(awk "BEGIN{printf \"%.0fK\", $TOKENS_USED/1000}")"
    else
        TOKEN_LABEL="${TOKENS_USED}"
    fi
fi

# ── Build display: model | used% | tokens | urgency ──
CTX_PART="${USED}% used"
[ -n "$TOKEN_LABEL" ] && CTX_PART="${CTX_PART} (${TOKEN_LABEL})"
[ -n "$WINDOW_LABEL" ] && CTX_PART="${CTX_PART}/${WINDOW_LABEL}"

URGENCY=""
case "$LEVEL" in
    4) URGENCY=" CRITICAL" ;;
    3) URGENCY=" ◆◆◆" ;;
    2) URGENCY=" ◆◆" ;;
    1) URGENCY=" ◆" ;;
esac

if [ -n "$MODEL_LABEL" ]; then
    echo "${MODEL_LABEL}  ${CTX_PART}${URGENCY}"
else
    echo "${CTX_PART}${URGENCY}"
fi

exit 0

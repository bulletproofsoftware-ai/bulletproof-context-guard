#!/bin/bash
# Context Guard v3.0 — SessionStart Handler
# Cleans per-session state for fresh session. Detects post-compaction resume
# and checks state_saved verification file to branch between good recovery
# and degraded recovery. Auto-cleans stale session dirs.

# ── Path resolution ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${PLUGIN_ROOT}/state"
mkdir -p "$STATE_DIR"

INPUT=$(cat)

# ── Extract session_id for per-session state isolation ──
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
SESSION_ID=${SESSION_ID:-unknown}
SESSION_ID=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
SESSION_DIR="${STATE_DIR}/sessions/${SESSION_ID}"
mkdir -p "$SESSION_DIR"

# ── Detect source before cleanup (compact check needs state_saved) ──
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"' 2>/dev/null)
SOURCE=${SOURCE:-startup}

# ── Clean escalation state files ──
# Only clean escalation state on fresh startup, NOT on compact resume
# (escalation level and notification state must survive compaction)
if [ "$SOURCE" != "compact" ]; then
    rm -f "${SESSION_DIR}/level"
    rm -f "${SESSION_DIR}/notified"
fi
# Always clean velocity on compact (velocity samples are invalid after compaction)
rm -f "${SESSION_DIR}/velocity"

# ── Clean legacy flat state files (backward compat on first run after upgrade) ──
rm -f "${STATE_DIR}/level"
rm -f "${STATE_DIR}/notified"
rm -f "${STATE_DIR}/velocity"
rm -f "${STATE_DIR}/raw"

# ── Auto-clean stale session dirs (>24h old) ──
if [ -d "${STATE_DIR}/sessions" ]; then
    find "${STATE_DIR}/sessions" -maxdepth 1 -type d -mmin +1440 -not -path "${STATE_DIR}/sessions" -exec rm -rf {} \; 2>/dev/null
fi

# ── Post-compaction resume ──
if [ "$SOURCE" = "compact" ]; then
    if [ -f "${SESSION_DIR}/state_saved" ]; then
        # Good recovery — state was confirmed saved
        rm -f "${SESSION_DIR}/state_saved"
        cat <<'MSG'
{"systemMessage":"SESSION RESUMED AFTER COMPACTION. You previously saved investigation state before compacting. IMMEDIATELY: (1) Use memory_scratch(operation='read', key='session-state') to retrieve your saved progress — if memory_scratch is unavailable, read the session-state.md fallback file under the plugin state/sessions directory instead. (2) Briefly tell the user what you were working on and where you left off. (3) Resume the task from where you stopped. Do NOT ask the user to re-explain — your saved state has everything."}
MSG
    else
        # Degraded recovery — state_saved was never confirmed
        cat <<'MSG'
{"systemMessage":"SESSION RESUMED AFTER COMPACTION — WARNING: State save was NOT confirmed before compaction. Recovery may be incomplete. IMMEDIATELY: (1) Try memory_scratch(operation='read', key='session-state') anyway — or check for a session-state.md fallback file under the plugin state/sessions directory; the save may have happened without confirmation. (2) If nothing found, use memory_recall to search for recent session context. (3) Ask the user: 'I just resumed after compaction but my saved state may be incomplete. Can you remind me what we were working on and where we left off?' (4) Do NOT pretend you remember — be honest about the gap."}
MSG
    fi
else
    # Fresh session — clean state_saved (only for non-compact starts)
    rm -f "${SESSION_DIR}/state_saved"
fi

exit 0

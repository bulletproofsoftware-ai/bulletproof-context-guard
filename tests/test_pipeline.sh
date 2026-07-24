#!/bin/bash
# Context Guard v3.0 — End-to-end lifecycle tests
# 15 test cases covering all tiers, velocity, logging, compaction, recovery, precision.
# Uses isolated test session IDs. Cleanup via trap. Exit 0 = all pass, 1 = any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${PLUGIN_ROOT}/state"
TEST_SESSION="test-$$-$(date +%s)"
SESSION_DIR="${STATE_DIR}/sessions/${TEST_SESSION}"

PASS=0
FAIL=0
ERRORS=()

# ── Cleanup on exit ──
cleanup() {
    rm -rf "$SESSION_DIR"
    rm -f "${STATE_DIR}/compaction.log.bak"
    # Restore original compaction.log if we backed it up
    if [ -f "${STATE_DIR}/compaction.log.test-backup" ]; then
        mv -f "${STATE_DIR}/compaction.log.test-backup" "${STATE_DIR}/compaction.log"
    fi
    # Clean test warnings
    if [ -f "${STATE_DIR}/warnings.log" ]; then
        grep -v "$TEST_SESSION" "${STATE_DIR}/warnings.log" > "${STATE_DIR}/warnings.log.tmp" 2>/dev/null || true
        mv -f "${STATE_DIR}/warnings.log.tmp" "${STATE_DIR}/warnings.log"
    fi
}
trap cleanup EXIT

# ── Helpers ──
pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("$1: $2"); printf '  ✗ %s — %s\n' "$1" "$2"; }

make_statusline_input() {
    local remaining="$1"
    local used=$((100 - remaining))
    # Optional token fields
    local total_input="${2:--1}"
    local total_output="${3:--1}"
    local window_size="${4:--1}"
    printf '{"session_id":"%s","context_window":{"remaining_percentage":%d,"used_percentage":%d,"total_input_tokens":%s,"total_output_tokens":%s,"context_window_size":%s}}' \
        "$TEST_SESSION" "$remaining" "$used" "$total_input" "$total_output" "$window_size"
}

make_warn_input() {
    printf '{"session_id":"%s","tool_name":"Read"}' "$TEST_SESSION"
}

make_session_start_input() {
    local source="${1:-startup}"
    printf '{"session_id":"%s","source":"%s"}' "$TEST_SESSION" "$source"
}

make_compact_input() {
    printf '{"session_id":"%s"}' "$TEST_SESSION"
}

run_statusline() {
    echo "$1" | bash "${PLUGIN_ROOT}/scripts/statusline.sh"
}

run_warn() {
    echo "$1" | bash "${PLUGIN_ROOT}/hooks/warn.sh"
}

run_session_start() {
    echo "$1" | bash "${PLUGIN_ROOT}/hooks/session_start.sh"
}

run_pre_compact() {
    echo "$1" | bash "${PLUGIN_ROOT}/hooks/pre_compact.sh"
}

echo "Context Guard v3.0 — Test Pipeline"
echo "Session: ${TEST_SESSION}"
echo "────────────────────────────────────"

# Back up compaction.log if it exists
if [ -f "${STATE_DIR}/compaction.log" ]; then
    cp "${STATE_DIR}/compaction.log" "${STATE_DIR}/compaction.log.test-backup"
fi

# Pin a deterministic dynamic threshold (~14) so the escalation tests below are
# independent of ambient compaction.log contents. Tests 11/14/15 manage the log
# themselves; cleanup restores the real one.
printf '[t] [x] remaining=14\n[t] [x] remaining=14\n[t] [x] remaining=14\n' > "${STATE_DIR}/compaction.log"

# ══════════════════════════════════════
# Test 1: Fresh session startup
# ══════════════════════════════════════
echo ""
echo "Test 1: Fresh session startup"
OUTPUT=$(run_session_start "$(make_session_start_input startup)")
if [ -z "$OUTPUT" ] && [ -d "$SESSION_DIR" ] && [ ! -f "${SESSION_DIR}/level" ] && [ ! -f "${SESSION_DIR}/notified" ] && [ ! -f "${SESSION_DIR}/state_saved" ]; then
    pass "Fresh startup: no output, state cleaned, state_saved absent"
else
    fail "Fresh startup" "unexpected output or state files present. Output: '$OUTPUT'"
fi

# ══════════════════════════════════════
# Test 2: L0 — no warning fires
# ══════════════════════════════════════
echo ""
echo "Test 2: L0 — no warning fires"
rm -f "${SESSION_DIR}/level" "${SESSION_DIR}/notified" "${SESSION_DIR}/velocity"
SL_OUT=$(run_statusline "$(make_statusline_input 80)")
WARN_OUT=$(run_warn "$(make_warn_input)")
# L0 = statusline renders, no escalation flag, warn is a no-op ('{}' or empty).
if [ -n "$SL_OUT" ] && [ ! -f "${SESSION_DIR}/level" ] && { [ "$WARN_OUT" = '{}' ] || [ -z "$WARN_OUT" ]; }; then
    pass "L0: statusline renders, no escalation, no warning"
else
    fail "L0" "SL='$SL_OUT' WARN='$WARN_OUT'"
fi

# ══════════════════════════════════════
# Test 3: L1 escalation
# ══════════════════════════════════════
echo ""
echo "Test 3: L1 escalation"
# Reset state
rm -f "${SESSION_DIR}/level" "${SESSION_DIR}/notified" "${SESSION_DIR}/velocity"
SL_OUT=$(run_statusline "$(make_statusline_input 40)")
if [ -f "${SESSION_DIR}/level" ] && [ "$(cat "${SESSION_DIR}/level")" = "1" ]; then
    WARN_OUT=$(run_warn "$(make_warn_input)")
    if echo "$WARN_OUT" | grep -q '≤30%'; then
        pass "L1: level file created, warning contains ≤30%"
    else
        fail "L1 warning" "expected ≤30% in output. Got: '$WARN_OUT'"
    fi
else
    fail "L1 escalation" "level file missing or wrong value"
fi

# ══════════════════════════════════════
# Test 4: L1 no re-fire
# ══════════════════════════════════════
echo ""
echo "Test 4: L1 no re-fire on same level"
# Run statusline again at same level — should NOT create new level file
SL_OUT=$(run_statusline "$(make_statusline_input 38)")
WARN_OUT=$(run_warn "$(make_warn_input)")
if [ "$WARN_OUT" = '{}' ] || [ -z "$WARN_OUT" ]; then
    pass "L1 no re-fire: no duplicate warning"
else
    fail "L1 no re-fire" "unexpected warning: '$WARN_OUT'"
fi

# ══════════════════════════════════════
# Test 5: L2 escalation with state_saved instruction
# ══════════════════════════════════════
echo ""
echo "Test 5: L2 escalation with state_saved instruction"
# Reset velocity to prevent carryover from tests 3-4 causing false velocity bump
rm -f "${SESSION_DIR}/velocity"
SL_OUT=$(run_statusline "$(make_statusline_input 28)")
WARN_OUT=$(run_warn "$(make_warn_input)")
if echo "$WARN_OUT" | grep -q '≤15%' && echo "$WARN_OUT" | grep -q 'state_saved'; then
    pass "L2: warning contains ≤15% and state_saved instruction"
else
    fail "L2 escalation" "SL='$SL_OUT' WARN='$WARN_OUT'"
fi

# ══════════════════════════════════════
# Test 6: L3 escalation + persistent reminder
# ══════════════════════════════════════
echo ""
echo "Test 6: L3 escalation (one-shot)"
# Reset velocity to prevent carryover
rm -f "${SESSION_DIR}/velocity"
SL_OUT=$(run_statusline "$(make_statusline_input 20)")
WARN_OUT=$(run_warn "$(make_warn_input)")
if echo "$WARN_OUT" | grep -q '≤7%'; then
    # L3 is one-shot in v3.1 (persistent reminders are L4-only) — next call is silent
    REMIND_OUT=$(run_warn "$(make_warn_input)")
    if [ "$REMIND_OUT" = '{}' ] || [ -z "$REMIND_OUT" ]; then
        pass "L3: one-shot escalation, silent thereafter (L4-only persistence)"
    else
        fail "L3 one-shot" "unexpected second warning: '$REMIND_OUT'"
    fi
else
    fail "L3 escalation" "WARN='$WARN_OUT'"
fi

# ══════════════════════════════════════
# Test 7: L4 escalation — CRITICAL
# ══════════════════════════════════════
echo ""
echo "Test 7: L4 escalation — CRITICAL"
rm -f "${SESSION_DIR}/velocity"
SL_OUT=$(run_statusline "$(make_statusline_input 16)")
WARN_OUT=$(run_warn "$(make_warn_input)")
if echo "$WARN_OUT" | grep -q 'CRITICAL' && echo "$WARN_OUT" | grep -q 'state_saved'; then
    pass "L4: CRITICAL warning with state_saved instruction"
else
    fail "L4 escalation" "WARN='$WARN_OUT'"
fi

# ══════════════════════════════════════
# Test 8: Velocity escalation — 3-sample average triggers bump
# ══════════════════════════════════════
echo ""
echo "Test 8: Velocity escalation"
# Fresh session for velocity test
rm -f "${SESSION_DIR}/level" "${SESSION_DIR}/notified" "${SESSION_DIR}/velocity"
# Three rapid drops: 55 -> 48 -> 40 (avg burn = (55-40)/2 = 7.5 ≈ 7 >= 5)
run_statusline "$(make_statusline_input 55)" >/dev/null
run_statusline "$(make_statusline_input 48)" >/dev/null
SL_OUT=$(run_statusline "$(make_statusline_input 40)")
# At remaining=40, distance=24 (with threshold=16), that's L1 normally.
# With velocity >= 5, it should bump to L2.
NOTIFIED=$(cat "${SESSION_DIR}/notified" 2>/dev/null)
if [ "$NOTIFIED" = "2" ]; then
    pass "Velocity escalation: L1 bumped to L2 by burn rate"
else
    fail "Velocity escalation" "expected notified=2, got '$NOTIFIED'"
fi

# ══════════════════════════════════════
# Test 9: Velocity smoothing — single spike averaged out
# ══════════════════════════════════════
echo ""
echo "Test 9: Velocity smoothing"
rm -f "${SESSION_DIR}/level" "${SESSION_DIR}/notified" "${SESSION_DIR}/velocity"
# Three readings: 60, 55, 54 — avg burn = (60-54)/2 = 3 < 5
run_statusline "$(make_statusline_input 60)" >/dev/null
run_statusline "$(make_statusline_input 55)" >/dev/null
SL_OUT=$(run_statusline "$(make_statusline_input 54)")
# distance=38, L0 territory. With burn_rate=3, no velocity bump.
NOTIFIED=$(cat "${SESSION_DIR}/notified" 2>/dev/null || echo "0")
if [ "$NOTIFIED" = "0" ]; then
    pass "Velocity smoothing: spike averaged out, no false escalation"
else
    fail "Velocity smoothing" "expected notified=0, got '$NOTIFIED'"
fi

# ══════════════════════════════════════
# Test 10: Warning delivery logging
# ══════════════════════════════════════
echo ""
echo "Test 10: Warning delivery logging"
WARNINGS_LOG="${STATE_DIR}/warnings.log"
if [ -f "$WARNINGS_LOG" ]; then
    ENTRIES=$(grep -c "$TEST_SESSION" "$WARNINGS_LOG" 2>/dev/null || true)
    # v3.1: L1, L2, L3, L4 each fire once (L3 is one-shot) = at least 4 entries
    if [ "$ENTRIES" -ge 4 ]; then
        # Check format: tier and trigger fields present
        if grep "$TEST_SESSION" "$WARNINGS_LOG" | grep -q 'tier=' && grep "$TEST_SESSION" "$WARNINGS_LOG" | grep -q 'trigger='; then
            pass "Warning logging: $ENTRIES entries with correct format"
        else
            fail "Warning logging" "entries present but format wrong"
        fi
    else
        fail "Warning logging" "expected >=5 entries, got $ENTRIES"
    fi
else
    fail "Warning logging" "warnings.log not found"
fi

# ══════════════════════════════════════
# Test 11: Pre-compaction — compaction.log has remaining=
# ══════════════════════════════════════
echo ""
echo "Test 11: Pre-compaction logging"
# Write a known raw value for pre_compact to read
echo '{"context_window":{"remaining_percentage":14}}' > "${SESSION_DIR}/raw"
run_pre_compact "$(make_compact_input)"
LAST_LOG=$(grep "$TEST_SESSION" "${STATE_DIR}/compaction.log" | tail -1)
if echo "$LAST_LOG" | grep -q 'remaining=14'; then
    # Check state cleaned
    if [ ! -f "${SESSION_DIR}/level" ] && [ ! -f "${SESSION_DIR}/notified" ] && [ ! -f "${SESSION_DIR}/velocity" ]; then
        pass "Pre-compaction: remaining=14 logged, state cleaned"
    else
        fail "Pre-compaction" "log correct but state files not cleaned"
    fi
else
    fail "Pre-compaction" "expected remaining=14, got: '$LAST_LOG'"
fi

# ══════════════════════════════════════
# Test 12: Post-compaction resume (state saved)
# ══════════════════════════════════════
echo ""
echo "Test 12: Post-compaction resume — state saved"
mkdir -p "$SESSION_DIR"
echo "saved" > "${SESSION_DIR}/state_saved"
OUTPUT=$(run_session_start "$(make_session_start_input compact)")
if echo "$OUTPUT" | grep -q 'memory_scratch' && ! echo "$OUTPUT" | grep -q 'WARNING'; then
    # state_saved should be cleaned after reading
    if [ ! -f "${SESSION_DIR}/state_saved" ]; then
        pass "Post-compact (saved): good recovery, flag cleaned"
    else
        fail "Post-compact (saved)" "state_saved not cleaned"
    fi
else
    fail "Post-compact (saved)" "OUTPUT='$OUTPUT'"
fi

# ══════════════════════════════════════
# Test 13: Post-compaction resume (state NOT saved)
# ══════════════════════════════════════
echo ""
echo "Test 13: Post-compaction resume — state NOT saved"
rm -f "${SESSION_DIR}/state_saved"
OUTPUT=$(run_session_start "$(make_session_start_input compact)")
if echo "$OUTPUT" | grep -q 'WARNING' && echo "$OUTPUT" | grep -q 'NOT confirmed'; then
    pass "Post-compact (not saved): degraded recovery warning"
else
    fail "Post-compact (not saved)" "OUTPUT='$OUTPUT'"
fi

# ══════════════════════════════════════
# Test 14: Dynamic threshold — synthetic compaction.log entries
# ══════════════════════════════════════
echo ""
echo "Test 14: Dynamic threshold"
# Clear state for fresh test
rm -f "${SESSION_DIR}/level" "${SESSION_DIR}/notified" "${SESSION_DIR}/velocity"
# Remove real compaction.log, write synthetic one with avg remaining=20 (<=max_sample)
rm -f "${STATE_DIR}/compaction.log"
for i in 18 19 20 21 22; do
    echo "[2026-03-14 00:00:00] [synthetic] remaining=$i" >> "${STATE_DIR}/compaction.log"
done
# Verify the dynamic threshold is ACTIVE via behavior: threshold=20 makes
# remaining=22 → distance=2 → L4. The fallback threshold (16) would give
# distance=6 → L3, so observing L4 proves the dynamic value (20) is in effect.
run_statusline "$(make_statusline_input 22)" >/dev/null
NOTIFIED=$(cat "${SESSION_DIR}/notified" 2>/dev/null || echo "0")
if [ "$NOTIFIED" = "4" ]; then
    pass "Dynamic threshold: avg=20 active (remaining=22 → L4, not fallback's L3)"
else
    fail "Dynamic threshold" "expected L4 from threshold=20, got L$NOTIFIED"
fi

# ══════════════════════════════════════
# Test 15: Token precision — integer% says L2 but token math says L4
# ══════════════════════════════════════
echo ""
echo "Test 15: Token precision overrides integer%"
rm -f "${SESSION_DIR}/level" "${SESSION_DIR}/notified" "${SESSION_DIR}/velocity"
# Restore fallback threshold for this test
rm -f "${STATE_DIR}/compaction.log"
# Integer remaining=19, threshold=16 → distance=3 → L4 by integer
# Token data: 84200 used of 100000 → 15800 remaining → 1580 bp → 1580 - 1600 = -20 bp → L4
# But let's make it so integer says L2 and tokens say L4:
# Integer remaining=28, threshold=16 → distance=12 → L2 by integer
# Token data: 83500 + 0 = 83500 used of 100000 → 16500 remaining → 1650 bp
# threshold bp = 1600 → distance_bp = 50 → L4 (<=300)
SL_OUT=$(run_statusline "$(make_statusline_input 28 83500 0 100000)")
NOTIFIED=$(cat "${SESSION_DIR}/notified" 2>/dev/null || echo "0")
if [ "$NOTIFIED" = "4" ]; then
    pass "Token precision: integer L2 overridden to L4 by token math"
else
    fail "Token precision" "expected notified=4, got '$NOTIFIED'. SL='$SL_OUT'"
fi

# ══════════════════════════════════════
# Summary
# ══════════════════════════════════════
echo ""
echo "════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo "Results: ${PASS}/${TOTAL} passed, ${FAIL} failed"

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        echo "  - $err"
    done
fi

echo "════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0

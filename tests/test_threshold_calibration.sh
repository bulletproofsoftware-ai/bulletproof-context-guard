#!/bin/bash
# Context Guard v3.1 — dynamic-threshold calibration tests
# Proves the compaction.log poisoning fix: a polluted log can no longer inflate
# the threshold into false L3/L4 escalations at high headroom, while genuine
# near-compaction states still escalate. Drives statusline.sh directly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${PLUGIN_ROOT}/state"
COMPACTION_LOG="${STATE_DIR}/compaction.log"
TEST_SESSION="testcal-$$-$(date +%s)"
SESSION_DIR="${STATE_DIR}/sessions/${TEST_SESSION}"

PASS=0; FAIL=0; ERRORS=()
pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("$1: $2"); printf '  ✗ %s — %s\n' "$1" "$2"; }

# Back up the real compaction.log; restore on exit.
[ -f "$COMPACTION_LOG" ] && cp "$COMPACTION_LOG" "${COMPACTION_LOG}.caltest-bak"
cleanup() {
    rm -rf "$SESSION_DIR"
    if [ -f "${COMPACTION_LOG}.caltest-bak" ]; then
        mv -f "${COMPACTION_LOG}.caltest-bak" "$COMPACTION_LOG"
    else
        rm -f "$COMPACTION_LOG"
    fi
    [ -f "${STATE_DIR}/compaction-skipped.log" ] && \
        grep -v "$TEST_SESSION" "${STATE_DIR}/compaction-skipped.log" > "${STATE_DIR}/compaction-skipped.log.tmp" 2>/dev/null && \
        mv -f "${STATE_DIR}/compaction-skipped.log.tmp" "${STATE_DIR}/compaction-skipped.log"
}
trap cleanup EXIT

run_statusline() { echo "$1" | bash "${PLUGIN_ROOT}/scripts/statusline.sh" >/dev/null 2>&1; }
level_now() { cat "${SESSION_DIR}/notified" 2>/dev/null || echo 0; }

# input: remaining%, total_input_tokens, window_size
make_input() {
    local r="$1" ti="$2" w="$3"
    printf '{"session_id":"%s","model":{"display_name":"Opus 4.8 (1M context)"},"context_window":{"remaining_percentage":%d,"used_percentage":%d,"total_input_tokens":%d,"total_output_tokens":0,"context_window_size":%d}}' \
        "$TEST_SESSION" "$r" "$((100 - r))" "$ti" "$w"
}

echo "Context Guard v3.1 — threshold calibration"
echo "Session: ${TEST_SESSION}"
echo "────────────────────────────────────"

# ── Test 1: POLLUTED log + high headroom → NO false escalation ──
# This is the production bug: compaction.log full of remaining=85/90/94 inflated
# the threshold to ~61, firing L4 at 80% remaining.
echo ""
echo "Test 1: poisoned log does not cause false L4 at 80% remaining"
printf '[t] [x] remaining=85\n[t] [x] remaining=90\n[t] [x] remaining=94\n[t] [x] remaining=88\n' > "$COMPACTION_LOG"
rm -f "${SESSION_DIR}/level" "${SESSION_DIR}/notified" "${SESSION_DIR}/velocity"
run_statusline "$(make_input 80 200000 1000000)"
LV=$(level_now)
if [ "$LV" = "0" ]; then
    pass "80% remaining → L0 (poison rejected by filter/clamp)"
else
    fail "false escalation" "expected L0, got L$LV"
fi

# ── Test 2: clean log + high headroom → L0 ──
echo ""
echo "Test 2: clean log, 80% remaining → L0"
printf '[t] [x] remaining=0\n[t] [x] remaining=14\n[t] [x] remaining=10\n' > "$COMPACTION_LOG"
rm -f "${SESSION_DIR}/level" "${SESSION_DIR}/notified" "${SESSION_DIR}/velocity"
run_statusline "$(make_input 80 200000 1000000)"
LV=$(level_now)
if [ "$LV" = "0" ]; then
    pass "80% remaining → L0"
else
    fail "clean high-headroom" "expected L0, got L$LV"
fi

# ── Test 3: genuine near-compaction → L4 still fires (no false negative) ──
echo ""
echo "Test 3: 3% remaining (970k/1M used) → L4"
rm -f "${SESSION_DIR}/level" "${SESSION_DIR}/notified" "${SESSION_DIR}/velocity"
run_statusline "$(make_input 3 970000 1000000)"
LV=$(level_now)
if [ "$LV" = "4" ]; then
    pass "near-compaction still escalates to L4"
else
    fail "false negative" "expected L4, got L$LV"
fi

# ── Test 4: mid-range usage → a sane mid tier (not L0, not L4) ──
echo ""
echo "Test 4: 25% remaining → escalates but not EMERGENCY"
printf '[t] [x] remaining=0\n[t] [x] remaining=14\n[t] [x] remaining=10\n' > "$COMPACTION_LOG"
rm -f "${SESSION_DIR}/level" "${SESSION_DIR}/notified" "${SESSION_DIR}/velocity"
run_statusline "$(make_input 25 750000 1000000)"
LV=$(level_now)
if [ "$LV" -ge 1 ] && [ "$LV" -le 3 ]; then
    pass "25% remaining → L$LV (graded, not false EMERGENCY)"
else
    fail "mid-range" "expected L1-L3, got L$LV"
fi

# ── Test 5: pre_compact routes manual /compact away from the threshold log ──
echo ""
echo "Test 5: pre_compact diverts high-remaining (manual) compactions"
: > "$COMPACTION_LOG"
mkdir -p "$SESSION_DIR"
# Manual compact at 94% remaining → must NOT land in compaction.log
printf '{"context_window":{"remaining_percentage":94,"context_window_size":1000000},"model":{"display_name":"Opus 4.8 (1M context)"}}' > "${SESSION_DIR}/raw"
printf '{"session_id":"%s"}' "$TEST_SESSION" | bash "${PLUGIN_ROOT}/hooks/pre_compact.sh"
# Real auto-compact at 12% remaining → must land in compaction.log
printf '{"context_window":{"remaining_percentage":12,"context_window_size":1000000},"model":{"display_name":"Opus 4.8 (1M context)"}}' > "${SESSION_DIR}/raw"
printf '{"session_id":"%s"}' "$TEST_SESSION" | bash "${PLUGIN_ROOT}/hooks/pre_compact.sh"
GOOD=$(grep -c 'remaining=12' "$COMPACTION_LOG" 2>/dev/null || true)
BAD=$(grep -c 'remaining=94' "$COMPACTION_LOG" 2>/dev/null || true)
if [ "$GOOD" -ge 1 ] && [ "$BAD" -eq 0 ]; then
    pass "remaining=12 logged, remaining=94 diverted to skipped log"
else
    fail "pre_compact routing" "remaining=12 count=$GOOD, remaining=94 count=$BAD (want >=1 and 0)"
fi

echo ""
echo "════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo "Results: ${PASS}/${TOTAL} passed, ${FAIL} failed"
if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""; echo "Failures:"; for err in "${ERRORS[@]}"; do echo "  - $err"; done
fi
echo "════════════════════════════════════"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

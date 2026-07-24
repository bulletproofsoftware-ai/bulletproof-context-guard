#!/bin/bash
# Context Guard v3.1 — warn.sh unit tests (L3/L4 repair + L4 enforcement)
# Drives warn.sh directly via its state-file contract (level / notified) so the
# tests are isolated from statusline.sh level-computation. Exit 0 = all pass.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${PLUGIN_ROOT}/state"
TEST_SESSION="testwarn-$$-$(date +%s)"
SESSION_DIR="${STATE_DIR}/sessions/${TEST_SESSION}"

PASS=0
FAIL=0
ERRORS=()

cleanup() {
    rm -rf "$SESSION_DIR"
    rm -f "${STATE_DIR}/telemetry/${TEST_SESSION}-warning.json"
    if [ -f "${STATE_DIR}/warnings.log" ]; then
        grep -v "$TEST_SESSION" "${STATE_DIR}/warnings.log" > "${STATE_DIR}/warnings.log.tmp" 2>/dev/null || true
        mv -f "${STATE_DIR}/warnings.log.tmp" "${STATE_DIR}/warnings.log"
    fi
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("$1: $2"); printf '  ✗ %s — %s\n' "$1" "$2"; }

run_warn() { # $1 = tool_name
    printf '{"session_id":"%s","tool_name":"%s"}' "$TEST_SESSION" "$1" \
        | bash "${PLUGIN_ROOT}/hooks/warn.sh"
}

# Establish a session dir with a raw dump so MODEL_CTX resolves.
mkdir -p "$SESSION_DIR"
printf '{"model":{"display_name":"Opus 4.8 (1M context)"},"context_window":{"context_window_size":1000000}}' \
    > "${SESSION_DIR}/raw"

echo "Context Guard v3.1 — warn.sh L3/L4 tests"
echo "Session: ${TEST_SESSION}"
echo "────────────────────────────────────"

# ── Test 1: L3 new-escalation fires (v3.0 regression repair) ──
echo ""
echo "Test 1: L3 escalation is announced"
rm -f "${SESSION_DIR}/level" "${SESSION_DIR}/notified"
echo 3 > "${SESSION_DIR}/level"
echo 3 > "${SESSION_DIR}/notified"
OUT=$(run_warn "Read")
if echo "$OUT" | grep -q '≤7%' && echo "$OUT" | grep -q 'systemMessage'; then
    pass "L3 announcement delivered (≤7%)"
else
    fail "L3 announcement" "expected ≤7% systemMessage, got: '$OUT'"
fi

# ── Test 2: L4 new-escalation fires (v3.0 regression repair) ──
echo ""
echo "Test 2: L4 escalation is announced"
rm -f "${SESSION_DIR}/level" "${SESSION_DIR}/notified"
echo 4 > "${SESSION_DIR}/level"
echo 4 > "${SESSION_DIR}/notified"
OUT=$(run_warn "Read")
if echo "$OUT" | grep -q 'CRITICAL' && echo "$OUT" | grep -q 'IMMINENT'; then
    pass "L4 announcement delivered (CRITICAL/IMMINENT)"
else
    fail "L4 announcement" "expected CRITICAL/IMMINENT, got: '$OUT'"
fi

# ── Test 3: L4 + Task → HARD BLOCK (Fix #2) ──
echo ""
echo "Test 3: L4 blocks subagent dispatch"
rm -f "${SESSION_DIR}/level"            # no new escalation pending
echo 4 > "${SESSION_DIR}/notified"      # high-water mark at L4
OUT=$(run_warn "Task")
if echo "$OUT" | grep -q '"decision":"block"' && echo "$OUT" | grep -q 'Subagent dispatch BLOCKED'; then
    pass "L4 Task dispatch blocked via decision:block"
else
    fail "L4 Task block" "expected decision:block, got: '$OUT'"
fi

# ── Test 4: L4 + non-Task → persistent reminder, NOT blocked (Fix #3) ──
echo ""
echo "Test 4: L4 persistent reminder on non-Task tools"
rm -f "${SESSION_DIR}/level"
echo 4 > "${SESSION_DIR}/notified"
OUT=$(run_warn "Read")
if echo "$OUT" | grep -q 'systemMessage' && echo "$OUT" | grep -q 'L4 EMERGENCY' && ! echo "$OUT" | grep -q '"decision":"block"'; then
    pass "L4 non-Task gets persistent reminder, not blocked"
else
    fail "L4 persistent reminder" "got: '$OUT'"
fi

# ── Test 5: L4 keeps state-saving tools usable (Bash not blocked) ──
echo ""
echo "Test 5: L4 does NOT block state-saving (Bash)"
rm -f "${SESSION_DIR}/level"
echo 4 > "${SESSION_DIR}/notified"
OUT=$(run_warn "Bash")
if ! echo "$OUT" | grep -q '"decision":"block"'; then
    pass "Bash allowed at L4 (state-save path open)"
else
    fail "L4 Bash" "Bash was blocked: '$OUT'"
fi

# ── Test 6: New L4 escalation announces before the block kicks in ──
echo ""
echo "Test 6: pending L4 escalation announces even for a Task call"
rm -f "${SESSION_DIR}/notified"
echo 4 > "${SESSION_DIR}/level"          # fresh escalation flag present
echo 4 > "${SESSION_DIR}/notified"
OUT=$(run_warn "Task")
if echo "$OUT" | grep -q 'systemMessage' && echo "$OUT" | grep -q 'IMMINENT'; then
    pass "fresh L4 flag announced (one-shot) ahead of persistent block"
else
    fail "L4 announce-before-block" "got: '$OUT'"
fi

# ── Test 7: L1/L2 still one-shot, then quiet ──
echo ""
echo "Test 7: L1 one-shot then silence"
rm -f "${SESSION_DIR}/level" "${SESSION_DIR}/notified"
echo 1 > "${SESSION_DIR}/level"
echo 1 > "${SESSION_DIR}/notified"
OUT1=$(run_warn "Read")
OUT2=$(run_warn "Read")
if echo "$OUT1" | grep -q '≤30%' && [ "$OUT2" = '{}' ]; then
    pass "L1 fires once, silent thereafter"
else
    fail "L1 one-shot" "OUT1='$OUT1' OUT2='$OUT2'"
fi

# ── Test 8: block decision is logged to warnings.log ──
echo ""
echo "Test 8: blocked dispatch is audited"
rm -f "${SESSION_DIR}/level"
echo 4 > "${SESSION_DIR}/notified"
run_warn "Task" >/dev/null
if grep "$TEST_SESSION" "${STATE_DIR}/warnings.log" | grep -q 'trigger=blocked-task-dispatch'; then
    pass "blocked-task-dispatch recorded in warnings.log"
else
    fail "block audit" "no blocked-task-dispatch entry in warnings.log"
fi

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
[ "$FAIL" -gt 0 ] && exit 1
exit 0

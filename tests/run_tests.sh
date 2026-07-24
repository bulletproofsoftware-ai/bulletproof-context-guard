#!/bin/bash
# Context Guard v3.0 — Test Suite Runner
# Runs all test_*.sh files, reports pass/fail summary.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

TOTAL=0
PASSED=0
FAILED=0
FAILED_TESTS=()

echo "Context Guard — Test Suite"
echo "══════════════════════════"

for test_file in "${SCRIPT_DIR}"/test_*.sh; do
    [ ! -f "$test_file" ] && continue
    TEST_NAME=$(basename "$test_file")
    TOTAL=$((TOTAL + 1))

    echo ""
    echo "Running: ${TEST_NAME}"
    echo "────────────────────────────────────"

    if bash "$test_file"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        FAILED_TESTS+=("$TEST_NAME")
    fi
done

echo ""
echo "══════════════════════════════════════"
echo "Suite: ${PASSED}/${TOTAL} test files passed"

if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo ""
    echo "Failed test files:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
fi

echo "══════════════════════════════════════"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0

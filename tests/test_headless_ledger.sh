#!/usr/bin/env bash
# tests/test_headless_ledger.sh
# Verifies the headless auto-resolve procedure references the stop list,
# logs ledger rows correctly, and preserves escalation paths.
#
# Run: bash tests/test_headless_ledger.sh
# Expected: all tests PASS; exit 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

HEADLESS_FILE="${PLUGIN_ROOT}/skills/n1-start/procedures/autonomy-headless.md"

# ---------------------------------------------------------------------------
# Test 1: procedure references alwaysAskOn
# ---------------------------------------------------------------------------
if grep -q 'alwaysAskOn' "$HEADLESS_FILE"; then
    pass "T1: procedure references alwaysAskOn"
else
    fail "T1: procedure missing alwaysAskOn reference"
fi

# ---------------------------------------------------------------------------
# Test 2: procedure contains the auto-resolve reason literal
# ---------------------------------------------------------------------------
if grep -q 'headless: not on stop list' "$HEADLESS_FILE"; then
    pass "T2: procedure contains 'headless: not on stop list'"
else
    fail "T2: procedure missing 'headless: not on stop list'"
fi

# ---------------------------------------------------------------------------
# Test 3: ledger row has exactly 9 cells (10 pipe separators)
# ---------------------------------------------------------------------------
LEDGER_LINE=$(grep 'headless: not on stop list' "$HEADLESS_FILE" | head -1)
PIPE_COUNT=$(echo "$LEDGER_LINE" | tr -cd '|' | wc -c)
if [ "$PIPE_COUNT" -eq 10 ]; then
    pass "T3: ledger row has 10 pipe separators (9 cells)"
else
    fail "T3: expected 10 pipe separators, got ${PIPE_COUNT}"
fi

# ---------------------------------------------------------------------------
# Test 4: procedure still contains escalation path markers
# ---------------------------------------------------------------------------
if grep -q 'step: escalated' "$HEADLESS_FILE"; then
    pass "T4: procedure still contains 'step: escalated'"
else
    fail "T4: procedure missing 'step: escalated' — escalation path may be broken"
fi

if grep -q 'HEADLESS ESCALATION' "$HEADLESS_FILE"; then
    pass "T5: procedure still contains 'HEADLESS ESCALATION'"
else
    fail "T5: procedure missing 'HEADLESS ESCALATION' — escalation path may be broken"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

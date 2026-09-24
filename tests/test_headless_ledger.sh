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
# Test 6: escalation procedure contains idempotency marker pattern
# ---------------------------------------------------------------------------
if grep -q 'n1-esc:' "$HEADLESS_FILE"; then
    pass "T6: procedure contains 'n1-esc:' idempotency marker"
else
    fail "T6: procedure missing 'n1-esc:' idempotency marker"
fi

# ---------------------------------------------------------------------------
# Test 7: escalation procedure references tracker.statuses.blocked
# ---------------------------------------------------------------------------
if grep -q 'tracker.statuses.blocked' "$HEADLESS_FILE"; then
    pass "T7: procedure references 'tracker.statuses.blocked'"
else
    fail "T7: procedure missing 'tracker.statuses.blocked'"
fi

# ---------------------------------------------------------------------------
# Test 8: escalation comment includes resume instruction
# ---------------------------------------------------------------------------
if grep -q 'Resume: /n1:n1-start' "$HEADLESS_FILE"; then
    pass "T8: procedure contains 'Resume: /n1:n1-start'"
else
    fail "T8: procedure missing 'Resume: /n1:n1-start'"
fi

# ---------------------------------------------------------------------------
# Test 9: tracker init contains blocked status slot
# ---------------------------------------------------------------------------
TRACKER_INIT="${PLUGIN_ROOT}/skills/n1-init/steps/03-tracker.md"
if grep -q '"blocked"' "$TRACKER_INIT"; then
    pass "T9: tracker init contains '\"blocked\"' config slot"
else
    fail "T9: tracker init missing '\"blocked\"' config slot"
fi

# ---------------------------------------------------------------------------
# Test 10: resume.md mentions escalated step handling
# ---------------------------------------------------------------------------
RESUME_FILE="${PLUGIN_ROOT}/skills/n1-start/procedures/resume.md"
if grep -q 'escalated' "$RESUME_FILE"; then
    pass "T10: resume.md mentions 'escalated'"
else
    fail "T10: resume.md missing 'escalated'"
fi

# ---------------------------------------------------------------------------
# Test 11: procedure references N1_UNATTENDED ask-mode gate
# ---------------------------------------------------------------------------
if grep -q 'N1_UNATTENDED' "$HEADLESS_FILE"; then
    pass "T11: procedure references N1_UNATTENDED"
else
    fail "T11: procedure missing N1_UNATTENDED reference"
fi

# ---------------------------------------------------------------------------
# Test 12: ask-mode branch marker present
# ---------------------------------------------------------------------------
if grep -q 'ask-mode' "$HEADLESS_FILE"; then
    pass "T12: procedure contains 'ask-mode' branch marker"
else
    fail "T12: procedure missing 'ask-mode' branch marker"
fi

# ---------------------------------------------------------------------------
# Test 13: ask-mode question includes an explicit stop option
# ---------------------------------------------------------------------------
if grep -q 'Stop this ticket' "$HEADLESS_FILE"; then
    pass "T13: procedure contains 'Stop this ticket' option"
else
    fail "T13: procedure missing 'Stop this ticket' option"
fi

# ---------------------------------------------------------------------------
# Test 14: ask-mode answers are tagged [asked] in the Decision Ledger
# ---------------------------------------------------------------------------
if grep -q '\[asked\]' "$HEADLESS_FILE"; then
    pass "T14: procedure contains '[asked]' ledger tag"
else
    fail "T14: procedure missing '[asked]' ledger tag"
fi

# ---------------------------------------------------------------------------
# Test 15: deterministic blocked-status resolution snippet present
# ---------------------------------------------------------------------------
if grep -q "n1_config_val '.tracker.statuses.blocked'" "$HEADLESS_FILE"; then
    pass "T15: procedure resolves tracker.statuses.blocked via config"
else
    fail "T15: procedure missing deterministic blocked-status resolution"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

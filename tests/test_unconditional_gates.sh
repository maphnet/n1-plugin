#!/usr/bin/env bash
# tests/test_unconditional_gates.sh
# Verifies that unconditional gates (security, architecture, public-API escalations,
# release confirmation) stay unconditional and that autonomy.mode is gone (N1-442).
#
# Run: bash tests/test_unconditional_gates.sh
# Expected: all tests PASS; exit 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Setup: source lib/config.sh with a temporary mock config
# ---------------------------------------------------------------------------
MOCK_CONFIG=$(mktemp /tmp/n1-test-config-XXXXXX.json)
echo '{}' > "$MOCK_CONFIG"

# Source lib/config.sh; override n1_config_file to return mock
source "${PLUGIN_ROOT}/lib/config.sh"
n1_config_file() { printf '%s' "$MOCK_CONFIG"; }

# ---------------------------------------------------------------------------
# Test 4: alwaysAskOn is a fixed constant (n1_escalation_val), NOT in 'autonomy'
# The unconditional gates must NOT be routable through autonomy config.
# ---------------------------------------------------------------------------
escalation_list=$(n1_escalation_val alwaysAskOn)
autonomy_security=$(n1_config_val '.autonomy.alwaysAskOn' "$MOCK_CONFIG" 2>/dev/null || true)
if [[ "$escalation_list" == *security* ]] && [ -z "$autonomy_security" ]; then
    pass "T4: security/architecture/public-api gates are a fixed constant, not in 'autonomy'"
else
    fail "T4: expected constant list with security and no autonomy.alwaysAskOn, got '${escalation_list}' / '${autonomy_security}'"
fi

# ---------------------------------------------------------------------------
# Test 5: Release confirmation gate in n1-release is unconditional
# (grep-based structural check)
# ---------------------------------------------------------------------------
RELEASE_CONFIRM="${PLUGIN_ROOT}/skills/n1-release/steps/02-confirm-execute.md"
if grep -q 'This gate is unconditional' "$RELEASE_CONFIRM" 2>/dev/null; then
    pass "T5: n1-release Step 3 Confirmation Gate carries 'unconditional' marker"
else
    fail "T5: n1-release steps/02-confirm-execute.md missing 'This gate is unconditional' marker — release gate may have been weakened"
fi

# ---------------------------------------------------------------------------
# Test 6c: security carve-out and ambiguous done-status fall-through stay in the skill text (N1-442)
# ---------------------------------------------------------------------------
if grep -qF 'If the findings involve security/architecture/public API:** show the interactive prompt' "${PLUGIN_ROOT}/skills/n1-start/procedures/autonomy-headless.md" 2>/dev/null; then
    pass "T6c: autonomy-headless.md keeps the security/architecture/public-API prompt carve-out"
else
    fail "T6c: autonomy-headless.md lost the security/architecture/public-API carve-out line"
fi
if grep -qF 'If zero or two or more candidates match: fall through to the prompt' "${PLUGIN_ROOT}/skills/n1-finish/references/done-status-recovery.md" 2>/dev/null; then
    pass "T6d: done-status-recovery.md keeps the zero-or-2+ fall-through"
else
    fail "T6d: done-status-recovery.md lost the zero-or-2+ fall-through line"
fi

# ---------------------------------------------------------------------------
# Test 6b: the inert N1_RUN_ID "inside a pipeline" guard is gone (N1-192)
# ---------------------------------------------------------------------------
if grep -q 'cannot run inside a pipeline' "$RELEASE_CONFIRM" 2>/dev/null; then
    fail "T6b: n1-release steps/02-confirm-execute.md still carries the inert N1_RUN_ID pipeline guard"
else
    pass "T6b: n1-release has no inert pipeline guard"
fi

# ---------------------------------------------------------------------------
# Test 10: autonomy.mode, its sub-keys and the preset are gone from shipped code (N1-442)
# ---------------------------------------------------------------------------
if grep -rqE 'n1_autonomy_val|autonomy\.mode|mechanicalPrompts|qualityEscalations|acceptanceGate|N1_AUTONOMY_PRESET' \
    "${PLUGIN_ROOT}/skills" "${PLUGIN_ROOT}/agents" "${PLUGIN_ROOT}/hooks" "${PLUGIN_ROOT}/lib" "${PLUGIN_ROOT}/references"; then
    fail "T10: autonomy mode keys still referenced in skills/agents/hooks/lib/references"
else
    pass "T10: no autonomy mode keys in skills/agents/hooks/lib/references"
fi
if declare -F n1_autonomy_val >/dev/null; then
    fail "T10b: lib/config.sh still defines n1_autonomy_val"
else
    pass "T10b: n1_autonomy_val is not defined"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -f "$MOCK_CONFIG"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

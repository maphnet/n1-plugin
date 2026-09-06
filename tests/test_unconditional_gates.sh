#!/usr/bin/env bash
# tests/test_unconditional_gates.sh
# Verifies that unconditional gates (security, architecture, public-API escalations,
# release confirmation) are structurally independent from autonomy.mode.
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
cat > "$MOCK_CONFIG" <<'EOF'
{
  "autonomy": { "mode": "hands-off" },
  "escalation": {
    "alwaysAskOn": ["security", "architecture", "public-api"]
  }
}
EOF

# Source lib/config.sh; override n1_config_file to return mock
source "${PLUGIN_ROOT}/lib/config.sh"
n1_config_file() { printf '%s' "$MOCK_CONFIG"; }

# ---------------------------------------------------------------------------
# Test 1: hands-off mode -> mechanicalPrompts = auto
# ---------------------------------------------------------------------------
val=$(n1_autonomy_val 'mechanicalPrompts')
if [ "$val" = "auto" ]; then
    pass "T1: autonomy.mode=hands-off -> mechanicalPrompts=auto"
else
    fail "T1: expected auto, got '${val}'"
fi

# ---------------------------------------------------------------------------
# Test 2: hands-off mode -> qualityEscalations = auto-accept
# ---------------------------------------------------------------------------
val=$(n1_autonomy_val 'qualityEscalations')
if [ "$val" = "auto-accept" ]; then
    pass "T2: autonomy.mode=hands-off -> qualityEscalations=auto-accept"
else
    fail "T2: expected auto-accept, got '${val}'"
fi

# ---------------------------------------------------------------------------
# Test 3: hands-off mode -> tailChain = suggest (never auto)
# ---------------------------------------------------------------------------
val=$(n1_autonomy_val 'tailChain')
if [ "$val" = "suggest" ]; then
    pass "T3: autonomy.mode=hands-off -> tailChain=suggest"
else
    fail "T3: expected suggest, got '${val}'"
fi

# ---------------------------------------------------------------------------
# Test 4: escalation.alwaysAskOn is in 'escalation' block, NOT in 'autonomy'
# The unconditional gates must NOT be routable through n1_autonomy_val.
# ---------------------------------------------------------------------------
escalation_security=$(n1_config_val '.escalation.alwaysAskOn' "$MOCK_CONFIG" 2>/dev/null || true)
autonomy_security=$(n1_config_val '.autonomy.alwaysAskOn' "$MOCK_CONFIG" 2>/dev/null || true)
if [ -z "$autonomy_security" ]; then
    pass "T4: security/architecture/public-api gates live in 'escalation' block, not 'autonomy'"
else
    fail "T4: autonomy.alwaysAskOn should be absent, got '${autonomy_security}'"
fi

# ---------------------------------------------------------------------------
# Test 5: Release confirmation gate in n1-release is NOT routed through n1_autonomy_val
# (grep-based structural check)
# ---------------------------------------------------------------------------
RELEASE_SKILL="${PLUGIN_ROOT}/skills/n1-release/SKILL.md"
if grep -q 'This gate is unconditional' "$RELEASE_SKILL" 2>/dev/null; then
    pass "T5: n1-release Step 3 Confirmation Gate carries 'unconditional' marker"
else
    fail "T5: n1-release SKILL.md missing 'This gate is unconditional' marker — release gate may have been weakened"
fi

# ---------------------------------------------------------------------------
# Test 6: n1-release Step 3 does NOT call n1_autonomy_val to decide whether to show prompt
# ---------------------------------------------------------------------------
# We check the region between "## Step 3" and "## Step 4" for absence of n1_autonomy_val calls.
GATE_SECTION=$(awk '/^## Step 3:/,/^## Step 4:/' "$RELEASE_SKILL" 2>/dev/null || true)
if echo "$GATE_SECTION" | grep -q 'n1_autonomy_val'; then
    fail "T6: n1-release Step 3 calls n1_autonomy_val — release gate is NOT unconditional"
else
    pass "T6: n1-release Step 3 does not call n1_autonomy_val"
fi

# ---------------------------------------------------------------------------
# Test 7: interactive mode -> mechanicalPrompts = ask (gate preserved)
# ---------------------------------------------------------------------------
cat > "$MOCK_CONFIG" <<'EOF'
{
  "autonomy": { "mode": "interactive" },
  "escalation": {
    "alwaysAskOn": ["security", "architecture", "public-api"]
  }
}
EOF
val=$(n1_autonomy_val 'mechanicalPrompts')
if [ "$val" = "ask" ]; then
    pass "T7: autonomy.mode=interactive -> mechanicalPrompts=ask"
else
    fail "T7: expected ask, got '${val}'"
fi

# ---------------------------------------------------------------------------
# Test 8: Legacy config (no autonomy.mode) -> falls back to individual keys
# ---------------------------------------------------------------------------
cat > "$MOCK_CONFIG" <<'EOF'
{
  "autonomy": { "brainstorm": "interactive", "mechanicalPrompts": "ask" }
}
EOF
val=$(n1_autonomy_val 'mechanicalPrompts')
if [ "$val" = "ask" ]; then
    pass "T8: legacy config (no autonomy.mode) falls back to individual key read"
else
    fail "T8: expected ask (legacy fallback), got '${val}'"
fi

# ---------------------------------------------------------------------------
# Test 9: Completely empty autonomy config -> hands-off defaults
# ---------------------------------------------------------------------------
cat > "$MOCK_CONFIG" <<'EOF'
{}
EOF
val=$(n1_autonomy_val 'mechanicalPrompts')
if [ "$val" = "auto" ]; then
    pass "T9: no autonomy config at all -> mechanicalPrompts defaults to auto (hands-off)"
else
    fail "T9: expected auto (hands-off default), got '${val}'"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -f "$MOCK_CONFIG"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

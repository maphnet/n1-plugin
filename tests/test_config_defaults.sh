#!/usr/bin/env bash
# tests/test_config_defaults.sh
# Verifies that constant-key accessor functions return code defaults when
# config keys are absent, and respect config overrides when present.
# Run: bash tests/test_config_defaults.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/config.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 -- expected '$2', got '$3'"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$label"; else fail "$label" "$expected" "$actual"; fi
}

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ---- Test group 1: Empty config -> code defaults ----
export N1_HOME="$TMPDIR_TEST/empty"
mkdir -p "$N1_HOME"
echo '{}' > "$N1_HOME/config.json"

assert_eq "T1: plan_review_enabled default" "true" "$(n1_plan_review_enabled)"
assert_eq "T2: test_coverage_tier default" "maintain" "$(n1_test_coverage_tier)"
assert_eq "T3: review_min_clean_passes default" "1" "$(n1_review_min_clean_passes)"
assert_eq "T4: ci_checks enabled default" "true" "$(n1_ci_checks_val enabled)"
assert_eq "T5: ci_checks maxFixAttempts default" "3" "$(n1_ci_checks_val maxFixAttempts)"
assert_eq "T6: ci_checks confidenceThreshold default" "0.7" "$(n1_ci_checks_val confidenceThreshold)"
assert_eq "T7: escalation checkpoints default" '["pr"]' "$(n1_escalation_val checkpoints)"
assert_eq "T8: memory ticketContext default" "true" "$(n1_memory_val ticketContext)"
assert_eq "T9: memory decisions default" "true" "$(n1_memory_val decisions)"

# ---- Test group 2: Config overrides take precedence ----
export N1_HOME="$TMPDIR_TEST/override"
mkdir -p "$N1_HOME"
cat > "$N1_HOME/config.json" <<'CONF'
{"planReview":{"reviewPlan":false},"testCoverage":{"tier":"standard"},"review":{"minCleanPasses":2},"ciChecks":{"enabled":false,"maxFixAttempts":5,"confidenceThreshold":0.9},"escalation":{"checkpoints":["pr","merge"]},"memory":{"ticketContext":false,"decisions":false}}
CONF

assert_eq "T10: plan_review_enabled override" "false" "$(n1_plan_review_enabled)"
assert_eq "T11: test_coverage_tier override" "standard" "$(n1_test_coverage_tier)"
assert_eq "T12: review_min_clean_passes override" "2" "$(n1_review_min_clean_passes)"
assert_eq "T13: ci_checks enabled override" "false" "$(n1_ci_checks_val enabled)"
assert_eq "T14: ci_checks maxFixAttempts override" "5" "$(n1_ci_checks_val maxFixAttempts)"
assert_eq "T15: ci_checks confidenceThreshold override" "0.9" "$(n1_ci_checks_val confidenceThreshold)"
assert_eq "T16: memory ticketContext override" "false" "$(n1_memory_val ticketContext)"
assert_eq "T17: memory decisions override" "false" "$(n1_memory_val decisions)"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

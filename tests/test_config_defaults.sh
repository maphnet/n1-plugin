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
assert_eq "T3b: review_narrow_threshold default" "50" "$(n1_review_narrow_threshold)"
assert_eq "T3c: review_skip_doc_config default" "true" "$(n1_review_skip_doc_config)"
assert_eq "T3d: review_narrow_threshold_codex default" "100" "$(n1_review_narrow_threshold_codex)"
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
{"planReview":{"reviewPlan":false},"testCoverage":{"tier":"standard"},"review":{"minCleanPasses":2,"narrowThreshold":30,"skipDocConfigOnly":false,"narrowThresholdCodexMode":75},"ciChecks":{"enabled":false,"maxFixAttempts":5,"confidenceThreshold":0.9},"escalation":{"checkpoints":["pr","merge"]},"memory":{"ticketContext":false,"decisions":false}}
CONF

assert_eq "T10: plan_review_enabled override" "false" "$(n1_plan_review_enabled)"
assert_eq "T11: test_coverage_tier override" "standard" "$(n1_test_coverage_tier)"
assert_eq "T12: review_min_clean_passes override" "2" "$(n1_review_min_clean_passes)"
assert_eq "T12b: review_narrow_threshold override" "30" "$(n1_review_narrow_threshold)"
assert_eq "T12c: review_skip_doc_config override" "false" "$(n1_review_skip_doc_config)"
assert_eq "T12d: review_narrow_threshold_codex override" "75" "$(n1_review_narrow_threshold_codex)"
assert_eq "T13: ci_checks enabled override" "false" "$(n1_ci_checks_val enabled)"
assert_eq "T14: ci_checks maxFixAttempts override" "5" "$(n1_ci_checks_val maxFixAttempts)"
assert_eq "T15: ci_checks confidenceThreshold override" "0.9" "$(n1_ci_checks_val confidenceThreshold)"
assert_eq "T16: memory ticketContext override" "false" "$(n1_memory_val ticketContext)"
assert_eq "T17: memory decisions override" "false" "$(n1_memory_val decisions)"

# ---- Test group 3: n1_config_val direct calls (regression for NP-213) ----
mkdir -p "$TMPDIR_TEST/nullcase"
echo '{"explicitNull": null}' > "$TMPDIR_TEST/nullcase/config.json"

assert_eq "T18: config_val explicit false (direct, not via wrapper)" "false" "$(n1_config_val '.ciChecks.enabled')"
assert_eq "T19: config_val absent key still empty" "" "$(n1_config_val '.doesNotExist.enabled')"
assert_eq "T20: config_val explicit null still empty" "" "$(n1_config_val '.explicitNull' "$TMPDIR_TEST/nullcase/config.json")"

# ---- Test group 4: merge gate helpers (NP-212) ----
mg() { if "$@"; then echo allow; else echo deny; fi; }
export N1_HOME="$TMPDIR_TEST/merge"
mkdir -p "$N1_HOME"
unset N1_QUEUE_RUN_ID

echo '{}' > "$N1_HOME/config.json"
assert_eq "T21: merge_allowed default deny" "deny" "$(mg n1_merge_allowed)"
assert_eq "T22: finish_enabled default off" "deny" "$(mg n1_finish_enabled)"

echo '{"finishWork":{"enabled":true,"mergeOnFinish":true}}' > "$N1_HOME/config.json"
assert_eq "T23: interactive merge allowed" "allow" "$(mg n1_merge_allowed)"
assert_eq "T24: interactive finish enabled" "allow" "$(mg n1_finish_enabled)"
assert_eq "T25: queue ignores finishWork.mergeOnFinish (incident)" "deny" "$(N1_QUEUE_RUN_ID=RUN1 mg n1_merge_allowed)"
assert_eq "T26: queue child skips n1-finish when merge denied" "deny" "$(N1_QUEUE_RUN_ID=RUN1 mg n1_finish_enabled)"

echo '{"finishWork":{"enabled":true,"mergeOnFinish":false}}' > "$N1_HOME/config.json"
assert_eq "T27: interactive merge denied when mergeOnFinish false" "deny" "$(mg n1_merge_allowed)"
assert_eq "T28: interactive still enters n1-finish (human-merge path)" "allow" "$(mg n1_finish_enabled)"

echo '{"finishWork":{"enabled":false,"mergeOnFinish":true}}' > "$N1_HOME/config.json"
assert_eq "T29: mergeOnFinish needs finishWork.enabled" "deny" "$(mg n1_merge_allowed)"

echo '{"queue":{"mergeOnFinish":true}}' > "$N1_HOME/config.json"
assert_eq "T30: queue merge allowed when queue.mergeOnFinish true" "allow" "$(N1_QUEUE_RUN_ID=RUN1 mg n1_merge_allowed)"
assert_eq "T31: queue child enters n1-finish when merge allowed" "allow" "$(N1_QUEUE_RUN_ID=RUN1 mg n1_finish_enabled)"
assert_eq "T32: queue key does not leak into interactive runs" "deny" "$(mg n1_merge_allowed)"

# ---- Test group 5: one decision path in skills, CI and no-CI alike (NP-212) ----
SK="$SCRIPT_DIR/../skills"
has() { grep -q -- "$2" "$1" && echo yes || echo no; }
assert_eq "T33: n1-start finish gate calls n1_finish_enabled" "yes" "$(has "$SK/n1-start/steps/finish.md" 'n1_finish_enabled')"
assert_eq "T34: n1-start finish gate no longer reads N1_STOP_AT" "no" "$(has "$SK/n1-start/steps/finish.md" 'N1_STOP_AT')"
assert_eq "T35: n1-start finish gate no longer reads finishWork.enabled" "no" "$(has "$SK/n1-start/steps/finish.md" "n1_config_val '.finishWork.enabled'")"
assert_eq "T36: n1-ci chaining calls n1_finish_enabled" "yes" "$(has "$SK/n1-ci/steps/01-monitor.md" 'n1_finish_enabled')"
assert_eq "T37: n1-finish merge calls n1_merge_allowed" "yes" "$(has "$SK/n1-finish/steps/02-merge.md" 'n1_merge_allowed')"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

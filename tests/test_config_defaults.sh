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

assert_eq "T3b: review_narrow_threshold default" "50" "$(n1_review_narrow_threshold)"
assert_eq "T3c: review_skip_doc_config default" "true" "$(n1_review_skip_doc_config)"
mkdir -p "$TMPDIR_TEST/override"
echo '{"escalation":{"alwaysAskOn":["security"]}}' > "$TMPDIR_TEST/override/config.json"
assert_eq "T5: escalation alwaysAskOn is a constant" '["security","architecture","public-api"]' "$(N1_HOME="$TMPDIR_TEST/override" n1_escalation_val alwaysAskOn)"

# ---- Test group 2: Config overrides take precedence ----
export N1_HOME="$TMPDIR_TEST/override"
mkdir -p "$N1_HOME"
cat > "$N1_HOME/config.json" <<'CONF'
{"review":{"narrowThreshold":30,"skipDocConfigOnly":false}}
CONF

assert_eq "T12b: review_narrow_threshold override" "30" "$(n1_review_narrow_threshold)"
assert_eq "T12c: review_skip_doc_config override" "false" "$(n1_review_skip_doc_config)"

# ---- Test group 3: n1_config_val direct calls (regression for NP-213) ----
mkdir -p "$TMPDIR_TEST/nullcase"
echo '{"explicitNull": null}' > "$TMPDIR_TEST/nullcase/config.json"

assert_eq "T18: config_val explicit false (direct, not via wrapper)" "false" "$(n1_config_val '.review.skipDocConfigOnly')"
assert_eq "T19: config_val absent key still empty" "" "$(n1_config_val '.doesNotExist.enabled')"
assert_eq "T20: config_val explicit null still empty" "" "$(n1_config_val '.explicitNull' "$TMPDIR_TEST/nullcase/config.json")"

# ---- Test group 4: post-deploy verification gate (N1-81) ----
post_deploy_gate() { n1_post_deploy_verification_enabled; }
mkdir -p "$TMPDIR_TEST/post-deploy"
export N1_HOME="$TMPDIR_TEST/post-deploy"

echo '{"localTesting":{"mode":"test"}}' > "$N1_HOME/config.json"
assert_eq "T21: post-deploy gate defaults off without smoke" "false" "$(post_deploy_gate)"

echo '{"localTesting":{"mode":"smoke"}}' > "$N1_HOME/config.json"
assert_eq "T22: post-deploy gate enables legacy smoke" "true" "$(post_deploy_gate)"

echo '{"finishWork":{"postDeployVerification":{"enabled":true}},"localTesting":{"mode":"test"}}' > "$N1_HOME/config.json"
assert_eq "T23: post-deploy gate accepts explicit true" "true" "$(post_deploy_gate)"

echo '{"finishWork":{"postDeployVerification":{"enabled":false}},"localTesting":{"mode":"smoke"}}' > "$N1_HOME/config.json"
assert_eq "T24: explicit false overrides legacy smoke" "false" "$(post_deploy_gate)"

echo '{"finishWork":{"postDeployVerification":{"enabled":false}},"localTesting":{"mode":"test"}}' > "$N1_HOME/config.json"
assert_eq "T25: explicit false remains off without smoke" "false" "$(post_deploy_gate)"

echo '{"localTesting":{"mode":"live"}}' > "$N1_HOME/config.json"
assert_eq "T26: explicit non-smoke mode remains off" "false" "$(post_deploy_gate)"

echo '{"finishWork":{"postDeployVerification":{"enabled":"true"}},"localTesting":{"mode":"smoke"}}' > "$N1_HOME/config.json"
assert_eq "T27: invalid explicit value fails closed" "false" "$(post_deploy_gate)"

# ---- Test group 5: merge gate helpers removed (N1-114: N1 never merges) ----
export N1_HOME="$TMPDIR_TEST/merge"
mkdir -p "$N1_HOME"
unset N1_QUEUE_RUN_ID

assert_eq "T32: n1_finish_enabled removed" "no" "$(declare -F n1_finish_enabled >/dev/null && echo yes || echo no)"
assert_eq "T31: n1_merge_allowed removed (N1-114)" "no" "$(declare -F n1_merge_allowed >/dev/null && echo yes || echo no)"

# ---- Test group 5b: mergeOnFinish strict boolean (N1-140) ----
merge_gate() { printf '%s\n' "$1" > "$N1_HOME/config.json"; n1_finish_merge_enabled; }
assert_eq "T33: mergeOnFinish absent -> false" "false" "$(merge_gate '{}')"
assert_eq "T34: mergeOnFinish true -> true" "true" "$(merge_gate '{"finishWork":{"mergeOnFinish":true}}')"
assert_eq "T35: mergeOnFinish false -> false" "false" "$(merge_gate '{"finishWork":{"mergeOnFinish":false}}')"
assert_eq "T36: stale string \"true\" -> false" "false" "$(merge_gate '{"finishWork":{"mergeOnFinish":"true"}}')"
assert_eq "T37: number 1 -> false" "false" "$(merge_gate '{"finishWork":{"mergeOnFinish":1}}')"
assert_eq "T38: finishWork not an object -> false" "false" "$(merge_gate '{"finishWork":true}')"
assert_eq "T39: invalid JSON -> false" "false" "$(merge_gate '{bad')"
assert_eq "T41: valid object followed by garbage -> false" "false" "$(merge_gate '{"finishWork":{"mergeOnFinish":true}} garbage')"
assert_eq "T40: missing config file -> false" "false" "$(N1_HOME="$TMPDIR_TEST/merge-missing" n1_finish_merge_enabled)"

# ---- Test group 5c: fullAuto strict boolean + merge predicate (N1-146) ----
unset N1_HEADLESS
fa_gate() { printf '%s\n' "$1" > "$N1_HOME/config.json"; n1_fullauto_enabled; }
assert_eq "T60: fullAuto absent -> false" "false" "$(fa_gate '{}')"
assert_eq "T61: fullAuto true -> true" "true" "$(fa_gate '{"autonomy":{"fullAuto":true}}')"
assert_eq "T62: fullAuto false -> false" "false" "$(fa_gate '{"autonomy":{"fullAuto":false}}')"
assert_eq "T63: string \"true\" -> false" "false" "$(fa_gate '{"autonomy":{"fullAuto":"true"}}')"
assert_eq "T64: number 1 -> false" "false" "$(fa_gate '{"autonomy":{"fullAuto":1}}')"
assert_eq "T65: autonomy not an object -> false" "false" "$(fa_gate '{"autonomy":"hands-off"}')"
assert_eq "T66: invalid JSON -> false" "false" "$(fa_gate '{bad')"
assert_eq "T67: missing config file -> false" "false" "$(N1_HOME="$TMPDIR_TEST/merge-missing" n1_fullauto_enabled)"
assert_eq "T68: no jq -> false" "false" "$(printf '%s\n' '{"autonomy":{"fullAuto":true}}' > "$N1_HOME/config.json"; command() { [ "${2:-}" = jq ] && return 1; builtin command "$@"; }; n1_fullauto_enabled)"

ma() { printf '%s\n' "$1" > "$N1_HOME/config.json"; shift; ( unset N1_QUEUE_RUN_ID N1_HEADLESS; for kv in "$@"; do export "$kv"; done; n1_merge_authorized ); }
MOF='{"finishWork":{"mergeOnFinish":true}}'
BOTH='{"finishWork":{"mergeOnFinish":true},"autonomy":{"fullAuto":true}}'
assert_eq "T69: mergeOnFinish, interactive -> true" "true" "$(ma "$MOF")"
assert_eq "T70: mergeOnFinish, queue child -> false" "false" "$(ma "$MOF" N1_QUEUE_RUN_ID=q-1)"
assert_eq "T71: mergeOnFinish, headless -> false" "false" "$(ma "$MOF" N1_HEADLESS=1)"
assert_eq "T72: both keys, queue headless -> true" "true" "$(ma "$BOTH" N1_QUEUE_RUN_ID=q-1 N1_HEADLESS=1)"
assert_eq "T73: fullAuto only, interactive -> false" "false" "$(ma '{"autonomy":{"fullAuto":true}}')"
assert_eq "T74: fullAuto + string mergeOnFinish, queue -> false" "false" "$(ma '{"finishWork":{"mergeOnFinish":"true"},"autonomy":{"fullAuto":true}}' N1_QUEUE_RUN_ID=q-1 N1_HEADLESS=1)"
assert_eq "T75: no keys -> false" "false" "$(ma '{}')"

# ---- Test group 6: one decision path in skills (NP-212) ----
SK="$SCRIPT_DIR/../skills"
has() { grep -q -- "$2" "$1" && echo yes || echo no; }
assert_eq "T44: n1-start finish gate no longer reads N1_STOP_AT" "no" "$(has "$SK/n1-start/steps/finish.md" 'N1_STOP_AT')"
assert_eq "T45: n1-start finish step tells the user to run n1-finish" "yes" "$(has "$SK/n1-start/steps/finish.md" '/n1:n1-finish')"
assert_eq "T46: n1-ci never chains into n1-finish (N1-114)" "no" "$(has "$SK/n1-ci/steps/01-monitor.md" 'chain:yes')"
assert_eq "T76: n1-init offers autonomy.fullAuto" "yes" "$(has "$SK/n1-init/steps/10-quality-config.md" '"fullAuto"')"
assert_eq "T77: fullAuto is not a dead key in the prune list" "no" "$(has "$SK/n1-init/steps/01-prerequisites.md" 'fullAuto')"
assert_eq "T78: architecture documents autonomy.fullAuto" "yes" "$(has "$SCRIPT_DIR/../references/architecture.md" '| `fullAuto` |')"

# ---- Test group 7: cross-host review defaults (N1-94) ----
export N1_HOME="$TMPDIR_TEST/xhr"
mkdir -p "$N1_HOME"
echo '{}' > "$N1_HOME/config.json"
assert_eq "T50: crossHostReview autoTriage defaults true" "true" "$(n1_cross_host_review_val autoTriage)"
assert_eq "T51: crossHostReview enabled defaults true" "true" "$(n1_cross_host_review_val enabled)"
assert_eq "T52: crossHostReview maxFixAttempts defaults 1" "1" "$(n1_cross_host_review_val maxFixAttempts)"

export N1_HOME="$TMPDIR_TEST/xhr-missing"
assert_eq "T53: autoTriage defaults true without config" "true" "$(n1_cross_host_review_val autoTriage)"

export N1_HOME="$TMPDIR_TEST/xhr"
echo '{"crossHostReview":{"autoTriage":false,"maxFixAttempts":2}}' > "$N1_HOME/config.json"
assert_eq "T54: autoTriage explicit false opts out" "false" "$(n1_cross_host_review_val autoTriage)"
assert_eq "T55: maxFixAttempts override" "2" "$(n1_cross_host_review_val maxFixAttempts)"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

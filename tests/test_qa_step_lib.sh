#!/usr/bin/env bash
# N1-476: lib/qa-step.sh runs the qa step's verifyGate and break-check blocks; qa.md's fence calls them.
# Run: bash tests/test_qa_step_lib.sh
set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_ROOT="$REPO_ROOT"
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1 (missing: $3)"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected=[$2] actual=[$3])"; fi; }

source "$REPO_ROOT/lib/config.sh"; source "$REPO_ROOT/lib/step.sh"; source "$REPO_ROOT/lib/validation.sh"
source "$REPO_ROOT/lib/qa-step.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_RUN_ID N1_STORY_ID N1_STORY_BRANCH N1_QUEUE_RUN_ID
export N1_HOME="$T/home" ID="QA-1" N1_SESSION_ID=test-session
MEM="$N1_HOME/memory/$ID"; mkdir -p "$MEM"; BT='`'

# --- n1_qa_verify ---
printf -- '---\n---\n' > "$MEM/overview.md"
printf '%s\n' '### Evidence' "New test: n | ${BT}true${BT}" 'Exit code: 0' > "$MEM/qa.md"
printf '%s\n' 'Verdict: PASS' 'n1:signals tests_added=1 new_functionality_untested=true' > "$MEM/qa-return.md"
OUT=$(n1_qa_verify 2>&1)
has "verify: NEW_FUNC_UNTESTED read from qa-return.md" "$OUT" "NEW_FUNC_UNTESTED=true"
has "verify: evidenced qa.md is not degraded" "$OUT" "QA_DEGRADED=0"
eq "verify: return signals written to qa.md" "1" "$(n1_read_signal "$MEM/qa.md" tests_added)"
eq "verify: qa-return.md consumed (no stale signals in the next qa cycle)" "no" "$([ -e "$MEM/qa-return.md" ] && echo yes || echo no)"
printf '%s\n' "New test: n | ${BT}true${BT}" > "$MEM/qa.md"; rm -f "$MEM/qa-return.md"
OUT=$(n1_qa_verify 2>&1)
has "verify: no Evidence section -> degraded" "$OUT" "QA_DEGRADED=1"
eq "verify: no return file -> empty NEW_FUNC_UNTESTED" "" "$(sed -n 's/^NEW_FUNC_UNTESTED=//p' <<<"$OUT")"
eq "verify: degraded writes qa_verdict_unverified" "true" "$(n1_read_frontmatter "$MEM/overview.md" qa_verdict_unverified)"

# --- n1_qa_break_check ---
printf -- '---\n---\n' > "$MEM/overview.md"
n1_break_check_base() { echo base; }
n1_break_check() { echo '{"success":true,"verdict":"red-then-green"}'; }
printf '%s\n' "Regression test: t_reg | ${BT}true${BT}" "New test: t_new | ${BT}true${BT}" > "$MEM/qa.md"
OUT=$(n1_qa_break_check "$T" 2>&1); RC=$?
eq "break-check: rc 0" "0" "$RC"
has "break-check: verdict printed" "$OUT" "BC_VERDICT=red-then-green"
has "break-check: empty TQ list delimited" "$OUT" $'BREAK_CHECK_TQ<<\n\nBREAK_CHECK_TQ>>'
eq "break-check: verdict frontmatter" "red-then-green" "$(n1_read_frontmatter "$MEM/overview.md" break_check_verdict)"
n1_break_check() { echo '{"success":true,"verdict":"inconclusive"}'; }
OUT=$(n1_qa_break_check "$T" 2>&1)
has "break-check: non-red new test listed for TQ" "$OUT" $'BREAK_CHECK_TQ<<\nt_new (inconclusive)\nBREAK_CHECK_TQ>>'
OUT=$( n1_story_base() { return 1; }; n1_qa_break_check "$T" 2>&1 ); RC=$?
eq "break-check: invalid story base -> rc 1" "1" "$RC"
has "break-check: invalid story base message" "$OUT" "ERROR: invalid story base"

# --- step wiring: run qa.md's own fences ---
STEP="$REPO_ROOT/skills/n1-start/steps/qa.md"
fence() { awk -v n="$2" '/^```bash$/{c++; if (c==n) {f=1; next}} /^```$/{f=0} f' "$1" | sed '/^source /d'; }
rawfence() { awk -v n="$2" '/^```bash$/{c++; if (c==n) {f=1; next}} /^```$/{f=0} f' "$1"; }
n1_step_begin() { :; }; n1_step_end() { :; }
eq "wiring: qa.md has 3 bash fences" "3" "$(grep -c '^```bash$' "$STEP")"
eq "wiring: qa.md has no snippet exception" "0" "$(grep -c 'n1:step-snippet-exception' "$STEP")"
has "wiring: verify fence sources the lib" "$(rawfence "$STEP" 2)" 'source "$N1_ROOT/lib/qa-step.sh"'
n1_break_check() { echo '{"success":true,"verdict":"red-then-green"}'; }
printf '%s\n' '### Evidence' "Regression test: t_reg | ${BT}true${BT}" > "$MEM/qa.md"
OUT=$( cd "$REPO_ROOT" && eval "$(fence "$STEP" 2)" 2>&1 )
has "wiring: fence prints QA_DEGRADED" "$OUT" "QA_DEGRADED=0"
has "wiring: fence prints BC_VERDICT" "$OUT" "BC_VERDICT=red-then-green"

exit $FAIL

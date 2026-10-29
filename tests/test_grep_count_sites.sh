#!/usr/bin/env bash
# tests/test_grep_count_sites.sh (N1-181)
# grep -c prints 0 and exits 1 on zero matches, so `|| echo 0` double-prints.
# Verifies the counter lines in the skill files yield exactly one numeric line
# for zero matches and for a missing input file, and that the planner-failed
# local-testing skip closes the step with telemetry.
#
# Run: bash tests/test_grep_count_sites.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INV="$REPO_ROOT/skills/n1-start/steps/investigation-deliverable.md"
LT="$REPO_ROOT/skills/n1-start/steps/local-testing.md"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# 1. Static guard
if grep -nE 'grep -c.*\|\| *echo' "$INV" "$LT" "$REPO_ROOT/tests/test_related_lib.sh"; then
    fail "no 'grep -c ... || echo' remains"
else
    pass "no 'grep -c ... || echo' remains"
fi

# 2. Behavioral: eval the counter lines against zero-match and missing files
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ID=X
N1_HOME="$TMP/home"
mkdir -p "$N1_HOME/memory/$ID"
: > "$N1_HOME/memory/$ID/analysis.md"
printf 'nothing here\n' > "$TMP/inv.md"

check() { # label file QA_MD-or-INV_FILE var...
    local label="$1" file="$2" qa="$3"; shift 3
    local INV_FILE="$file" QA_MD="$qa" UNKNOWNS="" v line lines
    for v in "$@"; do
        lines=$(grep -hE "^ *$v=[$][(].*grep -cE? " "$INV" "$LT")
        [ -n "$lines" ] || { fail "$label: no line found for $v"; continue; }
        while IFS= read -r line; do
            eval "$line"
            if [[ "${!v}" =~ ^[0-9]+$ ]] && [ "${!v}" = "0" ]; then
                pass "$label: $v is a single 0"
            else
                fail "$label: $v='${!v}'"
            fi
        done <<< "$lines"
    done
}

VARS="FINDINGS_COUNT RECOMMENDATIONS_COUNT UNKNOWNS_TOTAL UNKNOWNS_ANSWERED SELF_RESOLVED UNKNOWN_COUNT UNKNOWNS_ANSWERED_ANALYSIS UNKNOWNS_ANSWERED_INVEST QA_RUNNER_COUNT"
# shellcheck disable=SC2086
check "zero-match" "$TMP/inv.md" "$TMP/inv.md" $VARS
# shellcheck disable=SC2086
check "missing-file" "$TMP/missing.md" "$TMP/missing.md" $VARS

# 3. planner_failed closes the local-testing step
if grep -q 'n1_step_end "local-testing" 11 skipped .*"skip_reason":"planner_failed"' "$LT"; then
    pass "planner_failed emits n1_step_end"
else
    fail "planner_failed emits n1_step_end"
fi

echo "$FAIL failed, $PASS passed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# tests/test_stall_stop.sh -- N1-346: same-failure stall stop for the QA, local-testing and CI fix loops.
# Helper units (lib/stall.sh) plus wiring text checks over the loop files and procedures/stall-stop.md.
# Run: bash tests/test_stall_stop.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
source lib/stall.sh
source lib/testparse.sh

PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS + 1)); else echo "FAIL: $1 -- expected '$2', got '$3'"; FAIL=$((FAIL + 1)); fi; }
OV="$T/overview.md"
ov() { printf -- '---\nstep: qa\n---\n' > "$OV"; }

# ---- n1_stall_sig ----
A=$(printf 'b\na\n' | n1_stall_sig); B=$(printf 'a\nb\na\n\n' | n1_stall_sig)
eq "S1 order, duplicates and blank lines do not change the signature" "$A" "$B"
eq "S2 signature is a hex hash" "1" "$([[ "$A" =~ ^[0-9a-f]{32,64}$ ]] && echo 1 || echo 0)"
eq "S3 empty input -> empty signature" "" "$(printf '' | n1_stall_sig)"
eq "S4 blank lines only -> empty signature" "" "$(printf '\n  \n' | n1_stall_sig)"
C=$(printf 'a\nc\n' | n1_stall_sig)
eq "S5 different names -> different signature" "1" "$([ -n "$C" ] && [ "$A" != "$C" ] && echo 1 || echo 0)"

# ---- n1_stall_check ----
ov
eq "C1 first failing round -> ok" "ok" "$(n1_stall_check "$OV" qa_fail_sig "$A")"
eq "C1b signature stored" "$A" "$(n1_read_frontmatter "$OV" qa_fail_sig)"
eq "C2 same signature twice -> stalled" "stalled" "$(n1_stall_check "$OV" qa_fail_sig "$A")"
n1_stall_check "$OV" qa_fail_sig "$A" >/dev/null; eq "C2b stalled returns 0" "0" "$?"
eq "C3 changed signature -> ok" "ok" "$(n1_stall_check "$OV" qa_fail_sig "$C")"
n1_stall_check "$OV" qa_fail_sig "$A" >/dev/null; eq "C3b ok returns 1" "1" "$?"
eq "C4 empty signature -> ok and overwrites" "ok" "$(n1_stall_check "$OV" qa_fail_sig "")"
eq "C4b stored value now empty" "" "$(n1_read_frontmatter "$OV" qa_fail_sig)"
eq "C5 empty twice -> ok (empty never matches)" "ok" "$(n1_stall_check "$OV" qa_fail_sig "")"
eq "C6 empty then a signature -> ok" "ok" "$(n1_stall_check "$OV" qa_fail_sig "$A")"
n1_stall_check "$OV" qa_fail_sig 'x\y' >/dev/null
eq "C7 non-hex input is stored as empty" "" "$(n1_read_frontmatter "$OV" qa_fail_sig)"
eq "C7b non-hex twice -> ok" "ok" "$(n1_stall_check "$OV" qa_fail_sig 'x\y')"
eq "C8 missing overview.md -> ok" "ok" "$(n1_stall_check "$T/none.md" ci_fail_sig "$A")"
eq "C8b missing overview.md twice -> ok (standalone n1-ci)" "ok" "$(n1_stall_check "$T/none.md" ci_fail_sig "$A")"
ov; n1_stall_check "$OV" qa_fail_sig "$A" >/dev/null
eq "C9 keys are independent" "ok" "$(n1_stall_check "$OV" ci_fail_sig "$A")"

# ---- n1_stall_reset ----
ov; n1_stall_check "$OV" local_test_fail_sig "$A" >/dev/null; n1_stall_check "$OV" ci_fail_sig "$A" >/dev/null
n1_stall_reset "$OV" local_test_fail_sig ci_fail_sig
eq "R1 reset clears every named key" "|" "$(n1_read_frontmatter "$OV" local_test_fail_sig)|$(n1_read_frontmatter "$OV" ci_fail_sig)"
eq "R2 after a reset the same failure does not stall at once" "ok" "$(n1_stall_check "$OV" local_test_fail_sig "$A")"
eq "R3 the next identical round stalls" "stalled" "$(n1_stall_check "$OV" local_test_fail_sig "$A")"
n1_stall_reset "$T/none.md" qa_fail_sig; eq "R4 reset on a missing overview.md returns 0" "0" "$?"

# ---- n1_stall_names_lt ----
lt() { # <file> <row1-result> <row1-detail> <row3-result> <class>
    printf '%s\n' "## Local Testing Report" "" "### Existing E2E Test Results" "- **Result:** FAIL" "" \
        "### Ad-Hoc Scenario Results" "| # | Scenario | Result | Details |" "|---|----------|--------|---------|" \
        "| 1 | login works | $2 | $3 |" "| 2 | export csv | PASS | ok |" "| 3 | logout | $4 | timeout |" "" \
        "### Verdict: FAIL" "- **Failure class:** $5" > "$1"
}
lt "$T/lt1.md" FAIL "500 at 10:01" FAIL code-bug
eq "L1 FAIL rows then class" "$(printf 'login works\nlogout\nclass:code-bug')" "$(n1_stall_names_lt "$T/lt1.md")"
lt "$T/lt2.md" FAIL "500 at 10:07 after 3.2s" FAIL code-bug
eq "L2 Details changes do not alter the signature" "$(n1_stall_names_lt "$T/lt1.md" | n1_stall_sig)" "$(n1_stall_names_lt "$T/lt2.md" | n1_stall_sig)"
lt "$T/lt3.md" PASS ok PASS none
eq "L3 PASS-only table -> empty" "" "$(n1_stall_names_lt "$T/lt3.md")"
printf '%s\n' "## Local Testing Report" "### Existing E2E Test Results" "- **Result:** FAIL" "### Verdict: FAIL" "- **Failure class:** code-bug" > "$T/lt4.md"
eq "L4 failures only in existing e2e (no table) -> empty" "" "$(n1_stall_names_lt "$T/lt4.md")"
eq "L5 missing report -> empty" "" "$(n1_stall_names_lt "$T/none.md")"
lt "$T/lt6.md" FAIL x PASS code-bug
eq "L6 different FAIL set -> different signature" "1" "$([ "$(n1_stall_names_lt "$T/lt1.md" | n1_stall_sig)" != "$(n1_stall_names_lt "$T/lt6.md" | n1_stall_sig)" ] && echo 1 || echo 0)"
lt "$T/lt7.md" FAIL x FAIL infra
eq "L7 failure class is part of the signature" "1" "$([ "$(n1_stall_names_lt "$T/lt1.md" | n1_stall_sig)" != "$(n1_stall_names_lt "$T/lt7.md" | n1_stall_sig)" ] && echo 1 || echo 0)"
lt "$T/lt8.md" "**FAIL**" x "FAIL (flaky)" code-bug
eq "L8 Result must be exactly FAIL -> empty" "" "$(n1_stall_names_lt "$T/lt8.md")"

# ---- n1_stall_names_ci ----
printf 'total=3 pending=0\nFAIL\tlint\thttps://x/runs/1\nFAIL\ttest (ubuntu)\thttps://x/runs/2\n' > "$T/ci1.tsv"
printf 'total=3 pending=0\nFAIL\ttest (ubuntu)\thttps://x/runs/9\nFAIL\tlint\thttps://x/runs/8\n' > "$T/ci2.tsv"
eq "I1 check names only" "$(printf 'lint\ntest (ubuntu)')" "$(n1_stall_names_ci "$T/ci1.tsv")"
eq "I2 links and order do not alter the signature" "$(n1_stall_names_ci "$T/ci1.tsv" | n1_stall_sig)" "$(n1_stall_names_ci "$T/ci2.tsv" | n1_stall_sig)"
printf 'FAIL\tlint\thttps://x/runs/1\n' > "$T/ci3.tsv"
printf 'FAIL\tlint\thttps://x/runs/5\n' > "$T/ci4.tsv"
eq "I4 signature depends only on the lines written (skip-category check omitted upstream)" "$(n1_stall_names_ci "$T/ci3.tsv" | n1_stall_sig)" "$(n1_stall_names_ci "$T/ci4.tsv" | n1_stall_sig)"
eq "I3 missing file -> empty" "" "$(n1_stall_names_ci "$T/none.tsv")"

# ---- QA: names from qa-verify.log ----
printf 'FAIL: test a (expected=1 actual=2)\n' > "$T/q1.log"; printf 'FAIL: test a (expected=1 actual=3)\n' > "$T/q2.log"
ov; n1_stall_check "$OV" qa_fail_sig "$(n1_testparse_failed_names "$T/q1.log" | n1_stall_sig)" >/dev/null
eq "Q3 same failing test with a different detail -> stalled" "stalled" "$(n1_stall_check "$OV" qa_fail_sig "$(n1_testparse_failed_names "$T/q2.log" | n1_stall_sig)")"
ov; n1_stall_check "$OV" qa_fail_sig "$(n1_testparse_failed_names "$T/q1.log" | n1_stall_sig)" >/dev/null
eq "Q4 a round with no qa-verify.log (removed, no named tests) -> ok" "ok" "$(n1_stall_check "$OV" qa_fail_sig "$(n1_testparse_failed_names "$T/none.log" | n1_stall_sig)")"
printf 'FAILED a/test_x.py::test_x - e\n' > "$T/c1.log"; printf 'FAILED b/test_x.py::test_x - e\n' > "$T/c2.log"
eq "Q5 same bare name in different files collides in default mode" "stalled" "$(ov; n1_stall_check "$OV" qa_fail_sig "$(n1_testparse_failed_names "$T/c1.log" | n1_stall_sig)" >/dev/null; n1_stall_check "$OV" qa_fail_sig "$(n1_testparse_failed_names "$T/c2.log" | n1_stall_sig)")"
eq "Q6 same bare name in different files stays distinct in full mode -> ok" "ok" "$(ov; n1_stall_check "$OV" qa_fail_sig "$(n1_testparse_failed_names "$T/c1.log" full | n1_stall_sig)" >/dev/null; n1_stall_check "$OV" qa_fail_sig "$(n1_testparse_failed_names "$T/c2.log" full | n1_stall_sig)")"

# ---- wiring: procedures/stall-stop.md ----
P=skills/n1-start/procedures/stall-stop.md
sect() { awk -v h="## $2" '$0 == h {p=1; next} /^## /{p=0} p' "$1"; }
eq "W10 procedure has QA, Local testing, CI and Reset sections" "4" "$(grep -cE '^## (QA|Local testing|CI|Reset)$' "$P" 2>/dev/null)"
eq "W11 QA exit uses the Autonomy Gate with step qa" "1" "$(sect "$P" QA | grep -cF 'step=`qa`, action=`accept the QA failure and proceed to review`')"
eq "W11b QA ledger context names the stall" "1" "$(sect "$P" QA | grep -cF 'ledger_context=`QA stalled on the same failure: <FAILED_TESTS> failing tests')"
eq "W11c QA prompt marks no option Recommended" "0" "$(sect "$P" QA | grep -c '(Recommended)')"
eq "W11f QA prompt states the verbatim No-recommendation sentence (recommended-option rule)" "1" "$(sect "$P" QA | grep -cxF 'No recommendation. The options are equivalent given the available evidence; select based on team preference.')"
eq "W11d QA headless escalates via the Headless Guard" "1" "$(sect "$P" QA | grep -cE 'no recommended option.*Headless Guard|Headless Guard.*no recommended option')"
eq "W11e QA option 2 resets qa_fail_sig" "1" "$(sect "$P" QA | grep -cE '^2 — One more fix cycle: run § Reset with `qa_fail_sig`')"
eq "W14b QA section passes full to the name parser" "2" "$(sect "$P" QA | grep -c 'n1_testparse_failed_names "\$QD/qa-verify.log" full')"
eq "W12 CI stall goes to Step 6b" "1" "$([ "$(sect "$P" CI | grep -c 'Step 6b')" -ge 1 ] && echo 1 || echo 0)"
eq "W12b CI section has no Autonomy Gate (D1)" "0" "$(sect "$P" CI | grep -c 'Autonomy Gate')"
eq "W12c CI names reach the helper through ci-fail.tsv" "1" "$(sect "$P" CI | grep -c 'n1_stall_names_ci "\$M/ci-fail.tsv"')"
eq "W12e CI signature omits checks matching a skip category pattern" "1" "$(sect "$P" CI | grep -c 'omit checks whose name matches a `skip` category pattern')"
eq "W12d CI NOT_BRANCH_CAUSED clears ci_fail_sig (D8)" "1" "$(sect "$P" CI | grep -c 'NOT_BRANCH_CAUSED.*§ Reset with `ci_fail_sig`')"
eq "W13 local-testing stall goes to the cap exit" "1" "$(sect "$P" 'Local testing' | grep -c 'stalled on the same failure after <N> fix cycles')"
eq "W14 stall-stop.md is not in the standard-path budget list" "0" "$(grep -c 'stall-stop' tests/test_instruction_budget.sh)"

# ---- wiring: QA (steps/qa.md) ----
QA=skills/n1-start/steps/qa.md
prose() { awk '/^[[:space:]]*```/{b=!b; next} !b' "$1"; }
before() { # <text> <a> <b> -> 1 when a occurs before b in text
    local t="$1" i j; i=${t%%"$2"*}; j=${t%%"$3"*}
    [ "$i" != "$t" ] && [ "$j" != "$t" ] && [ "${#i}" -lt "${#j}" ] && echo 1 || echo 0
}
RM_LN=$(grep -nF 'rm -f "$QD/qa-verify.log"' "$QA" | head -1 | cut -d: -f1)
VL_LN=$(grep -nF 'VERIFY_LOG="$QD/qa-verify.log"' "$QA" | head -1 | cut -d: -f1)
eq "Q1 qa.md removes qa-verify.log before the verify run (D2)" "1" "$([ -n "$RM_LN" ] && [ -n "$VL_LN" ] && [ "$RM_LN" -lt "$VL_LN" ] && echo 1 || echo 0)"
eq "W1 qa.md stall pointer is in prose, not in a fence" "1" "$(prose "$QA" | grep -cF 'procedures/stall-stop.md § QA')"
QL=$(prose "$QA" | grep -F 'procedures/stall-stop.md § QA' | head -1)
eq "W2 qa.md stall check precedes the cap test" "1" "$(before "$QL" 'stall-stop.md § QA' 'qa.maxFixAttempts')"
eq "W2b qa.md stall check precedes the increment" "1" "$(before "$QL" 'stall-stop.md § QA' 'n1_increment_counter')"
eq "W2c qa.md loop exit covers the stall" "1" "$(grep -cF 'Loop exit only (PASS, cap or stall), once: run the final block below.' "$QA")"

# ---- wiring: local testing (procedures/local-testing-run.md) ----
LTR=skills/n1-start/procedures/local-testing-run.md
LP_LN=$(grep -nF 'procedures/stall-stop.md § Local testing' "$LTR" | head -1 | cut -d: -f1)
FL_LN=$(grep -n '^#### 9d\. FIX LOOP' "$LTR" | head -1 | cut -d: -f1)
SP_LN=$(awk -v s="${LP_LN:-0}" 'NR > s && index($0, "**Spawn agent:** developer (fix mode)") { print NR; exit }' "$LTR")
eq "W3 9d stall pointer sits after the 9d heading and before the developer spawn" "1" "$([ -n "$LP_LN" ] && [ -n "$FL_LN" ] && [ -n "$SP_LN" ] && [ "$FL_LN" -lt "$LP_LN" ] && [ "$LP_LN" -lt "$SP_LN" ] && echo 1 || echo 0)"
eq "W4 report template has the Failure class line (D3)" "1" "$(grep -cxF -- '- **Failure class:** infra|code-bug|none' "$LTR")"
eq "W5 report template states the Result vocabulary" "1" "$(grep -cF 'Result is exactly `PASS` or `FAIL`.' "$LTR")"
eq "W6 9d option 1 resets local_test_fail_sig" "1" "$(grep -cE '^- If 1: run `procedures/stall-stop\.md § Reset` with `local_test_fail_sig`' "$LTR")"
eq "W6b 9d option 3 resets local_test_fail_sig" "1" "$(grep -cE '^- If 3: run `procedures/stall-stop\.md § Reset` with `local_test_fail_sig`' "$LTR")"

# ---- wiring: CI (skills/n1-ci/steps/02-fix.md) ----
CF=skills/n1-ci/steps/02-fix.md
CP_LN=$(grep -nF '<N1_ROOT>/skills/n1-start/procedures/stall-stop.md § CI' "$CF" | head -1 | cut -d: -f1)
S5_LN=$(grep -n '^## Step 5: Classify Failures' "$CF" | head -1 | cut -d: -f1)
S5A_LN=$(grep -n '^### Step 5a' "$CF" | head -1 | cut -d: -f1)
eq "W7 Step 5 entry points at stall-stop.md § CI before classification" "1" "$([ -n "$CP_LN" ] && [ "$S5_LN" -lt "$CP_LN" ] && [ "$CP_LN" -lt "$S5A_LN" ] && echo 1 || echo 0)"
eq "W7b CI stall goes to Step 6b with the stall message" "1" "$(grep -cF 'stalled → **Step 6b** with "stalled on the same failure"' "$CF")"
eq "W8 Step 6b option 1 clears ci_fail_sig" "1" "$(grep -cE '^1\. Provide guidance .*clear `ci_fail_sig`' "$CF")"
eq "W8b Step 6b option 3 clears ci_fail_sig" "1" "$(grep -cE '^3\. Fix manually .*clear `ci_fail_sig`' "$CF")"
eq "W9 NOT_BRANCH_CAUSED clears ci_fail_sig (D8)" "1" "$(grep -cE 'NOT_BRANCH_CAUSED.*treat as `escalate`.*clear `ci_fail_sig`' "$CF")"
eq "W17 Step 5 escalate path clears ci_fail_sig" "1" "$(grep -cE '^- `escalate` .*ask user immediately.*clear `ci_fail_sig`' "$CF")"
eq "W18 Step 5b option 2 clears ci_fail_sig" "1" "$(grep -cE 'On option 2, clear `ci_fail_sig`' "$CF")"
eq "W19 n1-ci option lists state no recommendation" "3" "$(grep -cF 'No recommendation. The options are equivalent given the available evidence; select based on team preference.' "$CF")"
eq "W19b Step 5b option list is preceded by the no-recommendation sentence" "1" "$(grep -cE 'report path, with this sentence first, "No recommendation\. ' "$CF")"
S7_LN=$(grep -n '^### Update overview.md' "$CF" | head -1 | cut -d: -f1)
RE_LN=$(grep -nE '^Clear `ci_fail_sig` first' "$CF" | head -1 | cut -d: -f1)
eq "W16 Step 7 run end clears ci_fail_sig (no stall across n1-ci runs)" "1" "$([ -n "$S7_LN" ] && [ -n "$RE_LN" ] && [ "$S7_LN" -lt "$RE_LN" ] && echo 1 || echo 0)"

# ---- docs ----
eq "W15 architecture.md documents the stall stop" "1" "$(grep -cx '## Same-Failure Stall Stop' references/architecture.md)"
eq "W15b architecture.md documents the stale-log removal" "1" "$(grep -cF 'removes `qa-verify.log` before each verify run' references/architecture.md)"

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]

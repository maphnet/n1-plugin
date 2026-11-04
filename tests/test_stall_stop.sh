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
eq "I3 missing file -> empty" "" "$(n1_stall_names_ci "$T/none.tsv")"

# ---- QA: names from qa-verify.log ----
printf 'FAIL: test a (expected=1 actual=2)\n' > "$T/q1.log"; printf 'FAIL: test a (expected=1 actual=3)\n' > "$T/q2.log"
ov; n1_stall_check "$OV" qa_fail_sig "$(n1_testparse_failed_names "$T/q1.log" | n1_stall_sig)" >/dev/null
eq "Q3 same failing test with a different detail -> stalled" "stalled" "$(n1_stall_check "$OV" qa_fail_sig "$(n1_testparse_failed_names "$T/q2.log" | n1_stall_sig)")"
ov; n1_stall_check "$OV" qa_fail_sig "$(n1_testparse_failed_names "$T/q1.log" | n1_stall_sig)" >/dev/null
eq "Q4 a round with no qa-verify.log (removed, no named tests) -> ok" "ok" "$(n1_stall_check "$OV" qa_fail_sig "$(n1_testparse_failed_names "$T/none.log" | n1_stall_sig)")"

# ---- wiring (added by later tasks) ----

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]

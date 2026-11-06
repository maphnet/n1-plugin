#!/usr/bin/env bash
# tests/test_qa_break_check_skipped.sh — N1-469: the run-level break-check verdict is `skipped` (not
# `inconclusive`) for a non-bug ticket in mode `bugs` with no usable `Regression test:` line.
# Bug tickets, mode `all`, an unknown type, and a valid regression line keep their old paths.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA_MD="$REPO_ROOT/skills/n1-start/steps/qa.md"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }

# Extract the real run-level block (REG_LINE= ... BC_VERDICT=) from qa.md.
BLOCK=$(awk '/^REG_LINE=/{p=1} p{print} p&&/^BC_VERDICT=/{exit}' "$QA_MD")
assert_eq "qa.md has an extractable break-check verdict block" "1" "$([ -n "$BLOCK" ] && echo 1 || echo 0)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
BT='`'
run_bc() { # <case-dir> <task_type> <bc_mode> -> prints BC_VERDICT; stub call leaves <case-dir>/called
  ( set +e +u +o pipefail  # skill snippets run without errexit/pipefail
    QD="$1"; TASK_TYPE="$2"; BC_MODE="$3"; BC_BASE="base"; BC_LOG="$QD/break-check.log"
    source "$REPO_ROOT/lib/breakcheck.sh"
    n1_break_check() { touch "$QD/called"; echo '{"success":true,"verdict":"red-then-green"}'; }
    eval "$BLOCK"
    echo "$BC_VERDICT" )
}
# (a) non-bug, mode bugs, no Regression test: line -> skipped
mkdir -p "$T/a"; printf '%s\n' "Exit code: 0" > "$T/a/qa.md"
assert_eq "non-bug, bugs, no line -> skipped" "skipped" "$(run_bc "$T/a" task bugs)"
# (b) non-bug, mode bugs, Regression test: N/A -> skipped
mkdir -p "$T/b"; printf '%s\n' "Regression test: N/A (not a bug)" > "$T/b/qa.md"
assert_eq "non-bug, bugs, N/A line -> skipped" "skipped" "$(run_bc "$T/b" task bugs)"
# (c) bug, no line -> inconclusive (unchanged, still fails QA)
mkdir -p "$T/c"; printf '%s\n' "Exit code: 0" > "$T/c/qa.md"
assert_eq "bug, no line -> inconclusive" "inconclusive" "$(run_bc "$T/c" bug bugs)"
# (d) non-bug, mode all, no line -> inconclusive (unchanged, blocking)
mkdir -p "$T/d"; printf '%s\n' "Exit code: 0" > "$T/d/qa.md"
assert_eq "non-bug, all, no line -> inconclusive" "inconclusive" "$(run_bc "$T/d" task all)"
# (e) non-bug with a valid regression line -> lib verdict passes through, lib called
mkdir -p "$T/e"; printf '%s\n' "Regression test: t_reg | ${BT}true${BT}" > "$T/e/qa.md"
assert_eq "non-bug, valid line -> lib verdict" "red-then-green" "$(run_bc "$T/e" task bugs)"
assert_eq "non-bug, valid line -> n1_break_check called" "1" "$([ -f "$T/e/called" ] && echo 1 || echo 0)"
# (f) unknown task type (signal missing), no line -> inconclusive (conservative)
mkdir -p "$T/f"; printf '%s\n' "Exit code: 0" > "$T/f/qa.md"
assert_eq "empty task type, no line -> inconclusive" "inconclusive" "$(run_bc "$T/f" "" bugs)"
# (g) no-line cases never call the lib
assert_eq "no-line case does not call n1_break_check" "0" "$([ -f "$T/a/called" ] && echo 1 || echo 0)"

# Prose rule lists `skipped` among non-failing verdicts.
if grep -qF '`red-then-green`/`no-diff`/`skipped`' "$QA_MD"; then
  echo "PASS: qa.md prose lists skipped as non-failing"; PASS=$((PASS+1))
else
  echo "FAIL: qa.md prose does not list skipped as non-failing"; FAIL=$((FAIL+1))
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# tests/test_qa_break_check_skipped.sh — N1-469: the run-level break-check verdict is `skipped` (not
# `inconclusive`) for a non-bug ticket in mode `bugs` with no usable `Regression test:` line.
# Bug tickets, mode `all`, an unknown type, and a valid regression line keep their old paths.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA_MD="$REPO_ROOT/lib/qa-step.sh"   # N1-476: the break-check body lives in lib/qa-step.sh
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_ROOT="$REPO_ROOT"
source "$REPO_ROOT/lib/config.sh"; source "$REPO_ROOT/lib/step.sh"; source "$REPO_ROOT/lib/validation.sh"; source "$QA_MD"
QA_STEP="$REPO_ROOT/skills/n1-start/steps/qa.md"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
BT='`'
unset N1_STORY_ID N1_STORY_BRANCH N1_QUEUE_RUN_ID N1_RUN_ID
mk() { mkdir -p "$T/home/memory/$1"; printf -- '---\n---\n' > "$T/home/memory/$1/overview.md"; echo "$T/home/memory/$1"; }
run_bc() { # <case> <task_type> <bc_mode> -> prints BC_VERDICT; stub call leaves <case-dir>/called
  ( set +e +u +o pipefail  # skill snippets run without errexit/pipefail
    export N1_HOME="$T/home" ID="$1"; QD="$N1_HOME/memory/$1"
    printf '{"qa":{"breakCheck":"%s"}}\n' "$3" > "$N1_HOME/config.json"
    [ -n "$2" ] && printf '<!-- n1:signals task_type=%s -->\n' "$2" > "$QD/ticket.md"
    n1_break_check_base() { echo base; }
    n1_break_check() { touch "$QD/called"; echo '{"success":true,"verdict":"red-then-green"}'; }
    n1_qa_break_check "$T" 2>/dev/null | sed -n 's/^BC_VERDICT=//p' )
}
# (a) non-bug, mode bugs, no Regression test: line -> skipped
D=$(mk a); printf '%s\n' "Exit code: 0" > "$D/qa.md"
assert_eq "non-bug, bugs, no line -> skipped" "skipped" "$(run_bc a task bugs)"
# (b) non-bug, mode bugs, Regression test: N/A -> skipped
D=$(mk b); printf '%s\n' "Regression test: N/A (not a bug)" > "$D/qa.md"
assert_eq "non-bug, bugs, N/A line -> skipped" "skipped" "$(run_bc b task bugs)"
# (c) bug, no line -> inconclusive (unchanged, still fails QA)
D=$(mk c); printf '%s\n' "Exit code: 0" > "$D/qa.md"
assert_eq "bug, no line -> inconclusive" "inconclusive" "$(run_bc c bug bugs)"
# (d) non-bug, mode all, no line -> inconclusive (unchanged, blocking)
D=$(mk d); printf '%s\n' "Exit code: 0" > "$D/qa.md"
assert_eq "non-bug, all, no line -> inconclusive" "inconclusive" "$(run_bc d task all)"
# (e) non-bug with a valid regression line -> lib verdict passes through, lib called
D=$(mk e); printf '%s\n' "Regression test: t_reg | ${BT}true${BT}" > "$D/qa.md"
assert_eq "non-bug, valid line -> lib verdict" "red-then-green" "$(run_bc e task bugs)"
assert_eq "non-bug, valid line -> n1_break_check called" "1" "$([ -f "$T/home/memory/e/called" ] && echo 1 || echo 0)"
# (f) unknown task type (signal missing), no line -> inconclusive (conservative)
D=$(mk f); printf '%s\n' "Exit code: 0" > "$D/qa.md"
assert_eq "empty task type, no line -> inconclusive" "inconclusive" "$(run_bc f "" bugs)"
# (g) no-line cases never call the lib
assert_eq "no-line case does not call n1_break_check" "0" "$([ -f "$T/home/memory/a/called" ] && echo 1 || echo 0)"

# Prose rule lists `skipped` among non-failing verdicts.
if grep -qF '`red-then-green`/`no-diff`/`skipped`' "$QA_STEP"; then
  echo "PASS: qa.md prose lists skipped as non-failing"; PASS=$((PASS+1))
else
  echo "FAIL: qa.md prose does not list skipped as non-failing"; FAIL=$((FAIL+1))
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

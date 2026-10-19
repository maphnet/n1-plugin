#!/usr/bin/env bash
# N1-100: n1-finish final summary template in steps/06-cleanup.md.
# FILE env var overrides the target (used to prove the test fails pre-change).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="${FILE:-$REPO_ROOT/skills/n1-finish/steps/06-cleanup.md}"
PASS=0
FAIL=0

assert_contains() {
    local label="$1" needle="$2"
    if grep -qF -- "$needle" "$FILE"; then
        echo "PASS: $label"; PASS=$((PASS+1))
    else
        echo "FAIL: $label (missing [$needle])"; FAIL=$((FAIL+1))
    fi
}

assert_contains "header" 'Finish complete: <ID> (<ticket title>)'
assert_contains "done line" 'Done: <1-2 lines'
assert_contains "ticket line" 'Ticket: <ID> →'
assert_contains "ticket url unavailable" 'URL unavailable (<reason>)'
assert_contains "pr line" 'PR: <url'
assert_contains "next tickets none" 'Next tickets: <ID title [status]; ... | none | lookup failed (<reason>)>'
assert_contains "lookup op" 'tracker.operations.getIssueLinks'
assert_contains "next manual" 'Next (manual): /n1:n1-release'

if grep -qF "Work complete. If you're ready" "$FILE"; then
    echo "FAIL: auto branch still prints Work complete"; FAIL=$((FAIL+1))
else
    echo "PASS: auto branch has no Work complete print"; PASS=$((PASS+1))
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

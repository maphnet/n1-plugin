#!/usr/bin/env bash
# N1-606: qa-engineer, developer and code-reviewer carry the test-weakening guard (ticket.md citation required).
# N1-628: sleep/timeout/retry additions count as weakening; flaky-test deletion needs a documented reason.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

QA=agents/qa-engineer.md
DEV=agents/developer.md
CR=agents/code-reviewer.md

check "qa-engineer has the guard" '\*\*Test-weakening guard\.\*\*' "$QA"
check "qa-engineer requires a ticket.md citation in qa.md" 'Cite the justifying ticket\.md line in qa\.md' "$QA"
check "qa-engineer removal needs a ticket.md citation" 'removal is weakening: cite in qa\.md the ticket\.md line' "$QA"
check "developer requires a ticket.md citation" 'Cite the justifying ticket\.md line in (implementation\.md|the implementation summary)' "$DEV"
check "developer fix cycle names CI, review and simple-path fixes" 'Test-weakening guard\.\*\* Applies to CI, review and simple-path fixes' "$DEV"
check "code-reviewer has the guard" '\*\*Test-weakening guard\.\*\*' "$CR"
check "code-reviewer reports [CR-N] High, not TQ" 'Report as `\[CR-N\]` High, not `\[TQ-N\]`' "$CR"
check "code-reviewer may Read result files only for the citation lookup" 'solely to look up a citation; use them for nothing else' "$CR"

check "qa-engineer lists sleep, timeout and retry as weakening" 'sleep, raising a timeout, or wrapping a test or assertion in a retry loop' "$QA"
check "code-reviewer flags sleeps, raised timeouts and retry wrappers" 'added sleeps, raised timeouts or retry wrappers' "$CR"
check "qa-engineer delete path names the reason fields" 'the observed failure, and why the root cause is unknown' "$QA"

n=$(grep -c 'Test-weakening guard\.\*\*' "$DEV")
if [ "$n" -eq 2 ]; then echo "PASS: developer has the guard in both Constraints lists"; else echo "FAIL: developer guard count $n != 2"; FAIL=1; fi

n=$(grep -c 'raising a timeout, or wrapping a test or assertion in a retry loop' "$DEV")
if [ "$n" -eq 2 ]; then echo "PASS: developer has the sleep/timeout/retry rule in both sites"; else echo "FAIL: developer sleep/timeout/retry count $n != 2"; FAIL=1; fi

n=$(grep -c 'the observed failure, and why the root cause is unknown' "$DEV")
if [ "$n" -eq 2 ]; then echo "PASS: developer has the delete-reason rule in both sites"; else echo "FAIL: developer delete-reason count $n != 2"; FAIL=1; fi

exit $FAIL

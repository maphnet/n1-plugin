#!/usr/bin/env bash
# N1-606: qa-engineer, developer and code-reviewer carry the test-weakening guard (ticket.md citation required).
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

n=$(grep -c 'Test-weakening guard\.\*\*' "$DEV")
if [ "$n" -eq 2 ]; then echo "PASS: developer has the guard in both Constraints lists"; else echo "FAIL: developer guard count $n != 2"; FAIL=1; fi

exit $FAIL

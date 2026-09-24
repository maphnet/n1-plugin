#!/usr/bin/env bash
# NP-193: intake.md's Candidates Output must define a Reason field, and preview.md's
# plan table header must keep listing Reason -- guards against the two files drifting.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0

check() { # <label> <extended-regex> <file>
    if grep -qE "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

check "intake.md Candidates Output lists Reason field" \
    '\*\*Candidates\*\*:.*`Reason`' \
    skills/n1-queue/steps/intake.md
check "intake.md enumerates Reason values (tag match / story subtask)" \
    'tag match.*story subtask' \
    skills/n1-queue/steps/intake.md
check "preview.md plan table header includes Reason column" \
    '\| # \| Ticket \| Title \| Repo \| Model \| Reason \|' \
    skills/n1-queue/steps/preview.md

exit $FAIL

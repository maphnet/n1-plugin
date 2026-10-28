#!/usr/bin/env bash
# N1-96: addToSprint op is wired into n1-start (initial move only), n1-init, and docs.
# N1-182: the initial move (In Progress, addToSprint, assign) lives at the end of the ticket step.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
check() { # <label> <extended-regex> <file>
    if grep -qE "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
T=skills/n1-start/steps/ticket.md
check "ticket step names config key" 'tracker\.operations\.addToSprint' "$T"
check "ticket step routes via versionMcp" 'tracker\.operations\.addToSprint.*tracker\.versionMcp' "$T"
check "ticket step logs to Progress" 'addToSprint.*## Progress' "$T"
check "ticket step moves to In Progress" 'moveStatus` → In Progress' "$T"
check "SKILL step-1 row owns the status move" '^\| 1\. REQUIREMENTS ANALYSIS \| `steps/ticket\.md` \| moveStatus → In Progress' skills/n1-start/SKILL.md
check "SKILL directs step files in order" 'Run each step file in order' skills/n1-start/SKILL.md
if grep -qE 'moveStatus|addToSprint|Assign to creator' skills/n1-start/steps/analysis.md; then
    echo "FAIL: analysis step must not move status, add to sprint or assign"; FAIL=1
else
    echo "PASS: analysis step leaves the initial move to the ticket step"
fi
DUP=$(grep -n '^\*\*Duplicate check:\*\*' "$T" | head -1 | cut -d: -f1)
MOV=$(grep -n 'moveStatus` → In Progress' "$T" | head -1 | cut -d: -f1)
if [ -n "$DUP" ] && [ -n "$MOV" ] && [ "$DUP" -lt "$MOV" ]; then
    echo "PASS: status moves only after the duplicate check"
else
    echo "FAIL: status moves only after the duplicate check"; FAIL=1
fi
check "SKILL step-1 row mentions addToSprint" 'addToSprint if configured' skills/n1-start/SKILL.md
check "n1-init detects server-qualified tool" '__jcm_addToActiveSprint' skills/n1-init/steps/03-tracker.md
check "gap check gates on exposed tool" 'exposes `mcp__<server>__jcm_addToActiveSprint`' skills/n1-init/steps/01-prerequisites.md
check "gap check patches addToSprint" 'addToSprint \|= \(if \. == null or \. == "" then "jcm_addToActiveSprint"' skills/n1-init/steps/01-prerequisites.md
check "architecture documents addToSprint" 'addToSprint' references/architecture.md
if grep -q "addToSprint" skills/n1-start/procedures/autonomy-headless.md; then
    echo "FAIL: autonomy-headless must not call addToSprint"; FAIL=1
else
    echo "PASS: autonomy-headless omits addToSprint"
fi
exit "$FAIL"

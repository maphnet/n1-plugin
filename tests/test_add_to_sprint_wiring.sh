#!/usr/bin/env bash
# N1-96: addToSprint op is wired into n1-start (initial move only), n1-init, and docs.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
check() { # <label> <extended-regex> <file>
    if grep -qE "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
check "analysis names config key" 'tracker\.operations\.addToSprint' skills/n1-start/steps/analysis.md
check "analysis routes via versionMcp" 'tracker\.operations\.addToSprint.*tracker\.versionMcp' skills/n1-start/steps/analysis.md
check "analysis logs to Progress" 'addToSprint.*## Progress' skills/n1-start/steps/analysis.md
check "SKILL step-2 row mentions addToSprint" 'addToSprint if configured' skills/n1-start/SKILL.md
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

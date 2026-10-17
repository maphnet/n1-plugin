#!/usr/bin/env bash
# N1-89: ticket-watch procedure keeps its guards, and the orchestrator/init/docs reference it.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
P=skills/n1-start/procedures/ticket-watch.md
R=skills/n1-start/procedures/ticket-watch-react.md
check() { # <label> <extended-regex> <file>
    if grep -qE "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
check "SKILL.md check-point pointer" "procedures/ticket-watch\.md § Check\` before Steps 5, 6, 10 and 11b" skills/n1-start/SKILL.md
check "analysis seeds the watch" "procedures/ticket-watch\.md § Seed" skills/n1-start/steps/analysis.md
check "procedure has Seed" "^## § Seed" "$P"
check "procedure has Check" "^## § Check" "$P"
check "procedure has React" "^## § React" "$R"
check "procedure has Replan" "^## § Replan" "$R"
check "Check hands off to react file" "ticket-watch-react\.md" "$P"
check "Jira getChangelog mapping in n1-init" "\"getChangelog\": \"jcm_getIssueChangelog\"" skills/n1-init/steps/03-tracker.md
check "YouTrack getChangelog explicitly unmapped" "YouTrack.*getChangelog.*not mapped" skills/n1-init/steps/03-tracker.md
check "architecture documents the watch" "procedures/ticket-watch\.md" references/architecture.md
exit "$FAIL"

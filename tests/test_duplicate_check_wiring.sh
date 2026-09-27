#!/usr/bin/env bash
# NP-217: the shared duplicate-check procedure keeps its guards, and every call site references it.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
P=references/duplicate-check.md

check() { # <label> <extended-regex> <file>
    if grep -qE "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

check "procedure gates on operations.search" "tracker\.operations\.search" "$P"
check "procedure guards operations.linkIssues independently" "tracker\.operations\.linkIssues" "$P"
check "procedure caches result in overview frontmatter" "duplicate_check" "$P"
check "procedure has Check section" "^## § Check" "$P"
check "procedure has Apply Links section" "^## § Apply Links" "$P"
check "procedure guards untrusted hit fields" "untrusted data" "$P"
check "procedure classifies on summary/status, not description" "summary and status only" "$P"
check "procedure headless comment is IDs and match type only" "HIT_ID \\(duplicate\\|related\\)>" "$P"
check "procedure gate skips queue children (NP-203)" "N1_QUEUE_RUN_ID" "$P"
check "procedure has plan-time queue branch" "CONTEXT=queue-plan" "$P"
check "queue-plan branch offers exclusion" "Exclude from this queue run" "$P"
check "queue-plan branch never creates overview.md" "none is created" "$P"
check "queue child skip is recorded for resume" "queue-plan" "$P"
check "queue child skip also requires N1_HEADLESS=1 (SEC-L2)" "QUEUE_CHILD.*non-empty AND \`HEADLESS=1\`" "$P"
check "architecture.md documents the procedure" "references/duplicate-check\.md" references/architecture.md

check "n1-ticket runs the check before creation" "duplicate-check\.md. § Check" skills/n1-ticket/steps/02-create.md
check "n1-ticket applies links after creation" "duplicate-check\.md. § Apply Links" skills/n1-ticket/steps/02-create.md
check "n1-story runs the check at the tracker gate" "duplicate-check\.md. § Check" skills/n1-story/steps/01-collect.md
check "n1-story applies links after story creation" "duplicate-check\.md. § Apply Links" skills/n1-story/steps/02-compose.md

check "n1-start intake references the procedure" "duplicate-check\.md" skills/n1-start/steps/ticket.md

check "n1-queue intake references the procedure" "duplicate-check\.md" skills/n1-queue/steps/intake.md
check "n1-queue intake keeps the annotate-only pass" "CONTEXT=queue\`" skills/n1-queue/steps/intake.md
check "n1-queue intake hands matches to plan-time resolution" "CONTEXT=queue-plan" skills/n1-queue/steps/intake.md
check "n1-queue blocker check still present" "^## Blocker check" skills/n1-queue/steps/intake.md
check "n1-queue blocker check still excludes blocked candidates" "excluded with reason .blocked by <ID>." skills/n1-queue/steps/intake.md

exit $FAIL

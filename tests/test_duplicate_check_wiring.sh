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
check "procedure headless comment is IDs and match type only" "HIT_ID \\(duplicate\\|related\\), omit this line if none>" "$P"
check "NP-234: duplicates auto-link in start, unattended" "MATCHES\` contains any \`duplicate\` rows, set \`DUP_LINKS\` to \`<HIT_ID>:Duplicate\`" "$P"
check "NP-234: duplicates auto-link in start, interactive" "auto-link those without asking" "$P"
check "NP-234: auto-linked-duplicate notice line" "Auto-linked \\(duplicate\\): <HIT_ID>" "$P"
check "NP-234: related hits are never auto-linked" "Do not link \`related\` hits" "$P"
check "NP-234 CR-1: Stop still offered after all-duplicate auto-link" "no \`related\` rows remain\\), ask the user: \\*\\*Continue\\*\\* \\(default\\) or \\*\\*Stop\\*\\*" "$P"
check "NP-234 SEC-1: Apply Links validates HIT_ID before use" "Skip any entry whose \`HIT_ID\` does not match \`\\^\\[A-Z\\]\\[A-Z0-9_\\]\\*-\\[0-9\\]\\+\\\$\`" "$P"
check "NP-234 follow-up: YouTrack link types mapped to command names" "Map \`Duplicate\` .+ \`duplicates\` and \`Relates\` .+ \`relates to\`" "$P"
check "procedure gate skips queue children (NP-203)" "N1_QUEUE_RUN_ID" "$P"
check "procedure has plan-time queue branch" "CONTEXT=queue-plan" "$P"
check "queue-plan branch offers exclusion" "Exclude from this queue run" "$P"
check "queue-plan branch never creates overview.md" "none is created" "$P"
check "queue child skip is recorded for resume" "queue-plan" "$P"
check "queue child skip also requires N1_HEADLESS=1 (SEC-L2)" "QUEUE_CHILD.*non-empty AND \`HEADLESS=1\`" "$P"
check "NP-230: YouTrack query uses explicit and with quoted keywords" "project: <PROJECT_KEY> and \\(" "$P"
if grep -qE '\{kw1\} or \{kw2\}' "$P" 2>/dev/null; then echo "FAIL: NP-230: old brace-OR YouTrack query removed"; FAIL=1; else echo "PASS: NP-230: old brace-OR YouTrack query removed"; fi
check "NP-230: retry once on YouTrack search error before skipping" "retry once with a simpler query" "$P"
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

check "NP-239: n1-finish resolves link op from linkIssues" "tracker\.operations\.linkIssues" skills/n1-finish/steps/05-telemetry-followup.md
check "NP-239: n1-finish maps Relates to the relates to YouTrack command" "Map \`Relates\` .+ \`relates to\`" skills/n1-finish/steps/05-telemetry-followup.md
check "NP-239: n1-finish warns instead of skipping silently on link failure" "Could not link .+ → .+:" skills/n1-finish/steps/05-telemetry-followup.md
check "NP-239: investigation-deliverable resolves link op from linkIssues" "tracker\.operations\.linkIssues" skills/n1-start/steps/investigation-deliverable.md
check "NP-239: n1-story subtask link uses the subtask of direction name" "subtask of" skills/n1-story/steps/02-compose.md
check "NP-239 fix: n1-finish Jira link payload includes cloudId" "cloudId\`, \`inwardIssue" skills/n1-finish/steps/05-telemetry-followup.md
check "NP-239 fix: investigation-deliverable Jira link payload includes cloudId" "cloudId\`, \`inwardIssue" skills/n1-start/steps/investigation-deliverable.md

exit $FAIL

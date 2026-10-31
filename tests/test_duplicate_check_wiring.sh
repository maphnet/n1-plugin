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
check "N1-78: related hits auto-link, unattended" "MATCHES\` contains any \`related\` rows, also add \`<HIT_ID>:Relates\` to \`DUP_LINKS\`" "$P"
check "N1-78: related hits auto-link, interactive" "MATCHES\` contains any \`related\` rows, auto-link those without asking" "$P"
check "N1-78: auto-linked-related notice line" "Auto-linked \\(related\\): <HIT_ID>" "$P"
check "N1-78: headless comment combines duplicate+related with type" "Auto-linked: <HIT_ID> \\(duplicate\\|related\\)" "$P"
check "N1-78: Stop still offered after duplicate auto-link" "Auto-linked \\(duplicate\\): <HIT_ID>\\[, <HIT_ID>\\.\\.\\.\\]\`\\. Ask the user: \\*\\*Continue\\*\\* \\(default\\) or \\*\\*Stop\\*\\*" "$P"
check "NP-234 SEC-1: Apply Links validates HIT_ID before use" "Skip any entry whose \`HIT_ID\` does not match \`\\^\\[A-Z\\]\\[A-Z0-9_\\]\\*-\\[0-9\\]\\+\\\$\`" "$P"
check "NP-234 follow-up: YouTrack link types mapped to command names" "Map \`Duplicate\` .+ \`duplicates\` and \`Relates\` .+ \`relates to\`" "$P"
check "procedure gate skips queue children (NP-203)" "N1_QUEUE_RUN_ID" "$P"
check "procedure has plan-time queue branch" "CONTEXT=queue-plan" "$P"
check "queue-plan branch offers exclusion" "Exclude from this queue run" "$P"
check "N1-78: queue-plan related-only matches skip the prompt" "no duplicate.* rows remain.*continue with no prompt" "$P"
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

# N1-231: shared blocker-check lookup
B=references/blocker-check.md
check "N1-231: blocker-check reads operations.getIssueLinks" "tracker\.operations\.getIssueLinks" "$B"
check "N1-231: blocker-check routes links via versionMcp else mcp" "VERSION_MCP. when non-empty, else .TRACKER_MCP." "$B"
check "N1-231: open means status category not Done" "status category is not Done" "$B"
check "N1-231: In Review counts as open" "In Review counts as open" "$B"
check "N1-231: blocker-check guards untrusted link fields" "untrusted data" "$B"
check "N1-231: PR lookup gates on the key regex before any command" "does not match .\^\[A-Z\].*skip the lookup" "$B"
check "N1-231: Jira blocked-by links read from inwardIssue" "Blocks-type entries that carry .inwardIssue." "$B"
check "N1-231: headless blocker prompt follows the stop-list path with a category" "escalation \(stop-list path\), .STEP=ticket., category=.blocked-by." "$B"
check "N1-231: headless blocker prompt states no option is recommended" "No option is recommended, and never treat .continue anyway. as a default" "$B"
if grep -qE 'KEY="|KEY=.<KEY>' "$B"; then echo "FAIL: N1-231: no tracker key is assigned into a shell string"; FAIL=1; else echo "PASS: N1-231: no tracker key is assigned into a shell string"; fi
check "N1-231: queue caller skips the PR lookup" "CALLER=queue. skips this step" "$B"
check "N1-231: question shows status and PR" "<status>\[, PR #<n>\]" "$B"
check "N1-231: interactive options carry the no-recommendation sentence" "No recommendation\. The options are equivalent given the available evidence; select based on team preference\." "$B"
check "N1-231: headless options use the exact ask-mode stop label" "OPTIONS=continue anyway \| Stop this ticket" "$B"
check "N1-231: lookup failure warns and continues" "Warning: blocker check skipped \(<msg>\)" "$B"
check "N1-231: unconfigured lookup warns and continues" "Warning: blocker check skipped \(operations\.getIssueLinks not configured\)" "$B"
if grep -qE 'N1_QUEUE_RUN_ID|QUEUE_CHILD' "$B" 2>/dev/null; then echo "FAIL: N1-231: blocker-check has no queue-child skip (queue intake must run it)"; FAIL=1; else echo "PASS: N1-231: blocker-check has no queue-child skip (queue intake must run it)"; fi
check "N1-231: architecture.md documents the blocker check" "references/blocker-check\.md" references/architecture.md
check "N1-231: architecture.md notes the queue link routing change" "queue intake used .mcp. only before N1-231" references/architecture.md

# N1-231: queue intake delegates the link lookup and keeps its outcomes
I=skills/n1-queue/steps/intake.md
check "N1-231: queue intake follows blocker-check with CALLER=queue" "blocker-check\.md. § Check with .ID=<KEY>., .CALLER=queue." "$I"
check "N1-231: queue intake keeps the description-grep fallback" "SKIP_REASON=not-configured.*rely on the description grep" "$I"
check "N1-231: queue intake does not exclude on a failed lookup" "SKIP_REASON=error: <msg>.*do not exclude on links" "$I"
check "N1-231: queue intake keeps the held prefix" "blocked_on <ID> · " "$I"
check "N1-231: queue intake keeps the cycle rule" "blocked by <ID> \(cycle\)" "$I"
check "N1-231: queue intake keeps the description grep" "Additionally grep the description" "$I"

# N1-231: n1-start runs the blocker check after the duplicate check, before In Progress
T=skills/n1-start/steps/ticket.md
check "N1-231: n1-start ticket step runs the blocker check" "blocker-check\.md. § Check with .ID=<ID>., .CALLER=start." "$T"
check "N1-231: n1-start skips the blocker check only in queue children (SEC-L2)" "Blocker check.*N1_QUEUE_RUN_ID. set AND .N1_HEADLESS=1" "$T"
check "N1-231: n1-start reads both queue-child env vars" "Blocker check.*N1_QUEUE_RUN_ID:-.*N1_HEADLESS:-" "$T"
check "N1-231: blocker Stop ends the step with skip reason blocked" "Blocker check.*end as above \(.blocked.\)" "$T"
check "N1-231: blocker check runs only for existing tracker tickets (mode=ticket)" "Blocker check.* \(mode=ticket only" "$T"
LD=$(grep -m1 -n 'duplicate-check\.md' "$T" | cut -d: -f1)
LB=$(grep -m1 -n 'blocker-check\.md' "$T" | cut -d: -f1)
LS=$(grep -m1 -n '^\*\*Tracker status\*\*' "$T" | cut -d: -f1)
if [ -n "$LD" ] && [ -n "$LB" ] && [ -n "$LS" ] && [ "$LD" -lt "$LB" ] && [ "$LB" -lt "$LS" ]; then
    echo "PASS: N1-231: blocker check sits after the duplicate check and before Tracker status"
else
    echo "FAIL: N1-231: blocker check sits after the duplicate check and before Tracker status"; FAIL=1
fi

exit $FAIL

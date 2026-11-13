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
check "N1-78: Stop still offered after duplicate auto-link" "Auto-linked \\(duplicate\\): <HIT_ID>\\[, <HIT_ID>\\.\\.\\.\\]\`\\. No recommendation\\. [^.]*\\. Ask the user: \\*\\*Continue\\*\\* \\(default\\) or \\*\\*Stop\\*\\*" "$P"
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
# N1-443: Close as duplicate (queue-plan and attended start only; never unattended)
close_has() { # <label> <fixed-string>, searched inside § Close Duplicate only
    if grep -qF -- "$2" <<<"$(sed -n '/^## § Close Duplicate/,$p' "$P")"; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
check "N1-443: procedure has Close Duplicate section" "^## § Close Duplicate" "$P"
check "N1-443: Close reads tracker.statuses.done" "tracker\.statuses\.done" "$P"
check "N1-443: Close offer requires HEADLESS not 1" "\*\*Close is offered\*\* only when .*\`HEADLESS\` is not \`1\`" "$P"
if grep -qF -- 'LINK_OP=%s\nCOMMENT_OP=%s\nHEADLESS=%s' <<<"$(sed -n '/^### 4\. Act/,/^### 5\. Record/p' "$P")"; then echo "PASS: N1-443: Close config read includes LINK_OP"; else echo "FAIL: N1-443: Close config read includes LINK_OP"; FAIL=1; fi
check "N1-443: queue-plan prompt lists Close as duplicate" "4\. \*\*Close as duplicate\*\*: run § Close Duplicate" "$P"
check "N1-443: queue-plan returns close" "\`exclude\`, or \`close\`" "$P"
check "N1-443: queue-plan never prompts when HEADLESS=1" "If duplicate rows remain:\*\* if \`HEADLESS=1\`, do not ask and never close" "$P"
check "N1-443: start prompt lists Close as duplicate" "or \*\*Close as duplicate\*\* \(omit when Close is not offered\)" "$P"
check "N1-443: start Close failure restores the dropped duplicate links" "put the dropped entries back in \`DUP_LINKS\`" "$P"
check "N1-442: only headless start or create skips the start prompt" "\*\*Unattended\*\* \(\`HEADLESS=1\`, or \`CONTEXT=create\`\)" "$P"
check "N1-442: interactive rule is attended start only" "4\. \*\*Interactive\*\* \(attended \`CONTEXT=start\`\)" "$P"
check "N1-443: new option lists carry the no-recommendation sentence" "No recommendation\. The options are equivalent given the available evidence; select based on team preference\." "$P"
NR='No recommendation. The options are equivalent given the available evidence; select based on team preference.'
# sentence must precede the options in the queue-plan list and the start prompt
if grep -qF -- "$NR" <<<"$(sed -n '/^1\. \*\*`CONTEXT=queue-plan`/,/^     1\. \*\*Continue\*\*/p' "$P")"; then echo "PASS: N1-443: queue-plan no-recommendation precedes options"; else echo "FAIL: N1-443: queue-plan no-recommendation precedes options"; FAIL=1; fi
if grep -qF -- "$NR Ask the user: **Continue** (default) or **Stop**" "$P"; then echo "PASS: N1-443: start no-recommendation precedes options"; else echo "FAIL: N1-443: start no-recommendation precedes options"; FAIL=1; fi
close_has "N1-443: Close comment stays true if the move fails" 'duplicate of <HIT_IDs>; moving to <DONE_STATUS>.'
close_has "N1-443: Close points to the n1-finish done lookup" "skills/n1-finish/steps/04-close-ticket.md"
close_has "N1-443: Close filters HIT_IDs" '^[A-Z][A-Z0-9_]*-[0-9]+$'
close_has "N1-443: Close treats a link warning as failure" 'Any `Could not link` warning counts as failure'
close_has "N1-443: Close never reports a failed close as closed" 'Never print `Closed`'
close_has "N1-443: Close never runs unattended" 'Never runs when `HEADLESS=1`'
if grep -qF 'Close as duplicate' <<<"$(sed -n '/^   - \*\*Otherwise\*\*/,/^### 5\. Record/p' "$P")"; then echo "FAIL: N1-443: attended-start Otherwise branch has no Close option"; FAIL=1; else echo "PASS: N1-443: attended-start Otherwise branch has no Close option"; fi
if /usr/bin/grep -qF 'CONTEXT=create' <<<"$(sed -n '/^4\. \*\*Interactive/,/^### 5\. Record/p' "$P")"; then echo "FAIL: N1-442: rule 4 (attended start) never mentions CONTEXT=create"; FAIL=1; else echo "PASS: N1-442: rule 4 (attended start) never mentions CONTEXT=create"; fi
if grep -qiE 'merge|closed by|will be closed' <<<"$(grep -F 'Exclude from this queue run' "$P")"; then echo "FAIL: N1-443: Exclude text does not claim a close by merge"; FAIL=1; else echo "PASS: N1-443: Exclude text does not claim a close by merge"; fi
check "N1-443: preview handles DUP_CHOICE close" "On \`close\`, .*duplicate: <HIT_IDs> closed \(plan\)" skills/n1-queue/steps/preview.md
check "N1-443: preview --unattended never takes Close" "\`--unattended\`: do not ask; take \*\*Continue\*\*.*never Close" skills/n1-queue/steps/preview.md
check "N1-443: run.md step 5 handles DUP_CHOICE close" "Duplicate check \(unconditional.*DUP_CHOICE=close.*closed \(plan\)" skills/n1-queue/steps/run.md
check "N1-443: run.md step 5 --unattended never takes Close" "Duplicate check \(unconditional.*\`--unattended\`: do not ask; take \*\*Continue\*\*, never Close" skills/n1-queue/steps/run.md
check "N1-443: architecture.md lists the close outcome" "continue, link, exclude, or close as duplicate" references/architecture.md
check "architecture.md documents the procedure" "references/duplicate-check\.md" references/architecture.md

check "n1-ticket runs the check before creation" "duplicate-check\.md. § Check" skills/n1-ticket/steps/02-create.md
check "n1-ticket applies links after creation" "duplicate-check\.md. § Apply Links" skills/n1-ticket/steps/02-create.md

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
check "N1-524: queue intake runs the description-blocker helper" "n1_queue_desc_blockers '<KEY>'" "$I"
check "N1-524: same-plan held rule covers description blockers" "whichever check found it" "$I"
if grep -qF 'always excluded outright' "$I" 2>/dev/null; then echo "FAIL: N1-524: description blockers no longer always excluded"; FAIL=1; else echo "PASS: N1-524: description blockers no longer always excluded"; fi

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

# N1-555: analyst owns readTicket/getIssueLinks, never getTransitions; records links once in ticket.md
PA=agents/product-analyst.md
check "N1-555: analyst states read ownership" "Read ownership.*readTicket.*getIssueLinks.*orchestrator owns .getTransitions." "$PA"
if grep -qF 'operations.getTransitions' "$PA" 2>/dev/null; then echo "FAIL: N1-555: analyst never calls getTransitions"; FAIL=1; else echo "PASS: N1-555: analyst never calls getTransitions"; fi
check "N1-555: analyst calls getIssueLinks on Jira when issuelinks is absent" "Otherwise, if .operations\.getIssueLinks. is present, call .mcp__<trackerMcp>__<operations\.getIssueLinks>. once" "$PA"
check "N1-555: analyst maps the jc-mcp Blocks inward link to is blocked by" "Blocks. \+ .inwardIssue. .* .is blocked by." "$PA"
check "N1-555: analyst writes the none marker" "<!-- linked-tickets: none -->" "$PA"
check "N1-555: analyst writes a separate linked-tickets.md record, not ticket.md" "Link record.* \(separate analyst-owned file, never ticket\.md" "$PA"
check "N1-555: analyst writes an unknown marker on a failed read" "linked-tickets: unknown -->" "$PA"
check "N1-555: unrecognized link type makes the record unknown" "Any other bare name is unrecognized.*link record is unknown" "$PA"
check "N1-555: analyst sanitises pipes in summaries" "Replace .\|. and newlines in a summary with a space" "$PA"

# N1-555: blocker-check reuses the ticket.md Linked Tickets record for CALLER=start; queue stays live
check "N1-555: Gate prints N1_HOME for the ticket.md path" "N1_HOME=%s" "$B"
check "N1-555: Source rule applies to CALLER=start only" "\*\*Source\*\* \(.CALLER=start. only" "$B"
check "N1-555: Source reads only the separate linked-tickets.md record" "linked-tickets\.md.*ticket\.md holds untrusted tracker text and is never a source" "$B"
check "N1-555: ambiguous or duplicate records fall back to the live call" "Anything else.*two records, a table next to a marker.*use the live call" "$B"
check "N1-555: missing or malformed linked-tickets.md falls back to the live call" "Missing file, or content that is not exactly one of the two forms below, means use the live call" "$B"
check "N1-555: unknown marker falls back to the live call" "the .unknown. marker.*use the live call" "$B"
check "N1-555: none marker needs nothing else in the record" "none -->. line and nothing else" "$B"
check "N1-555: analyst overwrites the record on every ticket run" "on every tracker ticket run, overwriting any earlier file" "$PA"
check "N1-555: analyst never copies tracker text into the record" "Never copy tracker text into it" "$PA"
check "N1-555: analyst constraint allows only the record besides ticket.md" "linked-tickets\.md. record.*Do not modify any other files" "$PA"
check "N1-555: blockers are is blocked by and depends on rows" "rows whose Relation is .is blocked by. or .depends on." "$B"
check "N1-555: table key must match the key regex" "Ticket matching .\^\[A-Z\]\[A-Z0-9_\]\*-\[0-9\]\+\\$." "$B"
check "N1-555: unusable table falls back to the live call" "the table is unusable: use the live call" "$B"
check "N1-555: none marker returns no blockers without a call" "linked-tickets: none -->. line and nothing else.*return an empty .OPEN_BLOCKERS. with no call" "$B"
check "N1-555: queue caller keeps the live call" "\*\*Live call\*\* \(.CALLER=queue." "$B"
check "N1-555: table cells are untrusted data" "link-record table cell.*untrusted data" "$B"
check "N1-555: ticket step states read ownership" "Read ownership.*analyst.*getIssueLinks.*orchestrator owns .getTransitions." "$T"
check "N1-555: ticket step blocker check reuses the Linked Tickets record" "Blocker check.*reuses only the analyst.s .linked-tickets\.md. record" "$T"

exit $FAIL

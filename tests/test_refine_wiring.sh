#!/usr/bin/env bash
# N1-162: n1-refine wiring: --investigate move, *Refined by N1* consumers, caller mode, refine skill.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0

has() { # <label> <fixed-string> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
lacks() { # <label> <fixed-string> <file-or-dir>
    if grep -rqF -- "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}
line_has() { # <label> <needle> <also> <file>: some line containing needle also contains also
    if grep -F -- "$2" "$4" 2>/dev/null | grep -F -- "$3" >/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
before() { # <label> <fixed-a> <fixed-b> <file>: first a precedes first b
    local a b
    a=$(grep -nF -m1 -- "$2" "$4" 2>/dev/null | cut -d: -f1); b=$(grep -nF -m1 -- "$3" "$4" 2>/dev/null | cut -d: -f1)
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

# --- Task 1: --investigate leaves n1-start
lacks "no INVESTIGATE_FLAG left in skills" "INVESTIGATE_FLAG" skills
lacks "no investigate_interactive left in skills" "investigate_interactive" skills
lacks "no investigate_interactive left in architecture" "investigate_interactive" references/architecture.md
lacks "n1-start argument-hint drops --investigate" "[--investigate]" skills/n1-start/SKILL.md
has "input-parsing rejects --investigate" '`--investigate` moved: run `/n1:n1-refine <ID> --investigate`' skills/n1-start/procedures/input-parsing.md
line_has "ticket step redirects only interactive investigation" 'Interactive investigation moved: run `/n1:n1-refine <ID> --investigate`' 'N1_HEADLESS=1' skills/n1-start/steps/ticket.md
lacks "brain-dump investigation variant removed" "**Brain-dump variant**" skills/n1-start/steps/investigation-deliverable.md
has "architecture points investigation to n1-refine" '/n1:n1-refine <ID> --investigate' references/architecture.md

before "redirect precedes overview creation" 'Interactive investigation moved' '**Create overview.md**' skills/n1-start/steps/ticket.md
has "write closes block with end line" '*End of Refined by N1*' skills/n1-refine/steps/03-write.md
has "write replaces through end line" 'through the next `End of Refined by N1` line' skills/n1-refine/steps/03-write.md
line_has "handoff investigation form keys on resolved type" 'resolved type is `investigation`' '`--investigate` on a Task-typed ticket does not count' skills/n1-refine/steps/03-write.md
line_has "fallback boundary stops at blank line or heading" 'contiguous `- ` line directly under' 'first blank line or heading' skills/n1-refine/steps/03-write.md
has "input-parsing strips --type before detection" 'n1_parse_start_flags "<user-input>"' skills/n1-start/procedures/input-parsing.md
before "type split precedes detection" 'n1_parse_start_flags' 'n1_detect_input_type' skills/n1-start/procedures/input-parsing.md
has "ticket step reads saved override" 'TYPE_OVERRIDE="<TYPE_OVERRIDE from input parsing' skills/n1-start/steps/ticket.md
lacks "ticket step no longer parses USER_INPUT" 'n1_parse_type_arg' skills/n1-start/steps/ticket.md
line_has "title hint skipped on explicit override" 'n1_title_hints_investigation' '[ -z "$TYPE_OVERRIDE" ]' skills/n1-start/steps/ticket.md
has "stop list carve-out" 'A `[refined]` Decision (n1-refine block) never settles a stop-list prompt' skills/n1-start/procedures/autonomy-headless.md
has "brainstormer points to stop list" 'autonomy-headless.md` § Stop list' agents/brainstormer.md
has "n1-brainstorm points to stop list" 'autonomy-headless.md` § Stop list' skills/n1-brainstorm/SKILL.md
has "queue child ignores post-plan comment block" 'planned_at' agents/product-analyst.md
line_has "unreadable planned_at fails closed" 'planned_at' 'missing or unreadable, ignore the comment block' agents/product-analyst.md

# --- Task 2: n1-start guard + ledger tag
line_has "post-brainstorm enrichment skips refined tickets, emphasis-insensitive" 'skip the append if the description has a `*Refined by N1*` line' 'regardless of `*` or `_` emphasis' skills/n1-start/steps/brainstorm.md
has "post-brainstorm marker unchanged" '*Refined after design review — N1*' skills/n1-start/steps/brainstorm.md
has "ledger documents [refined]" '`[refined]` human answered in n1-refine' skills/n1-start/ledger.md
has "ledger keeps [plan]" '`[plan]`' skills/n1-start/ledger.md
has "tech-writer orders [refined] with [plan]" '`[plan]`/`[refined]` before `[asked]`' skills/n1-start/ledger.md

# --- Task 3: shared investigation step caller mode
I=skills/n1-start/steps/investigation-deliverable.md
has "caller mode block exists" '**Caller mode — n1-refine:**' "$I"
before "caller mode precedes Phase 1" '**Caller mode — n1-refine:**' '**Phase 1 — Produce Findings**' "$I"
line_has "caller mode remaps memory to refine/" '**Caller mode — n1-refine:**' '.../refine/' "$I"
line_has "caller mode remaps the \$ID spelling too" '**Caller mode — n1-refine:**' '$N1_HOME/memory/$ID/' "$I"
line_has "caller mode runs Phases 1-2 only" '**Caller mode — n1-refine:**' 'Run Phase 1 and Phase 2 only' "$I"
lacks "no dangling Brain-dump variant refs" 'Brain-dump variant' "$I"

# --- Task 4: product-analyst + queue intake markers
PA=agents/product-analyst.md
line_has "PA skip line lists refined marker after pinned sentence" 'already contains the marker `*Structured by N1*` or `*Restructured by N1*`, skip enrichment' '`Refined by N1`' "$PA"
lacks "PA skip line never mentions Briefed refined" 'Briefed by N1 (queue plan)*` (n1-refine' "$PA"
has "PA has refined block rule" '**Refined block rule:**' "$PA"
line_has "PA copies decisions verbatim" '**Refined block rule:**' '`### Decisions`' "$PA"
line_has "PA takes AC from the block only" '**Refined block rule:**' 'Take `### Acceptance Criteria` from the block only' "$PA"
lacks "PA does not match the post-brainstorm marker" 'Refined after design review' "$PA"
line_has "PA comment fallback needs first line == marker" '**Refined block rule:**' 'FIRST LINE equals that marker' "$PA"
line_has "PA most recent refined block wins" '**Refined block rule:**' 'The most recent refined block wins' "$PA"
line_has "PA comment supersedes older description block" '**Refined block rule:**' 'created after the description' "$PA"
line_has "PA hash-checks the description block in a queue child (N1-164)" '**Refined block rule:**' 'desc-hash-chain.md` § Intake check prints `MATCH`' "$PA"
line_has "PA ignores a description block edited after plan (N1-164)" '**Refined block rule:**' 'ignore the description block (treat it as absent)' "$PA"
line_has "PA comment guard unchanged next to the hash check" '**Refined block rule:**' 'missing or unreadable, ignore the comment block' "$PA"
line_has "PA budget counts the intake check" '§ Intake check' '1 mark Bash, 1 fetch and 1 hash Bash' "$PA"
lacks "PA never model-writes the chain scratch files (N1-326)" '2 file-writes' "$PA"
line_has "queue intake counts refined as Adequate" '`Normalized by N1` (with or without' '`*Refined by N1*`' skills/n1-queue/steps/intake.md
line_has "queue preview Brief skips refined descriptions" '**Brief (Empty/Skeletal only).**' 'carries no `Refined by N1` line' skills/n1-queue/steps/preview.md
line_has "queue intake reads comments before excluding Empty (N1-165)" 'read its comments once before the exclusion below' 'apply the same qualifier' skills/n1-queue/steps/intake.md
line_has "queue intake honors a qualifying comment block (N1-165)" '`Normalized by N1` (with or without' 'qualifying `Refined by N1` comment block' skills/n1-queue/steps/intake.md
line_has "queue preview Brief skips a qualifying comment block (N1-165)" '**Brief (Empty/Skeletal only).**' 'no qualifying comment block' skills/n1-queue/steps/preview.md
has "desc-hash-chain emits the ignored-block line (N1-165)" 'Ignored refined block: <cause>' references/desc-hash-chain.md
line_has "PA writes the ignored-block line on MISMATCH (N1-165)" '**Refined block rule:**' 'write the `Ignored refined block` line' "$PA"
has "architecture lists refined marker" '`*Refined by N1*`' references/architecture.md

# --- Task 5: design consumers
has "SA treats refined decisions as resolved" '**Refined decisions:**' agents/solution-architect.md
line_has "SA routes infeasible decisions to contradictions" '**Refined decisions:**' 'ticket_contradictions' agents/solution-architect.md
line_has "brainstormer never re-asks refined decisions" '*Refined by N1*' '`[refined]`' agents/brainstormer.md
line_has "n1-brainstorm never re-asks refined decisions" '**Refined decisions:**' '`[refined]`' skills/n1-brainstorm/SKILL.md

# --- Task 6: n1-refine dispatcher + fetch
R=skills/n1-refine
has "refine skill named" 'name: n1-refine' "$R/SKILL.md"
has "refine argument-hint" 'argument-hint: "<ticket-id> [--investigate]"' "$R/SKILL.md"
has "refine requires a ticket ID" 'Run `/n1:n1-ticket` first' "$R/SKILL.md"
has "refine documents queue-plan order" 'Run refine before `n1-queue --plan`' "$R/SKILL.md"
has "fetch disables enrichment" 'enrichmentEnabled=false' "$R/steps/01-fetch.md"
has "fetch writes under refine/" 'memory/<ID>/refine/ticket.md' "$R/steps/01-fetch.md"
line_has "fetch re-run check is emphasis-insensitive" 'already contains a `*Refined by N1*` line' 'regardless of `*` or `_` emphasis' "$R/steps/01-fetch.md"
lacks "no WRITE_MODE in refine" 'WRITE_MODE' "$R"
lacks "no GET_USER_OP in refine" 'GET_USER_OP' "$R"
has "fetch reuses shared investigation step" 'skills/n1-start/steps/investigation-deliverable.md' "$R/steps/01-fetch.md"
has "fetch uses caller mode" 'Caller mode — n1-refine' "$R/steps/01-fetch.md"
lacks "refine never writes frontmatter" 'n1_write_frontmatter' "$R"
lacks "refine never touches overview.md by path" 'memory/$ID/overview.md' "$R"

# --- Task 7: decision loop
L=skills/n1-refine/steps/02-loop.md
line_has "loop skips unknowns already under Clarifications" 'n1:unknown' '### Clarifications' "$L"
has "loop reuses contradiction signal" 'ticket_contradictions' "$L"
has "loop caps a batch at 4 questions" 'at most 4 questions per message' "$L"
has "loop rounds are uncapped" 'no round cap' "$L"
has "loop offers Decide for me" 'Decide for me' "$L"
has "loop parks into Assumptions" 'Park' "$L"
has "loop carries the no-recommendation sentence" 'No recommendation. The options are equivalent given the available evidence; select based on team preference.' "$L"
has "loop recommendation needs codebase evidence" '(Recommended): <evidence, file:line>' "$L"
has "loop runs duplicate check on widening" 'references/duplicate-check.md' "$L"
has "loop reclassifies scope" 'references/ticket-scope.md' "$L"
has "loop prints readiness verdict" 'Executable without questions: no — N open' "$L"
lacks "N1-296: refine to story handoff removed" '**Story scope in n1-refine:**' references/ticket-scope.md
lacks "N1-296: refine never mentions n1-story" 'n1-story' skills/n1-refine
lacks "N1-296: widening no longer ends refine without a block" 'refine writes no block' "$L"
has "N1-296: loop classifies by ticket type" 'ticket-scope.md` § Decomposition by ticket type' "$L"
has "N1-296: loop proposes only missing children" 'Propose only missing children' "$L"
has "N1-296: re-run never re-proposes an existing child" 'never re-proposes an existing child' "$L"
line_has "N1-296: CONVERT covers atomic Story to Task" '`CONVERT`' '`Task` (Story with one atomic deliverable' "$L"
line_has "N1-296: CONVERT covers Story-sized Task to Story" '`CONVERT`' '`Story` (Task classified `SCOPE_TYPE=Story`)' "$L"
has "N1-296: Story with children is never converted" 'a Story with children is never offered Task conversion' "$L"
S=references/ticket-scope.md
has "N1-296: ticket-scope has decomposition section" '## Decomposition by ticket type' "$S"
line_has "N1-296: Epic proposes Stories" '| Epic |' 'propose missing Stories' "$S"
line_has "N1-296: Story proposes Sub-tasks" '| Story | meaningful decomposition |' 'propose missing Sub-tasks' "$S"
line_has "N1-296: atomic Story converts to Task" '| Story, no children |' 'converting to Task' "$S"
line_has "N1-296: Story with children never converts" '| Story with children |' 'never convert' "$S"
line_has "N1-296: Story-sized Task converts to Story" '`SCOPE_TYPE=Story`' 'converting to Story' "$S"
line_has "N1-296: fitting Task refines only" '`SCOPE_TYPE=Task`' 'refine the block only' "$S"

# --- Task 8: write step
W=skills/n1-refine/steps/03-write.md
has "block starts with the marker" '*Refined by N1*' "$W"
has "decision line format" 'D<n> <topic>: <chosen>. Why: <reason>. Rejected: <alt>.' "$W"
has "assumption line format" '<X> (default). If wrong: <what changes>.' "$W"
before "block sections in order" '### Scope' '### Assumptions' "$W"
has "write re-fetches before writing" 'Re-fetch the ticket immediately before the write' "$W"
has "write replaces in place" 'replace exactly the lines from it' "$W"
has "single editTicket call" 'one `mcp__<TRACKER_MCP>__<EDIT_OP>` call' "$W"
has "comment mode posts one comment" 'one `mcp__<TRACKER_MCP>__<COMMENT_OP>` call' "$W"
has "write recommended" '1 — Write (Recommended)' "$W"
has "handoff prints n1-start" '/n1:n1-start <ID>' "$W"
has "architecture lists n1-refine" '| n1-refine |' references/architecture.md

# --- Task 9: n1-ticket hint
has "compose keeps the feasibility rating" 'Keep the feasibility rating for Step 9' skills/n1-ticket/steps/01-compose.md
line_has "create hints refine on risky tickets" '/n1:n1-refine <TICKET_ID>' 'needs investigation' skills/n1-ticket/steps/02-create.md

# --- N1-296: fetch type + existing children
F=skills/n1-refine/steps/01-fetch.md
has "N1-296: fetch parses issue_type" '"issue_type"' "$F"
has "N1-296: fetch parses subtask_count" '"subtask_count"' "$F"
has "N1-296: fetch reads createIssue op" ".tracker.operations.createIssue" "$F"
has "N1-296: fetch reads linkIssues op" ".tracker.operations.linkIssues" "$F"
has "N1-296: fetch reads getIssueLinks op" ".tracker.operations.getIssueLinks" "$F"
has "N1-296: fetch reads versionMcp" ".tracker.versionMcp" "$F"
line_has "N1-296: fetch lists Jira children by parent JQL, every page" 'parent = <ID>' 'startAt' "$F"
has "N1-296: fetch lists children of a Task" '`epic`, `story` or `task` only' "$F"
has "N1-296: Task with children is never converted" 'a Task with children is never offered Story conversion' "$L"
line_has "N1-296: fetch lists YouTrack subtask links" '<LINKS_OP>' '`subtask` link' "$F"
lacks "N1-296: fetch never uses the existence-only form" 'maxResults 1' "$F"
has "N1-296: subtask_count is a hint only" '`SUBTASK_COUNT` is a hint only' "$F"
has "N1-296: children lookup failure sets unknown" '`CHILDREN=unknown`' "$F"
before "N1-296: children lookup follows fetch" '## Step 3: Fetch' '## Step 3b: Existing Children' "$F"

# --- N1-296: write actions
W=skills/n1-refine/steps/03-write.md
n=$(grep -cF '(Recommended)' "$W")
if [ "$n" -eq 1 ]; then echo "PASS: N1-296: write has exactly one Recommended"; else echo "FAIL: N1-296: write has exactly one Recommended ($n)"; FAIL=1; fi
has "N1-296: preview offers Block only" '4 — Block only' "$W"
has "N1-296: preview offers Remove" '5 — Remove' "$W"
before "N1-296: block write precedes conversion" '## Step 3: Write' '## Step 3b: Conversion' "$W"
before "N1-296: conversion precedes children" '## Step 3b: Conversion' '## Step 3c: Children' "$W"
has "N1-296: failed block write runs no Actions" 'a failed block write runs no Actions' "$W"
line_has "N1-296: conversion via jcm_convertIssueType for Task and Story" 'jcm_convertIssueType' '`issueTypeName: <CONVERT>` (`Task` or `Story`)' "$W"
has "N1-296: failed Story conversion skips Sub-tasks" 'when `CONVERT=Story` skip Step 3c' "$W"
has "N1-296: child type rule exists" '**Child type rule:**' "$W"
line_has "N1-296: Story under Epic" '**Child type rule:**' 'Story under an Epic' "$W"
line_has "N1-296: Sub-task under Story" '**Child type rule:**' 'Sub-task under a Story' "$W"
line_has "N1-296: never Task under Story" '**Child type rule:**' 'Never `Task` under a Story' "$W"
line_has "N1-296: YouTrack child links subtask of" '**Child type rule:**' '`subtask of`' "$W"
line_has "N1-296: YouTrack children need a link op" '**Actions** come from' 'YouTrack children when `LINK_OP` is empty' "$W"
has "N1-296: per-child duplicate check" 'duplicate-check.md` § Check with `CONTEXT=create`' "$W"
has "N1-296: dup prompt has no recommendation" 'No recommendation. The options are equivalent given the available evidence; select based on team preference.' "$W"
line_has "N1-296: adopt passes child type and parentKey" 'issueKeys: [<HIT_ID>]' 'parentKey: <ID>' "$W"
line_has "N1-296: create passes child type and parentKey" 'issueType: <child type>' 'parentKey: <ID>' "$W"
has "N1-296: skip this child never ends the run" 'never ends the run' "$W"
has "N1-296: removing the Story conversion drops its Sub-tasks" 'dropping `A1` when `CONVERT=Story` also drops every Sub-task' "$W"
has "N1-296: handoff summarizes actions" 'Actions: converted' "$W"
lacks "N1-296: refine never transitions status" 'operations.transition' skills/n1-refine
lacks "N1-296: refine never creates a branch" 'git checkout' skills/n1-refine

# --- N1-296: dispatcher + docs
has "N1-296: SKILL states actions run only when picked" 'only for actions the user picks in the preview' skills/n1-refine/SKILL.md
has "N1-296: SKILL loop blurb names scope classification" 'scope classification' skills/n1-refine/SKILL.md
line_has "N1-296: architecture row describes decomposition" '| n1-refine |' 'Epic into Stories, Story into Sub-tasks' references/architecture.md
has "N1-296: duplicate-check lists n1-refine as caller" 'n1-ticket, n1-story and n1-refine (before creation)' references/duplicate-check.md

# --- N1-33: premise check for bug tickets
SA=agents/solution-architect.md
before "N1-33: premise check sits inside step 6 (bug only)" 'Bug investigation (when type is `bug`)' '**Premise check:**' "$SA"
before "N1-33: premise check precedes the defect trace" '**Premise check:**' 'Identify the code path where the bug manifests' "$SA"
line_has "N1-33: falsified premise counts in ticket_contradictions" '**Premise check:**' 'count it in `ticket_contradictions`' "$SA"
line_has "N1-33: premise search uses Grep tool with \\b" '**Premise check:**' 'Grep tool using `\b` word boundaries' "$SA"
line_has "N1-33: premise check never uses shell grep" '**Premise check:**' 'never shell grep' "$SA"
line_has "N1-33: unable to verify is not counted" '**Premise check:**' 'is unable to verify and is not counted' "$SA"
has "N1-33: output format documents the premise line" 'claim = `premise: <mechanism>`' "$SA"
line_has "N1-33: refine dispatch passes the resolved type" 'Dispatch persona `solution-architect`' 'Resolved ticket type: `<type from Step 3>`' "$F"

exit $FAIL

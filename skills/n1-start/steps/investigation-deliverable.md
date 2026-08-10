
**Spawn agent:** solution-architect

Resolve model for `solution-architect`.

**Phase 1 -- Produce Findings**

Spawn the solution-architect agent with:
- Path to `$N1_HOME/memory/<ID>/ticket.md` -- instruct: "Read this file yourself; it contains the investigation question."
- Path to `$N1_HOME/memory/<ID>/analysis.md` -- instruct: "Read this file yourself; it contains codebase analysis and findings. If it contains a `### Clarifications` section, treat those as answered questions -- incorporate the answers into your synthesis."
- Path to `$N1_HOME/memory/<ID>/brainstorm.md` (if it exists) -- instruct: "Read this file yourself; it contains additional research and design exploration."
- Directive: "This is an investigation task. Your job is to synthesize the analysis into a structured investigation deliverable. Do NOT propose implementation changes -- produce findings, conclusions, and recommendations.

    When you encounter a NEW constraint, assumption, or ambiguity not flagged in the analysis phase (check both the `### Clarifications` section and `<!-- n1:resolved: -->` markers in analysis.md -- do not re-flag already-resolved items), classify it before acting:

    - **A -- blocking:** Only a human can answer -- business intent, stakeholder preference, requirement ambiguity with no codebase evidence either way. Mark with `<!-- n1:unknown: <brief description> -->` inline.
    - **B -- significant:** The codebase likely contains the answer. You MUST explore (Read/Grep/Glob) before classifying. If you find evidence, resolve it inline and mark with `<!-- n1:resolved: <question> → <answer (file:line evidence)> -->`. If exploration is inconclusive, escalate to A.
    - **C -- convention:** Answerable from project patterns or standard practice. Resolve silently -- no marker needed.

    Default to B. Only classify as A after a genuine exploration attempt fails. The goal: the user should never be asked a question you could have answered by reading the code.

    Write your output in this exact format:"

```markdown
## Investigation: <title>

### Question
<the core question being investigated>

### Summary
<1-3 sentence answer>

### Metrics
- **Files analyzed:** <count of distinct files you read or grepped>
- **Blast radius:** <low|medium|high> (carry from analysis.md signal, or assess independently)
- **Confidence:** <high|medium|low> (<N>/<M> findings verified with file:line evidence)
- **Complexity assessment:** <XS|S|M|L|XL> (based on cross-cutting scope)
- **Implementable:** <yes|no> -- <one-line reason>
- **Risk factors:** <none | comma-separated list>
- **Unknowns resolved:** <N>/<M> (<K> deferred -- from analysis and deliverable Q&A phases)

### Findings
- <finding 1 with evidence (file:line references where applicable)>
- <finding 2 with evidence>

### Recommendations
- <recommendation 1>
- <recommendation 2>

### Next Steps
- <concrete action item 1>
- <concrete action item 2>

### References
- <file:line or URL cited>
```

- Directive: "Compute the Metrics section from your actual work -- files analyzed is the count of distinct files you Read or Grepped, confidence is the ratio of findings with file:line evidence vs total, complexity uses the XS-XL scale based on cross-cutting scope, and implementable reflects whether your recommendations describe concrete code changes."
- Directive: "Ground every finding in evidence from the codebase (file:line refs) or external sources (URLs). Do not speculate without noting uncertainty."
- Directive: "Scratch-artifact policy: write any throwaway test or benchmark under `$N1_HOME/memory/<ID>/benchmarks/` or `$N1_HOME/memory/<ID>/tests/` -- never into the repo's test suite."

After the agent returns:
- Write its output to `$N1_HOME/memory/<ID>/investigation.md`
- Update overview: `[x] Investigation deliverable`, set `step: investigation-deliverable`

**Extract and persist signals:**

Parse the `### Metrics` section from the written `investigation.md` to extract signal values:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"

INV_FILE="$N1_HOME/memory/$ID/investigation.md"

# Extract metrics from investigation.md (POSIX grep -- no -P)
CONFIDENCE=$(grep -oE '\*\*Confidence:\*\* [a-z]+' "$INV_FILE" | head -1 | sed 's/.*\*\* //')
IMPLEMENTABLE_RAW=$(grep -oE '\*\*Implementable:\*\* [a-z]+' "$INV_FILE" | head -1 | sed 's/.*\*\* //')
IMPLEMENTABLE=$([ "$IMPLEMENTABLE_RAW" = "yes" ] && echo "true" || echo "false")
FINDINGS_COUNT=$(sed -n '/^### Findings$/,/^### /p' "$INV_FILE" | grep -c '^- ' 2>/dev/null || echo "0")
RECOMMENDATIONS_COUNT=$(sed -n '/^### Recommendations$/,/^### /p' "$INV_FILE" | grep -c '^- ' 2>/dev/null || echo "0")

# Unknowns resolved: count clarifications answered vs total
UNKNOWNS_TOTAL=$(cat "$N1_HOME/memory/$ID/analysis.md" "$INV_FILE" 2>/dev/null | grep -c '<!-- n1:unknown:' || echo "0")
UNKNOWNS_ANSWERED=$(grep -cE '^[[:space:]]*\*\*A:\*\*' "$N1_HOME/memory/$ID/analysis.md" 2>/dev/null || echo "0")
UNKNOWNS_RESOLVED="${UNKNOWNS_ANSWERED}/${UNKNOWNS_TOTAL}"

# Self-resolved unknowns in deliverable
SELF_RESOLVED=$(grep -c '<!-- n1:resolved:' "$INV_FILE" 2>/dev/null || echo "0")

n1_write_signals "$INV_FILE" \
    "confidence=$CONFIDENCE" \
    "implementable=$IMPLEMENTABLE" \
    "unknowns_resolved=$UNKNOWNS_RESOLVED" \
    "findings_count=$FINDINGS_COUNT" \
    "recommendations_count=$RECOMMENDATIONS_COUNT" \
    "self_resolved=$SELF_RESOLVED"
```

If `SELF_RESOLVED` > 0, append a decision ledger row to `$N1_HOME/memory/<ID>/overview.md` per `skills/n1-start/ledger.md`:

| investigation-deliverable | scope | B | [auto] | {SELF_RESOLVED} unknowns answerable from codebase | Self-resolved via Read/Grep/Glob | — | B/C tier classification -- see `<!-- n1:resolved: -->` markers in investigation.md |

**Phase 1b -- Deliverable Q&A**

Extract any NEW unknowns flagged by the solution-architect during deliverable production:

```bash
# Only unknowns in investigation.md (analysis.md unknowns were already handled in the analysis step)
INV_FILE="$N1_HOME/memory/$ID/investigation.md"
UNKNOWNS=$(grep -oE '<!-- n1:unknown: [^>]+ -->' "$INV_FILE" | sed 's/<!-- n1:unknown: //;s/ -->//')
UNKNOWN_COUNT=$(echo "$UNKNOWNS" | grep -c '.' 2>/dev/null || echo "0")
```

If `UNKNOWN_COUNT` is 0, skip to Phase 2b.

**Interactive mode (not step mode):**

Present each unknown to the user one at a time:

```
During the investigation, I found {UNKNOWN_COUNT} additional question(s):

1. <first unknown>

Can you clarify this? (type your answer, or "skip" to leave it unresolved)
```

After collecting answers, append a `### Clarifications` section to `investigation.md` (after `### References`):

```markdown
### Clarifications
- **Q:** <unknown text>
  **A:** <user's answer or "Unresolved -- deferred">
```

Update the `unknowns_resolved` signal:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
INV_FILE="$N1_HOME/memory/$ID/investigation.md"
UNKNOWNS_TOTAL=$(cat "$N1_HOME/memory/$ID/analysis.md" "$INV_FILE" 2>/dev/null | grep -c '<!-- n1:unknown:' || echo "0")
UNKNOWNS_ANSWERED_ANALYSIS=$(grep -cE '^[[:space:]]*\*\*A:\*\*' "$N1_HOME/memory/$ID/analysis.md" 2>/dev/null || echo "0")
UNKNOWNS_ANSWERED_INVEST=$(grep -cE '^[[:space:]]*\*\*A:\*\*' "$INV_FILE" 2>/dev/null || echo "0")
UNKNOWNS_ANSWERED=$((UNKNOWNS_ANSWERED_ANALYSIS + UNKNOWNS_ANSWERED_INVEST))
n1_write_signals "$INV_FILE" "unknowns_resolved=${UNKNOWNS_ANSWERED}/${UNKNOWNS_TOTAL}"
```

**Step mode:**

Build the questions array from ALL extracted unknowns (one entry per unknown; do not limit to the first item):

```json
{
  "run_id": "<N1_RUN_ID>",
  "step": "investigation-deliverable",
  "questions": [
    { "id": "unknown_1", "text": "<first unknown text>", "context": "Flagged during investigation deliverable -- not covered by analysis" },
    { "id": "unknown_2", "text": "<second unknown text>", "context": "Flagged during investigation deliverable -- not covered by analysis" }
  ]
}
```

Write to `$N1_HOME/memory/<ID>/escalation/request.json`. Emit step result:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_emit_step_result "investigation-deliverable" "escalation" "null" "null" "" "$N1_HOME/memory/$ID"
```

On re-entry (when `escalation/response.json` exists and `run_id` matches `N1_RUN_ID`):
1. Read ALL answers from `response.json` -- iterate over every entry in the `answers` array, matching each answer to its `id` (`unknown_1`, `unknown_2`, ...)
2. Append `### Clarifications` section to `investigation.md` with one bullet per answered unknown (same format as interactive), using "Unresolved -- deferred" for any skipped or absent answers
3. Update the `unknowns_resolved` signal (same calculation as interactive mode above)
4. Delete `$N1_HOME/memory/<ID>/escalation/` directory
5. Proceed to Phase 2b normally

**Phase 2b -- Tracker Enrichment**

Use `mcp__<tracker.mcp>__` prefix (from session context TRACKER ROUTING) for all tracker calls.

**Gate -- ALL must hold, otherwise skip:**
1. A tracker ticket ID exists (not a slug -- must match `<prefix>-<number>` or equivalent)
2. `ticketEnrichment.enabled !== false` in `$N1_HOME/config.json` (default true when absent)
3. At least one of: `tracker.operations.editTicket` exists OR `tracker.operations.addComment` exists

If the gate fails, log "Tracker enrichment skipped -- no tracker or enrichment disabled." and proceed to Phase 2.

Read config:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
ENRICHMENT_ENABLED=$(n1_config_val ".ticketEnrichment.enabled" "$N1_HOME/config.json")
HAS_EDIT=$(n1_config_val ".tracker.operations.editTicket" "$N1_HOME/config.json")
HAS_COMMENT=$(n1_config_val ".tracker.operations.addComment" "$N1_HOME/config.json")
TRACKER_MCP=$(n1_config_val ".tracker.mcp" "$N1_HOME/config.json")
TRACKER_TYPE=$(n1_config_val ".tracker.type" "$N1_HOME/config.json")
```

**2b-i. Description update (when `HAS_EDIT` is non-empty):**

1. Fetch current ticket description. Call `tracker.operations.readTicket` via tracker MCP -- Jira: with `cloudId` (from `tracker.cloudId` in config, or resolve via `getAccessibleAtlassianResources` if absent), `issueIdOrKey: <ID>`; YouTrack: with `issueId: <ID>`.

2. Check idempotency: if current description contains `*Investigation completed -- N1*`, skip description update.

3. Extract from `investigation.md`: Summary section, Findings section (bullet items only), Metrics (Confidence, Blast radius, Implementable values), Recommendations section (bullet items only).

4. Construct append content:
   ```
   ---
   *Investigation completed -- N1*

   **Summary:** <summary text>

   **Key Findings:**
   <findings bullet items>

   **Confidence:** <level> | **Blast Radius:** <level> | **Implementable:** <yes/no>

   **Recommendations:**
   <recommendations bullet items>
   ```

5. Call `tracker.operations.editTicket` via tracker MCP -- Jira: with `cloudId`, `issueIdOrKey: <ID>`, `description: <current>\n\n<append>`; YouTrack: with `issueId: <ID>`, `description: <current>\n\n<append>`. On failure: log "Warning: Investigation description update failed: <reason>" -- non-blocking.

**2b-ii. Comment (when `HAS_COMMENT` is non-empty):**

Construct comment body:
```
**Investigation Results (N1)**

**Question:** <question section>
**Summary:** <summary>
**Findings:** <all findings with evidence>
**Metrics:** <full metrics section>
**Recommendations:** <all recommendations>
**Next Steps:** <all next steps>
```

Call `tracker.operations.addComment` via tracker MCP -- Jira: with `cloudId`, `issueIdOrKey: <ID>`, `body: <comment>`; YouTrack: with `issueId: <ID>`, `text: <comment>`. On failure: log "Warning: Investigation comment failed: <reason>" -- non-blocking.

**Phase 2 -- Discussion**

Present the findings summary to the user:

```
Investigation complete. Here are the key findings:

<Summary section from investigation.md>

<Recommendations section from investigation.md>

Would you like to discuss or refine any findings? (yes/no)
```

- **If yes:** Enter a back-and-forth conversation with the user. After discussion, update `investigation.md` with any refinements. Do NOT re-spawn the agent -- the orchestrator handles the refinement inline.
- **If no:** Proceed to post-investigation routing.

**Step mode variant:** In step mode (no interactive channel), skip Phase 2. The findings are written to `investigation.md` and the user can review them asynchronously.

**Phase 5 -- Post-Investigation Routing (interactive only)**

**Gate:** Skip entirely if step mode. Skip if no tracker is configured (`tracker.mcp` is null or absent).

Use `mcp__<tracker.mcp>__` prefix for all tracker calls in this phase.

**Step 1 -- Present results summary:**

Read signals from `investigation.md`:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
INV_FILE="$N1_HOME/memory/$ID/investigation.md"
CONFIDENCE=$(n1_read_signal "$INV_FILE" "confidence")
IMPLEMENTABLE=$(n1_read_signal "$INV_FILE" "implementable")
FINDINGS_COUNT=$(n1_read_signal "$INV_FILE" "findings_count")
RECOMMENDATIONS_COUNT=$(n1_read_signal "$INV_FILE" "recommendations_count")
```

Present:
```
Investigation complete.

- {FINDINGS_COUNT} findings (confidence: {CONFIDENCE})
- {RECOMMENDATIONS_COUNT} recommendations
- Implementable: {IMPLEMENTABLE == "true" ? "yes" : "no"}

What would you like to do next?
1 -- Create a new implementation ticket (linked to this investigation)
2 -- Convert this ticket to an implementation task
3 -- Done -- no further action needed
```

**Step 2 -- Route based on user choice:**

**If 1 -- Create new implementation ticket:**

Derive title from the first recommendation (~80 chars), or ask user. Construct description:
```
Follows investigation <ID>

## Summary
<investigation summary>

## Acceptance Criteria
- [ ] <derived from recommendation 1>
- [ ] <derived from recommendation 2>
...

## Scope
<scope boundaries derived from findings -- what is in and out of scope>

## Context
<relevant key findings as implementation context>
```

Create the follow-up implementation ticket using the Tracker Ticket Creation procedure from `steps/ticket.md` with `source_mode: braindump`. Pass: `summary=<title>`, `description=<description>`, `parentLink=<investigation ticket ID>`. All cloudId, tagging, assignToCreator, and ID adoption steps follow the same procedure.

After ticket creation (`<newID>` returned):

- **Link to investigation ticket:** call `tracker.operations.createIssueLink` via tracker MCP if the operation exists -- Jira: with `cloudId`, `issueIdOrKey: <newID>`, `linkedIssueIdOrKey: <ID>`, `linkType: "Relates"` (call `getIssueLinkTypes` first if a type ID is required); YouTrack: with `issueId: <newID>`, `targetIssueId: <ID>`, `linkType: "depends on"`. If absent or fails: the `Follows investigation <ID>` text in the description is the fallback -- log warning, non-blocking.
- **Comment on investigation ticket:** call `tracker.operations.addComment` via tracker MCP -- Jira: `cloudId`, `issueIdOrKey: <ID>`, `body: "Follow-up implementation ticket created: <newID> -- <title>"`; YouTrack: `issueId: <ID>`, `text: "Follow-up implementation ticket created: <newID> -- <title>"`. Non-blocking.
- **Report:** "Created follow-up ticket **[<newID>](<url>)**: <title>, linked to investigation <ID>."
- **Optionally close investigation ticket** (see close logic below) -- prompt: "Would you like to close this investigation ticket (<ID>)? 1 -- Yes, mark as done / 2 -- No, leave open". Close comment: "Investigation completed. Findings documented. Follow-up: <newID>".

**If 2 -- Convert this ticket to implementation:**

1. Call `tracker.operations.editTicket` via tracker MCP to update type -- Jira: with `cloudId`, `issueIdOrKey: <ID>`, `issueTypeName: "Task"`; YouTrack: with `issueId: <ID>`, `Type: "Task"`. On failure: log and continue.

2. Fetch current description. Check idempotency marker `*Converted to implementation -- N1*` -- skip if present. Otherwise construct append content:
   ```
   ---
   *Converted to implementation -- N1*

   ## Implementation Context
   <investigation summary>

   ## Acceptance Criteria
   - [ ] <derived from recommendation 1>
   - [ ] <derived from recommendation 2>
   ...

   ## Investigation Findings
   <key findings as implementation context>
   ```
   Call `tracker.operations.editTicket` via tracker MCP -- Jira: with `cloudId`, `issueIdOrKey: <ID>`, `description: <current>\n\n<append>`; YouTrack: with `issueId: <ID>`, `description: <current>\n\n<append>`.

3. Call `tracker.operations.addComment` via tracker MCP -- Jira: `cloudId`, `issueIdOrKey: <ID>`, `body: "Converted from investigation to implementation task. Investigation findings retained in description."`; YouTrack: `issueId: <ID>`, `text: "Converted from investigation to implementation task. Investigation findings retained in description."`. Non-blocking.

4. The ticket is not closed -- it continues as an active implementation task. Report: "Ticket <ID> converted to implementation task. Run `/n1:n1-start <ID>` to begin implementation."

**If 3 -- Done:**

Ask: "Would you like to close this investigation ticket (<ID>)? 1 -- Yes, mark as done / 2 -- No, leave open". If yes: close with comment "Investigation completed. Findings documented." (see close logic below).

**Close logic (shared by option 1 and option 3):**

**Gate -- ALL must hold, otherwise skip with warning:**
- `tracker.mcp` is configured; `tracker.statuses.done` is present; `tracker.operations.moveStatus` exists.

If the gate fails, log "Warning: Cannot close ticket -- tracker status configuration missing." and skip.

1. Call `tracker.operations.moveStatus` via tracker MCP -- Jira: first call `tracker.operations.getTransitions` with `cloudId`, `issueIdOrKey: <ID>` to find the transition matching `tracker.statuses.done`, then call `tracker.operations.moveStatus` with `cloudId`, `issueIdOrKey: <ID>`, `transitionId: <matched id>`; YouTrack: call `tracker.operations.moveStatus` with `issueId: <ID>`, `state: <tracker.statuses.done>`.
2. Call `tracker.operations.addComment` via tracker MCP -- Jira: with `cloudId`, `issueIdOrKey: <ID>`, `body: <close message>`; YouTrack: with `issueId: <ID>`, `text: <close message>`.
3. Tracker failures: warn, never block.

**Step mode variant:** In step mode, Phase 1b Q&A uses the escalation protocol (same as analysis step). Phase 2b tracker enrichment runs normally. Phase 2 discussion and Phase 5 post-investigation routing are skipped entirely. The step result is unchanged.

**Step result (step mode):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_emit_step_result "investigation-deliverable" "pass" "null" "null" "" "$N1_HOME/memory/$ID"
```

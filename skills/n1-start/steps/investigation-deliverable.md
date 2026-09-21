<!-- n1:step-snippet-exception: multi-phase investigation requires separate bash invocations for signals, telemetry, tracker enrichment, and routing -->

> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user.**

> **ORCHESTRATOR GUARDRAIL (experiments):** user requests to run/test/benchmark/curl are handled by spawning **developer** in experiment mode: pass the exact question + worktree path + "Experiment mode: build/run/benchmark in `$N1_HOME/memory/<ID>/scratch/`; no production code changes; no commits; write `experiment-<N>.md` with ## Question, ## Setup, ## Runs, ## Result, ## Cleanup; run cleanup; return ≤15-line summary + file path." Orchestrator reads summary and continues.

**Spawn agent:** solution-architect. Resolve model for `solution-architect`.

**Phase 1 — Produce Findings**

Spawn solution-architect with:
- Path to `$N1_HOME/memory/<ID>/ticket.md` — read yourself (investigation question).
- Path to `$N1_HOME/memory/<ID>/analysis.md` — read yourself (codebase analysis; treat `### Clarifications` answers as resolved).
- Path to `$N1_HOME/memory/<ID>/brainstorm.md` (if exists) — read yourself (additional research).
- Directive: "Investigate the question from ticket.md. Before synthesizing: inventory your available tools (Bash commands, MCP tools, web search) and collect real evidence relevant to the investigation question — run diagnostic commands, query available APIs or observability tools, check system state, fetch metrics, read logs. Use whatever tools you have that can produce evidence; do not limit yourself to codebase files. Then validate collected data against web search (documented thresholds, best practices, known standards) to contextualize it. Synthesize all evidence into a structured investigation deliverable. Do NOT propose implementation changes. Findings based solely on documentation or inference without collected evidence must be marked `(unverified)`. For NEW unknowns (not already in `### Clarifications` or `<!-- n1:resolved: -->` in analysis.md): A=blocking → `<!-- n1:unknown: -->`, B=significant → explore (Read/Grep/Glob/Bash/MCP) first; if resolved mark `<!-- n1:resolved: -->`; else escalate to A. Default to B. Write in this exact format:"

```markdown
## Investigation: <title>

### Question
<core question>

### Background
<2-4 paragraphs: problem domain, why investigation was needed, context for a new reader — cover what the system does, what went wrong, what the team was trying to achieve, why the answer wasn't obvious. Draw on ticket.md and analysis.md; write in your own voice.>

### Summary
<1-3 sentence answer>

### Metrics
- **Files analyzed:** <count>
- **Evidence sources:** <types used, e.g. codebase, commands, observability, web>
- **Blast radius:** <low|medium|high>
- **Confidence:** <high|medium|low> (<N>/<M> findings verified with collected evidence)
- **Complexity assessment:** <XS|S|M|L|XL>
- **Implementable:** <yes|no> — <one-line reason>
- **Risk factors:** <none | comma-separated>
- **Unknowns resolved:** <N>/<M> (<K> deferred)

### Findings
- <finding with evidence (file:line, command output, query result, or URL)>

### Recommendations
- <recommendation>

### Validation
- <recommendation summary> — ✓/⚠/✗ <evidence summary> (<url>, <url>)
...
Validation confidence: <high|medium|low> (<N>/<M> recommendations corroborated)

### Next Steps
- <action item>

### References
- <file:line, command, or URL>
```

- "Compute Metrics from actual work: files analyzed = distinct files Read/Grepped; evidence sources = categories of tools actually used (codebase, commands, observability, web); confidence = findings-with-collected-evidence / total; complexity uses XS-XL; implementable = recommendations describe concrete changes."
- "Ground every finding in collected evidence (file:line, command output, query result, or URL). Note uncertainty explicitly. Mark findings without collected evidence as `(unverified)`."
- "After completing Recommendations, add a ### Validation section (before ### Next Steps). For each recommendation: run web search using the research-standards.md rubric (corroborate ≥2 sources from trusted tiers; cite URLs; fitness gate — skip if no relevant standards exist). For each recommendation report: status (✓ Supported / ⚠ Mixed / ✗ Contradicted), 1-line evidence summary, source URLs. End Validation with one line: 'Validation confidence: <high|medium|low> (<N>/<M> recommendations corroborated)'. If web tools unavailable, write 'Validation: skipped — web tools unavailable'."
- "Scratch policy: write throwaway tests/benchmarks to `$N1_HOME/memory/<ID>/benchmarks/` or `$N1_HOME/memory/<ID>/tests/`."

> **WAIT:** Wait for the persona to return its result before proceeding. Do not continue until the solution-architect agent has written its output.

After agent returns: write output to `$N1_HOME/memory/<ID>/investigation.md`. Update overview: `[x] Investigation deliverable`, set `step: investigation-deliverable`.

```bash
source "$N1_ROOT/lib/preamble.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" investigation.md
```

**Extract and persist signals:**
```bash
source "$N1_ROOT/lib/preamble.sh"

INV_FILE="$N1_HOME/memory/$ID/investigation.md"

CONFIDENCE=$(grep -oE '\*\*Confidence:\*\* [a-z]+' "$INV_FILE" | head -1 | sed 's/.*\*\* //')
IMPLEMENTABLE_RAW=$(grep -oE '\*\*Implementable:\*\* [a-z]+' "$INV_FILE" | head -1 | sed 's/.*\*\* //')
IMPLEMENTABLE=$([ "$IMPLEMENTABLE_RAW" = "yes" ] && echo "true" || echo "false")
FINDINGS_COUNT=$(sed -n '/^### Findings$/,/^### /p' "$INV_FILE" | grep -c '^- ' 2>/dev/null || echo "0")
RECOMMENDATIONS_COUNT=$(sed -n '/^### Recommendations$/,/^### /p' "$INV_FILE" | grep -c '^- ' 2>/dev/null || echo "0")

UNKNOWNS_TOTAL=$(cat "$N1_HOME/memory/$ID/analysis.md" "$INV_FILE" 2>/dev/null | grep -c '<!-- n1:unknown:' || echo "0")
UNKNOWNS_ANSWERED=$(grep -cE '^[[:space:]]*\*\*A:\*\*' "$N1_HOME/memory/$ID/analysis.md" 2>/dev/null || echo "0")
UNKNOWNS_RESOLVED="${UNKNOWNS_ANSWERED}/${UNKNOWNS_TOTAL}"

SELF_RESOLVED=$(grep -c '<!-- n1:resolved:' "$INV_FILE" 2>/dev/null || echo "0")

VALIDATION_CONF=$(grep -oE 'Validation confidence: [a-z]+' "$INV_FILE" | head -1 | sed 's/.*: //')
[ -n "$VALIDATION_CONF" ] || VALIDATION_CONF="none"

n1_write_signals "$INV_FILE" \
    "confidence=$CONFIDENCE" \
    "implementable=$IMPLEMENTABLE" \
    "unknowns_resolved=$UNKNOWNS_RESOLVED" \
    "findings_count=$FINDINGS_COUNT" \
    "recommendations_count=$RECOMMENDATIONS_COUNT" \
    "self_resolved=$SELF_RESOLVED" \
    "validation_confidence=$VALIDATION_CONF"

UNKNOWNS=$(grep -oE '<!-- n1:unknown: [^>]+ -->' "$INV_FILE" | sed 's/<!-- n1:unknown: //;s/ -->//')
UNKNOWN_COUNT=$(echo "$UNKNOWNS" | grep -c '.' 2>/dev/null || echo "0")
echo "SELF_RESOLVED=$SELF_RESOLVED UNKNOWN_COUNT=$UNKNOWN_COUNT"
```

If `SELF_RESOLVED` > 0, append ledger row per `skills/n1-start/ledger.md`:

| investigation-deliverable | scope | B | [auto] | {SELF_RESOLVED} unknowns answerable from codebase | Self-resolved via Read/Grep/Glob | --- | B/C tier — see `<!-- n1:resolved: -->` markers in investigation.md | --- |

**Phase 2 — Deliverable Q&A**

If `UNKNOWN_COUNT` is 0, skip to Phase 3.

**Problem preamble:** same construction as analysis step. Bug root cause: same logic.

**Emit question telemetry** for each unknown presented and each "Decide for me":
```bash
source "$N1_ROOT/lib/preamble.sh"
n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "investigation-deliverable" "scope" "asked" "codebase|web"
# For "Decide for me":
n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "investigation-deliverable" "scope" "auto-decided" "codebase|web"
```

**Batch unknowns** (max 4; chain if more):

```
{PREAMBLE} During the investigation, I found {UNKNOWN_COUNT} additional question(s):

1. <unknown>
   Tried: codebase search, web search — unresolvable because <why>
   (Recommended) <answer>

For each: type your answer, "skip" to defer, or "Decide for me" to research and apply the recommendation.
Reply "use recommended" to accept all recommendations at once.
```

"Decide for me": re-run web search, apply best answer, record `[auto-decided]`, no follow-up.
"Use recommended": apply all; ask individually for those without a recommendation.

After answers: append `### Clarifications` to investigation.md (after `### References`): `**Q:** <text>\n  **A:** <answer or "Unresolved — deferred">`.

Update `unknowns_resolved` signal:
```bash
source "$N1_ROOT/lib/preamble.sh"
INV_FILE="$N1_HOME/memory/$ID/investigation.md"
UNKNOWNS_TOTAL=$(cat "$N1_HOME/memory/$ID/analysis.md" "$INV_FILE" 2>/dev/null | grep -c '<!-- n1:unknown:' || echo "0")
UNKNOWNS_ANSWERED_ANALYSIS=$(grep -cE '^[[:space:]]*\*\*A:\*\*' "$N1_HOME/memory/$ID/analysis.md" 2>/dev/null || echo "0")
UNKNOWNS_ANSWERED_INVEST=$(grep -cE '^[[:space:]]*\*\*A:\*\*' "$INV_FILE" 2>/dev/null || echo "0")
UNKNOWNS_ANSWERED=$((UNKNOWNS_ANSWERED_ANALYSIS + UNKNOWNS_ANSWERED_INVEST))
n1_write_signals "$INV_FILE" "unknowns_resolved=${UNKNOWNS_ANSWERED}/${UNKNOWNS_TOTAL}"
```

**Phase 3 — Tracker Enrichment**

**Gate** (skip if any fails): tracker ticket ID exists; `ticketEnrichment.enabled !== false`; `tracker.operations.editTicket` OR `tracker.operations.addComment` exists.

```bash
source "$N1_ROOT/lib/preamble.sh"
source "$N1_ROOT/lib/config.sh"
ENRICHMENT_ENABLED=$(n1_config_val ".ticketEnrichment.enabled" "$N1_HOME/config.json")
HAS_EDIT=$(n1_config_val ".tracker.operations.editTicket" "$N1_HOME/config.json")
HAS_COMMENT=$(n1_config_val ".tracker.operations.addComment" "$N1_HOME/config.json")
TRACKER_MCP=$(n1_config_val ".tracker.mcp" "$N1_HOME/config.json")
TRACKER_TYPE=$(n1_config_val ".tracker.type" "$N1_HOME/config.json")
KB_ENABLED=$(n1_config_val ".kb.enabled" "$N1_HOME/config.json")
HAS_CREATE_ARTICLE=$(n1_config_val ".tracker.operations.createArticle" "$N1_HOME/config.json")
echo "ENRICHMENT_ENABLED=$ENRICHMENT_ENABLED HAS_EDIT=$HAS_EDIT HAS_COMMENT=$HAS_COMMENT KB_ENABLED=$KB_ENABLED HAS_CREATE_ARTICLE=$HAS_CREATE_ARTICLE"
```

**3-i. KB auto-publish** (gate: `kb.enabled==true` AND `tracker.operations.createArticle` exists):

**Intent gate:** check ticket.md for explicit intent to publish to KB/Confluence/wiki. Positive: "publish to Confluence", "create KB article", "document in wiki". Non-positive: researching existing KB, no mention of publishing. If intent NOT detected: `KB_ARTICLE_LINK=""`, skip to 3-ii.

**Idempotency:** search for existing article titled `"Investigation: <title> (<ID>)"` (Jira: CQL; YouTrack: search_articles). If found: set `KB_ARTICLE_LINK` to URL, skip creation.

**Create article:** title = `"Investigation: <title> (<ID>)"`, body = full investigation.md content. Jira: call createArticle with cloudId, spaceId, title, body. YouTrack: call createArticle with project, summary, content. Set `KB_ARTICLE_LINK`. On failure: log warning, set `KB_ARTICLE_LINK=""`.

**3-ii. Description update** (when `HAS_EDIT` non-empty):

1. Fetch current description via tracker MCP.
2. Idempotency: skip if `*Investigation completed -- N1*` present.
3. Extract from investigation.md: Summary, Findings (file:line preserved), Recommendations, Metrics (all), Next Steps, Background.
4. Construct append content (Jira: plain bullets; YouTrack: checkboxes):
   ```
   ---
   *Investigation completed -- N1*

   ## Summary / ## Key Findings / ## Acceptance Criteria / ## Scope / ## Architectural Constraints / ## Metrics / ## Recommendations / ## Full Report (only when KB_ARTICLE_LINK non-empty)
   ```
   Derivation: AC = one verifiable criterion per recommendation. Scope-in = components from Findings. Scope-out = investigation boundaries. Constraints = invariants/dependencies from Findings. Full Report = KB_ARTICLE_LINK only.
5. Call editTicket via tracker MCP. On failure: log warning, non-blocking.

**3-iii. Comment** (when `HAS_COMMENT` non-empty):

Post comment: `**Investigation Results (N1)**\n**Question:** ...\n**Summary:** ...\n**Findings:** ...\n**Metrics:** ...\n**Recommendations:** ...\n**Next Steps:** ...`. On failure: log warning, non-blocking.

**Phase 4 — Discussion**

**Emit Gate 3 — investigation variant** (see `procedures/output-gates.md § Gate 3`). Use `=== <ID> — done ===` frame. Content = seven sections (Background, Summary, Metrics, Findings, Recommendations, Validation, Next Steps). When spawning the Phase 1 agent, add to compact-return contract: "Return Gate 3 block as your compact return — seven sections formatted inside `=== <ID> — done ===` markers; for Validation show summary line only: 'Validation confidence: <level> (<N>/<M> recommendations corroborated)'. Orchestrator prints verbatim." If agent doesn't return pre-formatted block: read investigation.md and emit seven sections inside frame.

**Findings budget:** cap at 20 lines. If over, print first 15 then `(full investigation: $N1_HOME/memory/<ID>/investigation.md)`. Omit `### References` and `### Clarifications` from chat output.

- Discussion: if user wants to discuss, enter back-and-forth; update investigation.md with refinements inline (no re-spawn).
- When done: proceed to Phase 5.

**Phase 5 — Post-Investigation Routing**

**Gate:** skip if no tracker configured. If tracker configured but no tracker ticket (brain-dump investigate mode): run Brain-dump variant.

**Brain-dump variant** (when `investigate_interactive: true` AND `<ID>` is a provisional slug):

Ask: `"Investigation done. Create a tracker ticket? 1 — Yes / 2 — No"`
- **2 (No):** report path to investigation.md and end.
- **1 (Yes):** create ticket via same mechanics as steps/ticket.md brain-dump creation (summary = investigation title; description = Summary + Findings + Recommendations from investigation.md). The returned ID is final. Run Reconcile Memory ID & Branch. Skip duplicate description append (already contains findings). Report `"Created ticket **[<ID>](<url>)**: <title>"`. Continue to Continuation offer.

Read signals:
```bash
source "$N1_ROOT/lib/preamble.sh"
INV_FILE="$N1_HOME/memory/$ID/investigation.md"
CONFIDENCE=$(n1_read_signal "$INV_FILE" "confidence")
IMPLEMENTABLE=$(n1_read_signal "$INV_FILE" "implementable")
FINDINGS_COUNT=$(n1_read_signal "$INV_FILE" "findings_count")
RECOMMENDATIONS_COUNT=$(n1_read_signal "$INV_FILE" "recommendations_count")
ORIGINAL_STATUS=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "original_status")
```

**Build menu** based on `IMPLEMENTABLE` and `ORIGINAL_STATUS`:

When `IMPLEMENTABLE==true`: "What next? 1 — Create new implementation ticket (linked) / 2 — Convert this ticket to implementation / 3 — Close ticket [/ 4 — Restore to original status ({ORIGINAL_STATUS}) (only when non-empty)]"

When `IMPLEMENTABLE!=true`: "What next? 1 — Close ticket [/ 2 — Restore to original status ({ORIGINAL_STATUS}) (only when non-empty)] / [2 or 3] — Leave as-is"

**Route based on choice:**

**If: Create new implementation ticket:**
1. Derive title from first recommendation (~80 chars) or ask user.
2. Construct description: `"Follows investigation <ID>\n\n## Summary\n...\n## Acceptance Criteria\n...\n## Scope\n...\n## Context\n..."` (Jira: plain bullets; YouTrack: checkboxes). Apply ticketTagging rules.
3. Call createIssue via tracker MCP.
4. **Link (mandatory):** call createIssueLink if configured (Jira: `linkType: "Relates"`; YouTrack: `linkType: "depends on"`). Fallback: `"Follows investigation <ID>"` in description.
5. Add comment to original ticket: "Follow-up created: <newID> — <title>".
6. Report: "Created follow-up **[<newID>](<url>)**: <title>, linked to <ID>."
7. Post-action: ask what to do with investigation ticket (Close / Restore / Leave as-is). Apply close or restore logic below.

**If: Convert to implementation:**
1. Call editTicket to update type to "Task".
2. Append to description (idempotency: skip if `*Converted to implementation -- N1*` present): `"*Converted to implementation -- N1*\n## Implementation Context\n...\n## Acceptance Criteria\n...\n## Investigation Findings\n..."` (Jira: plain bullets).
3. Add comment: "Converted from investigation to implementation task."
4. Update overview.md frontmatter:
   ```bash
   source "$N1_ROOT/lib/preamble.sh"
   n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "type" "task"
   n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "step" "brainstorm"
   n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "planning_need" "direct"
   ```
   Replace investigation checklist with normal pipeline checklist (carry over completed boxes). Crash-safe: tracker updates first, frontmatter writes last.
5. **Continuation offer:** "Continue to implementation now? 1 — Yes / 2 — No"
   - Yes: run workspace isolation (Ensure Worktree or Ensure Working Branch). Investigation served as brainstorm — do NOT re-run Step 3. Proceed directly to SKILL.md § Planning Need Routing using `planning_need` from overview.md frontmatter (set above; default `direct`).
   - No: report "Run `/n1:n1-start <ID>` to continue."

**If: Close ticket:** apply close logic. Comment: "Investigation completed. Findings documented."

**If: Restore to original status:** apply restore logic. Comment: "Investigation completed. Ticket restored to original status."

**If: Leave as-is:** no change, report "Investigation complete. Ticket status unchanged."

---

**Close logic** (gate: `tracker.mcp` configured AND `tracker.statuses.done` present AND `tracker.operations.moveStatus` exists):
- Jira: getTransitions → find done transition → moveStatus; then addComment. YouTrack: moveStatus with done state; then addComment. Failures: warn, non-blocking.

**Restore logic** (gate: `tracker.mcp` configured AND `ORIGINAL_STATUS` non-empty AND `tracker.operations.moveStatus` exists):
- Jira: getTransitions → find ORIGINAL_STATUS transition → moveStatus; then addComment. YouTrack: moveStatus with ORIGINAL_STATUS; then addComment. Failures: warn, non-blocking.

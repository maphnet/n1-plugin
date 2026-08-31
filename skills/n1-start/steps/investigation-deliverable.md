
> **ORCHESTRATOR GUARDRAIL (experiments):** in investigation tasks the user often asks for evidence — "test it locally", "run it in docker", "benchmark model A vs B", "curl the endpoint and check the stream". The orchestrator does NOT run these itself. Spawn the **developer** agent in *experiment mode* with:
> - the exact question to answer and the user's wording,
> - the worktree/branch path,
> - the directive: "Experiment mode: you may build, start containers, run scripts, install throwaway deps under `$N1_HOME/memory/<ID>/scratch/`, and call local endpoints. You MUST NOT modify production code or commit. Capture raw evidence (commands + output excerpts) and write `$N1_HOME/memory/<ID>/experiment-<N>.md` with sections `## Question`, `## Setup`, `## Runs`, `## Result`, `## Cleanup`. Always run cleanup (stop containers, kill processes). Return ONLY a ≤15-line summary and the file path."
>
> The orchestrator reads the summary and continues the investigation. If a *fix* is then requested, that is a normal developer (fix mode) spawn — again not inline.

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

### Background
<2-4 paragraphs explaining the problem domain, why this investigation was needed, and what context a reader needs to understand the findings. Written for someone encountering this problem for the first time. Cover: what the system or component does, what went wrong or was unclear, what the user or team was trying to achieve, and why the answer was not obvious from surface inspection. Draw on ticket.md and analysis.md for context but rewrite in your own narrative voice -- do not copy-paste.>

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

**Phase 2 -- Deliverable Q&A**

Extract any NEW unknowns flagged by the solution-architect during deliverable production:

```bash
# Only unknowns in investigation.md (analysis.md unknowns were already handled in the analysis step)
INV_FILE="$N1_HOME/memory/$ID/investigation.md"
UNKNOWNS=$(grep -oE '<!-- n1:unknown: [^>]+ -->' "$INV_FILE" | sed 's/<!-- n1:unknown: //;s/ -->//')
UNKNOWN_COUNT=$(echo "$UNKNOWNS" | grep -c '.' 2>/dev/null || echo "0")
```

If `UNKNOWN_COUNT` is 0, skip to Phase 3.

**Problem preamble:** compose a 1-2 sentence summary: extract the title from the `# <ID>: <Title>` heading in `$N1_HOME/memory/<ID>/overview.md` and the first non-blank line under `### Core Ask` in `$N1_HOME/memory/<ID>/ticket.md`. Format: `"{Title}: {Core Ask (≤1 sentence)}."` -- call this `PREAMBLE`. If either part is unavailable omit that part (keep the other); if both are missing, `PREAMBLE` is empty. **Bug root cause (bug tickets only):** Source `"${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"` first, then: if `$N1_HOME/memory/<ID>/analysis.md` contains a `### Bug Investigation` section AND the `has_bug_root_cause` signal is strictly `true` (read via `n1_read_signal`), prepend one sentence summarizing the root cause: `"Root cause: {root cause}. "` -- prepend this to `PREAMBLE`. If the signal is `false`, absent, or any other value, omit the root cause line entirely -- do not fall back to parsing the section body.

Present each unknown to the user one at a time, prefixing the opening message with `PREAMBLE` (omit if empty):

```
{PREAMBLE} During the investigation, I found {UNKNOWN_COUNT} additional question(s):

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

**Phase 3 -- Tracker Enrichment**

Use `mcp__<tracker.mcp>__` prefix (from session context TRACKER ROUTING) for all tracker calls.

**Gate -- ALL must hold, otherwise skip:**
1. A tracker ticket ID exists (not a slug -- must match `<prefix>-<number>` or equivalent)
2. `ticketEnrichment.enabled !== false` in `$N1_HOME/config.json` (default true when absent)
3. At least one of: `tracker.operations.editTicket` exists OR `tracker.operations.addComment` exists

If the gate fails, log "Tracker enrichment skipped -- no tracker or enrichment disabled." and proceed to Phase 4.

Read config:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
ENRICHMENT_ENABLED=$(n1_config_val ".ticketEnrichment.enabled" "$N1_HOME/config.json")
HAS_EDIT=$(n1_config_val ".tracker.operations.editTicket" "$N1_HOME/config.json")
HAS_COMMENT=$(n1_config_val ".tracker.operations.addComment" "$N1_HOME/config.json")
TRACKER_MCP=$(n1_config_val ".tracker.mcp" "$N1_HOME/config.json")
TRACKER_TYPE=$(n1_config_val ".tracker.type" "$N1_HOME/config.json")
```

**3-i. KB auto-publish (when KB is configured):**

**Gate -- ALL must hold, otherwise skip:**
1. `kb.enabled == true` in `$N1_HOME/config.json`
2. `tracker.operations.createArticle` exists in config

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
KB_ENABLED=$(n1_config_val ".kb.enabled" "$N1_HOME/config.json")
HAS_CREATE_ARTICLE=$(n1_config_val ".tracker.operations.createArticle" "$N1_HOME/config.json")
```

If either condition fails, set `KB_ARTICLE_LINK=""` and proceed to 3-ii.

**Intent gate:** KB auto-publish requires explicit user intent — `kb.enabled` alone is not sufficient for investigation mode. Read `$N1_HOME/memory/<ID>/ticket.md` and judge whether the user expressed intent to publish findings to a knowledge base, Confluence, wiki, or shared documentation. This is an inline LLM judgment on semantic intent, not a keyword search.

Positive intent examples: "publish results to Confluence", "create a KB article", "document this in the wiki", "add to knowledge base".

Non-intent examples: mentioning KB as research context ("check the KB for prior art"), no mention of KB/publishing at all, referencing existing articles.

If intent is **not** detected (the default path): set `KB_ARTICLE_LINK=""` and proceed to 3-ii.

If intent **is** detected: proceed with the idempotency check and article creation below.

**Idempotency:** Before creating, search for an existing article titled `"Investigation: <title> (<ID>)"`:
- Jira/Confluence: call `searchConfluenceUsingCql` via tracker MCP with CQL `title = "Investigation: <escaped_title> (<ID>)"` and `spaceKey` from `kb.spaceKey`. Escape double quotes in `<title>` with backslash before embedding in CQL. If results are non-empty, extract the article URL from the first result and set `KB_ARTICLE_LINK` to it. Skip creation.
- YouTrack: call `search_articles` via tracker MCP with query matching the title. If results are non-empty, extract the article URL/ID and set `KB_ARTICLE_LINK`. Skip creation.

**Create article:**
1. Read the full content of `$N1_HOME/memory/<ID>/investigation.md`.
2. Title: `"Investigation: <title> (<ID>)"` — where `<title>` is from the `## Investigation: <title>` heading in `investigation.md`.
3. Body: the full `investigation.md` content (all sections including References and Clarifications).
4. Jira/Confluence: call `tracker.operations.createArticle` via tracker MCP with `cloudId` (from `tracker.cloudId` in config), `spaceId` (from `kb.spaceId`), `title`, `body`. Extract the article URL from the response.
5. YouTrack: call `tracker.operations.createArticle` via tracker MCP with `project` (from `tracker.projectKey`), `summary` (title), `content` (body). Extract the article URL/ID from the response.

**Capture link:** Set `KB_ARTICLE_LINK` to the article URL. On failure: log `"Warning: KB article creation failed: <reason>"` — non-blocking, set `KB_ARTICLE_LINK=""`.

**3-ii. Description update (when `HAS_EDIT` is non-empty):**

1. Fetch current ticket description. Call `tracker.operations.readTicket` via tracker MCP -- Jira: with `cloudId` (from `tracker.cloudId` in config, or resolve via `getAccessibleAtlassianResources` if absent), `issueIdOrKey: <ID>`; YouTrack: with `issueId: <ID>`.

2. Check idempotency: if current description contains `*Investigation completed -- N1*`, skip description update.

3. Extract from `investigation.md`: Summary section, all Findings with evidence (file:line references preserved), Recommendations section, Metrics (all values — Confidence, Blast radius, Implementable, Complexity, Risk factors), Next Steps, Background section (for scope and constraints derivation).

4. Construct append content:
   ```
   ---
   *Investigation completed -- N1*

   ## Summary
   <summary text from investigation.md>

   ## Key Findings
   <all findings with evidence — file:line references preserved, not just bullets>

   ## Acceptance Criteria
   - [ ] <derived from recommendation 1>       ← YouTrack
   - <derived from recommendation 1>           ← Jira (see Jira formatting below)
   ...

   ## Scope
   - **In scope:** <components/areas affected, derived from findings and file references>
   - **Out of scope:** <explicitly excluded areas, derived from investigation boundaries>

   ## Architectural Constraints
   <constraints, decisions, or gotchas discovered during investigation — anything a fresh implementer needs to know that isn't obvious from the code>

   ## Metrics
   **Confidence:** <level> | **Blast Radius:** <level> | **Implementable:** <yes/no>
   **Complexity:** <tier> | **Risk factors:** <list or none>

   ## Recommendations
   <all recommendations from investigation.md>

   ## Full Report
   <KB article link — only present when KB_ARTICLE_LINK is non-empty>
   ```

   **Jira formatting:** If `tracker.type == "jira"`, use plain bullets (`- criterion`) instead of checkbox syntax (`- [ ] criterion`) in all content written to the tracker. Jira does not support GitHub-flavored Markdown checkboxes and silently strips the brackets. YouTrack supports checkboxes — use `- [ ]` for YouTrack.

   **Derivation rules:**
   - **Acceptance criteria:** One item per recommendation. Each criterion is a verifiable statement derived from the recommendation (e.g., recommendation "Add input validation to endpoint X" becomes `- [ ] Input validation added to endpoint X` for YouTrack, or `- Input validation added to endpoint X` for Jira).
   - **Scope — In scope:** List the components, files, or subsystems referenced in the Findings section. Group by area if more than 5.
   - **Scope — Out of scope:** Derive from investigation boundaries — anything the investigation explicitly noted as unrelated or deferred.
   - **Architectural constraints:** Extract from Findings any items that describe how something works or must work (invariants, dependencies, ordering requirements), as opposed to what's wrong. If none, omit the section.
   - **Full Report:** Include only when `KB_ARTICLE_LINK` is non-empty. Omit the entire section otherwise.

5. Call `tracker.operations.editTicket` via tracker MCP -- Jira: with `cloudId`, `issueIdOrKey: <ID>`, `description: <current>\n\n<append>`; YouTrack: with `issueId: <ID>`, `description: <current>\n\n<append>`. On failure: log "Warning: Investigation description update failed: <reason>" -- non-blocking.

**3-iii. Comment (when `HAS_COMMENT` is non-empty):**

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

**Phase 4 -- Discussion**

Present the investigation deliverable to the user. Extract the following sections from `investigation.md` and print them verbatim (preserve all markdown formatting, tables, and file:line references):

```
## Investigation: <title from investigation.md>

### Background
<Background section from investigation.md>

### Summary
<Summary section from investigation.md>

### Metrics
<Metrics section from investigation.md>

### Findings
<Findings section from investigation.md -- all evidence and file:line references preserved>

### Recommendations
<Recommendations section from investigation.md>

### Next Steps
<Next Steps section from investigation.md>

Full report: `$N1_HOME/memory/<ID>/investigation.md`

Would you like to discuss or refine any findings?
```

Omit `### References` and `### Clarifications` from chat output (reference-only, not actionable in conversation).

- **If yes:** Enter a back-and-forth conversation with the user. After discussion, update `investigation.md` with any refinements. Do NOT re-spawn the agent -- the orchestrator handles the refinement inline.
- **If no:** Proceed to post-investigation routing.

**Phase 5 -- Post-Investigation Routing**

**Gate:** Skip if no tracker is configured (`tracker.mcp` is null or absent). If a tracker IS configured but this run has no tracker ticket (deferred creation: `--investigate` brain-dump mode, `<ID>` is a description slug), run the **Brain-dump variant** below instead of Steps 1-2.

Use `mcp__<tracker.mcp>__` prefix for all tracker calls in this phase.

**Brain-dump variant (deferred ticket creation):**

Applies when overview.md frontmatter has `investigate_interactive: true` AND `<ID>` is a provisional slug (no tracker ticket was created at intake). Ask:

```
Investigation done. Create a tracker ticket for this?
1 -- Yes, create a ticket in <tracker.mcp>
2 -- No, keep the report in local memory only
```

**If 2 (No):** report "Investigation report saved to `$N1_HOME/memory/<ID>/investigation.md`." and end the run.

**If 1 (Yes):**

1. Create the ticket via tracker MCP using the same mechanics as steps/ticket.md brain-dump creation (tagging config, createIssue call shapes, assign-to-creator, URL extraction), with content derived from the investigation:
   - `summary` = the investigation title (from `investigation.md` heading, or `ticket.md` Title).
   - `description` = the `## Summary` section of `investigation.md`, then `## Findings` (key findings), then `## Recommendations` — copied from `investigation.md`.
2. The returned ticket ID is the final `<ID>`. Run **Reconcile Memory ID & Branch(`<provisional>`, `<ticketID>`)** (SKILL.md procedure) to move `$N1_HOME/memory/<provisional>/` to the real ID.
3. Run the existing tracker-enrichment idempotency check and comment logic against the NEW ticket only if enrichment has not already run this session (the description already contains the findings — skip the description append, add no duplicate comment).
4. Report: "Created ticket **[<ID>](<ticket URL>)**: <title>"
5. Continue to the **Continuation offer** below (same as convert path step 5).

**Ticket-creation failure:** log the tracker error, report "Ticket creation failed — investigation report remains at `$N1_HOME/memory/<ID>/investigation.md`.", and end the run without losing the report.

**Step 1 -- Present results summary:**

Read signals from `investigation.md`:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
INV_FILE="$N1_HOME/memory/$ID/investigation.md"
CONFIDENCE=$(n1_read_signal "$INV_FILE" "confidence")
IMPLEMENTABLE=$(n1_read_signal "$INV_FILE" "implementable")
FINDINGS_COUNT=$(n1_read_signal "$INV_FILE" "findings_count")
RECOMMENDATIONS_COUNT=$(n1_read_signal "$INV_FILE" "recommendations_count")
ORIGINAL_STATUS=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "original_status")
```

**Build the menu dynamically** based on `IMPLEMENTABLE` and `ORIGINAL_STATUS`:

**When `IMPLEMENTABLE == "true"` AND `ORIGINAL_STATUS` is non-empty:**
```
Investigation complete.

- {FINDINGS_COUNT} findings (confidence: {CONFIDENCE})
- {RECOMMENDATIONS_COUNT} recommendations
- Implementable: yes

What would you like to do next?
1 -- Create a new implementation ticket (linked to this investigation)
2 -- Convert this ticket to an implementation task
3 -- Close ticket
4 -- Restore to original status ({ORIGINAL_STATUS})
```

**When `IMPLEMENTABLE == "true"` AND `ORIGINAL_STATUS` is empty:**
```
Investigation complete.

- {FINDINGS_COUNT} findings (confidence: {CONFIDENCE})
- {RECOMMENDATIONS_COUNT} recommendations
- Implementable: yes

What would you like to do next?
1 -- Create a new implementation ticket (linked to this investigation)
2 -- Convert this ticket to an implementation task
3 -- Close ticket
```

**When `IMPLEMENTABLE != "true"` AND `ORIGINAL_STATUS` is non-empty:**
```
Investigation complete.

- {FINDINGS_COUNT} findings (confidence: {CONFIDENCE})
- {RECOMMENDATIONS_COUNT} recommendations
- Implementable: no

What would you like to do next?
1 -- Close ticket
2 -- Restore to original status ({ORIGINAL_STATUS})
3 -- Leave ticket as-is
```

**When `IMPLEMENTABLE != "true"` AND `ORIGINAL_STATUS` is empty:**
```
Investigation complete.

- {FINDINGS_COUNT} findings (confidence: {CONFIDENCE})
- {RECOMMENDATIONS_COUNT} recommendations
- Implementable: no

What would you like to do next?
1 -- Close ticket
2 -- Leave ticket as-is
```

**Step 2 -- Route based on user choice:**

---

**When `IMPLEMENTABLE == "true"` (options 1-3 or 1-4 depending on `ORIGINAL_STATUS`):**

**If 1 -- Create new implementation ticket:**

1. Read the `### Recommendations` and `### Summary` sections from `investigation.md`.
2. Derive title: first recommendation trimmed to ~80 chars, or ask user to provide a title.
3. Construct description:
   ```
   Follows investigation <ID>

   ## Summary
   <investigation summary>

   ## Acceptance Criteria
   - [ ] <derived from recommendation 1>       ← YouTrack
   - <derived from recommendation 1>           ← Jira (see Jira formatting below)
   ...

   ## Scope
   <scope boundaries derived from findings -- what is in and out of scope>

   ## Context
   <relevant key findings as implementation context>
   ```

4. **Jira formatting:** If `tracker.type == "jira"`, convert any checkbox syntax in the description: replace `- [ ] ` with `- ` and `- [x] ` with `- ` (Jira does not support GitHub-flavored Markdown checkboxes).

5. **Resolve ticket tagging** -- same logic as brain-dump ticket creation in `steps/ticket.md`:
   - Read `ticketTagging` from config. If `ticketTagging.enabled` is true AND `ticketTagging.service` is non-empty: `<summary>` = `<service> | <title>`, `<description>` = `**Service:** <service>\n\n<description>`. Idempotency guard on title prefix.
   - Otherwise: `<summary>` = title, `<description>` = description as-is.

6. Call `tracker.operations.createIssue` via tracker MCP -- Jira: `cloudId` (from `tracker.cloudId` in config, or resolve via `getAccessibleAtlassianResources` if absent), `projectKey`, `issueTypeName: "Task"`, `summary`, `description`; YouTrack: `project`, `summary`, `description`.

7. **Link to investigation ticket (mandatory invariant):**

   Attempt native linking first:
   - Read `tracker.operations.createIssueLink` from config. If absent, skip to fallback.
   - If exists: call `tracker.operations.createIssueLink` via tracker MCP -- Jira: `cloudId`, `issueIdOrKey: <newID>`, `linkedIssueIdOrKey: <ID>`, `linkType: "Relates"` (if link type ID required, first call `tracker.operations.getIssueLinkTypes` to resolve); YouTrack: `issueId: <newID>`, `targetIssueId: <ID>`, `linkType: "depends on"`.
   - If absent or fails: `Follows investigation <ID>` in description is the fallback (always present). Log "Warning: Native issue linking failed: <reason> -- text link in description." -- non-blocking.

8. Call `tracker.operations.addComment` via tracker MCP -- Jira: `cloudId`, `issueIdOrKey: <ID>`, `body: "Follow-up implementation ticket created: <newID> -- <title>"`; YouTrack: `issueId: <ID>`, `text: "Follow-up implementation ticket created: <newID> -- <title>"`. Non-blocking on failure.

9. Report: "Created follow-up ticket **[<newID>](<url>)**: <title>, linked to investigation <ID>."

10. **Post-action: investigation ticket disposition** -- when `ORIGINAL_STATUS` is non-empty, ask:
   ```
   What should happen to this investigation ticket (<ID>)?
   1 -- Close ticket
   2 -- Restore to original status ({ORIGINAL_STATUS})
   3 -- Leave as-is
   ```
   If 1: transition to `tracker.statuses.done` and add comment "Investigation completed. Findings documented. Follow-up: <newID>" (see close logic below).
   If 2: restore to original status and add comment "Investigation completed. Ticket restored to original status. Follow-up: <newID>" (see restore logic below).
   If 3: no status change.

   When `ORIGINAL_STATUS` is empty, ask:
   ```
   What should happen to this investigation ticket (<ID>)?
   1 -- Close ticket
   2 -- Leave as-is
   ```
   If 1: transition to `tracker.statuses.done` and add comment "Investigation completed. Findings documented. Follow-up: <newID>" (see close logic below).
   If 2: no status change.

**If 2 -- Convert this ticket to implementation** (applies only when `IMPLEMENTABLE == "true"`):

1. Call `tracker.operations.editTicket` via tracker MCP to update type -- Jira: with `cloudId`, `issueIdOrKey: <ID>`, `issueTypeName: "Task"`; YouTrack: with `issueId: <ID>`, `Type: "Task"`. On failure: log and continue.

2. Fetch current description. Check idempotency marker `*Converted to implementation -- N1*` -- skip if present. Otherwise construct append content (use plain bullets for Jira, checkboxes for YouTrack -- see Jira formatting rule in Phase 3):
   ```
   ---
   *Converted to implementation -- N1*

   ## Implementation Context
   <investigation summary>

   ## Acceptance Criteria
   - [ ] <derived from recommendation 1>       ← YouTrack
   - <derived from recommendation 1>           ← Jira
   ...

   ## Investigation Findings
   <key findings as implementation context>
   ```
   Call `tracker.operations.editTicket` via tracker MCP -- Jira: with `cloudId`, `issueIdOrKey: <ID>`, `description: <current>\n\n<append>`; YouTrack: with `issueId: <ID>`, `description: <current>\n\n<append>`.

3. Call `tracker.operations.addComment` via tracker MCP -- Jira: `cloudId`, `issueIdOrKey: <ID>`, `body: "Converted from investigation to implementation task. Investigation findings retained in description."`; YouTrack: `issueId: <ID>`, `text: "Converted from investigation to implementation task. Investigation findings retained in description."`. Non-blocking.

4. Update `overview.md` so the pipeline can actually continue (this is the resume contract — without it, `n1_read_type` still returns `investigation` and resume dead-ends in the terminal investigation flow):

   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
   n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "type" "task"
   n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "step" "brainstorm"
   ```

   Then replace the investigation progress checklist in overview.md with the normal pipeline checklist, carrying over completed boxes:

   ```markdown
   ## Progress
   - [x] Ticket read
   - [x] Analysis
   - [x] Brainstorm
   - [ ] Plan
   - [ ] Estimation
   - [ ] Implementation
   - [ ] QA
   - [ ] Review
   - [ ] Local Testing
   - [ ] PR
   - [ ] CI
   ```

   Crash-safe order: the tracker updates (items 1-3) and checklist rewrite happen first; the `step`/`type` frontmatter writes are the last mutation.

5. **Continuation offer.** Ask: "Continue to implementation now? 1 -- Yes, continue in this session / 2 -- No, stop here".
   - **If 1 (Yes):** run workspace isolation now — **Ensure Worktree(`<ID>`)** when `USE_WORKTREE` is true, or **Ensure Working Branch(`<ID>`)** otherwise (investigation mode skipped it) — then proceed to SKILL.md § Planning Need Routing using the `planning_need` signal from `$N1_HOME/memory/$ID/brainstorm.md`; if the signal is absent (research-focused brainstorm may not emit it), default to `deep` (route to plan). The existing artifacts (`ticket.md`, `analysis.md`, `brainstorm.md`) satisfy the dependency guard — no step is re-run.
   - **If 2 (No):** report "Ticket <ID> converted to implementation task. Run `/n1:n1-start <ID>` to continue — the pipeline will resume at the next step."

**If 3 -- Close ticket** (option 3 in both the 3-item and 4-item implementable menus — applies regardless of `ORIGINAL_STATUS`):
Apply close logic below. Comment: "Investigation completed. Findings documented."

**If 4 -- Restore to original status** (only present when `ORIGINAL_STATUS` is non-empty; option 4 in the 4-item menu):
Apply restore logic below. Comment: "Investigation completed. Ticket restored to original status."

---

**When `IMPLEMENTABLE != "true"` (options 1-3 when `ORIGINAL_STATUS` is non-empty; options 1-2 when empty):**

**If 1 -- Close ticket:**
Apply close logic below. Comment: "Investigation completed. Findings documented."

**If 2 -- Restore to original status** (only present when `ORIGINAL_STATUS` is non-empty):
Apply restore logic below. Comment: "Investigation completed. Ticket restored to original status."

**If 3 (when `ORIGINAL_STATUS` is non-empty) or If 2 (when `ORIGINAL_STATUS` is empty) -- Leave ticket as-is:**
No status change, no comment. Report "Investigation complete. Ticket status unchanged."

---

**Close logic (shared by close options across all menu variants):**

**Gate -- ALL must hold, otherwise skip with warning:**
- `tracker.mcp` is configured; `tracker.statuses.done` is present; `tracker.operations.moveStatus` exists.

If the gate fails, log "Warning: Cannot close ticket -- tracker status configuration missing." and skip.

1. Call `tracker.operations.moveStatus` via tracker MCP -- Jira: first call `tracker.operations.getTransitions` with `cloudId`, `issueIdOrKey: <ID>` to find the transition matching `tracker.statuses.done`, then call `tracker.operations.moveStatus` with `cloudId`, `issueIdOrKey: <ID>`, `transitionId: <matched id>`; YouTrack: call `tracker.operations.moveStatus` with `issueId: <ID>`, `state: <tracker.statuses.done>`.
2. Call `tracker.operations.addComment` via tracker MCP -- Jira: with `cloudId`, `issueIdOrKey: <ID>`, `body: <close message>`; YouTrack: with `issueId: <ID>`, `text: <close message>`.
3. Tracker failures: warn, never block.

**Restore logic:**

**Gate -- ALL must hold, otherwise skip with warning:**
- `tracker.mcp` is configured; `ORIGINAL_STATUS` is non-empty; `tracker.operations.moveStatus` exists.

If the gate fails, log "Warning: Cannot restore ticket status -- tracker configuration missing or original status unknown." and skip.

1. Call `tracker.operations.moveStatus` via tracker MCP -- Jira: first call `tracker.operations.getTransitions` with `cloudId`, `issueIdOrKey: <ID>` to find the transition matching `ORIGINAL_STATUS`, then call `tracker.operations.moveStatus` with `cloudId`, `issueIdOrKey: <ID>`, `transitionId: <matched id>`; YouTrack: call `tracker.operations.moveStatus` with `issueId: <ID>`, `state: <ORIGINAL_STATUS>`.
2. Call `tracker.operations.addComment` via tracker MCP -- Jira: with `cloudId`, `issueIdOrKey: <ID>`, `body: <restore message>`; YouTrack: with `issueId: <ID>`, `text: <restore message>`.
3. Tracker failures: warn, never block.

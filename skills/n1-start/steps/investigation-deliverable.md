
**Spawn agent:** solution-architect

Resolve model for `solution-architect`.

**Phase 1 -- Produce Findings**

Spawn the solution-architect agent with:
- Path to `$N1_HOME/memory/<ID>/ticket.md` -- instruct: "Read this file yourself; it contains the investigation question."
- Path to `$N1_HOME/memory/<ID>/analysis.md` -- instruct: "Read this file yourself; it contains codebase analysis and findings."
- Path to `$N1_HOME/memory/<ID>/brainstorm.md` (if it exists) -- instruct: "Read this file yourself; it contains additional research and design exploration."
- Directive: "This is an investigation task. Your job is to synthesize the analysis into a structured investigation deliverable. Do NOT propose implementation changes -- produce findings, conclusions, and recommendations. Write your output in this exact format:"

```markdown
## Investigation: <title>

### Question
<the core question being investigated>

### Summary
<1-3 sentence answer>

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

- Directive: "Ground every finding in evidence from the codebase (file:line refs) or external sources (URLs). Do not speculate without noting uncertainty."
- Directive: "Scratch-artifact policy: write any throwaway test or benchmark under `$N1_HOME/memory/<ID>/benchmarks/` or `$N1_HOME/memory/<ID>/tests/` -- never into the repo's test suite."

After the agent returns:
- Write its output to `$N1_HOME/memory/<ID>/investigation.md`
- Update overview: `[x] Investigation deliverable`, set `step: investigation-deliverable`

**Phase 2 -- Discussion**

Present the findings summary to the user:

```
Investigation complete. Here are the key findings:

<Summary section from investigation.md>

<Recommendations section from investigation.md>

Would you like to discuss or refine any findings? (yes/no)
```

- **If yes:** Enter a back-and-forth conversation with the user. After discussion, update `investigation.md` with any refinements. Do NOT re-spawn the agent -- the orchestrator handles the refinement inline.
- **If no:** Proceed to follow-up.

**Step mode variant:** In step mode (no interactive channel), skip Phase 2. The findings are written to `investigation.md` and the user can review them asynchronously.

**Phase 3 -- Follow-up Ticket Creation (inline)**

Check if follow-up is applicable:
1. Read `$N1_HOME/config.json` for `tracker.mcp` and `tracker.operations.createIssue`
2. Read the `### Next Steps` section from `investigation.md`

**If tracker is configured AND next steps exist AND NOT step mode:**

Ask the user:
```
Would you like to create a follow-up ticket for the next steps identified in this investigation?
1 -- Yes, create a follow-up ticket
2 -- No, skip
```

**If 1 (Yes):**
1. Compose the follow-up ticket:
   - `<summary>`: First next-step item as title (trimmed to ~80 chars)
   - `<description>`: All next steps as acceptance criteria, prefixed with:
     ```
     Follows investigation <ID> (<ticket URL if available>)

     ## Next Steps (from investigation)
     <next steps items as checkboxes>
     ```
2. **Resolve ticket tagging** -- same logic as brain-dump ticket creation in `steps/ticket.md`.
3. Create via MCP -- same tracker-type-specific logic as brain-dump ticket creation in `steps/ticket.md`.
4. Report: "Created follow-up ticket **[<newID>](<url>)**: <title>"

**If 2 (No) or tracker not configured or no next steps:** Skip silently.

**Step mode variant:** In step mode, skip follow-up ticket creation. Write a note to `investigation.md`: "Follow-up ticket creation deferred to interactive session."

**Phase 4 -- Close Investigation Ticket (inline)**

**Gate -- ALL must hold, otherwise skip:**
- A tracker ticket ID exists (not a slug)
- `tracker.mcp` is configured
- `tracker.statuses.done` is present in config
- NOT step mode

**If gate passes:**

Ask the user:
```
Would you like to close this investigation ticket (<ID>)?
1 -- Yes, mark as done
2 -- No, leave open
```

**If 1 (Yes):**
1. Move status via the operations map (same pattern as n1-finish Step 4):
   - Jira: `mcp__<tracker.mcp>__<operations.getTransitions>` -> find done transition -> `mcp__<tracker.mcp>__<operations.moveStatus>`
   - YouTrack: `mcp__<tracker.mcp>__<operations.moveStatus>` with done state
2. Add comment: `mcp__<tracker.mcp>__<operations.addComment>` with "Investigation completed. Findings documented."
   If a follow-up ticket was created, append: " Follow-up: <newID>"
3. Tracker failures: warn, never block.

**If 2 (No):** Skip.

**Step result (step mode):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_emit_step_result "investigation-deliverable" "pass" "null" "null" "" "$N1_HOME/memory/$ID"
```

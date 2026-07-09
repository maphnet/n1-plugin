
**Conditional routing based on execution mode:**

**Step mode** (`--step brainstorm`): Use the autonomous brainstormer defined in `autonomous-brainstorm.md` (in this skill's directory). This skill runs without any interactive channel — it generates approaches, scores them, and either selects autonomously or writes an escalation request for n1-loop to mediate.

**Full pipeline + investigation mode** (no `--step` flag, AND `MODE == "investigation"` from overview.md frontmatter): Use the autonomous brainstormer defined in `autonomous-brainstorm.md` (in this skill's directory). Pass the investigation focus override (see Investigation mode section below). After the autonomous brainstormer returns, skip the `REQUIRED SUB-SKILL` block below and proceed directly to the overview update and Post-Brainstorm Enrichment gate.

**Full pipeline + non-investigation mode** (no `--step` flag, normal task): Use the interactive brainstormer:

**REQUIRED SUB-SKILL:** Use superpowers:brainstorming to explore the scope and refine the approach.

Pass to brainstorming:
- The content of `ticket.md` as the idea to explore
- The content of `analysis.md` as **pre-researched codebase context** — tell brainstorming: "Here is a codebase analysis already performed by our solution architect — use this as your starting context instead of exploring from scratch."
- **If ticket type is `bug`:** Also tell brainstorming: "This is a bug. The analysis includes a Bug Investigation section with the likely root cause and affected code path. Use these findings to ask informed questions about the fix approach rather than generic questions."

**Brainstorming overrides (IMPORTANT):**
- **Spec location:** Write the design doc directly to `$N1_HOME/memory/<ID>/brainstorm.md` — NOT to `docs/superpowers/specs/`. The brainstorming skill honors "user preferences for spec location override this default," so this is the sanctioned location override.
- **Do NOT commit the spec.** `$N1_HOME/` is N1's ephemeral state directory — N1 owns this content in per-ticket memory. No spec artifact may be committed to the target repo.
- **Skip the User Review Gate.** The brainstorming skill's checklist has a "User reviews written spec" step that asks the user to re-approve the spec after it is written to disk. Skip it — the design was already approved conversationally (step 5), and `brainstorm.md` is an ephemeral memory file, not a committed artifact. Writing it is a recording step, not a review step. After the spec self-review passes, hand control back to the N1 orchestrator immediately.
- **Stop after the design; do NOT auto-invoke `writing-plans`.** SP 5.1 brainstorming treats "invoke writing-plans" as its terminal state ("the ONLY skill you invoke after brainstorming is writing-plans"). Override this: once the design is written to `brainstorm.md` and approved, hand control back to the N1 orchestrator. N1 runs its own Complexity Decision and then invokes `writing-plans` itself with the overrides in Step 4. If brainstorming auto-chained into `writing-plans` directly, the plan would be produced WITHOUT N1's location and execution-handoff overrides — writing to `docs/superpowers/plans/` and offering execution options. Do not let it.

> **After `superpowers:brainstorming` returns, IMMEDIATELY continue to the overview update and Post-Brainstorm Enrichment section below -- do NOT write a summary message or yield to the user.**

**Investigation mode (when `MODE` is `"investigation"`, read from overview.md frontmatter: `n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "mode"`):**

In step mode, the autonomous brainstormer is already used (routing above). In full pipeline mode, the autonomous brainstormer is used instead of `superpowers:brainstorming` (routing above). In both cases, override the brainstorming focus:
- Pass to brainstorming (or autonomous brainstormer): "This is an investigation task -- explore the question and research findings, not implementation approaches. Focus on validating or challenging the analysis findings, exploring alternative explanations, and identifying gaps in the investigation. The output should be research-focused, not design-focused."
- The brainstorm output goes to `$N1_HOME/memory/<ID>/brainstorm.md` as usual.
- **Skip Post-Brainstorm Enrichment** (Phase 2) entirely -- investigation tasks don't refine acceptance criteria.

After brainstorming completes (the design already lives in `$N1_HOME/memory/<ID>/brainstorm.md` per the override above):
- Update overview: `[x] Brainstorm`, set `step: brainstorm`
- Record key decisions in overview's `## Key Decisions` section

### Post-Brainstorm Enrichment (Phase 2)

**Gate:** Run ONLY when ALL conditions are met:
1. A tracker ticket ID exists (ticket mode, OR brain-dump/file/error-tracker mode where the user created a ticket)
2. `ticketEnrichment.enabled !== false` (from config; default true when block is absent)
3. `tracker.operations.editTicket` exists
4. `tracker.operations.addComment` exists

If any condition fails, skip silently and proceed to Complexity Decision.

**Process:**

1. Read `brainstorm.md` — extract:
   - Refined acceptance criteria (more specific than what Phase 1 may have added)
   - Scope boundaries (in-scope / out-of-scope)
   - Design approach summary (1-2 sentences)
   - Key design decisions (bulleted list)

2. **Check whether brainstorming produced meaningful refinements.** Compare the brainstorm output against `ticket.md`'s acceptance criteria. If the brainstorm AC are substantively identical to what's already in the ticket (Phase 1 enrichment or original), skip the description update. Always post the comment (the design summary is new information regardless).

3. **Update description** (append) — only if refinements exist:
   - First, fetch the current description from the tracker: call `mcp__<tracker.mcp>__<tracker.operations.readTicket>` with the ticket ID to get the latest description (it may have been modified by Phase 1 or manually since).
   - Construct append content:
     ```
     ---
     *Refined after design review — N1*

     ### Refined Acceptance Criteria
     - [ ] <refined criterion — more specific than earlier>

     ### Scope Boundaries
     - In scope: <what's included>
     - Out of scope: <what's explicitly excluded>
     ```
     Only include sections that add new information. If brainstorming didn't refine AC, omit that section. If no scope boundaries were discussed, omit that section. If BOTH would be omitted, skip the description update entirely.
   - Idempotency: if the current description already contains `*Refined after design review — N1*`, skip the description update (already applied in a prior run).
   - Call `mcp__<tracker.mcp>__<tracker.operations.editTicket>`. Use exactly `mcp__<tracker.mcp>__` as the tool prefix — the value from config, not from the tool list.
     - If `tracker.type == "jira"`: with `cloudId` (resolve via `mcp__<tracker.mcp>__getAccessibleAtlassianResources` if not cached), `issueIdOrKey`: `<ticketId>`, `description`: `<current description>\n\n<append content>`
     - Else (`tracker.type == "youtrack"`): with `issueId`: `<ticketId>`, `description`: `<current description>\n\n<append content>`
   - If the MCP call fails: log "⚠ Post-brainstorm description update failed: <reason>" and continue — non-blocking.

4. **Post design summary comment:**
   - Construct comment:
     ```
     **Design Summary (N1)**

     Approach: <1-2 sentence summary of chosen approach from brainstorm>
     Key decisions:
     - <decision 1>
     - <decision 2>

     Design doc: internal (per-ticket memory)
     ```
   - Call `mcp__<tracker.mcp>__<tracker.operations.addComment>`. Use exactly `mcp__<tracker.mcp>__` as the tool prefix — the value from config, not from the tool list.
     - If `tracker.type == "jira"`: with `cloudId`, `issueIdOrKey`: `<ticketId>`, `body`: `<comment text>`
     - Else (`tracker.type == "youtrack"`): with `issueId`: `<ticketId>`, `text`: `<comment text>`
   - If the MCP call fails: log "⚠ Design summary comment failed: <reason>" and continue — non-blocking.

5. Log: "Tracker updated with refined requirements and design summary." (or "Tracker enrichment skipped." if gated out)


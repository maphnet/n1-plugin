
**Conditional routing based on execution mode:**

**Step mode** (`--step brainstorm`): Use the autonomous brainstormer defined in `autonomous-brainstorm.md` (in this skill's directory). This skill runs without any interactive channel — it generates approaches, scores them, and either selects autonomously or writes an escalation request for n1-loop to mediate.

**Full pipeline + investigation mode** (no `--step` flag, AND `TYPE == "investigation"` from overview.md frontmatter): Use the autonomous brainstormer defined in `autonomous-brainstorm.md` (in this skill's directory). Pass the investigation focus override (see Investigation mode section below). After the autonomous brainstormer returns, skip the `REQUIRED SUB-SKILL` block below and proceed directly to the overview update and Post-Brainstorm Enrichment gate.

**Full pipeline + non-investigation mode** (no `--step` flag, normal task): Use the interactive brainstormer:

Read the test coverage tier from config:
```bash
TEST_TIER=$(n1_config_val '.testCoverage.tier' 2>/dev/null)
TEST_TIER="${TEST_TIER:-maintain}"
```

**REQUIRED SUB-SKILL:** Use superpowers:brainstorming to explore the scope and refine the approach.

Pass to brainstorming:
- The content of `ticket.md` as the idea to explore
- The content of `analysis.md` as **pre-researched codebase context** — tell brainstorming: "Here is a codebase analysis already performed by our solution architect — use this as your starting context instead of exploring from scratch."
- **If ticket type is `bug`:** Also tell brainstorming: "This is a bug. The analysis includes a Bug Investigation section with the likely root cause and affected code path. Use these findings to ask informed questions about the fix approach rather than generic questions."
- **Project testing policy:** "testCoverage.tier is `{TEST_TIER}` (substitute the actual value). QA behavior by tier: `maintain` = fix broken existing tests only, no new tests added; `minimal` = up to 3 focused behavioral tests per feature for acceptance criteria only; `standard` = edge cases and error paths included. When designing the Testing section, default your proposals to match this tier. Only propose new tests if this specific change introduces risk that existing coverage does not address and the risk clearly justifies an exception to the project's testing policy."

**Brainstorming overrides (IMPORTANT):**
- **Spec location:** Write the design doc directly to `$N1_HOME/memory/<ID>/brainstorm.md` — NOT to `docs/superpowers/specs/`. The brainstorming skill honors "user preferences for spec location override this default," so this is the sanctioned location override.
- **Do NOT commit the spec.** `$N1_HOME/` is N1's ephemeral state directory — N1 owns this content in per-ticket memory. No spec artifact may be committed to the target repo.
- **Skip the User Review Gate.** The brainstorming skill's checklist has a "User reviews written spec" step that asks the user to re-approve the spec after it is written to disk. Skip it — the design was already approved conversationally (step 5), and `brainstorm.md` is an ephemeral memory file, not a committed artifact. Writing it is a recording step, not a review step. After the spec self-review passes, hand control back to the N1 orchestrator immediately.
- **Stop after the design; do NOT auto-invoke `writing-plans`.** SP 5.1 brainstorming treats "invoke writing-plans" as its terminal state ("the ONLY skill you invoke after brainstorming is writing-plans"). Override this: once the design is written to `brainstorm.md` and approved, hand control back to the N1 orchestrator. N1 runs its own Planning Need Routing and then invokes `writing-plans` itself with the overrides in Step 4. If brainstorming auto-chained into `writing-plans` directly, the plan would be produced WITHOUT N1's location and execution-handoff overrides — writing to `docs/superpowers/plans/` and offering execution options. Do not let it.

> **After `superpowers:brainstorming` returns, IMMEDIATELY continue to the overview update and Post-Brainstorm Enrichment section below -- do NOT write a summary message or yield to the user.**

**Investigation mode (when `TYPE` is `"investigation"`, read from overview.md frontmatter via `n1_read_type "$N1_HOME/memory/$ID/overview.md"`):**

In step mode, the autonomous brainstormer is already used (routing above). In full pipeline mode, the autonomous brainstormer is used instead of `superpowers:brainstorming` (routing above). In both cases, override the brainstorming focus:
- Pass to brainstorming (or autonomous brainstormer): "This is an investigation task -- explore the question and research findings, not implementation approaches. Focus on validating or challenging the analysis findings, exploring alternative explanations, and identifying gaps in the investigation. The output should be research-focused, not design-focused."
- The brainstorm output goes to `$N1_HOME/memory/<ID>/brainstorm.md` as usual.
- **Skip Post-Brainstorm Enrichment** (Phase 2) entirely -- investigation tasks don't refine acceptance criteria.

After brainstorming completes (the design already lives in `$N1_HOME/memory/<ID>/brainstorm.md` per the override above):
- Update overview: `[x] Brainstorm`, set `step: brainstorm`
- Record key decisions in overview's `## Key Decisions` section

### Planning Need Evaluation

Evaluate whether the brainstorm output is sufficient for direct implementation, or whether a formal plan is needed. The brainstorm content and `analysis.md` are already in your context — do not re-read them.

**Route `direct` when ALL hold:**
1. **Changes are specified** — the brainstorm names the files and describes what changes in each
2. **Changes are independent** — no ordering constraints between files; editing file A doesn't change what's needed in file B
3. **No remaining design decisions** — the approach is fully resolved; the implementer makes no architectural calls
4. **No test strategy needed** — changes don't require new tests or a validation approach beyond what QA does naturally

**Route `plan` when ANY hold:**
1. **Coordination required** — changes interact across files/components, ordering matters, or there are dependencies to sequence
2. **Open questions remain** — the brainstorm flagged uncertainties or the approach has decision points the implementer will face
3. **New abstractions introduced** — the design creates new interfaces, modules, or patterns needing specification beyond the brainstorm
4. **Non-trivial test/migration strategy** — changes need a test plan, data migration path, or rollback approach

**Safety guard (always `plan`):** If `analysis.md` flags security concerns, public API changes, or cross-cutting architectural impact, route to `plan` regardless of design clarity.

**Uncertainty default:** When uncertain, prefer `plan` — plan-review is cheap insurance.

State your evaluation: "Planning need: [plan/direct] because [one-line reason]."

Record the `planning_need` value (`plan` or `direct`) for use in the step result. The orchestrator uses this to route — it does NOT perform its own complexity judgment.

**Persist to overview.md frontmatter** so the implementation step can read it back:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "planning_need" "$PLANNING_NEED"
```

This write happens in both full-pipeline and step mode — the Planning Need Evaluation section is shared by both paths.

**Persist brainstorm signals:**
After `planning_need` is determined, assess and persist signals:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
if [ "$PLANNING_NEED" = "direct" ]; then
    DESIGN_CLARITY="high"
else
    DESIGN_CLARITY="medium"
fi
APPROACH_COUNT=$(grep -c -iE '^#{2,3}\s*(approach|option)\s' "$N1_HOME/memory/$ID/brainstorm.md" 2>/dev/null || echo "1")
n1_write_signals "$N1_HOME/memory/$ID/brainstorm.md" "planning_need=$PLANNING_NEED" "design_clarity=$DESIGN_CLARITY" "approach_count=$APPROACH_COUNT"
```

**Compact brainstorm memory:**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/memory.sh"
n1_compact_memory "$N1_HOME/memory/$ID/brainstorm.md" "summary,design summary,key decisions,approach,acceptance criteria,testing"
```

### Post-Brainstorm Enrichment (Phase 2)

**Gate:** Run ONLY when ALL conditions are met:
1. A tracker ticket ID exists (ticket mode, OR brain-dump/file/error-tracker mode where the user created a ticket)
2. `ticketEnrichment.enabled !== false` (from config; default true when block is absent)
3. `tracker.operations.editTicket` exists
4. `tracker.operations.addComment` exists

If any condition fails, skip silently and proceed to Planning Need Routing.

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

**Step result (step mode):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type" 2>/dev/null || echo "")
PLANNING_NEED=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "planning_need" 2>/dev/null || echo "plan")
if [ "$TYPE" = "investigation" ]; then
    NEXT="investigation-deliverable"
elif [ "$PLANNING_NEED" = "direct" ]; then
    NEXT="implementation"
else
    NEXT="plan"
fi
n1_emit_step_result "brainstorm" "pass" "$NEXT" "null"
```

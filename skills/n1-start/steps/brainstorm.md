
**Conditional routing based on execution mode:**

**Step mode** (`--step brainstorm`): Use the autonomous brainstormer defined in `autonomous-brainstorm.md` (in this skill's directory). This skill runs without any interactive channel — it generates approaches, scores them, and either selects autonomously or writes an escalation request for n1-loop to mediate.

**Full pipeline + investigation mode** (no `--step` flag, AND `TYPE == "investigation"` from overview.md frontmatter): Use the autonomous brainstormer defined in `autonomous-brainstorm.md` (in this skill's directory). Pass the investigation focus override (see Investigation mode section below). After the autonomous brainstormer returns, skip the `REQUIRED SUB-SKILL` block below and proceed directly to the overview update and Post-Brainstorm Enrichment gate.

**Full pipeline + non-investigation mode** (no `--step` flag, normal task): route by autonomy config:

```bash
BRAINSTORM_MODE=$(n1_autonomy_val 'brainstorm')
```

Read the test coverage tier from config:
```bash
TEST_TIER=$(n1_config_val '.testCoverage.tier' 2>/dev/null)
TEST_TIER="${TEST_TIER:-maintain}"
```

Run SKILL.md § Rules Injection with `agent_name=solution-architect` (no `changed_files_source` — brainstorm runs before implementation; `CHANGED_FILES` will be empty). Capture result as `$RULES_BLOCK`.

- **`BRAINSTORM_MODE` == `auto`:** Use the autonomous brainstormer defined in `autonomous-brainstorm.md` in **interactive escalation mode** — tell it: "interactive escalation mode: you have a user-facing session; ask A-tier and inconclusive-dominance questions inline, one at a time; write [auto]/[asked] ledger rows per skills/n1-start/ledger.md." Also pass the test-coverage-tier directive and `$RULES_BLOCK` (same way the interactive path passes them). After it returns, skip the `REQUIRED SUB-SKILL` block below and proceed directly to the overview update and Planning Need Evaluation (Post-Brainstorm Enrichment still applies).
- **`BRAINSTORM_MODE` == `interactive` (default):** Use the interactive brainstormer:

**REQUIRED SUB-SKILL:** Use superpowers:brainstorming to explore the scope and refine the approach.

Pass to brainstorming:
- The content of `ticket.md` as the idea to explore
- The content of `analysis.md` as **pre-researched codebase context** — tell brainstorming: "Here is a codebase analysis already performed by our solution architect — use this as your starting context instead of exploring from scratch."
- **If ticket type is `bug`:** Also tell brainstorming: "This is a bug. The analysis includes a Bug Investigation section with the likely root cause and affected code path. Use these findings to ask informed questions about the fix approach rather than generic questions."
- **Project testing policy:** "testCoverage.tier is `{TEST_TIER}` (substitute the actual value). QA behavior by tier: `maintain` = fix broken existing tests only, no new tests added; `minimal` = up to 3 focused behavioral tests per feature for acceptance criteria only; `standard` = edge cases and error paths included. When designing the Testing section, default your proposals to match this tier. Only propose new tests if this specific change introduces risk that existing coverage does not address and the risk clearly justifies an exception to the project's testing policy."
- When `$RULES_BLOCK` is non-empty, append it verbatim to the brainstorming prompt after the other directives above.

<N1-OVERRIDE>
These overrides take precedence over superpowers:brainstorming's checklist and HARD-GATE for steps 5-9.
Steps 1-4 (explore context, clarifying questions, propose approaches) run normally.

Step 5 (Present design): Present the recommended approach as the chosen design in a single cohesive section.
Do NOT ask for section-by-section approval or wait for explicit user confirmation before proceeding.
State the design, then move directly to writing the spec. If the user objects before you finish writing,
stop and address their feedback — this override removes the mandatory gate, not the user's ability to intervene.

Step 6 (Write design doc): Write to `$N1_HOME/memory/<ID>/brainstorm.md` (passed by the orchestrator).
Do NOT write to docs/superpowers/specs/. Do NOT git-commit the spec.

Step 7 (Spec self-review): Run normally (placeholder scan, consistency, scope, ambiguity).

Step 8 (User reviews written spec): SKIP entirely. The design was already presented in step 5,
and brainstorm.md is an ephemeral N1 memory file, not a committed artifact.

Step 9 (Transition to implementation): Do NOT invoke writing-plans or any other skill.
Return control to the N1 orchestrator immediately after step 7 completes.

Output discipline: After the brainstorming sub-skill returns, do NOT write a summary message
or yield to the user. The orchestrator continues to the next pipeline section immediately.
</N1-OVERRIDE>

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
```

**Reassess scope signals from the finalized design:**
The brainstorm design names specific files and describes the change scope. Re-derive `files_changed` and `blast_radius` from the design output — these supersede the analysis estimates when brainstorming narrows (or widens) scope.

```bash
# Count files explicitly named in the design's file list / change description.
# Look for file paths (containing / or ending in common extensions) in the brainstorm doc.
BRAINSTORM_FILES=$(grep -oE '[a-zA-Z0-9_/.-]+\.(py|ts|tsx|js|jsx|go|rs|java|rb|sh|sql|yaml|yml|json|toml|md|css|html)' "$N1_HOME/memory/$ID/brainstorm.md" 2>/dev/null | sort -u | wc -l)
BRAINSTORM_FILES=$((BRAINSTORM_FILES > 0 ? BRAINSTORM_FILES : 1))

# Reassess blast radius based on the design's file count and scope.
ANALYSIS_BLAST=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "blast_radius")
if [ "$BRAINSTORM_FILES" -le 2 ]; then
    BRAINSTORM_BLAST="low"
elif [ "$BRAINSTORM_FILES" -le 5 ]; then
    BRAINSTORM_BLAST="${ANALYSIS_BLAST:-medium}"
else
    BRAINSTORM_BLAST="${ANALYSIS_BLAST:-high}"
fi

n1_write_signals "$N1_HOME/memory/$ID/brainstorm.md" "planning_need=$PLANNING_NEED" "design_clarity=$DESIGN_CLARITY" "approach_count=$APPROACH_COUNT" "files_changed=$BRAINSTORM_FILES" "blast_radius=$BRAINSTORM_BLAST"
```

**Compact brainstorm memory:**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/memory.sh"
n1_compact_memory "$N1_HOME/memory/$ID/brainstorm.md" "summary,design summary,key decisions,approach,acceptance criteria,testing"
```

### Post-Brainstorm Enrichment (Phase 2)

**MCP routing:** Use the tracker MCP prefix from session context (`mcp__<tracker.mcp>__`) for all tracker calls in this section — do not repeat or restate it per call.

**Gate (skip silently if any fails):** Tracker ticket ID exists; `ticketEnrichment.enabled !== false` (default true); `tracker.operations.editTicket` and `.addComment` exist.

**Process:**

1. Read `brainstorm.md` — extract refined AC, scope boundaries (in/out-of-scope), approach summary (1-2 sentences), and key decisions.

2. **Check for meaningful refinements.** If brainstorm AC are substantively identical to `ticket.md`'s AC (Phase 1 or original), skip the description update. Always post the comment (design summary is always new information).

3. **Update description** (append) — only if refinements exist:
   - First, fetch the current description: call `readTicket` via tracker MCP routing with the ticket ID (it may have been modified by Phase 1 or manually since).
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
     Omit sections that add no new information; if both would be omitted, skip the update entirely.
   - Idempotency: if the current description already contains `*Refined after design review — N1*`, skip the description update (already applied in a prior run).
   - Call `editTicket` via tracker MCP routing (Jira: `issueIdOrKey`, `description`, `cloudId` from `tracker.cloudId` in config or resolve via `getAccessibleAtlassianResources` if absent; YouTrack: `issueId`, `description`).
   - On failure: log "⚠ Post-brainstorm description update failed: <reason>" and continue — non-blocking.

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
   - Call `addComment` via tracker MCP routing (Jira: `issueIdOrKey`, `body`, `cloudId` from `tracker.cloudId` in config or resolve via `getAccessibleAtlassianResources` if absent; YouTrack: `issueId`, `text`).
   - On failure: log "⚠ Design summary comment failed: <reason>" and continue — non-blocking.

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
n1_emit_step_result "brainstorm" "pass" "$NEXT" "null" "" "$N1_HOME/memory/$ID"
```

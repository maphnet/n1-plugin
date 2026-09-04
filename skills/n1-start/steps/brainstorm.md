
**Telemetry (if enabled):** Emit `started_at` for step 3 (`brainstorm`) before any routing or agent spawning:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "brainstorm" 3 "${N1_HOME}/memory/$ID/telemetry" started_at=now
```

**Conditional routing:**

**Investigation mode** (`TYPE == "investigation"` from overview.md frontmatter): route by `BRAINSTORM_MODE`, with one override — if overview.md frontmatter has `investigate_interactive: true` (set by the `--investigate` flag), force `BRAINSTORM_MODE=interactive` for this run:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
INVESTIGATE_INTERACTIVE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "investigate_interactive")
BRAINSTORM_MODE=$(n1_autonomy_val 'brainstorm')
if [ "$INVESTIGATE_INTERACTIVE" = "true" ]; then
    BRAINSTORM_MODE=interactive
fi
```

- **`BRAINSTORM_MODE` == `auto`:** Spawn a subagent to run the autonomous brainstormer. The subagent absorbs the brainstormer's turn boundary — when the Agent tool returns, the orchestrator sees a clean result and continues.

  Spawn via Agent tool with `subagent_type: "n1:solution-architect"` (the SA has Read/Grep/Glob/Bash/WebSearch — everything the autonomous brainstormer needs). Prompt the subagent:

  "You are the autonomous brainstormer. Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/autonomous-brainstorm.md` exactly. Inputs: `$N1_HOME/memory/$ID/ticket.md`, `$N1_HOME/memory/$ID/analysis.md`. Output: write the design to `$N1_HOME/memory/$ID/brainstorm.md`. Investigation focus: this is an investigation task — explore the question and research findings, not implementation approaches. Focus on validating or challenging the analysis findings, exploring alternative explanations, and identifying gaps in the investigation. The output should be research-focused, not design-focused. After writing brainstorm.md, report back: the `planning_need` value (plan or direct) and, if scope changed materially, an updated `context:` block."

  Pass the test-coverage-tier directive and `$RULES_BLOCK` if applicable.

  After the subagent returns, skip the `REQUIRED SUB-SKILL` block below and proceed directly to the overview update (Post-Brainstorm Enrichment stays skipped for investigation).
- **`BRAINSTORM_MODE` == `interactive`:** Use the interactive brainstormer (`REQUIRED SUB-SKILL: superpowers:brainstorming`) exactly as in the non-investigation interactive path below — including the N1-OVERRIDE block — but ADD the investigation focus override (see Investigation mode section below) to the brainstorming prompt, and SKIP the bug directive and the test-coverage-tier directive (investigation output is research, not a design with a Testing section). Post-Brainstorm Enrichment stays skipped for investigation.

**Non-investigation mode** (normal task): route by autonomy config:

```bash
BRAINSTORM_MODE=$(n1_autonomy_val 'brainstorm')
```

Read the test coverage tier from config:
```bash
TEST_TIER=$(n1_config_val '.testCoverage.tier' 2>/dev/null)
TEST_TIER="${TEST_TIER:-maintain}"
```

Run SKILL.md § Rules Injection with `agent_name=solution-architect` (no `changed_files_source` — brainstorm runs before implementation; `CHANGED_FILES` will be empty). Capture result as `$RULES_BLOCK`.

- **`BRAINSTORM_MODE` == `auto`:** Spawn a subagent to run the autonomous brainstormer. The subagent absorbs the brainstormer's turn boundary — when the Agent tool returns, the orchestrator sees a clean result and continues. This replaces the prior in-context skill-fragment approach that intermittently caused the orchestrator to stop after brainstorming completed.

  Spawn via Agent tool with `subagent_type: "n1:solution-architect"` (the SA has Read/Grep/Glob/Bash/WebSearch — everything the autonomous brainstormer needs). Prompt the subagent:

  "You are the autonomous brainstormer. Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/autonomous-brainstorm.md` exactly. Inputs: `$N1_HOME/memory/$ID/ticket.md`, `$N1_HOME/memory/$ID/analysis.md`. Output: write the design to `$N1_HOME/memory/$ID/brainstorm.md`. Batch ALL A-tier and inconclusive-dominance questions into ONE message (do not ask one at a time); write [auto]/[asked] ledger rows per `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/ledger.md`; if all A-tier questions are resolved, mark none as deferred. testCoverage.tier is `{TEST_TIER}`. After writing brainstorm.md, report back: the `planning_need` value (plan or direct) and, if scope changed materially, an updated `context:` block."

  When `$RULES_BLOCK` is non-empty, append it to the subagent prompt.

  After the subagent returns, skip the `REQUIRED SUB-SKILL` block below and proceed directly to the overview update and Planning Need Evaluation (Post-Brainstorm Enrichment still applies).
- **`BRAINSTORM_MODE` == `interactive` (default):** Use the interactive brainstormer:

**REQUIRED SUB-SKILL:** Use superpowers:brainstorming to explore the scope and refine the approach.

Pass to brainstorming:
- The content of `ticket.md` as the idea to explore
- The content of `analysis.md` as **pre-researched codebase context** — tell brainstorming: "Here is a codebase analysis already performed by our solution architect. It REPLACES your Step 1 (explore context) — treat it as complete. Do not open project source files to re-verify it."
- **If ticket type is `bug`:** Also tell brainstorming: "This is a bug. The analysis includes a Bug Investigation section with the likely root cause and affected code path. Use these findings to ask informed questions about the fix approach rather than generic questions."
- **Project testing policy:** "testCoverage.tier is `{TEST_TIER}` (substitute the actual value). QA behavior by tier: `maintain` = fix broken existing tests only, no new tests added; `minimal` = up to 3 focused behavioral tests per feature for acceptance criteria only; `standard` = edge cases and error paths included. When designing the Testing section, default your proposals to match this tier. Only propose new tests if this specific change introduces risk that existing coverage does not address and the risk clearly justifies an exception to the project's testing policy."
- When `$RULES_BLOCK` is non-empty, append it verbatim to the brainstorming prompt after the other directives above.

<N1-OVERRIDE>
These overrides take precedence over superpowers:brainstorming's checklist AND its HARD-GATE for steps 5-9.
The HARD-GATE ("Do NOT invoke any implementation skill... until the user has approved") is SUSPENDED inside this N1 pipeline — user approval is NOT required to proceed past brainstorming. Steps 1-4 (explore context, clarifying questions, propose approaches) run normally.

**ORCHESTRATOR GUARDRAIL (brainstorm): do NOT Read, Grep, Glob, `cat`, `sed -n`, or otherwise open project source files in this step — Step 1 is satisfied by `analysis.md`.** If a design question needs a fact that `analysis.md` lacks (how a name is generated, which script owns cleanup, what a template contains), re-spawn `solution-architect` with that specific question ("Answer only: <question>. Return file:line evidence, ≤200 words.") and feed the answer into the conversation. Reading `$N1_HOME/**` memory files and `rules/` is fine.

Step 5 (Present design): Present the recommended approach as the chosen design in a single cohesive section.
Do NOT ask for user approval, confirmation, or "proceed" prompts. Do NOT end with "let me know if you'd like changes" or similar.
State the design, then move directly to writing the spec without pausing. If the user objects before you finish writing,
stop and address their feedback — this override removes the mandatory gate, not the user's ability to intervene.

Step 6 (Write design doc): Write to `$N1_HOME/memory/<ID>/brainstorm.md` (passed by the orchestrator).
Do NOT write to docs/superpowers/specs/. Do NOT git-commit the spec.

Step 7 (Spec self-review): Run normally (placeholder scan, consistency, scope, ambiguity).

Step 8 (User reviews written spec): SKIP entirely. The design was already presented in step 5,
and brainstorm.md is an ephemeral N1 memory file, not a committed artifact.

Step 9 (Post-brainstorm continuation): Do NOT invoke writing-plans or any other skill.
After step 7 completes, IMMEDIATELY execute these post-brainstorm procedures
(they are part of the brainstorm step, not a handoff):

1. Update overview.md: mark `[x] Brainstorm` checkbox, set `step: brainstorm` in frontmatter:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
   n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "step" "brainstorm"
   ```
2. Record key decisions from the design in overview.md's `## Key Decisions` section
3. State: "Brainstorm step complete. Proceeding to user gate."

Do NOT stop, pause, ask for confirmation, or say "returning control" between step 7
and these updates. Execute them immediately as the final part of the brainstorm skill.
</N1-OVERRIDE>

**Investigation mode (when `TYPE` is `"investigation"`, read from overview.md frontmatter via `n1_read_type "$N1_HOME/memory/$ID/overview.md"`):**

Routing follows `BRAINSTORM_MODE` (`--investigate` forces `interactive`; see routing above). In all cases, override the brainstorming focus:
- Pass to brainstorming (or autonomous brainstormer): "This is an investigation task -- explore the question and research findings, not implementation approaches. Focus on validating or challenging the analysis findings, exploring alternative explanations, and identifying gaps in the investigation. The output should be research-focused, not design-focused."
- The brainstorm output goes to `$N1_HOME/memory/<ID>/brainstorm.md` as usual.
- **Skip Post-Brainstorm Enrichment** (Phase 2) entirely -- investigation tasks don't refine acceptance criteria.
- **ORCHESTRATOR GUARDRAIL (experiments):** if, during brainstorming, the user asks to run something (local test, docker build, benchmark, curl, script), do not run it in this session — spawn `developer` in experiment mode as described in `investigation-deliverable.md` and bring back its summary.

After brainstorming completes (the design already lives in `$N1_HOME/memory/<ID>/brainstorm.md` per the override above):

**Context scope-change update:**

**Autonomous path:** Parse the brainstormer's output for a `context:` block (same parsing as the analysis step):
```bash
UPDATED_CONTEXT=$(echo "$BRAINSTORM_OUTPUT" | sed -n '/^context: |$/,/^[^ ]/{/^context: |$/d;/^[^ ]/d;s/^  //;p}')
```

**Interactive path:** The Superpowers brainstorming skill is not modified. After the interactive session completes, the orchestrator evaluates whether scope changed materially by comparing the design in `brainstorm.md` against the existing `## Context` in overview.md. If the brainstorm chose a fundamentally different approach or redefined the problem, the orchestrator generates an updated context block itself (it has brainstorm.md + ticket.md + analysis.md available). If the design refines without redefining, no update.

**Both paths — if updated context is available:**
1. Replace the `## Context` section in overview.md:
   - Read overview.md
   - Replace content between `## Context` and the next `## ` heading with the updated text
   - Write overview.md back
2. Reprint the orientation block with a scope-updated header:
   ```
   ── <ID> (scope updated) ──────────────────────
   <TITLE>

   <UPDATED_CONTEXT>

   Tier: <TIER> · Files: ~<FILES_CHANGED> · Blast radius: <BLAST_RADIUS>
   <TICKET_URL — omit if empty>
   ─────────────────────────────────────────────────
   ```

If no updated context: no action — the original context stands.

- Update overview: `[x] Brainstorm`, set `step: brainstorm`
- Record key decisions in overview's `## Key Decisions` section

### User Gate

**Applies when:** `BRAINSTORM_MODE` is `interactive` or `auto`.

**Skip when:** investigation mode.

Present the design checkpoint to the user. Before presenting, extract two pieces of context:

1. **Acceptance criteria** — read `$N1_HOME/memory/<ID>/brainstorm.md` and extract the acceptance criteria (look for a section headed `## Acceptance Criteria`, `### Acceptance Criteria`, or a checklist under any heading containing "acceptance" or "criteria"). If no such section exists, note that no explicit acceptance criteria were found.

2. **Input quality signal** — read the `description_quality` signal from `$N1_HOME/memory/<ID>/ticket.md`:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
   DESC_QUALITY=$(n1_read_signal "$N1_HOME/memory/$ID/ticket.md" "description_quality")
   ```
   If the file is missing or the signal is absent, treat quality as unknown.

Present the checkpoint:

> Brainstorm complete — design saved to `brainstorm.md`.
>
> **Acceptance Criteria:**
> - [ ] <first criterion from brainstorm.md>
> - [ ] <second criterion>
> - [ ] ...
>
> **Scope:** <key files or areas identified in the brainstorm>
>
> Confirm these are correct, amend, or add what's missing.

**Conditional warning:** If `DESC_QUALITY` is `empty` or `skeletal`, insert before the confirm line:

> **Note:** input was terse — criteria above are inferred, not stated. Please verify carefully.

If no acceptance criteria section was found in `brainstorm.md`, replace the criteria list with:

> No explicit acceptance criteria found in the brainstorm. Consider adding criteria before proceeding.

**Acceptance gate routing:**

```bash
ACCEPTANCE_GATE=$(n1_autonomy_val 'acceptanceGate')
```

If `ACCEPTANCE_GATE` is `auto`: auto-confirm unconditionally without waiting for user input. Present the checkpoint info (acceptance criteria, scope) for visibility, then continue directly to Planning Need Evaluation. The user can still intervene if they see something wrong, but no explicit confirmation is requested.

If `ACCEPTANCE_GATE` is `auto-when-clear`, check ALL of the following conditions:
1. `DESC_QUALITY` is `adequate` (not `empty`, `skeletal`, `weak`, or unknown)
2. Acceptance criteria section exists in `brainstorm.md`
3. The autonomous brainstormer reported no deferred A-tier questions (no ledger rows with `[deferred]` for this brainstorm run)
4. `BRAINSTORM_MODE` is `auto`

If ALL four conditions hold: auto-confirm without waiting for user input. Append a Decision Ledger row to `$N1_HOME/memory/$ID/overview.md`:

`| brainstorm | acceptance | A | [auto] | description_quality=adequate, AC present, no deferred A-tier questions | Auto-confirm design and proceed | Wait for user | acceptanceGate=auto-when-clear; all clarity conditions met |`

Then continue directly to Planning Need Evaluation.

If ANY condition fails: fall through to the interactive gate below.

**Wait for the user's response.** If they amend or add criteria, update the `## Acceptance Criteria` section in `brainstorm.md` to match, then re-present the gate. Only continue to Planning Need Evaluation after the user confirms.

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

Record the `planning_need` value (`plan` or `direct`). The orchestrator uses this to route — it does NOT perform its own complexity judgment.

**Persist to overview.md frontmatter** so the implementation step can read it back:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "planning_need" "$PLANNING_NEED"
```

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
   - Construct append content. **Jira formatting:** If `tracker.type == "jira"`, use plain bullets (`- criterion`) instead of checkbox syntax (`- [ ] criterion`) — Jira silently strips the brackets:
     ```
     ---
     *Refined after design review — N1*

     ### Refined Acceptance Criteria
     - [ ] <refined criterion — more specific than earlier>  ← YouTrack
     - <refined criterion — more specific than earlier>      ← Jira

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

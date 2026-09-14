<!-- n1:step-snippet-exception: agent-dispatch boundaries across brainstorm mode routing and user gate -->

> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user.**

**Telemetry:** emit `started_at` for step 3 (`brainstorm`):
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "brainstorm" 3 "${N1_HOME}/memory/$ID/telemetry" started_at=now
```

**Conditional routing:**

**Investigation mode** (`TYPE=="investigation"` from overview.md frontmatter): route by `BRAINSTORM_MODE`; if `investigate_interactive: true` in frontmatter, force `BRAINSTORM_MODE=interactive`.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
INVESTIGATE_INTERACTIVE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "investigate_interactive")
BRAINSTORM_MODE=$(n1_autonomy_val 'brainstorm')
if [ "$INVESTIGATE_INTERACTIVE" = "true" ]; then
    BRAINSTORM_MODE=interactive
fi
```

Investigation auto path: dispatch `solution-architect` with prompt: "You are the autonomous brainstormer. Read `<N1_ROOT>/skills/n1-start/autonomous-brainstorm.md`. Inputs: ticket.md, analysis.md. Output: write design to `$N1_HOME/memory/$ID/brainstorm.md`. Investigation focus: explore the question and research findings, not implementation approaches — validate/challenge analysis findings, explore alternative explanations, identify gaps. After writing brainstorm.md, report: `planning_need` value and updated `context:` block if scope changed." After return: skip REQUIRED SUB-SKILL below; proceed to overview update. Post-Brainstorm Enrichment stays skipped.

Investigation interactive path: use REQUIRED SUB-SKILL (`brainstorming`) as in non-investigation interactive path below, adding investigation focus override; skip bug directive and test-coverage-tier directive. Post-Brainstorm Enrichment stays skipped.

**Non-investigation mode** (normal task): route by autonomy:
```bash
BRAINSTORM_MODE=$(n1_autonomy_val 'brainstorm')
```

Read test coverage tier:
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
TEST_TIER=$(n1_config_val '.testCoverage.tier' 2>/dev/null)
TEST_TIER="${TEST_TIER:-maintain}"
```

Run `procedures/rules-injection.md` with `agent_name=solution-architect` (no `changed_files_source`). Capture as `$RULES_BLOCK`.

**`BRAINSTORM_MODE=auto`:** dispatch `solution-architect` with: "You are the autonomous brainstormer. Read `<N1_ROOT>/skills/n1-start/autonomous-brainstorm.md`. Inputs: ticket.md, analysis.md. Output: write to `$N1_HOME/memory/$ID/brainstorm.md`. Batch ALL A-tier and inconclusive questions into ONE message. For each A-tier question, include 'Decide for me — research and apply recommendation' option; when selected, apply without follow-up; record as [auto-decided]. testCoverage.tier={TEST_TIER}. Report back: `planning_need` and updated `context:` if scope changed." Append `$RULES_BLOCK` if non-empty. After return: skip REQUIRED SUB-SKILL below; proceed to overview update and Planning Need Evaluation.

**`BRAINSTORM_MODE=interactive` (default):** relay loop (cap: 2 rounds).

Round 1: dispatch `solution-architect` with:
- Invoke skill `brainstorming` against ticket.md + analysis.md
- Apply directives below for ticket type
- Bug directive: "This is a bug. Analysis has Bug Investigation section with root cause. Use findings to ask informed questions about fix approach."
- `testCoverage.tier is {TEST_TIER}` (maintain = fix broken tests only; minimal = ≤3 focused tests; standard = edge cases + error paths). Only propose new tests when risk clearly justifies exception to project policy.
- Append `$RULES_BLOCK` if non-empty
- "When a user question is needed: stop and return `QUESTIONS:` block — numbered, each with a recommended answer. No one-at-a-time. If no questions needed: write brainstorm.md and return compact block."

If subagent returns `QUESTIONS:` block: raise all in single user prompt (max 4; chain beyond 4). Accept "use recommended" as global answer. Round 2: dispatch again with original inputs + user answers; write brainstorm.md + compact return. No third round.

**Apply these directives to subagent regardless of mode:**

<N1-OVERRIDE>
These overrides take precedence over the brainstorming skill's checklist AND its HARD-GATE for steps 5-9. The HARD-GATE is SUSPENDED inside this N1 pipeline — user approval NOT required to proceed past brainstorming. Steps 1-4 run normally.

**ORCHESTRATOR GUARDRAIL (brainstorm): do NOT Read/Grep/Glob/cat project source files — Step 1 is satisfied by `analysis.md`.** If a design question needs a fact analysis.md lacks, re-spawn `solution-architect` with that specific question ("Answer only: <question>. Return file:line evidence, ≤200 words."). Reading `$N1_HOME/**` memory files and `rules/` is fine.

**Question batching:** present ALL clarifying questions in ONE message. Include recommended answer for each. Accept "use recommended" as global answer. Apply recommendations for selectively-answered questions.

Step 5: present recommended approach as chosen design in single cohesive section. No approval prompts. State design, then write spec without pausing.

Step 6: write to `$N1_HOME/memory/<ID>/brainstorm.md`. Do NOT write to docs/superpowers/specs/. Do NOT commit.

Step 7: run self-review normally (placeholder scan, consistency, scope, ambiguity).

Step 8: SKIP — brainstorm.md is ephemeral N1 memory, not a committed artifact.

Step 9: SKIP the "Post-brainstorm continuation" handoff. The orchestrator handles continuation.
</N1-OVERRIDE>

**Investigation mode focus override** (when `TYPE=="investigation"`): "This is an investigation task — explore the question and research findings, not implementation approaches. Focus on validating/challenging analysis findings, alternative explanations, gaps."

After brainstorming (design in `$N1_HOME/memory/<ID>/brainstorm.md`):

**Context scope-change update:**

Auto path: parse `context:` block:
```bash
UPDATED_CONTEXT=$(echo "$BRAINSTORM_OUTPUT" | sed -n '/^context: |$/,/^[^ ]/{/^context: |$/d;/^[^ ]/d;s/^  //;p}')
```

Interactive path: orchestrator evaluates whether scope changed materially by comparing brainstorm.md design against overview `## Context`. Generate updated context block if approach is fundamentally different; no update if design only refines.

Both paths — if updated context available:
1. Replace `## Context` section in overview.md (read → replace between `## Context` and next `## ` → write).
2. Reprint orientation block with `── <ID> (scope updated) ──` frame.

- Update overview: `[x] Brainstorm`, set `step: brainstorm`; record key decisions in `## Key Decisions`.

### User Gate

**Applies when:** `BRAINSTORM_MODE` is `interactive` or `auto`. **Skip when:** investigation mode.

Extract from brainstorm.md: acceptance criteria section (look for `## Acceptance Criteria`, `### Acceptance Criteria`, or checklist with "acceptance"/"criteria").

Read `description_quality` signal:
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
DESC_QUALITY=$(n1_read_signal "$N1_HOME/memory/$ID/ticket.md" "description_quality")
```

Present checkpoint:
> Brainstorm complete — design saved to `brainstorm.md`.
>
> **Acceptance Criteria:** [list from brainstorm.md, or "No explicit criteria found"]
> **Scope:** [key files/areas from brainstorm]
>
> [When DESC_QUALITY is `empty` or `skeletal`: **Note:** input was terse — criteria are inferred. Verify carefully.]
>
> Confirm these are correct, amend, or add what's missing.

**Acceptance gate routing:**
```bash
ACCEPTANCE_GATE=$(n1_autonomy_val 'acceptanceGate')
```

If `ACCEPTANCE_GATE=auto`: auto-confirm; present info for visibility; append ledger row `[auto]`; emit telemetry:
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "brainstorm" "design" "auto-decided" "---"
```

If `ACCEPTANCE_GATE=ask`: wait for user; emit:
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "brainstorm" "design" "asked" "codebase|web"
```

If user amends criteria: update `## Acceptance Criteria` in brainstorm.md, re-present gate. Only continue after confirmation.

**Headless:** under `N1_HEADLESS=1`, apply `procedures/autonomy-headless.md § Headless Guard`.

### Planning Need Evaluation

Route `direct` when ALL: changes specified (files + what changes), independent (no ordering constraints), no remaining design decisions, no test strategy needed.

Route `plan` when ANY: coordination required, open questions remain, new abstractions introduced, non-trivial test/migration strategy. Safety guard: always `plan` when security, public API, or cross-cutting architectural impact flagged. Uncertainty default: prefer `plan`.

State: "Planning need: [plan/direct] because [one-line reason]."

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "planning_need" "$PLANNING_NEED"
```

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
n1_record_decision planning-need-direct "$( [ "$PLANNING_NEED" = "direct" ] && echo true || echo false )" \
  '{"signal":"brainstorm.design_clarity","eq":"high"}' "planning_need=$PLANNING_NEED"
```

**Persist brainstorm signals:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
source "$N1_ROOT/lib/memory.sh"
if [ "$PLANNING_NEED" = "direct" ]; then DESIGN_CLARITY="high"; else DESIGN_CLARITY="medium"; fi
APPROACH_COUNT=$(grep -c -iE '^#{2,3}\s*(approach|option)\s' "$N1_HOME/memory/$ID/brainstorm.md" 2>/dev/null || echo "1")
BRAINSTORM_FILES=$(grep -oE '[a-zA-Z0-9_/.-]+\.(py|ts|tsx|js|jsx|go|rs|java|rb|sh|sql|yaml|yml|json|toml|md|css|html)' "$N1_HOME/memory/$ID/brainstorm.md" 2>/dev/null | sort -u | wc -l)
BRAINSTORM_FILES=$((BRAINSTORM_FILES > 0 ? BRAINSTORM_FILES : 1))
ANALYSIS_BLAST=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "blast_radius")
if [ "$BRAINSTORM_FILES" -le 2 ]; then BRAINSTORM_BLAST="low"
elif [ "$BRAINSTORM_FILES" -le 5 ]; then BRAINSTORM_BLAST="${ANALYSIS_BLAST:-medium}"
else BRAINSTORM_BLAST="${ANALYSIS_BLAST:-high}"; fi
n1_write_signals "$N1_HOME/memory/$ID/brainstorm.md" "planning_need=$PLANNING_NEED" "design_clarity=$DESIGN_CLARITY" "approach_count=$APPROACH_COUNT" "files_changed=$BRAINSTORM_FILES" "blast_radius=$BRAINSTORM_BLAST"
n1_compact_memory "$N1_HOME/memory/$ID/brainstorm.md" "summary,design summary,key decisions,approach,acceptance criteria,testing"
```

### Post-Brainstorm Enrichment (Phase 2)

**Gate** (skip silently if any fails): tracker ticket ID exists; `ticketEnrichment.enabled !== false`; `tracker.operations.editTicket` and `.addComment` exist.

1. Read brainstorm.md: extract refined AC, scope (in/out), approach summary (1-2 sentences), key decisions.
2. Skip description update if refined AC are substantively identical to ticket.md AC.
3. Update description (append, Jira: plain bullets; YouTrack: checkboxes):
   ```
   ---
   *Refined after design review — N1*

   ### Refined Acceptance Criteria / ### Scope Boundaries
   ```
   Idempotency: skip if `*Refined after design review — N1*` present. Call editTicket via tracker MCP.
4. Post design summary comment: `**Design Summary (N1)**\nApproach: <1-2 sentences>\nKey decisions:\n- ...\nDesign doc: internal`. Call addComment via tracker MCP. On failure: log warning, non-blocking.

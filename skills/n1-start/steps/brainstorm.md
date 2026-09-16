<!-- n1:step-snippet-exception: agent-dispatch boundaries across brainstorm mode routing and user gate -->

> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user.**

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "brainstorm" 3 "${N1_HOME}/memory/$ID/telemetry" started_at=now
INVESTIGATE_INTERACTIVE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "investigate_interactive")
BRAINSTORM_MODE=$(n1_autonomy_val 'brainstorm'); [ "$INVESTIGATE_INTERACTIVE" = "true" ] && BRAINSTORM_MODE=interactive
TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
TEST_TIER=$(n1_config_val '.testCoverage.tier' 2>/dev/null); TEST_TIER="${TEST_TIER:-maintain}"
# Ordinary analysis, autonomous, interactive, and missing-fact re-spawns have no
# Astra context. Dispatch the coherent model/effort pair together.
IFS=$'\t' read -r SA_MODEL SA_EFFORT < <(n1_resolve_agent solution-architect brainstorm)
```

Run `procedures/rules-injection.md`: `agent_name=solution-architect`.

**Investigation auto:** dispatch SA, autonomous brainstormer, investigation focus, write brainstorm.md, report `planning_need`.

**`BRAINSTORM_MODE=auto`:** dispatch SA — "Read `<N1_ROOT>/skills/n1-start/autonomous-brainstorm.md`. Inputs: ticket.md, analysis.md. Write `$N1_HOME/memory/$ID/brainstorm.md`. tier={TEST_TIER}. Batch A-tier questions ONE message 'Decide for me'. Report `planning_need`. Append `$RULES_BLOCK`."

**`BRAINSTORM_MODE=interactive`:** relay loop (cap 2 rounds). Dispatch SA: invoke `n1-brainstorm` against ticket.md+analysis.md. Single prompt max 4 questions. **GUARDRAIL:** do NOT Read/Grep/Glob project source files — `analysis.md` is sufficient; re-spawn SA for missing facts only. Round 2: inputs+answers; write `$N1_HOME/memory/<ID>/brainstorm.md`; do NOT commit.

### Architecture Adjudication (narrow exception)

Use this branch only when the prompt explicitly asks the solution architect to choose between at least two named designs **and** `analysis.md` identifies cross-cutting consequences in at least two components. Label the spawn prompt `Architecture adjudication`. Otherwise retain the ordinary no-third-argument resolution above, including routine analysis, missing-fact re-spawns, interactive brainstorming, and plan review.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
# Set either value to true only after reading the user prompt and analysis.md.
PROMPT_NAMES_TWO_DESIGNS=false
ANALYSIS_HAS_TWO_CROSS_CUTTING_COMPONENTS=false
if [ "$PROMPT_NAMES_TWO_DESIGNS" = true ] && [ "$ANALYSIS_HAS_TWO_CROSS_CUTTING_COMPONENTS" = true ]; then
    BRAINSTORM_ASTRA_CONTEXT=architecture-adjudication
    IFS=$'\t' read -r SA_MODEL SA_EFFORT < <(n1_resolve_agent solution-architect brainstorm "$BRAINSTORM_ASTRA_CONTEXT")
fi
```

Bug: use root cause findings. Investigation: explore question. Append `$RULES_BLOCK`.

After: parse `context:`; if updated replace `## Context` in overview.md. Update: `[x] Brainstorm`, `step: brainstorm`.

### User Gate

Skip when investigation mode. Read `DESC_QUALITY`. Present checkpoint: design saved, AC list, scope.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/memory.sh"
ACCEPTANCE_GATE=$(n1_autonomy_val 'acceptanceGate')
if [ "$ACCEPTANCE_GATE" = "auto" ]; then n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "brainstorm" "design" "auto-decided" "---"
else n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "brainstorm" "design" "asked" "codebase|web"; fi
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "planning_need" "$PLANNING_NEED"
n1_record_decision planning-need-direct "$( [ "$PLANNING_NEED" = "direct" ] && echo true || echo false )" '{"signal":"brainstorm.design_clarity","eq":"high"}' "planning_need=$PLANNING_NEED"
[ "$PLANNING_NEED" = "direct" ] && DESIGN_CLARITY="high" || DESIGN_CLARITY="medium"
APPROACH_COUNT=$(grep -c -iE '^#{2,3}\s*(approach|option)\s' "$N1_HOME/memory/$ID/brainstorm.md" 2>/dev/null || echo "1")
BRAINSTORM_FILES=$(grep -oE '[a-zA-Z0-9_/.-]+\.(py|ts|tsx|js|jsx|go|rs|java|rb|sh|sql|yaml|yml|json|toml|md|css|html)' "$N1_HOME/memory/$ID/brainstorm.md" 2>/dev/null | sort -u | wc -l); BRAINSTORM_FILES=$((BRAINSTORM_FILES > 0 ? BRAINSTORM_FILES : 1))
ANALYSIS_BLAST=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "blast_radius")
[ "$BRAINSTORM_FILES" -le 2 ] && BRAINSTORM_BLAST="low" || { [ "$BRAINSTORM_FILES" -le 5 ] && BRAINSTORM_BLAST="${ANALYSIS_BLAST:-medium}" || BRAINSTORM_BLAST="${ANALYSIS_BLAST:-high}"; }
n1_write_signals "$N1_HOME/memory/$ID/brainstorm.md" "planning_need=$PLANNING_NEED" "design_clarity=$DESIGN_CLARITY" "approach_count=$APPROACH_COUNT" "files_changed=$BRAINSTORM_FILES" "blast_radius=$BRAINSTORM_BLAST"
n1_compact_memory "$N1_HOME/memory/$ID/brainstorm.md" "summary,design summary,key decisions,approach,acceptance criteria,testing"
```
`auto`: auto-confirm, `[auto]` ledger. `ask`: wait; amend → update AC. **Headless:** `procedures/autonomy-headless.md § Headless Guard`.

`direct`: changes specified, independent, no design decisions, no test strategy. `plan`: coordination, open questions, new abstractions, security/API/cross-cutting. Default `plan`.

### Post-Brainstorm Enrichment

Gate: ticket ID + `ticketEnrichment.enabled!==false` + `editTicket` + `addComment`. Append refined AC/scope/approach (idempotent: skip if `*Refined after design review — N1*`). Post design summary comment. Non-blocking.

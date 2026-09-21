<!-- n1:step-snippet-exception: agent-dispatch boundaries across brainstorm mode routing and user gate -->

> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user.**

```bash
source "$N1_ROOT/lib/preamble.sh"
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "brainstorm" 3 "${N1_HOME}/memory/$ID/telemetry" started_at=now
INVESTIGATE_INTERACTIVE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "investigate_interactive")
BRAINSTORM_MODE=$(n1_autonomy_val 'brainstorm'); [ "$INVESTIGATE_INTERACTIVE" = "true" ] && BRAINSTORM_MODE=interactive
TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
TEST_TIER=$(n1_config_val '.testCoverage.tier' 2>/dev/null); TEST_TIER="${TEST_TIER:-maintain}"
# Ordinary analysis, autonomous, interactive, and missing-fact re-spawns have no
# Astra context. Dispatch the coherent model/effort pair together.
IFS=$'\t' read -r SA_MODEL SA_EFFORT < <(n1_resolve_agent solution-architect brainstorm)
HAS_INVESTIGATION=false; [ -s "$N1_HOME/memory/$ID/investigation.md" ] && HAS_INVESTIGATION=true
```

Run `procedures/rules-injection.md`: `agent_name=solution-architect`.

**`BRAINSTORM_MODE=auto`:** dispatch the **brainstormer** agent — Inputs: ticket.md, analysis.md{if HAS_INVESTIGATION: , investigation.md}. Write `$N1_HOME/memory/$ID/brainstorm.md`. tier={TEST_TIER}. Batch A-tier questions 'Decide for me'. Report `planning_need`. Append `$RULES_BLOCK`. **Investigation auto:** same, investigation focus.

**`BRAINSTORM_MODE=interactive`:** relay loop (cap 2 rounds). Dispatch SA: invoke `n1-brainstorm` against ticket.md+analysis.md{if HAS_INVESTIGATION: +investigation.md}. Single prompt max 4 questions. **ORCHESTRATOR GUARDRAIL (brainstorm): do NOT Read, Grep, Glob, `cat`, `sed -n`, or otherwise open project source files** — `analysis.md` is sufficient; re-spawn SA for missing facts only. Round 2: inputs+answers; write `$N1_HOME/memory/<ID>/brainstorm.md`; do NOT commit.

### Architecture Adjudication (narrow exception)

Only when prompt explicitly names ≥2 designs AND `analysis.md` shows cross-cutting consequences in ≥2 components. Set `BRAINSTORM_ASTRA_CONTEXT=architecture-adjudication` and re-resolve SA: `IFS=$'\t' read -r SA_MODEL SA_EFFORT < <(n1_resolve_agent solution-architect brainstorm "$BRAINSTORM_ASTRA_CONTEXT")`. All other cases (routine, missing-fact, interactive, plan review): no Astra context.

Bug: use root cause findings. Investigation: explore question. Append `$RULES_BLOCK`.
**ORCHESTRATOR GUARDRAIL (experiments):** do not run ad-hoc experiments, benchmarks, or probes inline — delegate to the developer or qa-engineer agent.

**Wait for the persona to return its result before proceeding. Do NOT read ahead to the next step or check for files until the agent tool call completes.**

After: parse `context:`; if updated replace `## Context` in overview.md. Update: `[x] Brainstorm`, `step: brainstorm`.

```bash
source "$N1_ROOT/lib/preamble.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" brainstorm.md || { echo "ERROR: brainstorm.md not written by SA — aborting" >&2; exit 1; }
```

### User Gate

Skip when investigation mode. Read `DESC_QUALITY`. Present checkpoint: design saved, AC list, scope.

```bash
source "$N1_ROOT/lib/preamble.sh"
source "$N1_ROOT/lib/memory.sh"
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

`direct`: specified+independent+no design+no test strategy. `plan`: coordination/open questions/new abstractions/security/API/cross-cutting. Default `plan`.

**Post-Brainstorm Enrichment:** ticket ID + `ticketEnrichment.enabled!==false` + `editTicket` + `addComment`. Append refined AC/scope/approach (idempotent if `*Refined after design review — N1*`). Post design summary. Non-blocking.

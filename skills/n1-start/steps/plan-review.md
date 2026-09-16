
Run `n1_config_val '.planReview.reviewPlan'` (default: `true`).

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/telemetry.sh"; source "$N1_ROOT/lib/validation.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" plan.md || { echo "ERROR: plan.md missing — cannot review plan" >&2; exit 1; }
GATE_ENABLED=$(n1_config_val '.planReview.reviewPlan' 2>/dev/null || echo 'true')
n1_record_decision plan-review-gate "$( [ "${GATE_ENABLED:-true}" = "true" ] && echo true || echo false )" '{"config":"planReview.reviewPlan"}' "enabled=${GATE_ENABLED:-true}"
```

> The gate key (`planReview.reviewPlan`) and its default (`true`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

**If `planReview.reviewPlan` is `false`:** skip to checkpoint logic below.

**If `planReview.reviewPlan` is `true`:**

**Spawn reviewer:**

#### Solution-architect CCR

**Spawn agent:** solution-architect (fresh context — CCR)

Resolve via `n1_resolve_agent solution-architect plan-review`, split tab-separated model/effort pair, pass both. No Astra context. Spawn with codebase access (Read, Grep, Glob); instruct: "Read these files before reviewing: ticket.md, analysis.md, brainstorm.md, plan.md (the plan — fix issues in-place). NOT generative — this is a review."

Review categories (find issues, fix in-place):
1. **Assumption validation** — Do referenced files, functions, APIs exist? Use Grep/Read.
2. **Scope drift** — Each task traces to a ticket requirement?
3. **Missing edge cases** — Failure modes, error paths, data states not addressed.
4. **Ordering/dependency risks** — Correct sequence? Hidden inter-task dependencies?
5. **Blast radius** — Minimal changes? Same result with fewer files?
6. **Standards validation** — Aligns with `analysis.md § Industry Standards`? Single targeted lookup per `agents/research-standards.md` only for uncovered standards; fitness gate; cite URLs. Skip lookup if web unavailable.

If issues: fix in-place, state changes. If clean: "Plan validated, no issues found."

Output: `## Plan Review Result` / `**Verdict:** CLEAN | FIXED` / `**Changes:**` / `**Verified assumptions:**` / `**Verified standards:**`

**Wait for the persona to return its result before proceeding. Do NOT read ahead to the step result or check plan.md until the agent tool call completes.**

#### After CCR returns:

- Record the CCR verdict: if verdict is FIXED, the plan file was updated in-place by the reviewer. Record the plan-review verdict and a one-line summary of changes in overview's `## Key Decisions` — durable traceability that survives a resume, rather than living only in transient orchestrator context.

**Step result (step mode):**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/validation.sh"
source "$N1_ROOT/lib/config.sh"
EST=$(n1_config_val '.estimation.enabled')
if [ "${EST:-false}" = "true" ]; then
    NEXT="estimation"
else
    NEXT="implementation"
fi
n1_emit_step_result "plan-review" "pass" "$NEXT" "null"
```

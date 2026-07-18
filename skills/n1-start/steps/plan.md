
The single Step-2 `analysis.md` (broad codebase analysis with its one research round) plus `brainstorm.md` feed planning directly. File-level discovery ("which files change / patterns to follow / integration risks") is done natively by the `planner` during `writing-plans` (it carries Read/Grep/Glob), and any codebase assumption it gets wrong is caught by plan-review's Assumption Validation step (4b). Do **not** spawn a second `solution-architect` "deeper analysis" pass here — that duplication was removed for execution-time reasons (see docs/superpowers/specs/2026-07-01-n1-execution-time-optimization-design.md).

**Spawn agent:** planner

Resolve model for `planner` (see Model Resolution above).

The planner runs `superpowers:writing-plans` in an isolated subagent context. This is deliberate: the writing-plans skill ends with an "Execution Handoff" step that asks the user which execution mode to use, and when invoked in-context that prompt intermittently leaks to the user even though N1 predetermines the execution mode. A dispatched subagent has no interactive channel — any such prompt returns to the orchestrator as text and is absorbed here, never shown to the user. The planner also lacks `Bash`, so it cannot chain into implementation or commit.

Spawn the planner agent with:
- The paths to its inputs — instruct the planner: "Read these files yourself before planning: `$N1_HOME/memory/<ID>/ticket.md`, `$N1_HOME/memory/<ID>/brainstorm.md`, `$N1_HOME/memory/<ID>/analysis.md` (the Step-2 analysis). Their content is NOT inlined here. `analysis.md` contains the codebase context already discovered — use it instead of re-exploring from scratch."
- **Output path:** `$N1_HOME/memory/<ID>/plan.md` — instruct the planner to write the plan there and nowhere else, and NOT to commit it (`$N1_HOME/` is N1's ephemeral state directory; N1 owns this content in per-ticket memory).
- Directive: "Do NOT include any `REQUIRED SUB-SKILL` execution directive in the plan body — N1 controls execution mode; the plan contains only implementation tasks."

After the planner returns (the full plan body already lives in `$N1_HOME/memory/<ID>/plan.md`, written by the planner):
- Update overview: `[x] Plan`, set `step: plan`
- Record a 2-3 sentence summary of the approach in overview's `## Key Decisions` section

**Step result (step mode):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
REVIEW_PLAN=$(n1_config_val '.planReview.reviewPlan')
if [ "${REVIEW_PLAN:-true}" = "true" ]; then
    NEXT="plan-review"
else
    EST=$(n1_config_val '.estimation.enabled')
    if [ "${EST:-false}" = "true" ]; then
        NEXT="estimation"
    else
        NEXT="implementation"
    fi
fi
n1_emit_step_result "plan" "pass" "$NEXT" "null"
```

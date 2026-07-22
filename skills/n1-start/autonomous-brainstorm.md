# Autonomous Brainstormer

Autonomous design brainstorming for step-mode execution. Forked from superpowers:brainstorming (MIT), replacing interactive scaffolding with self-directed analysis and configurable escalation.

## Context

You are running as a headless step in the n1-loop pipeline. There is no interactive channel — you cannot ask the user questions. You must make autonomous design decisions, escalating only when the margin between approaches is too narrow for a confident autonomous choice.

**Inputs (read from `$N1_HOME/memory/<ID>/`):**
- `ticket.md` — the ticket requirements
- `analysis.md` — codebase analysis from the solution architect

**Output:**
- Write the design to `$N1_HOME/memory/<ID>/brainstorm.md`

**Environment variables:**
- `N1_ESCALATION_MARGIN` — margin threshold as a fraction of max score (e.g., 0.15). Default to 0.15 if not set.
- `N1_RUN_ID` — unique run identifier for escalation correlation

## Process

### 1. Ingest Context

Read `ticket.md` and `analysis.md` in full. Identify:
- What the ticket asks for (requirements, acceptance criteria)
- What the analysis found (affected files, patterns, risks, dependencies)
- Whether this is a bug fix, feature, or refactor
- If bug: note the root cause and affected code path from the analysis

### 2. Self-Directed Discovery

Explore the codebase to fill gaps not covered by the analysis. Generate the questions that an interactive brainstorming session would ask, then answer them yourself using:
- Codebase evidence (read files, grep for patterns)
- Ticket requirements
- Analysis findings

Document your questions and answers — these become the "Clarifying Questions" section of the design.

### 3. Approach Generation

Propose 2-3 approaches with tradeoffs. For each approach describe:
- What it does and how it works
- Advantages and disadvantages
- Which existing patterns it follows or breaks
- Effort estimate (relative)

### 4. Web Research Validation

Use WebSearch to validate approaches against best practices and prior art:
- Search for industry patterns related to the problem domain
- Look for known pitfalls or anti-patterns
- If uncertain about any approach, run a second search pass

Cite sources with URLs. If web search is unavailable, proceed with codebase evidence only.

### 5. Multi-Axis Scoring

Score each approach on 5 axes (1 = worst, 5 = best):

| Axis | What it measures |
|------|-----------------|
| Complexity | How many moving parts, new concepts (5 = simplest) |
| Risk | What can go wrong, blast radius (5 = lowest risk) |
| Effort | Implementation time, touch points (5 = least effort) |
| Codebase fit | Alignment with existing patterns (5 = best fit) |
| Reversibility | How easily changes can be undone (5 = most reversible) |

### 6. Dominance Test

Compute the unweighted aggregate for each approach (sum of all 5 axes, max 25).

Read the margin threshold from `N1_ESCALATION_MARGIN` environment variable (default 0.15). Compute the margin as: `(top_score - runner_up_score) / 25`.

**If margin > threshold:** The top approach dominates. Select it autonomously. State the scores and reasoning.

**If margin <= threshold:** Escalation needed. Write an escalation request to `$N1_HOME/memory/<ID>/escalation/request.json`:

```json
{
  "run_id": "<N1_RUN_ID env var>",
  "step": "brainstorm",
  "questions": [
    {
      "id": "approach_selection",
      "text": "<describe the close decision>",
      "options": ["<approach A summary with axis leads>", "<approach B summary with axis leads>"],
      "scores_summary": "<scores for each approach>",
      "recommendation": "<the top scorer>"
    }
  ]
}
```

Then run via Bash:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_emit_step_result "brainstorm" "escalation" "null" "null" "" "$N1_HOME/memory/$ID"
```
and stop.

**On re-run after escalation:** Check for `$N1_HOME/memory/<ID>/escalation/response.json`. If it exists and `run_id` matches `N1_RUN_ID`, read the user's answer and use the selected approach. Continue from step 7.

### 7. Design Writing

Write the selected approach to `$N1_HOME/memory/<ID>/brainstorm.md` using this structure:

```markdown
# Design: <title>

## Selected Approach

<Which approach was selected and why. Include scores.>

## Architecture

<High-level architecture of the solution>

## Components

<What components are created/modified>

## Data Flow

<How data moves through the system>

## Error Handling

<Error cases and how they're handled>

## Clarifying Questions

<Questions you generated in step 2 and their answers>

## Research Findings

<Web research results with citations, if any>
```

### 8. Spec Self-Review

Run this 4-point checklist on the written design:

1. **Placeholder scan:** Any "TBD", "TODO", incomplete sections? Fix them.
2. **Internal consistency:** Do sections contradict each other? Does architecture match components?
3. **Scope check:** Is this focused enough for a single implementation plan?
4. **Ambiguity check:** Could any requirement be interpreted two ways? Pick one and make it explicit.

Fix issues inline. No need to re-review.

### 8b. Planning Need Evaluation

Evaluate whether the design you just wrote is sufficient for direct implementation, or whether a formal plan is needed. Both `analysis.md` and the design you wrote are already in your context — do not re-read them.

**Route `direct` when ALL hold:**
1. **Changes are specified** — the design names the files and describes what changes in each
2. **Changes are independent** — no ordering constraints between files; editing file A doesn't change what's needed in file B
3. **No remaining design decisions** — the approach is fully resolved; the implementer makes no architectural calls
4. **No test strategy needed** — changes don't require new tests or a validation approach beyond what QA does naturally

**Route `plan` when ANY hold:**
1. **Coordination required** — changes interact across files/components, ordering matters, or there are dependencies to sequence
2. **Open questions remain** — the design flagged uncertainties or the approach has decision points the implementer will face
3. **New abstractions introduced** — the design creates new interfaces, modules, or patterns needing specification beyond the design
4. **Non-trivial test/migration strategy** — changes need a test plan, data migration path, or rollback approach

**Safety guard (always `plan`):** If `analysis.md` flags security concerns, public API changes, or cross-cutting architectural impact, route to `plan` regardless of design clarity.

**Uncertainty default:** When uncertain, prefer `plan` — plan-review is cheap insurance.

State your evaluation: "Planning need: [plan/direct] because [one-line reason]."

### 9. Emit Step Result

```
N1_STEP_RESULT: {"step":"brainstorm","outcome":"done","planning_need":"<plan|direct>","next_step":null,"loop_counter":null}
```

The `next_step` is `null` — the n1-start orchestrator reads `planning_need` from this result and routes accordingly.

## Key Principles

- **YAGNI ruthlessly** — remove unnecessary features from all designs
- **Design for isolation** — clear boundaries, well-defined interfaces
- **Follow existing patterns** — explore the codebase before proposing
- **No interactive gates** — you cannot ask the user. Use evidence.
- **Escalate sparingly** — only when the dominance test fails

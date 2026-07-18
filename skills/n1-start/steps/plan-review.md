
Run `n1_config_val '.planReview.reviewPlan'` (default: `true`).

> The gate key (`planReview.reviewPlan`) and its default (`true`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

**If `planReview.reviewPlan` is `false`:** skip to checkpoint logic below.

**If `planReview.reviewPlan` is `true`:**

**Spawn reviewers in PARALLEL:**

#### A. Solution-architect CCR (always)

**Spawn agent:** solution-architect (fresh context — CCR)

Resolve model for `solution-architect` using **Sonnet as the fallback default for this plan-review pass** — this pass is grep-heavy assumption/standards checking, not open-ended reasoning. The `models.solution-architect` config override still takes precedence; only the default changes here (the Step-2 analysis pass keeps its Opus default). Resolve via `n1_resolve_model solution-architect sonnet`. Spawn with:
- The paths to its inputs — instruct the reviewer: "Read these files yourself before reviewing: `$N1_HOME/memory/<ID>/ticket.md`, `$N1_HOME/memory/<ID>/analysis.md`, `$N1_HOME/memory/<ID>/brainstorm.md`, and `$N1_HOME/memory/<ID>/plan.md` (the plan under review — you will fix issues in this file in-place). Their content is NOT inlined here."
- Codebase access (Read, Grep, Glob)
- Review-oriented instructions (NOT generative — this is a review, not a second plan):

```
You are reviewing an existing implementation plan. Do NOT rewrite or restructure the plan.
Your job is to find specific issues in these categories:

1. ASSUMPTION VALIDATION — Does the plan rely on assumptions about the codebase
   that aren't verified? Use Grep/Read to check: do the referenced files, functions,
   patterns, and APIs actually exist as described?

2. SCOPE DRIFT — Compare the plan against the ticket. Does it solve what was asked,
   or has it drifted beyond scope? Flag any tasks that don't trace back to a ticket
   requirement.

3. MISSING EDGE CASES — Are there failure modes, error paths, or data states the
   plan doesn't address but should?

4. ORDERING/DEPENDENCY RISKS — Are implementation steps in the right order? Are
   there hidden dependencies between tasks that could cause issues if executed
   in the listed sequence?

5. BLAST RADIUS — Does the plan touch more files or systems than necessary? Could
   the same result be achieved with fewer changes?

6. STANDARDS VALIDATION — Does the plan align with the industry standards and best
   practices already recorded in the `Industry Standards & Best Practices` section
   of `analysis.md`? Validate the plan against those recorded standards first —
   do NOT re-run a full research round. Only if the plan hinges on a standard that
   `analysis.md` does not cover may you do a single targeted lookup per
   agents/research-standards.md (>=2 independent trusted sources, cite the URL).
   Apply the fitness gate — prefer decisive standards over contestable practices,
   and do not flag a "best practice" the plan correctly omitted as over-engineering
   for this scope. If web tools are unavailable, validate against the recorded
   standards only and note that no new lookup was performed.

If you find issues: fix them in-place in the plan file. State what you changed and why.
If the plan is clean: state "Plan validated, no issues found."

Output format:
## Plan Review Result
**Verdict:** CLEAN | FIXED
**Changes:** (list of fixes applied, or "None")
**Verified assumptions:** (list of codebase claims you confirmed via Grep/Read)
**Verified standards:** (list of best-practice/standard claims confirmed via web, with cited URLs; or "None")
```

#### B. Codex plan review (conditional, advisory)

Call `n1_codex_available` (from `plugin/lib/config.sh`).

**If unavailable:** Log in overview `## Key Decisions`: "Codex plan review skipped — not available". Proceed with CCR only.

**If available:** `CODEX` is set by the availability probe. Read config:
```bash
CODEX_MODEL=$(n1_codex_val 'model')
CODEX_EFFORT=$(n1_codex_val 'effort')
: "${CODEX_EFFORT:=medium}"
```

Write a temporary prompt file containing the plan content, ticket acceptance criteria, and this instruction:

```
You are reviewing an implementation plan for correctness and completeness.

Review the plan below against the acceptance criteria. Produce exactly one of these verdicts:

APPROVED — the plan addresses all acceptance criteria and has no significant gaps.

ISSUES:
- <issue 1>
- <issue 2>
...

Only flag concrete issues (missing acceptance criteria, logical errors, impossible steps). Do not flag style preferences.

=== ACCEPTANCE CRITERIA ===
<content of ticket.md acceptance criteria section>

=== PLAN ===
<content of plan.md>
```

Run:
```bash
node "$CODEX" task --wait \
  ${CODEX_MODEL:+--model "$CODEX_MODEL"} \
  --effort "$CODEX_EFFORT" \
  --prompt-file "<temp-prompt-file>"
```

**Graceful fallback:** If the Codex call errors or times out, retry once. If it still fails, log in overview `## Key Decisions`: "Codex plan review failed — proceeding with CCR only". Never treat missing Codex as a review FAIL.

The `codex-adapter` agent is NOT used — output is a simple verdict string, not structured `[CX-N]` findings.

**Non-blocking:** CCR is the authoritative reviewer. Codex is advisory only.

#### After BOTH return:

- Record the CCR verdict: if verdict is FIXED, the plan file was updated in-place by the reviewer. Record the plan-review verdict and a one-line summary of changes in overview's `## Key Decisions` — durable traceability that survives a resume, rather than living only in transient orchestrator context.
- Record the Codex verdict (if it ran): append to overview `## Key Decisions`: "Codex plan review: APPROVED" or "Codex plan review flagged issues: <summary>". If Codex flagged issues that the CCR did not catch, note them in Key Decisions for awareness but do NOT block the pipeline.

**Step result (step mode):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
EST=$(n1_config_val '.estimation.enabled')
if [ "${EST:-false}" = "true" ]; then
    NEXT="estimation"
else
    NEXT="implementation"
fi
n1_emit_step_result "plan-review" "pass" "$NEXT" "null"
```

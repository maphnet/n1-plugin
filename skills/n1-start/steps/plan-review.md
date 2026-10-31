
```bash
source ~/.n1/preamble.sh
n1_step_begin "plan-review" 5
n1_verify_dependencies "$N1_HOME/memory/$ID" plan.md || { n1_step_end "plan-review" 5 failed; echo "ERROR: plan.md missing — cannot review plan" >&2; exit 1; }
```

**Spawn reviewer:**

#### Solution-architect CCR

**Spawn agent:** solution-architect (fresh context — CCR)

Resolve via `n1_resolve_agent solution-architect plan-review`, split tab-separated model/effort pair, pass both. Spawn with codebase access (Read, Grep, Glob); instruct: "Read these files before reviewing: ticket.md, analysis.md, brainstorm.md, plan.md (the plan — fix issues in-place). NOT generative — this is a review. Budget ≤30 tool calls; grep with -l/-c or head-capped output; read plan.md once."

Review categories (find issues, fix in-place):
1. **Assumption validation** — Do referenced files, functions, APIs exist? Use Grep/Read.
2. **Scope drift** — Each task traces to a ticket requirement?
3. **Missing edge cases** — Failure modes, error paths, data states not addressed.
4. **Ordering/dependency risks** — Correct sequence? Hidden inter-task dependencies?
5. **Blast radius** — Minimal changes? Same result with fewer files?
6. **Standards validation** — Aligns with `analysis.md § Industry Standards`? Single targeted lookup per `agents/research-standards.md` only for uncovered standards; fitness gate; cite URLs. Skip lookup if web unavailable.

If issues: fix in-place, state changes. If clean: "Plan validated, no issues found."

Output: `## Plan Review Result` / `**Verdict:** CLEAN | FIXED` / `**Changes:**` / `**Verified assumptions:**` / `**Verified standards:**`

#### After CCR returns:

- Record the verdict in `## Key Decisions` (never `## Escalations`):

```bash
source ~/.n1/preamble.sh
n1_append_key_decision "$N1_HOME/memory/$ID/overview.md" "Plan review: <CLEAN|FIXED> - <one-line change summary; no quotes, backticks or $>"
n1_step_end "plan-review" 5 success '{"verdict":"<CLEAN|FIXED>"}'
```

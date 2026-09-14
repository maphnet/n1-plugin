
`n1_config_val '.planReview.reviewPlan'` (default `true`). If `false`: skip.

**Rule injection:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/rules.sh"
RULES_DIR=$(n1_rules_dir)
PLAN_RULES_BLOCK=""
if [ -n "$RULES_DIR" ] && [ -d "$RULES_DIR" ]; then
    GATE_RULES=""
    while IFS= read -r rf; do
        [ -z "$rf" ] && continue
        enf=$(n1_rule_field "$rf" "enforcement")
        [ "$enf" = "gate" ] && GATE_RULES="${GATE_RULES} ${rf}"
    done < <(n1_rules_for_agent "solution-architect" "" "$RULES_DIR")
    if [ -n "$GATE_RULES" ]; then PLAN_RULES_BLOCK=$(n1_rules_render $GATE_RULES); fi
fi
```

**Spawn agent:** solution-architect (fresh context — CCR). `n1_resolve_model solution-architect sonnet`. Inputs: ticket.md, analysis.md, brainstorm.md, plan.md (under review — fix in-place). Codebase access. Instructions:

```
Review plan. Fix issues in-place. If clean: "Plan validated."

1. Assumptions: do referenced files/functions/APIs exist? Grep/Read to verify.
2. Scope: flag tasks not tracing to a ticket requirement.
3. Edge cases: failure modes, error paths, data states not addressed.
4. Ordering: steps in wrong order or hidden dependencies.
5. Blast radius: plan touches more than necessary?
6. Standards: compare against analysis.md Industry Standards. One lookup per research-standards.md if plan hinges on uncovered standard only.

{When $PLAN_RULES_BLOCK non-empty:}
7. Rules: test each against plan. Violations need justification or edit.
$PLAN_RULES_BLOCK

Output:
## Plan Review Result
**Verdict:** CLEAN | FIXED
**Changes:** (list or "None")
**Verified assumptions:** (confirmed)
**Verified standards:** (URLs or "None")
```

After return: record verdict + one-line summary in `## Key Decisions`. Update overview `[x] Plan Review`, `step: plan-review`.

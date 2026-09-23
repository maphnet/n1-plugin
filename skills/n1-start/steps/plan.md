
**Spawn agent:** planner.

Runs `n1-plan` skill in isolated subagent (prevents interactive prompts leaking to user; subagent lacks Bash so cannot chain into implementation or commit).

```bash
source ~/.n1/root/lib/preamble.sh
IFS=$'\t' read -r PLANNER_MODEL PLANNER_EFFORT < <(n1_resolve_agent planner plan)
source "$N1_ROOT/lib/rules.sh"
RULES_DIR=$(n1_rules_dir)
RULES_BLOCK=""
if [ -n "$RULES_DIR" ] && [ -d "$RULES_DIR" ]; then
    MATCHING_RULES=$(n1_rules_for_agent "planner" "" "$RULES_DIR")
    if [ -n "$MATCHING_RULES" ]; then
        RULES_BLOCK=$(n1_rules_render $MATCHING_RULES)
    fi
fi
```

```bash
source ~/.n1/root/lib/preamble.sh
n1_verify_dependencies "$N1_HOME/memory/$ID" brainstorm.md analysis.md || { echo "ERROR: upstream artifacts missing — cannot plan" >&2; exit 1; }
```

Spawn with `$PLANNER_MODEL` and `$PLANNER_EFFORT`:
- Inputs: "Read these files yourself: `$N1_HOME/memory/<ID>/ticket.md`, `$N1_HOME/memory/<ID>/brainstorm.md`, `$N1_HOME/memory/<ID>/analysis.md`. Content NOT inlined. `analysis.md` contains codebase context — use instead of re-exploring."
- Output path: `$N1_HOME/memory/<ID>/plan.md` — write there and nowhere else; do NOT commit.
- "Do NOT include any `REQUIRED SUB-SKILL` execution directive in the plan body."
- Append `$RULES_BLOCK` if non-empty.

**Wait for the persona to return its result before proceeding. Do NOT read ahead to the next step or check for files until the agent tool call completes.**

After return: update overview `[x] Plan`, set `step: plan`. Record 2-3 sentence approach summary in `## Key Decisions`.

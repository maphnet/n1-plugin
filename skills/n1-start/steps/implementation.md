
> **After the implementer subagent returns, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user.**

Run **Ensure Dependencies(`<ID>`)** before spawning. Spawn directives: `WORKTREE_PATH` set → "Work in `$WORKTREE_PATH`." Scratch: `$N1_HOME/memory/<ID>/benchmarks/`. No finish/branch-delete skills, no push, no PRs. Output: `$N1_HOME/memory/<ID>/implementation.md` (format below). Append `$RULES_BLOCK`. Escalation: see below.

```bash
source "$N1_ROOT/lib/preamble.sh"
n1_step_begin "implementation" 7
n1_verify_dependencies "$N1_HOME/memory/$ID" analysis.md || { echo "ERROR: analysis.md missing — cannot implement" >&2; exit 1; }
TIER=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier")
BLAST=$(n1_read_signal "$N1_HOME/memory/$ID/brainstorm.md" "blast_radius" 2>/dev/null); BLAST="${BLAST:-$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "blast_radius")}"
FILES_CHANGED=$(n1_read_signal "$N1_HOME/memory/$ID/brainstorm.md" "files_changed" 2>/dev/null); FILES_CHANGED="${FILES_CHANGED:-$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "files_changed")}"
IFS=$'\t' read -r DEVELOPER_MODEL DEVELOPER_EFFORT < <(n1_resolve_agent developer implementation)
IFS=$'\t' read -r IMPLEMENTER_MODEL IMPLEMENTER_EFFORT < <(n1_resolve_agent implementer implementation)
PLANNING_NEED=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "planning_need")
# Fallback simplicity gate: fires if simple-path gate (analysis.md) did not already route directly.
# Primary routing is done earlier by the simple-path gate in analysis.md.
GATE_RESULT=$( [ "$TIER" = "simple" ] && [ "$BLAST" = "low" ] && [ "${FILES_CHANGED:-999}" -lt 3 ] && echo true || echo false )
n1_record_decision simplicity-gate "$GATE_RESULT" '{"all":[{"signal":"brainstorm.blast_radius","fallback":"analysis.blast_radius","eq":"low"},{"signal":"brainstorm.files_changed","fallback":"analysis.files_changed","lt":3}]}' "tier=$TIER"
```

Run `procedures/rules-injection.md`: `agent_name=developer` for direct routes and `agent_name=implementer` for the Plan path. Dispatch prompts always retain the selected persona, resolved model/effort, input-file path, `WORKTREE_PATH`, output path, escalation rules, `$RULES_BLOCK`, constraints, and required result format.

**Simplicity gate PASS** (all: `TIER==simple`, `BLAST==low`, `FILES_CHANGED<3`): dispatch **developer** persona with `$DEVELOPER_MODEL` and `$DEVELOPER_EFFORT`, brainstorm.md or plan.md, `$N1_HOME/memory/$ID/analysis.md` (codebase analysis; use file:line references for targeted reads), and "Direct Implementation mode." → QA.

**ANY fails:** `PLANNING_NEED=direct` → dispatch **developer** persona with the resolved model/effort pair, brainstorm.md, `$N1_HOME/memory/$ID/analysis.md` (codebase analysis; use file:line references for targeted reads), "Direct Implementation." `PLANNING_NEED=plan`/absent → plan.md; absent → Plan path. Top-level headers >2 → Plan path; ≤2 no cross-deps → dispatch developer with the resolved pair, plan.md, `$N1_HOME/memory/$ID/analysis.md` (codebase analysis; use file:line references for targeted reads), "Direct, sequential"; else Plan path.

**Plan path:** dispatch **implementer** persona with `$IMPLEMENTER_MODEL` and `$IMPLEMENTER_EFFORT`. Input plan.md or brainstorm.md, `$N1_HOME/memory/$ID/analysis.md` (codebase analysis; use file:line references for targeted reads): "Enumerate tasks; dispatch developer per task." Always invoke `n1-implement`. Constraints: Think Before Coding; Simplicity First; Surgical Changes; Goal-Driven; existing patterns; test+commit per change; BLOCKED on architectural; no finish/branch-delete skills, CONTINUOUS. Pass `WORKTREE_PATH`, output path, escalation, `$RULES_BLOCK`, and the implementation-result format.

**Wait contract applies** (see `procedures/output-gates.md § Wait Contract`). Idle until the persona returns its result.

```bash
source "$N1_ROOT/lib/preamble.sh"
BP_FILE="$N1_HOME/memory/$ID/branch-point"; BASE_REF=$( [ -f "$BP_FILE" ] && cat "$BP_FILE" || n1_config_val '.git.defaultBranch' )
BASE=$(git merge-base "$BASE_REF" HEAD 2>/dev/null || git rev-parse HEAD~1 2>/dev/null || echo "HEAD")
LINES_CHANGED=$(git diff --stat "$BASE" 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | paste -sd+ | bc 2>/dev/null || echo "0")
NEW_FILES=$(git diff --name-status "$BASE" 2>/dev/null | grep -c '^A' || echo "0"); CHANGED_FILES=$(git diff --name-only "$BASE" 2>/dev/null || true)
source "$N1_ROOT/lib/classify.sh"
_surf=$(n1_classify_doc_config_only "$CHANGED_FILES"); [ "$_surf" = "true" ] && DIFF_SURFACE="config" || DIFF_SURFACE="code"
n1_write_signals "$N1_HOME/memory/$ID/implementation.md" "diff_surface=$DIFF_SURFACE" "lines_changed=$LINES_CHANGED" "new_files_count=$NEW_FILES"
n1_step_end "implementation" 7 "success"
```
BLOCKED: Confidence-Based Escalation. Re-spawn after decision.

**Confidence-Based Escalation:** high confidence → proceed. Low+low blast → proceed, log `## Key Decisions`. Low+high blast → ESCALATE: present `**Decision:**`, `**Options:** A/B` with tradeoffs, `**Recommendation:**`. Always escalate: security, new architectural patterns, public API changes.

**implementation.md format:** `## Implementation Summary` / `### Completed Tasks` / `### Files Changed` / `### Test Results` / `### Decisions Made`

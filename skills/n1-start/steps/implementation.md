
> **After the implementer subagent returns, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user.**

Ensure Dependencies. Use worktree, scratch, output, rules; no finish/branch-delete, push, PR.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/config.sh"
n1_step_begin "implementation" 7
TIER=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier")
BLAST=$(n1_read_signal "$N1_HOME/memory/$ID/brainstorm.md" "blast_radius" 2>/dev/null); BLAST="${BLAST:-$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "blast_radius")}"
FILES_CHANGED=$(n1_read_signal "$N1_HOME/memory/$ID/brainstorm.md" "files_changed" 2>/dev/null); FILES_CHANGED="${FILES_CHANGED:-$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "files_changed")}"
IFS=$'\t' read -r DEVELOPER_MODEL DEVELOPER_EFFORT < <(n1_resolve_agent developer implementation)
PLANNING_NEED=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "planning_need")
# Fallback simplicity gate: fires if simple-path gate (analysis.md) did not already route directly.
# Primary routing is done earlier by the simple-path gate in analysis.md.
GATE_RESULT=$( [ "$TIER" = "simple" ] && [ "$BLAST" = "low" ] && [ "${FILES_CHANGED:-999}" -lt 3 ] && echo true || echo false )
n1_record_decision simplicity-gate "$GATE_RESULT" '{"all":[{"signal":"brainstorm.blast_radius","fallback":"analysis.blast_radius","eq":"low"},{"signal":"brainstorm.files_changed","fallback":"analysis.files_changed","lt":3}]}' "tier=$TIER"
```

Run `procedures/rules-injection.md`: `agent_name=developer`.

**Simplicity PASS:** developer gets resolved pair and brainstorm/plan in Direct mode → QA. Otherwise direct planning need uses developer; plan/absent or >2 headers/cross-deps uses Plan path. **Plan path:** implementer uses `n1-implement`, enumerates tasks and dispatches developers; preserve patterns, surgical goal-driven work, per-change test+commit, architectural blocking, no finish/branch-delete, worktree/output/escalation/rules.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/config.sh"
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

**Confidence escalation:** high confidence proceeds; low+low blast proceeds with Key Decisions; low+high asks:
```
**Decision:** <what> **Options:** A. <opt> — <tradeoff>  B. <opt> — <tradeoff>
**Recommendation:** <opt> because <reason>. Which?
```
Always escalate security, new architecture, or public API.

**implementation.md:**
```markdown
## Implementation Summary
### Completed Tasks
- Task 1: <description> — <result>
### Files Changed
- <file> — <what changed>
### Test Results
<output summary>
### Decisions Made
- <decision>: <choice> (reason: <why>)
```

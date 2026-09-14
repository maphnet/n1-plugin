
> **After the implementer subagent returns, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user.**

Run **Ensure Dependencies(`<ID>`)** before spawning. Spawn directives: `WORKTREE_PATH` set → "Work in `$WORKTREE_PATH`." Scratch: `$N1_HOME/memory/<ID>/benchmarks/`. No `finishing-a-development-branch`, no push, no PRs. Output: `$N1_HOME/memory/<ID>/implementation.md` (format below). Append `$RULES_BLOCK`. Escalation: see below.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/config.sh"
n1_step_begin "implementation" 7
TIER=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier")
BLAST=$(n1_read_signal "$N1_HOME/memory/$ID/brainstorm.md" "blast_radius" 2>/dev/null); BLAST="${BLAST:-$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "blast_radius")}"
FILES_CHANGED=$(n1_read_signal "$N1_HOME/memory/$ID/brainstorm.md" "files_changed" 2>/dev/null); FILES_CHANGED="${FILES_CHANGED:-$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "files_changed")}"
DEVELOPER_MODEL=$(n1_resolve_model developer implementation)
PLANNING_NEED=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "planning_need")
# Fallback simplicity gate: fires if simple-path gate (analysis.md) did not already route directly.
# Primary routing is done earlier by the simple-path gate in analysis.md.
GATE_RESULT=$( [ "$TIER" = "simple" ] && [ "$BLAST" = "low" ] && [ "${FILES_CHANGED:-999}" -lt 3 ] && echo true || echo false )
n1_record_decision simplicity-gate "$GATE_RESULT" '{"all":[{"signal":"brainstorm.blast_radius","fallback":"analysis.blast_radius","eq":"low"},{"signal":"brainstorm.files_changed","fallback":"analysis.files_changed","lt":3}]}' "tier=$TIER"
```

Run `procedures/rules-injection.md`: `agent_name=developer`.

**Simplicity gate PASS** (all: `TIER==simple`, `BLAST==low`, `FILES_CHANGED<3`): spawn developer `$DEVELOPER_MODEL`, input brainstorm.md or plan.md, "Direct Implementation mode." → QA.

**ANY fails:** `PLANNING_NEED=direct` → spawn developer, brainstorm.md, "Direct Implementation." `PLANNING_NEED=plan`/absent → plan.md; absent → Plan path. Top-level headers >2 → Plan path; ≤2 no cross-deps → developer, plan.md, "Direct, sequential"; else Plan path.

**Plan path:** spawn **implementer**. Input plan.md or brainstorm.md: "Enumerate tasks; pass each to SDD subagents." Always `subagent-driven-development`. Constraints: Think Before Coding; Simplicity First; Surgical Changes; Goal-Driven; existing patterns; test+commit per change; BLOCKED on architectural; SDD overrides: no `finishing-a-development-branch`, CONTINUOUS. Pass `WORKTREE_PATH`, output path, escalation, `$RULES_BLOCK`.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/config.sh"
BP_FILE="$N1_HOME/memory/$ID/branch-point"; BASE_REF=$( [ -f "$BP_FILE" ] && cat "$BP_FILE" || n1_config_val '.git.defaultBranch' )
BASE=$(git merge-base "$BASE_REF" HEAD 2>/dev/null || git rev-parse HEAD~1 2>/dev/null || echo "HEAD")
LINES_CHANGED=$(git diff --stat "$BASE" 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | paste -sd+ | bc 2>/dev/null || echo "0")
NEW_FILES=$(git diff --name-status "$BASE" 2>/dev/null | grep -c '^A' || echo "0"); CHANGED_FILES=$(git diff --name-only "$BASE" 2>/dev/null || true)
echo "$CHANGED_FILES" | grep -qvE '\.(md|txt|json|ya?ml|toml|cfg|ini|conf|env)$' && DIFF_SURFACE="code" || DIFF_SURFACE="config"
n1_write_signals "$N1_HOME/memory/$ID/implementation.md" "diff_surface=$DIFF_SURFACE" "lines_changed=$LINES_CHANGED" "new_files_count=$NEW_FILES"
n1_step_end "implementation" 7 "success"
```
BLOCKED: Confidence-Based Escalation. Re-spawn after decision.

**Confidence-Based Escalation:** high confidence → proceed. Low+low blast → proceed, log `## Key Decisions`. Low+high blast → ESCALATE:
```
**Decision:** <what> **Options:** A. <opt> — <tradeoff>  B. <opt> — <tradeoff>
**Recommendation:** <opt> because <reason>. Which?
```
Always escalate: security, new architectural patterns, public API changes.

**implementation.md format:**
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

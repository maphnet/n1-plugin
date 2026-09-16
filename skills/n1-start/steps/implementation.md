
> **After the implementer subagent returns, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user.**

Run **Ensure Dependencies(`<ID>`)** before spawning. Spawn directives: `WORKTREE_PATH` set → "Work in `$WORKTREE_PATH`." Scratch: `$N1_HOME/memory/<ID>/benchmarks/`. No finish/branch-delete skills, no push, no PRs. Output: `$N1_HOME/memory/<ID>/implementation.md` (format below). Append `$RULES_BLOCK`. Escalation: see below.

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

**Codex headless dispatch:** When `n1_host` returns `codex`, the implementation persona is dispatched as a blocking headless child via `n1_headless_cmd` instead of the normal persona dispatch (which uses `spawn_agent + wait_agent` and times out on long-running tasks). Generate the command and run it via Bash:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/host.sh"; source "$N1_ROOT/lib/config.sh"
IS_CODEX=$( [ "$(n1_host)" = "codex" ] && echo true || echo false )
echo "IS_CODEX=$IS_CODEX"
```

When `IS_CODEX=true`, use this pattern instead of persona dispatch for **both** the simplicity-gate-PASS developer and the Plan-path implementer:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/host.sh"; source "$N1_ROOT/lib/config.sh"
IMPL_LOG="$N1_HOME/memory/$ID/impl-run.jsonl"
PLAN_FILE="$N1_HOME/memory/$ID/plan.md"
[ -f "$PLAN_FILE" ] || PLAN_FILE="$N1_HOME/memory/$ID/brainstorm.md"
IMPL_OUTPUT="$N1_HOME/memory/$ID/implementation.md"
IMPL_ARGS="$ID plan=$PLAN_FILE output=$IMPL_OUTPUT"
IMPL_CMD=$(n1_headless_cmd n1-implement "$IMPL_ARGS" "$DEVELOPER_MODEL" "$IMPL_LOG" "$WORKTREE_PATH")
echo "IMPL_CMD=$IMPL_CMD"
```

Run `bash -c "$IMPL_CMD"` — this blocks until the child exits (no timeout). Then read the result: `tail -20 "$IMPL_LOG"`. Check exit code: if non-zero and `$IMPL_OUTPUT` does not exist, the child crashed — escalate to the user. The child runs the full `n1-implement` skill, which handles task dispatch, review, and fix loops internally.

The args string includes the plan file path and output path because `n1-implement` expects these in its dispatch prompt (see `skills/n1-implement/SKILL.md` Input section). The worktree path is handled by the `--cd` flag in `n1_headless_cmd`.

When `IS_CODEX=false` (Claude Code), use the normal persona dispatch as described below (unchanged).

**Simplicity gate PASS** (all: `TIER==simple`, `BLAST==low`, `FILES_CHANGED<3`): On Codex (`IS_CODEX=true`), use the headless dispatch pattern above with `n1-implement` skill and the brainstorm.md or plan.md as input. On Claude Code, dispatch developer persona with `$DEVELOPER_MODEL` and `$DEVELOPER_EFFORT`, input brainstorm.md or plan.md, "Direct Implementation mode." → QA.

**ANY fails:** `PLANNING_NEED=direct` → spawn developer with the resolved model/effort pair, brainstorm.md, "Direct Implementation." `PLANNING_NEED=plan`/absent → plan.md; absent → Plan path. Top-level headers >2 → Plan path; ≤2 no cross-deps → developer with the resolved pair, plan.md, "Direct, sequential"; else Plan path.

**Plan path:** On Codex (`IS_CODEX=true`), use the headless dispatch pattern above — the child runs `n1-implement` with plan.md as input, blocking until complete. On Claude Code, dispatch **implementer** persona. Input plan.md or brainstorm.md: "Enumerate tasks; dispatch developer per task." Always `n1-implement`. Constraints: Think Before Coding; Simplicity First; Surgical Changes; Goal-Driven; existing patterns; test+commit per change; BLOCKED on architectural; no finish/branch-delete skills, CONTINUOUS. Pass `WORKTREE_PATH`, output path, escalation, `$RULES_BLOCK`.

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

**Confidence-Based Escalation:** high confidence → proceed. Low+low blast → proceed, log `## Key Decisions`. Low+high blast → ESCALATE: present `**Decision:**`, `**Options:** A/B` with tradeoffs, `**Recommendation:**`. Always escalate: security, new architectural patterns, public API changes.

**implementation.md format:** `## Implementation Summary` / `### Completed Tasks` / `### Files Changed` / `### Test Results` / `### Decisions Made`

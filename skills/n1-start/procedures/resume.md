# Procedure: Resume

## Post-Compaction Recovery

After compaction, ORCHESTRATOR STATE block is injected into `additionalContext` by the session-start hook.

**Must:**
1. Read ORCHESTRATOR STATE — it is marked "authoritative, overrides any compacted summary."
2. Use those values for all decisions — tracker type, MCP prefix, worktree, step routing, loop counters.
3. Do NOT rely on compacted summary for config/routing values.
4. If `Task context:` non-empty: print **Gate 1** (resume variant from `procedures/output-gates.md § Gate 1`).
5. If ORCHESTRATOR STATE missing: re-resolve N1_HOME:
   ```bash
   source "$N1_ROOT/lib/preamble.sh"
   N1_HOME=$(n1_home)
   cat "$N1_HOME/config.json"
   ```

## Memory Check

Check if `$N1_HOME/memory/<input>/overview.md` exists.

**Exists:** read step from frontmatter.
```bash
source "$N1_ROOT/lib/preamble.sh"
TYPE=$(n1_read_type "$N1_HOME/memory/$ID/overview.md")
```
`TYPE=="investigation"`: skip workspace isolation. Else run workspace isolation. Read loop counters:
```bash
source "$N1_ROOT/lib/preamble.sh"
n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle"
```
(Repeat for `tq_fix_cycle`, `review_fix_cycle`, `clean_passes`, `local_test_fix_cycle`, `ci_fix_cycle`.) Print Gate 1 (resume variant). Read `## Context`:
```bash
CONTEXT_SECTION=$(sed -n '/^## Context$/,/^## /{/^## Context$/d;/^## /d;p}' "$N1_HOME/memory/$ID/overview.md")
```
If empty: skip Gate 1 silently. Else populate template from frontmatter and print.

**Not exists:** fresh start. Create `$N1_HOME/memory/<ID>/`.

## Loop-Counter Durability

Loop counters live in overview frontmatter (`qa_fix_cycle`, `tq_fix_cycle`, `review_fix_cycle`, `clean_passes`, `local_test_fix_cycle`, `ci_fix_cycle`). Increment in file as loop turns; read back on resume.

Overview is single source of truth. Each step writes output file FIRST, then updates `step:`/checkbox LAST. Resume: step is done only if overview says so. Artifact writes are full overwrites — idempotent.

**Dependency integrity guard:**
```bash
source "$N1_ROOT/lib/preamble.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" ticket.md analysis.md
```
(Pass declared dependency files for current step.) Missing/empty dependency → STOP and report.

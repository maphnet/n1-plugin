# Procedure: Resume

Covers post-compaction recovery, memory check (resume support), loop-counter durability, and step dependency map.

### Post-Compaction Recovery

When Claude Code compacts the conversation context, the session-start hook fires synchronously and injects an **ORCHESTRATOR STATE** block into `additionalContext`. This block contains the authoritative runtime state: N1_HOME, active ticket, current step, worktree path, branch, loop counters, autonomy settings, and config gates.

**After any compaction, you MUST:**

1. Read the ORCHESTRATOR STATE block from the re-injected session context — it is marked "authoritative, overrides any compacted summary"
2. Use those values for all subsequent decisions — tracker type, MCP prefix, worktree path, step routing, loop counters
3. Do NOT rely on the compacted conversation summary for config or routing values — compaction is lossy and may distort tracker type, MCP names, or other critical state
4. If `Task context:` is present in the ORCHESTRATOR STATE block and non-empty, print **Gate 1** (see `procedures/output-gates.md § Gate 1 — Task Orientation`) using the resume/post-compaction variant:
     - `<ID>` from ORCHESTRATOR STATE `Active ticket:`
     - `<TITLE>` from overview.md heading
     - `<CONTEXT_BLOCK>` from ORCHESTRATOR STATE `Task context:` (single-line flattened value; print as-is)
     - `<TIER>` and `<CURRENT_STEP>` from ORCHESTRATOR STATE
     - `<FILES_CHANGED>` from ORCHESTRATOR STATE `Files changed:` (omit line if absent)
     - `<TICKET_URL>` from ORCHESTRATOR STATE (omit line if empty)
5. If the ORCHESTRATOR STATE block is missing (no active run), re-resolve N1_HOME and re-read config.json via Bash before continuing:
   ```bash
   N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
   source "$N1_ROOT/lib/config.sh"
   N1_HOME=$(n1_home)
   cat "$N1_HOME/config.json"
   ```

This is belt-and-suspenders: the hook guarantees config delivery, the directive ensures the orchestrator knows to trust it over the compacted summary.

## Memory Check (Resume Support)

Check if `$N1_HOME/memory/<input>/overview.md` exists:

- **If exists:** Read the overview frontmatter to determine current step. Also read the pipeline type:
  ```bash
  N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
  source "$N1_ROOT/lib/validation.sh"
  TYPE=$(n1_read_type "$N1_HOME/memory/$ID/overview.md")
  ```
  When `TYPE` is `"investigation"`, the pipeline runs the shortened investigation flow (see Step 3b and Planning Need Routing below) — skip workspace isolation (no branch or worktree needed for investigation tasks). When `EXTERNAL_WORKTREE` is true, skip workspace isolation entirely — the external checkout is reused (set `WORKTREE_PATH` and `BRANCH` from git as described in Isolation Mode Resolution above). Otherwise, run the appropriate workspace isolation procedure: **Ensure Worktree(`<ID>`)** when `USE_WORKTREE` is true, or **Ensure Working Branch(`<ID>`)** otherwise (see procedures/workspace-isolation.md). This covers resuming from a session that ended without cleanup. Then resume from where work left off: read the dependency files for the current step (see dependency map below) and continue. **Also read the loop counters** (`qa_fix_cycle`, `tq_fix_cycle`, `review_fix_cycle`, `clean_passes`, `local_test_fix_cycle`, and `ci_fix_cycle` if present) so bounded loops resume at their true count, not zero (see Loop-Counter Durability below). Read each via:
  ```bash
  N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
  source "$N1_ROOT/lib/frontmatter.sh"
  n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle"
  ```

  **Print Gate 1 (resume):** See `procedures/output-gates.md § Gate 1 — Task Orientation`. Use the resume/post-compaction variant. Read values via Bash:
  ```bash
  CONTEXT_SECTION=$(sed -n '/^## Context$/,/^## /{/^## Context$/d;/^## /d;p}' "$N1_HOME/memory/$ID/overview.md")
  ```
  If `CONTEXT_SECTION` is empty (pre-feature runs or SA did not emit it), skip Gate 1 silently — no error, no warning. Otherwise populate the template fields from frontmatter (`tier`, `step`, `ticket_url`) and signals (`files_changed`), then print.

- **If not exists:** Fresh start. Create `$N1_HOME/memory/<ID>/` directory.

### Step dependency map

Read `pipeline.json` under `steps[]` for dependency declarations.

### Loop-counter durability & crash-safe checkpointing

- **Loop counters live in overview frontmatter**, never only in orchestrator context: `qa_fix_cycle`, `tq_fix_cycle`, `review_fix_cycle`, `clean_passes`, `local_test_fix_cycle` (and `ci_fix_cycle`, owned by n1-ci). Increment them in the file as each loop turns and read them back on resume. A bound held only in context resets to zero on restart, silently defeating it.
- **Overview is the single source of truth for progress.** Each step writes its output file FIRST, then updates `step:`/checkbox in overview LAST. On resume, a step counts as done only if overview says so. If a crash lands between the two writes (output file exists but overview still points at the prior step), re-running is safe because every artifact write is a full overwrite — idempotent, never an append.

**Dependency integrity guard (applies to every step).** Before spawning a step's agent or sub-skill, run:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/validation.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" ticket.md analysis.md
```

(Pass the declared dependency files for the current step — see table above.) If any dependency is missing or empty, the function prints the missing files to stderr and returns non-zero — **STOP and report** rather than proceeding with a degraded handoff. (`ticket.md` with no acceptance criteria is handled upstream by product-analyst and is not a hard stop.)

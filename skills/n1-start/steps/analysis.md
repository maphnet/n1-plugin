
**Cache check (when `analysisCache.enabled` is true):**

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/cache.sh"

CACHE_ENABLED=$(n1_config_val ".analysisCache.enabled" "$N1_HOME/config.json")
SNAPSHOT_PATH=$(n1_snapshot_path "$N1_HOME")
CACHE_STATE="cold"

if [ "$CACHE_ENABLED" = "true" ]; then
    CACHE_STATE=$(n1_snapshot_check_freshness "$SNAPSHOT_PATH" "$N1_HOME/config.json")
fi
```

The `CACHE_STATE` variable (`cold`, `stale`, or `fresh`) determines the dispatch path below. When `analysisCache.enabled` is `false` (default), `CACHE_STATE` stays `cold` and the step runs identically to today.

**Spawn agent:** solution-architect

Resolve model for `solution-architect` with context `analysis`.

**Prompt construction depends on CACHE_STATE:**

**When CACHE_STATE is `cold` or `stale`:**

Spawn the solution-architect agent with:
- The path to the ticket file — instruct the agent: "Read `$N1_HOME/memory/<ID>/ticket.md` yourself (you have Read); it is the scope to analyze. Its content is NOT inlined here."
- The **Type** field (bug/feature/task/improvement) — extract it without reading the whole file into orchestrator context:
  ```bash
  grep -m1 -i '^\*\*Type:\*\*' "$N1_HOME/memory/$ID/ticket.md"
  ```
  Pass the value explicitly so the architect knows whether to perform bug investigation
- Directive: "Research relevant industry standards, best practices, and practitioner experience per agents/research-standards.md and include the cited Industry Standards & Best Practices section."
- Directive: "Scratch-artifact policy: write any throwaway benchmark or investigative/spike test (one that answers a current question rather than verifying committed code) under `$N1_HOME/memory/<ID>/benchmarks/` or `$N1_HOME/memory/<ID>/tests/` (both gitignored; create the directory if needed) — never into the repo's test suite. Tests that verify the implementation still go into the repo as usual. When unsure, default to scratch."
- **Investigation mode directive (when `TYPE` is `"investigation"`, read from overview.md frontmatter via `n1_read_type "$N1_HOME/memory/$ID/overview.md"`):** Also pass: "This is an investigation task -- analyze the codebase to answer the question posed in the ticket, not to plan implementation changes. Focus on findings, evidence, and recommendations rather than files-to-change and blast radius. Your analysis will feed directly into an investigation deliverable, not a plan."
- **When `CACHE_ENABLED` is `true`**, also append this OUTPUT FORMAT REQUIREMENT at end of prompt:

  > Separate your findings into two clearly marked sections:
  > `## [PROJECT] <section name>` — for project-level facts (architecture, conventions, patterns, stack, industry standards, subsystem registry, key files).
  > Include `<!-- provenance: <files/globs that informed this section> -->` after each [PROJECT] section heading.
  > `## [TICKET] <section name>` — for ticket-specific analysis (affected files, blast radius, risks, integration points, tier assessment).

**When CACHE_STATE is `fresh`:**

Read the snapshot metadata:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
SNAPSHOT_BODY=$(n1_snapshot_read_body "$SNAPSHOT_PATH")
SNAPSHOT_SHA=$(n1_read_frontmatter "$SNAPSHOT_PATH" "git_sha_short")
SNAPSHOT_AGE_RAW=$(n1_read_frontmatter "$SNAPSHOT_PATH" "generated_at")
```

Spawn the solution-architect agent with this prompt (replacing the standard project-discovery directives):

> You have a recent project snapshot of this codebase (generated at {SNAPSHOT_AGE_RAW}, git SHA {SNAPSHOT_SHA}). It covers: stack, architecture, conventions, patterns, subsystem registry, industry standards, and key files.
>
> PROJECT SNAPSHOT:
> {SNAPSHOT_BODY}
>
> ---
>
> TASK: Analyze the following ticket for implementation readiness.
>
> Ticket: Read `$N1_HOME/memory/<ID>/ticket.md` yourself (you have Read); it is the scope to analyze.
> Type: {TYPE extracted via `grep -m1 -i '^\*\*Type:\*\*' "$N1_HOME/memory/$ID/ticket.md"`}
>
> INSTRUCTIONS:
> - DO NOT re-scan the project structure, conventions, or architecture — the snapshot covers this.
> - DO focus on ticket-specific analysis: affected files/modules, blast radius, integration points, risks, complexity tier.
> - You MAY read specific files referenced in the Subsystem Registry for deeper understanding.
> - You MAY do ticket-specific web research if the ticket touches a domain not covered by the Industry Standards section.
> - If you notice the snapshot appears incorrect or outdated, flag it with: SNAPSHOT_DRIFT: <description>
>
> OUTPUT FORMAT:
> Use `## [TICKET] <section name>` for all sections.
> Emit signals as the final line as usual.
>
> Directive: "Scratch-artifact policy: write any throwaway benchmark or investigative/spike test under `$N1_HOME/memory/<ID>/benchmarks/` or `$N1_HOME/memory/<ID>/tests/` — never into the repo's test suite."

Include investigation-mode and error-tracking-enrichment directives same as cold/stale path (these are ticket-specific and always apply).

**Error-tracking enrichment (error tracker mode only):**

If the task originated from an error tracker URL (ticket.md Source contains an error tracker reference):
1. Read `$N1_HOME/config.json` → `errorTracking.mcp` and `errorTracking.operations`
2. Append the error-tracking search MCP tool to the agent's tool grant: add `mcp__<errorTracking.mcp>__<errorTracking.operations.searchIssues>` to the `tools` list for this spawn (e.g., `Read, Grep, Glob, Bash, WebSearch, WebFetch, mcp__sentry__search_sentry_issues`)
3. Add directive: "Search the error-tracking system for related issues using `mcp__<errorTracking.mcp>__<errorTracking.operations.searchIssues>`. Look for issues with the same exception type, affected file, or error message. Include findings in the Related Error-Tracker Issues section of your output."

After the agent returns:

**Post-processing — snapshot extraction (cold/stale + cache enabled):**

When CACHE_STATE is `cold` or `stale` AND `$CACHE_ENABLED` is `true`:
1. Split agent output by `## [PROJECT]` and `## [TICKET]` markers.
2. Collect all `## [PROJECT]` sections into a single string, stripping the `[PROJECT] ` prefix from each heading (so `## [PROJECT] Architecture` becomes `## Architecture`).
3. If `## [PROJECT]` sections were found, write the project content to the snapshot:
   ```bash
   GIT_SHA=$(git rev-parse HEAD)
   n1_snapshot_write "$SNAPSHOT_PATH" "$PROJECT_CONTENT" "$GIT_SHA"
   ```
4. Collect all `## [TICKET]` sections, strip the `[TICKET] ` prefix from each heading.
5. Write the ticket content to `$N1_HOME/memory/<ID>/analysis.md`.
6. If no `## [PROJECT]` sections were found in agent output: write the FULL agent output to `$N1_HOME/memory/<ID>/analysis.md` (fail-open — no snapshot created, next ticket retries cold start).

**Post-processing — warm path (fresh):**

When CACHE_STATE is `fresh`:
1. Strip `[TICKET] ` prefix from all `## [TICKET]` headings in agent output.
2. Write the result to `$N1_HOME/memory/<ID>/analysis.md`.
3. Check for `SNAPSHOT_DRIFT:` markers in agent output:
   ```bash
   DRIFT=$(echo "$AGENT_OUTPUT" | grep -m1 '^SNAPSHOT_DRIFT:')
   if [ -n "$DRIFT" ]; then
       # Log drift note in overview.md Key Decisions section
       # Force regeneration on next ticket by deleting snapshot
       rm -f "$SNAPSHOT_PATH"
   fi
   ```

**Post-processing — default (cold + cache disabled):**

When CACHE_STATE is `cold` AND `$CACHE_ENABLED` is not `true`:
- Write agent output directly to `$N1_HOME/memory/<ID>/analysis.md` (no prefix stripping — no `[PROJECT]`/`[TICKET]` markers will be present)

- Update overview: `[x] Analysis`, set `step: analysis`

**Parse and persist tier revision (if any):**
1. Extract `tier:` from the written analysis file. Use case-insensitive regex: `^tier:\s*(simple|standard|complex)` against `$N1_HOME/memory/$ID/analysis.md`.
2. If a valid tier is found:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
   CURRENT_TIER=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier")
   if [ "$NEW_TIER" != "$CURRENT_TIER" ]; then
       n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier" "$NEW_TIER"
       echo "Tier updated to '$NEW_TIER' (was '$CURRENT_TIER')"
   else
       echo "Tier confirmed as '$CURRENT_TIER'"
   fi
   ```
3. If no valid tier found in architect output, leave the existing tier unchanged (analyst's assessment stands).

**Extract and persist signals:**
Parse the written analysis file for a line starting with `n1:signals `:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
SIGNAL_LINE=$(grep -m1 '^n1:signals ' "$N1_HOME/memory/$ID/analysis.md")
if [ -n "$SIGNAL_LINE" ]; then
    PAIRS=$(echo "$SIGNAL_LINE" | sed 's/^n1:signals //')
    n1_write_signals "$N1_HOME/memory/$ID/analysis.md" $PAIRS
fi
```

**Compact analysis memory (non-investigation only):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/memory.sh"
TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
if [ "$TYPE" != "investigation" ]; then
    n1_compact_memory "$N1_HOME/memory/$ID/analysis.md" "conclusions,affected files,blast radius,risks,industry standards,bug investigation,tier"
fi
```

**Step result (step mode):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_emit_step_result "analysis" "pass" "brainstorm" "null"
```

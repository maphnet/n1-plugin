
**Spawn agent:** solution-architect

Resolve model for `solution-architect` with context `analysis`.

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

**Error-tracking enrichment (error tracker mode only):**

If the task originated from an error tracker URL (ticket.md Source contains an error tracker reference):
1. Read `$N1_HOME/config.json` → `errorTracking.mcp` and `errorTracking.operations`
2. Append the error-tracking search MCP tool to the agent's tool grant: add `mcp__<errorTracking.mcp>__<errorTracking.operations.searchIssues>` to the `tools` list for this spawn (e.g., `Read, Grep, Glob, Bash, WebSearch, WebFetch, mcp__sentry__search_sentry_issues`)
3. Add directive: "Search the error-tracking system for related issues using `mcp__<errorTracking.mcp>__<errorTracking.operations.searchIssues>`. Look for issues with the same exception type, affected file, or error message. Include findings in the Related Error-Tracker Issues section of your output."

After the agent returns:
- Write its output to `$N1_HOME/memory/<ID>/analysis.md`
- Update overview: `[x] Analysis`, set `step: analysis`

**Parse and persist tier revision (if any):**
1. Extract `tier:` from the solution-architect's output text. Use case-insensitive regex: `^tier:\s*(simple|standard|complex)` against the output.
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
Parse the solution-architect's output for a line starting with `n1:signals `:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
SIGNAL_LINE=$(echo "$AGENT_OUTPUT" | grep -m1 '^n1:signals ')
if [ -n "$SIGNAL_LINE" ]; then
    PAIRS=$(echo "$SIGNAL_LINE" | sed 's/^n1:signals //')
    n1_write_signals "$N1_HOME/memory/$ID/analysis.md" $PAIRS
fi
```



**Update tracker status to In Progress.** Before analysis begins, move the ticket to the configured In Progress status:
- **Gate:** Skip if `tracker.mcp` is not configured, `tracker.statuses.inProgress` is absent, or `tracker.operations.moveStatus` is absent.
- Jira: first call `mcp__<tracker.mcp>__<tracker.operations.getTransitions>` with `cloudId`, `issueIdOrKey: <ID>` to find the transition matching `tracker.statuses.inProgress`, then call `mcp__<tracker.mcp>__<tracker.operations.moveStatus>` with `cloudId`, `issueIdOrKey: <ID>`, `transitionId: <matched id>`.
- YouTrack: call `mcp__<tracker.mcp>__<tracker.operations.moveStatus>` with `issueId: <ID>`, `state: <tracker.statuses.inProgress>`.
- If the call fails, emit a warning and continue — do not block analysis on a status update failure.

**Cache check:**

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/cache.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/rules.sh"

CACHE_ENABLED=$(n1_config_val ".analysisCache.enabled" "$N1_HOME/config.json")
CACHE_ENABLED="${CACHE_ENABLED:-true}"
SNAPSHOT_PATH=$(n1_snapshot_path "$N1_HOME")
CACHE_STATE="cold"

if [ "$CACHE_ENABLED" = "true" ]; then
    CACHE_STATE=$(n1_snapshot_check_freshness "$SNAPSHOT_PATH" "$N1_HOME/config.json")
fi

```

Run SKILL.md § Rules Injection with `agent_name=solution-architect`, no `changed_files_source` — analysis runs before implementation; CHANGED_FILES will be empty, matching rules by agent name only.

The `CACHE_STATE` variable (`cold`, `stale`, or `fresh`) determines the dispatch path below. When `analysisCache.enabled` is `false`, `CACHE_STATE` stays `cold` and the step always runs full analysis. When `analysisCache` is absent from config, the cache defaults to enabled.

**Spawn agent:** solution-architect

Resolve model for `solution-architect` with context `analysis`.

**Shared spawn directives (apply to both cold/stale and fresh paths):**

- **Type:** Extract via `grep -m1 -i '^\*\*Type:\*\*' "$N1_HOME/memory/$ID/ticket.md"` and pass the value explicitly so the architect knows whether to perform bug investigation.
- **Scratch-artifact policy:** "Write any throwaway benchmark or investigative/spike test (one that answers a current question rather than verifying committed code) under `$N1_HOME/memory/<ID>/benchmarks/` or `$N1_HOME/memory/<ID>/tests/` (both gitignored; create the directory if needed) — never into the repo's test suite. Tests that verify the implementation still go into the repo as usual. When unsure, default to scratch."
- **Unknown classification directive:** "When you encounter a constraint, assumption, or ambiguity not covered by the ticket description, classify it before acting:

    - **A -- blocking:** Only a human can answer -- business intent, stakeholder preference, requirement ambiguity that cannot be resolved from codebase, documentation, or web search. Mark with `<!-- n1:unknown: <brief description> -->` inline.
    - **B -- significant:** Resolvable with effort. You MUST attempt resolution in this order before escalating to A:
      1. Codebase search (Read/Grep/Glob) — if you find evidence, resolve inline: `<!-- n1:resolved: <question> → <answer (file:line evidence)> -->`
      2. Web search (WebSearch) for docs, best practices, API references, changelogs — if you find the answer, resolve inline: `<!-- n1:web-resolved: <question> → <answer (source URL)> -->`
      3. Command prescription — when the answer is observable on a host the agent cannot reach (e.g., `cat /etc/resolv.conf`, `apt list --installed`), resolve by noting the command and a reasonable default: `<!-- n1:cmd-prescribed: <question> → <command> (default: <value>) -->`
      If all three fail, escalate to A.
    - **C -- convention:** Answerable from project patterns or standard practice. Resolve silently -- no marker needed.

    Default to B. Only classify as A after a genuine resolution attempt fails across all three channels. The goal: the user should never be asked a question you could have answered by reading the code, searching the web, or prescribing a lookup command."
- **Investigation mode directive (when `TYPE` is `"investigation"`, read from overview.md frontmatter via `n1_read_type "$N1_HOME/memory/$ID/overview.md"`):** "This is an investigation task -- analyze the codebase to answer the question posed in the ticket, not to plan implementation changes. Focus on findings, evidence, and recommendations rather than files-to-change and blast radius. Your analysis will feed directly into an investigation deliverable, not a plan."
- **Rules:** If `$RULES_BLOCK` is non-empty, append it after the directives above.

**Shared output-path directives (apply to all paths):**

<!-- #44657: Claude Code harness may refuse Write tool calls targeting files named
     "analysis.md" (blocked-filename family). The agent must write analysis.md via
     Bash (heredoc/cat redirect) rather than the Write tool. Do not simplify back
     to Write without verifying #44657 is resolved in the target harness version. -->

- Output-path directive: "Write your full analysis report to `$N1_HOME/memory/<ID>/analysis.md` yourself using your Bash tool (cat heredoc redirect — do NOT use the Write tool for this file, ref #44657). Write ONLY to the provided paths under `$N1_HOME`. Return to the orchestrator ONLY this compact block: your `n1:signals` line, `tier:` line, optional `SNAPSHOT_DRIFT:` line, and a 3-10 line summary. Do NOT return the full analysis report — it is in the file you wrote."

**Prompt construction depends on CACHE_STATE:**

**When CACHE_STATE is `cold` or `stale`:**

Spawn the solution-architect agent with:
- The path to the ticket file — instruct the agent: "Read `$N1_HOME/memory/<ID>/ticket.md` yourself (you have Read); it is the scope to analyze. Its content is NOT inlined here."
- Directive: "Research relevant industry standards, best practices, and practitioner experience per agents/research-standards.md and include the cited Industry Standards & Best Practices section."
- All shared spawn directives above.
- All shared output-path directives above.
- **When `CACHE_ENABLED` is `true`**, also append this SNAPSHOT PERSISTENCE REQUIREMENT at end of prompt:

  > Separate your findings into two categories:
  > `## [PROJECT] <section name>` — for project-level facts (architecture, conventions, patterns, stack, industry standards, subsystem registry, key files).
  > Include `<!-- provenance: <files/globs that informed this section> -->` after each [PROJECT] section heading.
  > `## [TICKET] <section name>` — for ticket-specific analysis (affected files, blast radius, risks, integration points, tier assessment).
  >
  > When writing to analysis.md, include ONLY the [TICKET] sections (strip the `[TICKET] ` prefix from headings).
  > Persist the [PROJECT] sections as a snapshot by running this via Bash:
  > ```bash
  > source "<CLAUDE_PLUGIN_ROOT>/lib/cache.sh"
  > n1_snapshot_write "<SNAPSHOT_PATH>" "$PROJECT_CONTENT" "$(git rev-parse HEAD)"
  > ```
  > Where `$PROJECT_CONTENT` is all [PROJECT] sections concatenated with the `[PROJECT] ` prefix stripped from headings (so `## [PROJECT] Architecture` becomes `## Architecture`).
  > Snapshot path: `<SNAPSHOT_PATH>` (substitute the actual resolved path).

  Substitute `<CLAUDE_PLUGIN_ROOT>` and `<SNAPSHOT_PATH>` with their actual resolved values in the prompt.

- **When `CACHE_ENABLED` is `false`**, no [PROJECT]/[TICKET] separation needed — the agent writes its full report directly to analysis.md.

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
> Type: {TYPE from shared spawn directives}
>
> INSTRUCTIONS:
> - DO NOT re-scan the project structure, conventions, or architecture — the snapshot covers this.
> - DO focus on ticket-specific analysis: affected files/modules, blast radius, integration points, risks, complexity tier.
> - You MAY read specific files referenced in the Subsystem Registry for deeper understanding.
> - You MAY do ticket-specific web research if the ticket touches a domain not covered by the Industry Standards section.
> - Where the snapshot describes current practice and a rule prescribes required practice, the rule wins.
>
> {$RULES_BLOCK from shared spawn directives, if non-empty, otherwise omit}
> - If you notice the snapshot appears incorrect or outdated, flag it with: SNAPSHOT_DRIFT: <description>
>
> OUTPUT FORMAT:
> Write only [TICKET]-scoped content to analysis.md (no [TICKET] prefix in headings — just the section names).
> Emit signals and summary as the compact return per your Output Contract.
>
> {Scratch-artifact policy from shared spawn directives}

Also apply the investigation-mode directive from shared spawn directives (ticket-specific, always applies).
Also apply all shared output-path directives.

**Observability enrichment:**

If `observability` is configured (not null) in `$N1_HOME/config.json`:

1. Read `observability` from config. If null/absent or `observability.providers` is empty, skip enrichment entirely (requires jq — skip enrichment entirely without jq).
2. Read `observability.default` from config.
3. Collect active providers: all entries in `observability.providers` where `env` is absent (global) OR `env` matches `observability.default`. If `default` is null/empty, only global providers (no `env` field) activate.
4. If no providers are active (e.g., `default` is set but no providers match, and no global providers exist), skip enrichment. If no `default` and all providers have `env`, skip enrichment and log a warning in the SA prompt: "Observability is configured but no providers are active (all have env tags and no default is set)."
5. Build a directive block listing each active provider by name with its `instructions` text and append it to the SA prompt:
   ```
   The following observability sources are available for this project:

   - **<provider-name>**: <instructions text>
   - **<provider-name>**: <instructions text>
   ```
6. If the task originated from an error tracker URL, append directive: "Query all available observability sources for context around this error. Search for related errors, query logs, and check traces as relevant. Include findings in an `### Observability Findings` section of your output."
7. If the task type is `bug` (not from error tracker), append directive: "Query the available observability sources for errors, logs, and traces related to this bug. Include findings in an `### Observability Findings` section of your output."
8. For all other task types, append directive: "Observability sources are available. If relevant to understanding the system behavior for this task, query them for context. Include any relevant findings in an `### Observability Findings` section."

After the agent returns:

**Post-return verification — analysis.md (all paths):**

The agent wrote `$N1_HOME/memory/<ID>/analysis.md` itself. Verify it:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" analysis.md
```
If missing/empty (agent failed to write), **re-prompt the agent once** with: "analysis.md was not written. Write your full analysis report to `$N1_HOME/memory/<ID>/analysis.md` now using Bash (cat heredoc redirect, ref #44657)."

After re-prompt, verify again:
```bash
n1_verify_dependencies "$N1_HOME/memory/$ID" analysis.md
```
If still missing/empty: write the agent's returned summary to `$N1_HOME/memory/<ID>/analysis.md` as a degraded fallback (via Bash cat redirect, ref #44657), and record the degradation in overview's `## Key Decisions`: "Analysis: agent failed to write analysis.md; using returned summary as fallback."

**Post-return verification — snapshot (cold/stale + cache enabled):**

When CACHE_STATE is `cold` or `stale` AND `$CACHE_ENABLED` is `true`:
```bash
if [ ! -f "$SNAPSHOT_PATH" ] || [ ! -s "$SNAPSHOT_PATH" ]; then
    # Record snapshot-persist failure — cache stays cold, next run re-analyzes.
    # Do NOT fail the pipeline for this.
    echo "Snapshot persistence failed — cache remains cold."
    # Log in overview's ## Key Decisions
fi
```

**Post-return — SNAPSHOT_DRIFT handling (fresh path):**

When CACHE_STATE is `fresh`, check the agent's returned text for `SNAPSHOT_DRIFT:`:
```bash
DRIFT=$(echo "$AGENT_OUTPUT" | grep -m1 '^SNAPSHOT_DRIFT:')
if [ -n "$DRIFT" ]; then
    # Log drift note in overview.md Key Decisions section
    # Force regeneration on next ticket by deleting snapshot
    rm -f "$SNAPSHOT_PATH"
fi
```

- Update overview: `[x] Analysis`, set `step: analysis`

**Parse and persist context block:**

Extract the `context:` block from the SA's compact return:
```bash
CONTEXT_BLOCK=$(echo "$AGENT_OUTPUT" | sed -n '/^context: |$/,/^[^ ]/{/^context: |$/d;/^[^ ]/d;s/^  //;p}')
```

If `CONTEXT_BLOCK` is non-empty:

1. Write the `## Context` section to overview.md, between the `# <ID>: <Title>` heading and `## Progress`:
   - Read overview.md
   - Insert after the `# <ID>:` heading line and before `## Progress`:
     ```markdown
     ## Context
     <CONTEXT_BLOCK content>

     ```
   - Write overview.md back

2. Persist ticket URL to overview.md frontmatter (if available from the ticket step):
   ```bash
   if [ -n "$TICKET_URL" ]; then
       source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
       n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "ticket_url" "$TICKET_URL"
   fi
   ```

3. Read signals for the metadata line:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
   FILES_CHANGED=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "files_changed")
   BLAST_RADIUS=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "blast_radius")
   TIER=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier")
   ```

4. Print the orientation block:
   ```
   ── <ID> ────────────────────────────────────────
   <TITLE>

   <CONTEXT_BLOCK>

   Tier: <TIER> · Files: ~<FILES_CHANGED> · Blast radius: <BLAST_RADIUS>
   <TICKET_URL — omit this line entirely if empty>
   ─────────────────────────────────────────────────
   ```

If `CONTEXT_BLOCK` is empty (SA failed to emit it), log in overview's `## Key Decisions`: "Context block: SA did not emit context: block — orientation block skipped." Do not fail the pipeline.

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
Parse the solution-architect's return for a line starting with `n1:signals `:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
SIGNAL_LINE=$(echo "$AGENT_OUTPUT" | grep -m1 '^n1:signals ')
if [ -n "$SIGNAL_LINE" ]; then
    PAIRS=$(echo "$SIGNAL_LINE" | sed 's/^n1:signals //')
    n1_write_signals "$N1_HOME/memory/$ID/analysis.md" $PAIRS
fi

# Self-resolved unknowns (investigation mode)
SELF_RESOLVED=$(grep -c '<!-- n1:resolved:' "$N1_HOME/memory/$ID/analysis.md" 2>/dev/null || echo "0")
if [ "$SELF_RESOLVED" -gt 0 ]; then
    n1_write_signals "$N1_HOME/memory/$ID/analysis.md" "self_resolved=$SELF_RESOLVED"
fi
```

If `SELF_RESOLVED` > 0, append a decision ledger row to `$N1_HOME/memory/<ID>/overview.md` per `skills/n1-start/ledger.md`:

| analysis | scope | B | [auto] | {SELF_RESOLVED} unknowns answerable from codebase | Self-resolved via Read/Grep/Glob | — | B/C tier classification -- see `<!-- n1:resolved: -->` markers in analysis.md |

**Compact analysis memory (non-investigation only):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/memory.sh"
TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
if [ "$TYPE" != "investigation" ]; then
    n1_compact_memory "$N1_HOME/memory/$ID/analysis.md" "conclusions,affected files,blast radius,risks,industry standards,bug investigation,tier"
fi
```

**Phase 3 — Unknown Q&A (all task types):**

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
```

Run this phase for all task types (not just investigation).

Extract unknowns from the analysis output:
```bash
UNKNOWNS=$(grep -oE '<!-- n1:unknown: [^>]+ -->' "$N1_HOME/memory/$ID/analysis.md" | sed 's/<!-- n1:unknown: //;s/ -->//')
UNKNOWN_COUNT=$(echo "$UNKNOWNS" | grep -c '.' 2>/dev/null || echo "0")
```

If `UNKNOWN_COUNT` is 0, skip the rest of this phase.

**Problem preamble:** Before presenting the unknowns, compose a 1-2 sentence summary: extract the title from the `# <ID>: <Title>` heading in `$N1_HOME/memory/<ID>/overview.md` and the first non-blank line under `### Core Ask` in `$N1_HOME/memory/<ID>/ticket.md`. Format: `"{Title}: {Core Ask (≤1 sentence)}."` — call this `PREAMBLE`. If either part is unavailable omit that part (keep the other); if both are missing, `PREAMBLE` is empty. **Bug root cause (bug tickets only):** Source `"${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"` first, then: if `$N1_HOME/memory/<ID>/analysis.md` contains a `### Bug Investigation` section AND the `has_bug_root_cause` signal is strictly `true` (read via `n1_read_signal`), prepend one sentence summarizing the root cause: `"Root cause: {root cause}. "` — prepend this to `PREAMBLE`. If the signal is `false`, absent, or any other value, omit the root cause line entirely — do not fall back to parsing the section body.

Present each unknown to the user one at a time, prefixing the opening message with `PREAMBLE` (omit if empty):

```
{PREAMBLE} During analysis, I found {UNKNOWN_COUNT} item(s) not covered by the ticket:

1. <first unknown>

Can you clarify this? (type your answer, or "skip" to leave it unresolved)
```

After collecting all answers, append a `### Clarifications` section to `analysis.md`:

```markdown
### Clarifications
- **Q:** <unknown text>
  **A:** <user's answer or "Unresolved — deferred">
```


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

**Lite-Analysis Gate:**

A simple, well-described `task` or `chore` does not need the full architect treatment. Evaluate this gate before building any of the expensive prompt context below.

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"

TIER=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier")
TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
DESC_QUALITY=$(n1_read_signal "$N1_HOME/memory/$ID/ticket.md" "description_quality")

LITE_MODE=false
if [ "$TIER" = "simple" ] \
   && { [ "$DESC_QUALITY" = "adequate" ] || [ "$DESC_QUALITY" = "weak" ]; } \
   && { [ "$TYPE" = "task" ] || [ "$TYPE" = "chore" ]; }; then
    LITE_MODE=true
fi
echo "LITE_MODE=$LITE_MODE (tier=$TIER type=$TYPE quality=$DESC_QUALITY)"

n1_record_decision lite-analysis-gate "$LITE_MODE" \
  '{"all":[{"frontmatter":"tier","eq":"simple"},{"signal":"ticket.description_quality","neq":"empty"},{"signal":"ticket.description_quality","neq":"skeletal"},{"any":[{"frontmatter":"type","eq":"task"},{"frontmatter":"type","eq":"chore"}]}]}' \
  "tier=$TIER" "type=$TYPE" "quality=$DESC_QUALITY"
```

`LITE_MODE` controls the scope of the analysis, never its output contract. The solution-architect still returns the full `n1:signals` line, `tier:` line, and `context:` block in lite mode — every downstream gate depends on them.

The Bash predicate uses an explicit `adequate`/`weak` allowlist; the recorded condition JSON expresses the same set as paired `neq` guards (`n1_eval_signal_gate` has no `in` operator) plus a nested `any` for the type allowlist. The two agree on every reachable value, including an absent `description_quality` signal, which both treat as not-lite.

When `LITE_MODE` is `true`, log to overview's `## Key Decisions`: "Lite-analysis gate: reduced-scope analysis (tier=$TIER, type=$TYPE, quality=$DESC_QUALITY)."

**Related projects context:**

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/related.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"

# Re-derived: LITE_MODE was set in a different Bash invocation.
TIER=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier")
TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
DESC_QUALITY=$(n1_read_signal "$N1_HOME/memory/$ID/ticket.md" "description_quality")
LITE_MODE=false
if [ "$TIER" = "simple" ] \
   && { [ "$DESC_QUALITY" = "adequate" ] || [ "$DESC_QUALITY" = "weak" ]; } \
   && { [ "$TYPE" = "task" ] || [ "$TYPE" = "chore" ]; }; then
    LITE_MODE=true
fi

RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json")
RELATED_CONTEXT=""
PROJECT_MAP_PATH=$(n1_project_map_path "$N1_HOME")

if [ "$RELATED_ENABLED" = "true" ] && [ "$LITE_MODE" != "true" ]; then
    MAX_AGE=$(n1_config_val ".relatedProjects.maxSnapshotAge" "$N1_HOME/config.json")
    MAX_AGE="${MAX_AGE:-72h}"

    RELATED_LINES=""
    while IFS=$'\t' read -r slug reason repo_path; do
        [ -z "$slug" ] && continue
        peer_map=$(n1_related_project_map "$slug")
        map_state=$(n1_project_map_check_freshness "$peer_map" "$MAX_AGE") || true

        RELATED_LINES="${RELATED_LINES}
- **${slug}** (${reason}): map=${map_state}, mapPath=${peer_map}, repoPath=${repo_path}"
    done < <(n1_related_projects "$N1_HOME/config.json")

    if [ -n "$RELATED_LINES" ]; then
        RELATED_CONTEXT="
RELATED PROJECTS (from N1 config — explore when relevant to the current task):
${RELATED_LINES}

For each relevant project:
1. If map is 'fresh', read the map file at mapPath for navigation context.
2. If map is 'stale' or 'cold', generate the map yourself: scan the repo at repoPath (directory structure, CLAUDE.md, exports, API surface), run \`mkdir -p \"\$(dirname <mapPath>)\"\` first (the peer cache directory may not exist), then write to mapPath using Bash. The peer map MUST carry the same frontmatter as a local project map (\`schema_version: 1\`, \`generated_at\`, \`git_sha\`, \`git_sha_short\`, \`generator: solution-architect\`) — without it the map is treated as stale and regenerated on every run. Report each map you generate in your return text as: \`XREPO_MAP_GENERATED: <slug>\`.
3. Use repoPath + relative paths from the map to read specific files.
4. Include findings in a '### Cross-Repo Context' section of your analysis, one bullet per project in the form '- <slug>: <findings>'."
    fi
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
- **Lite scope directive (when `LITE_MODE` is `true`):** "This is a LITE analysis. The ticket is pre-classified as a simple `task` or `chore` with a usable description. Scope your work accordingly:

    - Read only the files the ticket actually touches, plus their direct callers. Do NOT survey the project structure, module layout, or conventions beyond what the ticket needs.
    - Do NOT research industry standards or best practices, and do NOT use WebSearch or WebFetch.
    - Do NOT explore other repositories.
    - Do NOT query observability sources.
    - Keep `analysis.md` to 300 words or fewer. Omit any section that would be N/A at this size — no Industry Standards section, no Cross-Repo Context section.
    - Your Output Contract is UNCHANGED: still return the complete `n1:signals` line, the `tier:` line, and the `context:` block exactly as your agent definition specifies. Every downstream step reads them."
- **Lite escape-hatch directive (when `LITE_MODE` is `true`):** "If, while reading the code, the task proves materially more than simple — it touches 3 or more files, spans more than one module, touches authentication, authorization, cryptography, secrets, or input validation, changes a public API, or changes a schema or wire contract — do NOT constrain yourself to the lite budget. Analyze it properly, emit the corrected `tier`, `blast_radius`, and `security_relevant` signals, and add one line to your return: `LITE_ESCALATED: <one-sentence reason>`."
- **Rules:** If `$RULES_BLOCK` is non-empty, append it after the directives above.

**Shared output-path directives (apply to all paths):**

<!-- #44657: Claude Code harness may refuse Write tool calls targeting files named
     "analysis.md" (blocked-filename family). The agent must write analysis.md via
     Bash (heredoc/cat redirect) rather than the Write tool. Do not simplify back
     to Write without verifying #44657 is resolved in the target harness version. -->

- Output-path directive: "Write your full analysis report to `$N1_HOME/memory/<ID>/analysis.md` yourself using your Bash tool (cat heredoc redirect — do NOT use the Write tool for this file, ref #44657). Write ONLY to the provided paths under `$N1_HOME`. Return to the orchestrator ONLY this compact block: your `n1:signals` line, `tier:` line, optional `SNAPSHOT_DRIFT:` line, and a 3-10 line summary. Do NOT return the full analysis report — it is in the file you wrote."
- Project map output-path directive (when `CACHE_STATE` is `cold` or `stale` AND `CACHE_ENABLED` is `true` AND `LITE_MODE` is `false`): "Also write a project map (structural index) for THIS project to `<PROJECT_MAP_PATH>` using Bash (cat heredoc redirect). Format: frontmatter (schema_version: 1, generated_at, git_sha, git_sha_short, generator: solution-architect) + sections: ## Modules, ## API Surface, ## Exports & Shared Types, ## Integration Points, ## Key Files. Target 300-500 tokens. This is a navigation index, not an architecture document."

**Prompt construction depends on CACHE_STATE:**

**When CACHE_STATE is `cold` or `stale`:**

Spawn the solution-architect agent with:
- The path to the ticket file — instruct the agent: "Read `$N1_HOME/memory/<ID>/ticket.md` yourself (you have Read); it is the scope to analyze. Its content is NOT inlined here."
- **When `LITE_MODE` is `false`:** Directive: "Research relevant industry standards, best practices, and practitioner experience per agents/research-standards.md and include the cited Industry Standards & Best Practices section." Omit this directive entirely when `LITE_MODE` is `true`.
- All shared spawn directives above.
- All shared output-path directives above.
- **When `CACHE_ENABLED` is `true` AND `LITE_MODE` is `false`**, also append this SNAPSHOT PERSISTENCE REQUIREMENT at end of prompt:

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
- **When `LITE_MODE` is `true`**, no [PROJECT]/[TICKET] separation either — the agent writes its (short) report directly to analysis.md and persists no snapshot. The cache stays cold; the next standard-tier ticket warms it.

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

Skip this entire block when `LITE_MODE` is `true` — only `task` and `chore` tickets reach lite mode, and observability pays off on bugs and error-tracker tickets, which never do.

Otherwise, if `observability` is configured (not null) in `$N1_HOME/config.json`:

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

If `$RELATED_CONTEXT` is non-empty, append it to the SA prompt after the observability enrichment block.

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

**Post-return — LITE_ESCALATED handling (lite path):**

When `LITE_MODE` is `true`, check the agent's returned text for the escape hatch:

```bash
ESCALATED=$(echo "$AGENT_OUTPUT" | grep -m1 '^LITE_ESCALATED:')
if [ -n "$ESCALATED" ]; then
    echo "$ESCALATED"
fi
```

If non-empty, log it to overview's `## Key Decisions`: "Lite analysis escalated: <reason from the LITE_ESCALATED line> — corrected signals applied, analysis not re-run."

Do NOT re-run analysis. The architect's corrected `tier`, `blast_radius`, and `security_relevant` values flow through the tier-revision and signal-extraction blocks below, and the escalation triggers in `pipeline.json` react on their own: `security_relevant == true` escalates review to frontier, `blast_radius == high` escalates implementation to frontier.

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

**Post-return verification — project map (cold/stale + cache enabled):**

```bash
if [ "$CACHE_STATE" != "fresh" ] && [ "$CACHE_ENABLED" = "true" ] && [ "$LITE_MODE" != "true" ]; then
    if [ ! -f "$PROJECT_MAP_PATH" ] || [ ! -s "$PROJECT_MAP_PATH" ]; then
        echo "Project map persistence failed — map will be generated on next run."
    fi
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

1. Replace the `## Context` section in overview.md with the real content. The overview template already has `## Context` with placeholder text "(pending — written after analysis)" — replace that placeholder, do not insert a second section. Read overview.md, replace the lines between `## Context` and `## Progress` (keeping both headings, replacing only the body) with the `CONTEXT_BLOCK` text, then write it back.

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
SELF_RESOLVED=$(grep -c '<!-- n1:resolved:' "$N1_HOME/memory/$ID/analysis.md" 2>/dev/null | head -1)
SELF_RESOLVED="${SELF_RESOLVED:-0}"
if [ "$SELF_RESOLVED" -gt 0 ]; then
    n1_write_signals "$N1_HOME/memory/$ID/analysis.md" "self_resolved=$SELF_RESOLVED"
fi
```

**Parse cross-repo signals:**

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/related.sh"

CROSS_REPO_EXPLORED=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "cross_repo_explored")

# Handle XREPO_SUGGEST lines (runtime discovery during analysis)
XREPO_PENDING_FILE="$N1_HOME/memory/$ID/xrepo-pending.tsv"
rm -f "$XREPO_PENDING_FILE"
XREPO_SUGGESTS=$(echo "$AGENT_OUTPUT" | grep '^XREPO_SUGGEST: ' || true)
if [ -n "$XREPO_SUGGESTS" ]; then
    autonomy_mode=$(n1_autonomy_val "mechanicalPrompts")

    while IFS= read -r line; do
        xr_slug=$(echo "$line" | sed 's/^XREPO_SUGGEST: //' | awk '{print $1}')
        xr_reason=$(echo "$line" | sed 's/^XREPO_SUGGEST: [^ ]* //')
        [ -z "$xr_slug" ] && continue
        # Ledger cells must not contain pipes and must stay short (ledger.md Rules 4-5)
        xr_reason_cell=$(printf '%s' "$xr_reason" | tr '|' '/' | cut -c1-80)

        if [ "$autonomy_mode" = "auto" ]; then
            n1_related_add "$N1_HOME/config.json" "$xr_slug" "$xr_reason" "auto"
            if ! grep -q '^## Decision Ledger' "$N1_HOME/memory/$ID/overview.md" 2>/dev/null; then
                printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$N1_HOME/memory/$ID/overview.md"
            fi
            printf '| analysis | scope | B | [auto] | New integration with %s detected by SA | Added to related projects | — | XREPO_SUGGEST: %s | --- |\n' "$xr_slug" "$xr_reason_cell" >> "$N1_HOME/memory/$ID/overview.md"
        else
            # Persist for the interactive prompt below — the prompt and its
            # response handler run in LATER Bash invocations, so shell variables
            # do not survive.
            printf '%s\t%s\n' "$xr_slug" "$xr_reason" >> "$XREPO_PENDING_FILE"
        fi
    done < <(printf '%s\n' "$XREPO_SUGGESTS")
fi

if [ -s "$XREPO_PENDING_FILE" ]; then
    printf '\nThe solution-architect discovered cross-repo integrations that are not registered:\n'
    awk -F'\t' '{printf "- %s: %s\n", $1, $2}' "$XREPO_PENDING_FILE"
    printf '\nAdd to related projects? (yes/no/select)\n'
fi
```

**Interactive response handling (non-auto path):**

When the pending list was presented, handle the user's response to "Add to related projects? (yes/no/select)". Re-read `$XREPO_PENDING_FILE` — the response arrives in a separate Bash invocation:

- **"yes"** — add every pending slug:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/related.sh"
XREPO_PENDING_FILE="$N1_HOME/memory/$ID/xrepo-pending.tsv"
while IFS=$'\t' read -r xr_slug xr_reason; do
    [ -z "$xr_slug" ] && continue
    n1_related_add "$N1_HOME/config.json" "$xr_slug" "$xr_reason" "manual"
    xr_reason_cell=$(printf '%s' "$xr_reason" | tr '|' '/' | cut -c1-80)
    if ! grep -q '^## Decision Ledger' "$N1_HOME/memory/$ID/overview.md" 2>/dev/null; then
        printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$N1_HOME/memory/$ID/overview.md"
    fi
    printf '| analysis | scope | B | [asked] | New integration with %s detected by SA | Added to related projects | Not added | User approved: %s | codebase |\n' "$xr_slug" "$xr_reason_cell" >> "$N1_HOME/memory/$ID/overview.md"
done < "$XREPO_PENDING_FILE"
```

- **"select"** — present each pending slug individually; apply `n1_related_add` + the `[asked]` ledger row above only for the approved ones; skip the rest (no ledger row for skipped).
- **"no"** — add nothing; append one `[asked]` ledger row per pending slug recording the decline (`Chosen` = `Not added`, `Alternatives` = `Added to related projects`, `Reason` = `User declined on prompt`).

**Headless:** under `N1_HEADLESS=1`, do not prompt — apply SKILL.md § Headless Guard (record the pending slugs as an escalation and continue).

**Cross-repo telemetry metadata (if telemetry enabled AND `relatedProjects.enabled` is `true`):**

This block owns the step-2 (`analysis`) end event when cross-repo awareness is on — see the Telemetry Step Markers table in SKILL.md. When `relatedProjects.enabled` is `false`, skip the whole block; the orchestrator emits the standard end event per the table.

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json")

if [ "$RELATED_ENABLED" = "true" ]; then
    # Re-derived here: the values above were set in a different Bash invocation.
    CROSS_REPO_EXPLORED=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "cross_repo_explored")
    XREPO_SUGGESTS=$(echo "$AGENT_OUTPUT" | grep '^XREPO_SUGGEST: ' || true)

    # Explored projects — scoped to the ### Cross-Repo Context section, whose
    # bullets are '- <slug>: <findings>' (portable BRE/ERE, no grep -P).
    XREPO_PROJECTS=""
    if [ "$CROSS_REPO_EXPLORED" = "true" ]; then
        XREPO_PROJECTS=$(sed -n '/^### Cross-Repo Context/,/^### /p' "$N1_HOME/memory/$ID/analysis.md" \
            | grep -oE '^- [A-Za-z0-9._-]+:' | sed 's/^- //; s/:$//' | tr '\n' ',' | sed 's/,$//')
    fi

    # On-demand peer maps generated (agent return contract line)
    XREPO_MAPS_GENERATED=$(echo "$AGENT_OUTPUT" | grep -c '^XREPO_MAP_GENERATED: ' 2>/dev/null | head -1)

    # New discoveries (from XREPO_SUGGEST lines)
    XREPO_DISCOVERY_NEW=$(echo "$XREPO_SUGGESTS" | grep -c '^XREPO_SUGGEST: ' 2>/dev/null | head -1)

    # Build completed-step metadata JSON object
    XREPO_EXPLORED_BOOL="${CROSS_REPO_EXPLORED:-false}"
    XREPO_METADATA="{\"cross_repo_explored\":${XREPO_EXPLORED_BOOL},\"cross_repo_projects\":\"${XREPO_PROJECTS}\",\"cross_repo_maps_generated\":${XREPO_MAPS_GENERATED},\"cross_repo_discovery_new\":${XREPO_DISCOVERY_NEW}}"

    # Emit analysis step completed event
    source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
    n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "analysis" 2 "${N1_HOME}/memory/$ID/telemetry" completed_at=now outcome=pass loop_iteration=null metadata="$XREPO_METADATA"
fi
```

If `SELF_RESOLVED` > 0, append a decision ledger row to `$N1_HOME/memory/<ID>/overview.md` per `skills/n1-start/ledger.md`:

| analysis | scope | B | [auto] | {SELF_RESOLVED} unknowns answerable from codebase | Self-resolved via Read/Grep/Glob | — | B/C tier classification -- see `<!-- n1:resolved: -->` markers in analysis.md | --- |

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
UNKNOWN_COUNT=$(echo "$UNKNOWNS" | grep -c '.' 2>/dev/null | head -1)
UNKNOWN_COUNT="${UNKNOWN_COUNT:-0}"
```

If `UNKNOWN_COUNT` is 0, skip the rest of this phase.

**Story-run clarification inheritance (headless children only):**

When `N1_HEADLESS=1` and `N1_STORY_ID` is set, check parent story clarifications before asking:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/story.sh"
STORY_MEM="$N1_HOME/memory/$N1_STORY_ID"
INHERITED_COUNT=0
REMAINING_UNKNOWNS=""

while IFS= read -r unknown; do
    [ -z "$unknown" ] && continue
    ANSWER=$(n1_story_match_clarification "$unknown" "$STORY_MEM/story.md")
    if [ -n "$ANSWER" ]; then
        # Inherited from parent story -- resolve without asking
        ((INHERITED_COUNT++))
        # Append to clarifications section directly
    else
        REMAINING_UNKNOWNS="${REMAINING_UNKNOWNS}${unknown}\n"
    fi
done <<< "$UNKNOWNS"
```

For each inherited answer:
- Append to `### Clarifications` in analysis.md: `**Q:** <unknown> **A:** <answer> (inherited from story <N1_STORY_ID>)`
- Emit telemetry: `n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "analysis" "scope" "inherited" "---"`
- Append a ledger row: `| analysis | scope | B | [auto] | <unknown> | <answer> | --- | Inherited from parent story clarifications | --- |`

Update `UNKNOWNS` to `REMAINING_UNKNOWNS` and `UNKNOWN_COUNT` to the remaining count. If `UNKNOWN_COUNT` becomes 0, skip the rest of Phase 3.

**Story clarification pre-check (interactive story children):**

When `N1_STORY_ID` is set but `N1_HEADLESS` is NOT set:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/story.sh"
STORY_MEM="$N1_HOME/memory/$N1_STORY_ID"
```

For each unknown, check story clarifications using `n1_story_match_clarification`. If a match is found, pre-populate the recommended answer in the batched presentation: `(Pre-answered in story: <answer>)`. The user can confirm or override the pre-populated answer.

**Problem preamble:** Before presenting the unknowns, compose a 1-2 sentence summary: extract the title from the `# <ID>: <Title>` heading in `$N1_HOME/memory/<ID>/overview.md` and the first non-blank line under `### Core Ask` in `$N1_HOME/memory/<ID>/ticket.md`. Format: `"{Title}: {Core Ask (≤1 sentence)}."` — call this `PREAMBLE`. If either part is unavailable omit that part (keep the other); if both are missing, `PREAMBLE` is empty. **Bug root cause (bug tickets only):** Source `"${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"` first, then: if `$N1_HOME/memory/<ID>/analysis.md` contains a `### Bug Investigation` section AND the `has_bug_root_cause` signal is strictly `true` (read via `n1_read_signal`), prepend one sentence summarizing the root cause: `"Root cause: {root cause}. "` — prepend this to `PREAMBLE`. If the signal is `false`, absent, or any other value, omit the root cause line entirely — do not fall back to parsing the section body.

**Batch all unknowns into one AskUserQuestion** (max 4 per call; chain if more than 4):

Present all unknowns in a single message, prefixing with `PREAMBLE` (omit if empty). For each unknown, state the resolution ladder rungs already tried by the solution-architect (extract from `<!-- n1:unknown: ... -->` context or infer from the SA's analysis process -- at minimum `codebase` was tried since the SA always searches first).

```
{PREAMBLE} During analysis, I found {UNKNOWN_COUNT} item(s) not covered by the ticket:

1. <first unknown>
   Tried: codebase search, web search -- unresolvable because <why>
   (Recommended) <recommended answer if available>

2. <second unknown>
   Tried: codebase search -- unresolvable because <why>
   (Recommended) <recommended answer if available>

...

For each item: type your answer, "skip" to defer, or "Decide for me" to research and apply the recommendation.
You can also reply "use recommended" to accept all recommendations at once.
```

When 5+ unknowns exist, present the first 4 in one AskUserQuestion call, then chain additional calls for the remainder (max 4 per call).

**"Use recommended" handling:** If the user replies "use recommended" (or similar: "use all recommendations", "recommended for all"), apply the recommendation for each unknown that has one. For unknowns without a recommendation, ask individually as a follow-up.

**"Decide for me" handling (per-item):** When the user selects "Decide for me" for a specific item:
1. Re-run the resolution ladder for that item with emphasis on broader web search (multiple queries, cross-reference sources).
2. Apply the best-evidenced answer.
3. Record as `[auto-decided]` ledger row with reason starting with `decide-for-me:` and `rungs_tried` listing all rungs attempted.
4. Do NOT ask a follow-up question for this item.

After collecting all answers, append a `### Clarifications` section to `analysis.md`:

```markdown
### Clarifications
- **Q:** <unknown text>
  **A:** <user's answer or "Unresolved — deferred">
```

**Emit question telemetry (if enabled):**

For each unknown that was presented to the user:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
# For each asked unknown:
n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "analysis" "scope" "asked" "codebase,web"
# For each "Decide for me" resolution:
n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "analysis" "scope" "decide-for-me" "codebase,web,prescribed"
# For each "skip":
n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "analysis" "scope" "asked" "codebase,web"
```

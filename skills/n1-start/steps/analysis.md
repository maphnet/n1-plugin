<!-- n1:step-snippet-exception: agent-dispatch boundaries and output-dependent routing across cache/LITE/cross-repo gates -->

> **After this step's agent returns, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user.**

**Update tracker status to In Progress** (gate: skip if `tracker.mcp`, `tracker.statuses.inProgress`, or `tracker.operations.moveStatus` absent):
- Jira: call `getTransitions`, find matching transition, call `moveStatus`.
- YouTrack: call `moveStatus` with `state: <tracker.statuses.inProgress>`.
- On failure: warn and continue.

**Cache check:**

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
source "$N1_ROOT/lib/config.sh"
source "$N1_ROOT/lib/cache.sh"

CACHE_ENABLED=$(n1_config_val ".analysisCache.enabled" "$N1_HOME/config.json")
CACHE_ENABLED="${CACHE_ENABLED:-true}"
SNAPSHOT_PATH=$(n1_snapshot_path "$N1_HOME")
CACHE_STATE="cold"

if [ "$CACHE_ENABLED" = "true" ]; then
    CACHE_STATE=$(n1_snapshot_check_freshness "$SNAPSHOT_PATH" "$N1_HOME/config.json")
fi
```

**Lite-Analysis Gate:** simple/well-described task or chore skips full architect analysis.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
source "$N1_ROOT/lib/context.sh"

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

n1_write_context
```

`LITE_MODE` controls analysis scope, never its output contract. The solution-architect still returns full `n1:signals`, `tier:`, and `context:` in lite mode. When `LITE_MODE=true`, log to overview `## Key Decisions`: "Lite-analysis gate: reduced-scope analysis (tier=$TIER, type=$TYPE, quality=$DESC_QUALITY)."

**Related projects context:**

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
source "$N1_ROOT/lib/config.sh"
source "$N1_ROOT/lib/related.sh"
source "$N1_ROOT/lib/context.sh"

n1_read_context

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
2. If map is 'stale' or 'cold', generate the map yourself: scan the repo at repoPath (directory structure, CLAUDE.md, exports, API surface), run \`mkdir -p \"\$(dirname <mapPath>)\"\` first, then write to mapPath using Bash. The peer map MUST carry frontmatter (schema_version: 1, generated_at, git_sha, git_sha_short, generator: solution-architect) — without it the map is treated as stale. Report: \`XREPO_MAP_GENERATED: <slug>\`.
3. Use repoPath + relative paths from map to read specific files.
4. Include findings in '### Cross-Repo Context' section, one bullet: '- <slug>: <findings>'."
    fi
fi
```

Run `procedures/rules-injection.md` with `agent_name=solution-architect`, no `changed_files_source`.

`CACHE_STATE` (`cold`, `stale`, or `fresh`) determines the dispatch path. When `analysisCache.enabled=false`, `CACHE_STATE` stays `cold`. When absent, cache defaults to enabled.

**Spawn agent:** solution-architect. Resolve model for `solution-architect` with context `analysis`.

**Shared spawn directives:**

- **Type:** extract via `grep -m1 -i '^\*\*Type:\*\*' "$N1_HOME/memory/$ID/ticket.md"`, pass explicitly.
- **Scratch policy:** write throwaway benchmarks/tests to `$N1_HOME/memory/<ID>/benchmarks/` or `$N1_HOME/memory/<ID>/tests/` (gitignored) — never into the repo test suite.
- **Unknown classification:** A=blocking (only human can answer — mark `<!-- n1:unknown: <desc> -->`); B=significant (try codebase→web→cmd-prescription before escalating — mark `<!-- n1:resolved: -->` / `<!-- n1:web-resolved: -->` / `<!-- n1:cmd-prescribed: -->` on success); C=convention (resolve silently). Default to B.
- **Investigation directive** (when `TYPE=="investigation"`): analyze to answer the investigation question, not plan implementation; focus on findings, evidence, recommendations.
- **Lite scope** (when `LITE_MODE==true`): read only files the ticket touches + direct callers; no project survey; no proactive web research (web still available for specific unknown resolution); no cross-repo; no observability; keep analysis.md ≤300 words; omit N/A sections; Tier Assessment mandatory; output contract unchanged.
- **Lite escape-hatch** (when `LITE_MODE==true`): if task proves materially non-simple (≥3 files, cross-module, auth/crypto/secrets/input-validation, public API, schema change), analyze fully, emit corrected signals, add `LITE_ESCALATED: <reason>`.
- **Rules:** append `$RULES_BLOCK` if non-empty.

**Shared output-path directives:**

<!-- #44657: Claude Code harness may refuse Write tool calls targeting files named
     "analysis.md" (blocked-filename family). The agent must write analysis.md via
     Bash (heredoc/cat redirect) rather than the Write tool. Do not simplify back
     to Write without verifying #44657 is resolved in the target harness version. -->

- "Write full analysis to `$N1_HOME/memory/<ID>/analysis.md` via Bash cat heredoc (NOT Write tool, ref #44657). Return ONLY: `n1:signals` line, `tier:` line, optional `SNAPSHOT_DRIFT:` line, 3-10 line summary."
- Project map directive (when `CACHE_STATE` is `cold`/`stale` AND `CACHE_ENABLED=true` AND `LITE_MODE=false`): "Write project map to `<PROJECT_MAP_PATH>` via Bash. Format: frontmatter (schema_version: 1, generated_at, git_sha, git_sha_short, generator: solution-architect) + ## Modules, ## API Surface, ## Exports & Shared Types, ## Integration Points, ## Key Files. Target 300-500 tokens."

**When CACHE_STATE is `cold` or `stale`:**

Spawn solution-architect with: ticket file path (instruct to Read), all shared directives.
- When `LITE_MODE=false`: add directive to research industry standards per `agents/research-standards.md`.
- When `CACHE_ENABLED=true` AND `LITE_MODE=false`, append SNAPSHOT PERSISTENCE REQUIREMENT:

  > Separate findings: `## [PROJECT] <section>` for project-level facts (include `<!-- provenance: <files> -->` after heading), `## [TICKET] <section>` for ticket-specific analysis. Write only [TICKET] sections to analysis.md (strip prefix). Persist [PROJECT] sections as snapshot:
  > ```bash
  > source "<N1_ROOT>/lib/cache.sh"
  > n1_snapshot_write "<SNAPSHOT_PATH>" "$PROJECT_CONTENT" "$(git rev-parse HEAD)"
  > ```
  > Snapshot path: `<SNAPSHOT_PATH>` (substitute actual resolved path). Strip `[PROJECT] ` prefix from headings.

- When `CACHE_ENABLED=false`: agent writes full report directly.
- When `LITE_MODE=true`: agent writes short report directly; no snapshot.

**When CACHE_STATE is `fresh`:**

Read snapshot metadata:
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
SNAPSHOT_BODY=$(n1_snapshot_read_body "$SNAPSHOT_PATH")
SNAPSHOT_SHA=$(n1_read_frontmatter "$SNAPSHOT_PATH" "git_sha_short")
SNAPSHOT_AGE_RAW=$(n1_read_frontmatter "$SNAPSHOT_PATH" "generated_at")
```

Spawn solution-architect with prompt:

> PROJECT SNAPSHOT (generated {SNAPSHOT_AGE_RAW}, git SHA {SNAPSHOT_SHA}):
> {SNAPSHOT_BODY}
>
> TASK: Analyze ticket for implementation readiness. Read `$N1_HOME/memory/<ID>/ticket.md` yourself.
>
> - Do NOT re-scan project structure — snapshot covers it. Focus on ticket-specific analysis: affected files, blast radius, integration points, risks, tier.
> - You MAY read specific files from Subsystem Registry.
> - [Omit when LITE_MODE=true] You MAY do ticket-specific web research.
> - Where snapshot and a rule conflict, rule wins.
> - Flag snapshot issues: `SNAPSHOT_DRIFT: <description>`
>
> Write only [TICKET]-scoped content to analysis.md. Emit signals and summary per Output Contract.
> {$RULES_BLOCK if non-empty; lite scope + escape-hatch when LITE_MODE=true; investigation directive when TYPE=="investigation"; scratch policy}

Apply all shared output-path directives. When `LITE_MODE=true`, also apply lite scope and escape-hatch directives.

**Observability enrichment** (skip when `LITE_MODE=true`):

When `observability` is configured and jq is available:
1. Collect active providers: `env` absent OR `env` matches `observability.default`. If none active (or all have env tags and no default), skip.
2. Append to SA prompt: `"The following observability sources are available:\n- **<name>**: <instructions>"`
3. Bug from error tracker: query all sources; include `### Observability Findings`.
4. Bug (other): query for related errors/logs/traces; include `### Observability Findings`.
5. Other types: query if relevant; include `### Observability Findings` if useful.

If `$RELATED_CONTEXT` is non-empty, append after observability block.

After the agent returns:

**Post-return — analysis.md verification:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
source "$N1_ROOT/lib/validation.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" analysis.md
```
If missing/empty: re-prompt once. If still missing: write returned summary as fallback, log in overview `## Key Decisions`.

**Post-return — LITE_ESCALATED (lite path):**
```bash
ESCALATED=$(echo "$AGENT_OUTPUT" | grep -m1 '^LITE_ESCALATED:')
if [ -n "$ESCALATED" ]; then
    echo "$ESCALATED"
fi
```
If non-empty: log to overview `## Key Decisions`: "Lite analysis escalated: <reason> — corrected signals applied, analysis not re-run."

**Post-return — snapshot verification (cold/stale + cache enabled + non-lite):**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
source "$N1_ROOT/lib/cache.sh"

SNAPSHOT_PATH=$(n1_snapshot_path "$N1_HOME")

if [ ! -f "$SNAPSHOT_PATH" ] || [ ! -s "$SNAPSHOT_PATH" ]; then
    echo "Snapshot persistence failed — cache remains cold."
fi
```

**Post-return — project map verification (cold/stale + cache enabled):**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
source "$N1_ROOT/lib/config.sh"
source "$N1_ROOT/lib/cache.sh"
source "$N1_ROOT/lib/related.sh"
source "$N1_ROOT/lib/context.sh"

n1_read_context

CACHE_ENABLED=$(n1_config_val ".analysisCache.enabled" "$N1_HOME/config.json")
CACHE_ENABLED="${CACHE_ENABLED:-true}"
SNAPSHOT_PATH=$(n1_snapshot_path "$N1_HOME")
PROJECT_MAP_PATH=$(n1_project_map_path "$N1_HOME")
CACHE_STATE="cold"
if [ "$CACHE_ENABLED" = "true" ]; then
    CACHE_STATE=$(n1_snapshot_check_freshness "$SNAPSHOT_PATH" "$N1_HOME/config.json") || true
fi

if [ "$CACHE_STATE" != "fresh" ] && [ "$CACHE_ENABLED" = "true" ] && [ "$LITE_MODE" != "true" ]; then
    if [ ! -f "$PROJECT_MAP_PATH" ] || [ ! -s "$PROJECT_MAP_PATH" ]; then
        echo "Project map persistence failed — map will be generated on next run."
    fi
fi
```

**Post-return — SNAPSHOT_DRIFT (fresh path):**
```bash
DRIFT=$(echo "$AGENT_OUTPUT" | grep -m1 '^SNAPSHOT_DRIFT:')
if [ -n "$DRIFT" ]; then
    rm -f "$SNAPSHOT_PATH"
fi
```
If drift found: log in overview `## Key Decisions`, delete snapshot to force regeneration.

- Update overview: `[x] Analysis`, set `step: analysis`

**Parse and persist context block:**
```bash
CONTEXT_BLOCK=$(echo "$AGENT_OUTPUT" | sed -n '/^context: |$/,/^[^ ]/{/^context: |$/d;/^[^ ]/d;s/^  //;p}')
```

If `CONTEXT_BLOCK` non-empty:
1. Replace `## Context` section in overview.md (between `## Context` and `## Progress` headings).
2. Persist ticket URL:
   ```bash
   N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
   if [ -n "$TICKET_URL" ]; then
       source "$N1_ROOT/lib/step.sh"
       n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "ticket_url" "$TICKET_URL"
   fi
   ```
3. Read signals:
   ```bash
   N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
   source "$N1_ROOT/lib/step.sh"
   FILES_CHANGED=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "files_changed")
   BLAST_RADIUS=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "blast_radius")
   TIER=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier")
   ```
4. **Print Gate 1** (see `procedures/output-gates.md § Gate 1`). Fields: `<ID>`, `<TITLE>`, `<CONTEXT_BLOCK>`, `<TIER>`, `<FILES_CHANGED>`, `<BLAST_RADIUS>`, `Pipeline:`, `Workspace: $WORKTREE_PATH ($BRANCH)`, `<TICKET_URL>` (omit if empty). If `CONTEXT_BLOCK` empty: log "Context block: SA did not emit context: block — Gate 1 skipped."

**Parse and persist tier revision:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
CURRENT_TIER=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier")
```
Extract `tier:` via regex `^tier:\s*(simple|standard|complex)` from analysis.md. If valid and differs from `$CURRENT_TIER`: `n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier" "$NEW_TIER"`.

**Extract and persist signals:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
SIGNAL_LINE=$(echo "$AGENT_OUTPUT" | grep -m1 '^n1:signals ')
if [ -n "$SIGNAL_LINE" ]; then
    PAIRS=$(echo "$SIGNAL_LINE" | sed 's/^n1:signals //')
    n1_write_signals "$N1_HOME/memory/$ID/analysis.md" $PAIRS
fi

SELF_RESOLVED=$(grep -c '<!-- n1:resolved:' "$N1_HOME/memory/$ID/analysis.md" 2>/dev/null | head -1)
SELF_RESOLVED="${SELF_RESOLVED:-0}"
if [ "$SELF_RESOLVED" -gt 0 ]; then
    n1_write_signals "$N1_HOME/memory/$ID/analysis.md" "self_resolved=$SELF_RESOLVED"
fi
```

**Parse cross-repo signals:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
source "$N1_ROOT/lib/config.sh"
source "$N1_ROOT/lib/related.sh"

CROSS_REPO_EXPLORED=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "cross_repo_explored")

XREPO_PENDING_FILE="$N1_HOME/memory/$ID/xrepo-pending.tsv"
rm -f "$XREPO_PENDING_FILE"
XREPO_SUGGESTS=$(echo "$AGENT_OUTPUT" | grep '^XREPO_SUGGEST: ' || true)
if [ -n "$XREPO_SUGGESTS" ]; then
    autonomy_mode=$(n1_autonomy_val "mechanicalPrompts")

    while IFS= read -r line; do
        xr_slug=$(echo "$line" | sed 's/^XREPO_SUGGEST: //' | awk '{print $1}')
        xr_reason=$(echo "$line" | sed 's/^XREPO_SUGGEST: [^ ]* //')
        [ -z "$xr_slug" ] && continue
        xr_reason_cell=$(printf '%s' "$xr_reason" | tr '|' '/' | cut -c1-80)

        if [ "$autonomy_mode" = "auto" ]; then
            n1_related_add "$N1_HOME/config.json" "$xr_slug" "$xr_reason" "auto"
            if ! grep -q '^## Decision Ledger' "$N1_HOME/memory/$ID/overview.md" 2>/dev/null; then
                printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$N1_HOME/memory/$ID/overview.md"
            fi
            printf '| analysis | scope | B | [auto] | New integration with %s detected by SA | Added to related projects | — | XREPO_SUGGEST: %s | --- |\n' "$xr_slug" "$xr_reason_cell" >> "$N1_HOME/memory/$ID/overview.md"
        else
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

**Interactive response handling (non-auto path):** re-read `$XREPO_PENDING_FILE` (separate Bash invocation):

- **"yes":**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/related.sh"
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

- **"select":** present each slug individually; add + ledger row only for approved ones.
- **"no":** add nothing; append `[asked]` ledger row per slug recording decline.

**Headless:** under `N1_HEADLESS=1`, apply `procedures/autonomy-headless.md § Headless Guard`.

**Cross-repo telemetry (when `relatedProjects.enabled=true`):** owns the step-2 end event.
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
source "$N1_ROOT/lib/config.sh"
source "$N1_ROOT/lib/related.sh"
RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json")

if [ "$RELATED_ENABLED" = "true" ]; then
    CROSS_REPO_EXPLORED=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "cross_repo_explored")
    XREPO_SUGGESTS=$(echo "$AGENT_OUTPUT" | grep '^XREPO_SUGGEST: ' || true)

    XREPO_PROJECTS=""
    if [ "$CROSS_REPO_EXPLORED" = "true" ]; then
        XREPO_PROJECTS=$(sed -n '/^### Cross-Repo Context/,/^### /p' "$N1_HOME/memory/$ID/analysis.md" \
            | grep -oE '^- [A-Za-z0-9._-]+:' | sed 's/^- //; s/:$//' | tr '\n' ',' | sed 's/,$//')
    fi

    XREPO_MAPS_GENERATED=$(echo "$AGENT_OUTPUT" | grep -c '^XREPO_MAP_GENERATED: ' 2>/dev/null | head -1)
    XREPO_DISCOVERY_NEW=$(echo "$XREPO_SUGGESTS" | grep -c '^XREPO_SUGGEST: ' 2>/dev/null | head -1)
    XREPO_EXPLORED_BOOL="${CROSS_REPO_EXPLORED:-false}"
    XREPO_METADATA="{\"cross_repo_explored\":${XREPO_EXPLORED_BOOL},\"cross_repo_projects\":\"${XREPO_PROJECTS}\",\"cross_repo_maps_generated\":${XREPO_MAPS_GENERATED},\"cross_repo_discovery_new\":${XREPO_DISCOVERY_NEW}}"

    n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "analysis" 2 "${N1_HOME}/memory/$ID/telemetry" completed_at=now outcome=pass loop_iteration=null metadata="$XREPO_METADATA"
fi
```

If `SELF_RESOLVED` > 0, append decision ledger row per `skills/n1-start/ledger.md`:

| analysis | scope | B | [auto] | {SELF_RESOLVED} unknowns answerable from codebase | Self-resolved via Read/Grep/Glob | — | B/C tier — see `<!-- n1:resolved: -->` markers in analysis.md | --- |

**Compact analysis memory (non-investigation only):**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
source "$N1_ROOT/lib/memory.sh"
TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
if [ "$TYPE" != "investigation" ]; then
    n1_compact_memory "$N1_HOME/memory/$ID/analysis.md" "conclusions,affected files,blast radius,risks,industry standards,bug investigation,tier"
fi
```

**Phase 3 — Unknown Q&A (all task types):**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
```

```bash
UNKNOWNS=$(grep -oE '<!-- n1:unknown: [^>]+ -->' "$N1_HOME/memory/$ID/analysis.md" | sed 's/<!-- n1:unknown: //;s/ -->//')
UNKNOWN_COUNT=$(echo "$UNKNOWNS" | grep -c '.' 2>/dev/null | head -1)
UNKNOWN_COUNT="${UNKNOWN_COUNT:-0}"
```

If `UNKNOWN_COUNT` is 0, skip Phase 3.

**Story clarification inheritance (headless, `N1_HEADLESS=1` + `N1_STORY_ID` set):**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/story.sh"
STORY_MEM="$N1_HOME/memory/$N1_STORY_ID"
INHERITED_COUNT=0
REMAINING_UNKNOWNS=""

while IFS= read -r unknown; do
    [ -z "$unknown" ] && continue
    ANSWER=$(n1_story_match_clarification "$unknown" "$STORY_MEM/story.md")
    if [ -n "$ANSWER" ]; then
        ((INHERITED_COUNT++))
    else
        REMAINING_UNKNOWNS="${REMAINING_UNKNOWNS}${unknown}\n"
    fi
done <<< "$UNKNOWNS"
```

For each inherited: append to `### Clarifications` in analysis.md: `**Q:** <unknown> **A:** <answer> (inherited from story <N1_STORY_ID>)`. Emit telemetry: `n1_emit_question_event ... "inherited" "---"`. Append `[auto]` ledger row. Update `UNKNOWNS`/`UNKNOWN_COUNT` to remaining.

**Story pre-check (interactive, `N1_STORY_ID` set, not headless):**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/story.sh"
STORY_MEM="$N1_HOME/memory/$N1_STORY_ID"
```
For each unknown with story match: pre-populate `(Pre-answered in story: <answer>)` in batched presentation.

**Problem preamble:** `"{Title}: {Core Ask (≤1 sentence)}."` — title from `# <ID>: <Title>` in overview.md; Core Ask from first non-blank line under `### Core Ask` in ticket.md. Bug root cause (bug only): if `### Bug Investigation` in analysis.md AND `has_bug_root_cause==true`, prepend `"Root cause: {root cause}. "`.

**Batch unknowns** (max 4 per call; chain if more):

```
{PREAMBLE} During analysis, I found {UNKNOWN_COUNT} item(s) not covered by the ticket:

1. <unknown>
   Tried: codebase search, web search — unresolvable because <why>
   (Recommended) <recommended answer>

For each: type your answer, "skip" to defer, or "Decide for me" to research and apply the recommendation.
Reply "use recommended" to accept all recommendations at once.
```

- **"Use recommended"**: apply all; ask individually for unknowns without a recommendation.
- **"Decide for me" (per item)**: re-run resolution ladder with broader web search, apply best answer, record as `[auto-decided]`, no follow-up.
- After answers: append `### Clarifications` to analysis.md: `**Q:** <text>\n  **A:** <answer or "Unresolved — deferred">`.

**Emit question telemetry:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
# For each asked unknown:
n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "analysis" "scope" "asked" "codebase,web"
# For each "Decide for me":
n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "analysis" "scope" "decide-for-me" "codebase,web,prescribed"
# For each "skip":
n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "analysis" "scope" "asked" "codebase,web"
```

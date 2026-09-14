<!-- n1:step-snippet-exception: agent-dispatch boundaries and output-dependent routing across cache/LITE/cross-repo gates -->

> **After this step's agent returns, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user.**

`moveStatus` → In Progress (skip if absent; warn and continue).

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/config.sh"; source "$N1_ROOT/lib/cache.sh"; source "$N1_ROOT/lib/related.sh"; source "$N1_ROOT/lib/context.sh"
CACHE_ENABLED=$(n1_config_val ".analysisCache.enabled" "$N1_HOME/config.json"); CACHE_ENABLED="${CACHE_ENABLED:-true}"
SNAPSHOT_PATH=$(n1_snapshot_path "$N1_HOME"); CACHE_STATE="cold"
[ "$CACHE_ENABLED" = "true" ] && CACHE_STATE=$(n1_snapshot_check_freshness "$SNAPSHOT_PATH" "$N1_HOME/config.json")
TIER=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier"); TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
DESC_QUALITY=$(n1_read_signal "$N1_HOME/memory/$ID/ticket.md" "description_quality"); LITE_MODE=false
[ "$TIER" = "simple" ] && { [ "$DESC_QUALITY" = "adequate" ] || [ "$DESC_QUALITY" = "weak" ]; } && { [ "$TYPE" = "task" ] || [ "$TYPE" = "chore" ]; } && LITE_MODE=true
n1_record_decision lite-analysis-gate "$LITE_MODE" '{"all":[{"frontmatter":"tier","eq":"simple"},{"signal":"ticket.description_quality","neq":"empty"},{"signal":"ticket.description_quality","neq":"skeletal"},{"any":[{"frontmatter":"type","eq":"task"},{"frontmatter":"type","eq":"chore"}]}]}' "tier=$TIER" "type=$TYPE" "quality=$DESC_QUALITY"
n1_write_context
RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json"); PROJECT_MAP_PATH=$(n1_project_map_path "$N1_HOME"); RELATED_CONTEXT=""
if [ "$RELATED_ENABLED" = "true" ] && [ "$LITE_MODE" != "true" ]; then
    MAX_AGE=$(n1_config_val ".relatedProjects.maxSnapshotAge" "$N1_HOME/config.json"); MAX_AGE="${MAX_AGE:-72h}"; RELATED_LINES=""
    while IFS=$'\t' read -r slug reason repo_path; do [ -z "$slug" ] && continue
        peer_map=$(n1_related_project_map "$slug"); map_state=$(n1_project_map_check_freshness "$peer_map" "$MAX_AGE") || true
        RELATED_LINES="${RELATED_LINES}
- ${slug} (${reason}): map=${map_state} mapPath=${peer_map} repo=${repo_path}"
    done < <(n1_related_projects "$N1_HOME/config.json")
    [ -n "$RELATED_LINES" ] && RELATED_CONTEXT="RELATED PROJECTS:${RELATED_LINES}
Fresh→read mapPath. Stale/cold→generate map (schema_version:1,generated_at,git_sha,git_sha_short,generator:solution-architect), emit XREPO_MAP_GENERATED:<slug>. Add '### Cross-Repo Context'."
fi
echo "LITE_MODE=$LITE_MODE CACHE_STATE=$CACHE_STATE"
```
`LITE_MODE=true`: log to `## Key Decisions`.

Run `procedures/rules-injection.md`: `agent_name=solution-architect`.

**Spawn SA** (context `analysis`): scratch `$N1_HOME/memory/<ID>/tests/`; unknown A=`<!-- n1:unknown: -->` B=codebase→web→cmd C=silent; investigation→analyze question; lite→touched files+callers ≤300w, `LITE_ESCALATED:<reason>` if ≥3/cross-module/security/API. Write analysis.md (Bash heredoc); return `n1:signals tier: [SNAPSHOT_DRIFT:]`+summary. Cold/stale+cache+non-lite: write project map `<PROJECT_MAP_PATH>` (## Modules, ## API Surface, ## Exports & Shared Types, ## Integration Points, ## Key Files; 300-500 tokens). Append `$RULES_BLOCK`.

**Cold/stale:** use `agents/research-standards.md`. Cache: `## [PROJECT]`+`## [TICKET]`; persist [PROJECT] via `n1_snapshot_write`.

**Fresh:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
SNAPSHOT_BODY=$(n1_snapshot_read_body "$SNAPSHOT_PATH"); SNAPSHOT_SHA=$(n1_read_frontmatter "$SNAPSHOT_PATH" "git_sha_short"); SNAPSHOT_AGE_RAW=$(n1_read_frontmatter "$SNAPSHOT_PATH" "generated_at")
```
Spawn SA: "SNAPSHOT (age:{SNAPSHOT_AGE_RAW} sha:{SNAPSHOT_SHA}): {SNAPSHOT_BODY}\n\nAnalyze ticket. No re-scan. Flag SNAPSHOT_DRIFT:<desc>. Write [TICKET]. {directives}"

**Observability** (skip if LITE): append provider sources; bugs: `### Observability Findings`; append `$RELATED_CONTEXT`.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/validation.sh"; source "$N1_ROOT/lib/config.sh"; source "$N1_ROOT/lib/cache.sh"; source "$N1_ROOT/lib/related.sh"; source "$N1_ROOT/lib/context.sh"; source "$N1_ROOT/lib/memory.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" analysis.md; n1_read_context
CACHE_ENABLED=$(n1_config_val ".analysisCache.enabled" "$N1_HOME/config.json"); CACHE_ENABLED="${CACHE_ENABLED:-true}"
SNAPSHOT_PATH=$(n1_snapshot_path "$N1_HOME"); PROJECT_MAP_PATH=$(n1_project_map_path "$N1_HOME"); CACHE_STATE="cold"
[ "$CACHE_ENABLED" = "true" ] && CACHE_STATE=$(n1_snapshot_check_freshness "$SNAPSHOT_PATH" "$N1_HOME/config.json") || true
{ [ ! -f "$SNAPSHOT_PATH" ] || [ ! -s "$SNAPSHOT_PATH" ]; } && echo "Snapshot persistence failed."
[ "$CACHE_STATE" != "fresh" ] && [ "$CACHE_ENABLED" = "true" ] && [ "$LITE_MODE" != "true" ] && { [ ! -f "$PROJECT_MAP_PATH" ] || [ ! -s "$PROJECT_MAP_PATH" ]; } && echo "Project map persistence failed."
DRIFT=$(echo "$AGENT_OUTPUT" | grep -m1 '^SNAPSHOT_DRIFT:'); [ -n "$DRIFT" ] && rm -f "$SNAPSHOT_PATH"
CONTEXT_BLOCK=$(echo "$AGENT_OUTPUT" | sed -n '/^context: |$/,/^[^ ]/{/^context: |$/d;/^[^ ]/d;s/^  //;p}')
[ -n "$TICKET_URL" ] && n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "ticket_url" "$TICKET_URL"
SIGNAL_LINE=$(echo "$AGENT_OUTPUT" | grep -m1 '^n1:signals ')
[ -n "$SIGNAL_LINE" ] && { PAIRS=$(echo "$SIGNAL_LINE" | sed 's/^n1:signals //'); n1_write_signals "$N1_HOME/memory/$ID/analysis.md" $PAIRS; }
ESCALATED=$(echo "$AGENT_OUTPUT" | grep -m1 '^LITE_ESCALATED:'); [ -n "$ESCALATED" ] && echo "$ESCALATED"
SELF_RESOLVED=$(grep -c '<!-- n1:resolved:' "$N1_HOME/memory/$ID/analysis.md" 2>/dev/null | head -1); SELF_RESOLVED="${SELF_RESOLVED:-0}"
[ "$SELF_RESOLVED" -gt 0 ] && n1_write_signals "$N1_HOME/memory/$ID/analysis.md" "self_resolved=$SELF_RESOLVED"
TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
[ "$TYPE" != "investigation" ] && n1_compact_memory "$N1_HOME/memory/$ID/analysis.md" "conclusions,affected files,blast radius,risks,industry standards,bug investigation,tier"
BLAST=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "blast_radius"); FILES_CHANGED_A=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "files_changed")
SECURITY=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "security_relevant"); HAS_ROOT_CAUSE=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "has_bug_root_cause")
SIMPLE_PATH=false
if [ "$TIER" = "simple" ] && [ "$BLAST" = "low" ] && [ "${FILES_CHANGED_A:-999}" -lt 3 ] && [ "$SECURITY" != "true" ]; then
    if [ "$TYPE" = "task" ] || [ "$TYPE" = "chore" ] || { [ "$TYPE" = "bug" ] && [ "$HAS_ROOT_CAUSE" = "true" ]; }; then
        SIMPLE_PATH=true
    fi
fi
n1_record_decision simple-path "$SIMPLE_PATH" '{"all":[{"frontmatter":"tier","eq":"simple"},{"signal":"analysis.blast_radius","eq":"low"},{"signal":"analysis.files_changed","lt":3},{"signal":"analysis.security_relevant","neq":"true"},{"any":[{"frontmatter":"type","eq":"task"},{"frontmatter":"type","eq":"chore"},{"all":[{"frontmatter":"type","eq":"bug"},{"signal":"analysis.has_bug_root_cause","eq":"true"}]}]}]}' "tier=$TIER" "type=$TYPE" "blast=$BLAST" "files_changed=${FILES_CHANGED_A:-}" "security_relevant=${SECURITY:-}" "has_bug_root_cause=${HAS_ROOT_CAUSE:-}"
n1_write_context
[ "$SIMPLE_PATH" = "true" ] && echo "Simple-path: skipping brainstorm and plan"
XREPO_PENDING_FILE="$N1_HOME/memory/$ID/xrepo-pending.tsv"; rm -f "$XREPO_PENDING_FILE"
XREPO_SUGGESTS=$(echo "$AGENT_OUTPUT" | grep '^XREPO_SUGGEST: ' || true)
if [ -n "$XREPO_SUGGESTS" ]; then
    autonomy_mode=$(n1_autonomy_val "mechanicalPrompts")
    while IFS= read -r line; do
        xr_slug=$(echo "$line" | sed 's/^XREPO_SUGGEST: //' | awk '{print $1}'); xr_reason=$(echo "$line" | sed 's/^XREPO_SUGGEST: [^ ]* //'); [ -z "$xr_slug" ] && continue
        xr_reason_cell=$(printf '%s' "$xr_reason" | tr '|' '/' | cut -c1-80)
        if [ "$autonomy_mode" = "auto" ]; then
            n1_related_add "$N1_HOME/config.json" "$xr_slug" "$xr_reason" "auto"
            grep -q '^## Decision Ledger' "$N1_HOME/memory/$ID/overview.md" 2>/dev/null || printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$N1_HOME/memory/$ID/overview.md"
            printf '| analysis | scope | B | [auto] | New integration with %s detected by SA | Added | — | XREPO_SUGGEST: %s | --- |\n' "$xr_slug" "$xr_reason_cell" >> "$N1_HOME/memory/$ID/overview.md"
        else printf '%s\t%s\n' "$xr_slug" "$xr_reason" >> "$XREPO_PENDING_FILE"; fi
    done < <(printf '%s\n' "$XREPO_SUGGESTS")
fi
[ -s "$XREPO_PENDING_FILE" ] && { printf '\nSA detected cross-repo integrations:\n'; awk -F'\t' '{printf "- %s: %s\n",$1,$2}' "$XREPO_PENDING_FILE"; printf '\nAdd? (yes/no/select)\n'; }
```
Missing/empty: re-prompt once; fallback write summary. DRIFT: delete snapshot. Extract `tier:` → write frontmatter. `CONTEXT_BLOCK` → replace `## Context`; **Print Gate 1** (`SIMPLE_PATH=true`: pipeline shows `analysis → developer → qa → review → pr (simple-path)`). `SELF_RESOLVED>0`: `[auto]` ledger. Update overview: `[x] Analysis`, `step: analysis`.

Interactive (non-auto): re-read `$XREPO_PENDING_FILE`. **"yes":**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/related.sh"; XREPO_PENDING_FILE="$N1_HOME/memory/$ID/xrepo-pending.tsv"
while IFS=$'\t' read -r xr_slug xr_reason; do [ -z "$xr_slug" ] && continue
    n1_related_add "$N1_HOME/config.json" "$xr_slug" "$xr_reason" "manual"
    xr_reason_cell=$(printf '%s' "$xr_reason" | tr '|' '/' | cut -c1-80)
    grep -q '^## Decision Ledger' "$N1_HOME/memory/$ID/overview.md" 2>/dev/null || printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$N1_HOME/memory/$ID/overview.md"
    printf '| analysis | scope | B | [asked] | New integration with %s detected by SA | Added | Not added | User approved: %s | codebase |\n' "$xr_slug" "$xr_reason_cell" >> "$N1_HOME/memory/$ID/overview.md"
done < "$XREPO_PENDING_FILE"
```
**"select":** add approved. **"no":** `[asked]` row. **Headless:** `procedures/autonomy-headless.md § Headless Guard`.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/config.sh"; source "$N1_ROOT/lib/related.sh"; source "$N1_ROOT/lib/story.sh"; source "$N1_ROOT/lib/frontmatter.sh"
RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json")
if [ "$RELATED_ENABLED" = "true" ]; then
    CROSS_REPO_EXPLORED=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "cross_repo_explored"); XREPO_PROJECTS=""
    [ "$CROSS_REPO_EXPLORED" = "true" ] && XREPO_PROJECTS=$(sed -n '/^### Cross-Repo Context/,/^### /p' "$N1_HOME/memory/$ID/analysis.md" | grep -oE '^- [A-Za-z0-9._-]+:' | sed 's/^- //; s/:$//' | tr '\n' ',' | sed 's/,$//')
    XREPO_SUGGESTS=$(echo "$AGENT_OUTPUT" | grep '^XREPO_SUGGEST: ' || true)
    XREPO_MAPS_GENERATED=$(echo "$AGENT_OUTPUT" | grep -c '^XREPO_MAP_GENERATED: ' 2>/dev/null | head -1)
    XREPO_DISCOVERY_NEW=$(echo "$XREPO_SUGGESTS" | grep -c '^XREPO_SUGGEST: ' 2>/dev/null | head -1); XREPO_EXPLORED_BOOL="${CROSS_REPO_EXPLORED:-false}"
    n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "analysis" 2 "${N1_HOME}/memory/$ID/telemetry" completed_at=now outcome=pass loop_iteration=null metadata="{\"cross_repo_explored\":${XREPO_EXPLORED_BOOL},\"cross_repo_projects\":\"${XREPO_PROJECTS}\",\"cross_repo_maps_generated\":${XREPO_MAPS_GENERATED},\"cross_repo_discovery_new\":${XREPO_DISCOVERY_NEW}}"
fi
TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
UNKNOWNS=$(grep -oE '<!-- n1:unknown: [^>]+ -->' "$N1_HOME/memory/$ID/analysis.md" | sed 's/<!-- n1:unknown: //;s/ -->//'); UNKNOWN_COUNT=$(echo "$UNKNOWNS" | grep -c '.' 2>/dev/null | head -1); UNKNOWN_COUNT="${UNKNOWN_COUNT:-0}"
if [ "${N1_HEADLESS:-0}" = "1" ] && [ -n "${N1_STORY_ID:-}" ] && [ "$UNKNOWN_COUNT" -gt 0 ]; then
    STORY_MEM="$N1_HOME/memory/$N1_STORY_ID"; INHERITED_COUNT=0; REMAINING_UNKNOWNS=""
    while IFS= read -r unknown; do [ -z "$unknown" ] && continue
        ANSWER=$(n1_story_match_clarification "$unknown" "$STORY_MEM/story.md")
        [ -n "$ANSWER" ] && ((INHERITED_COUNT++)) || REMAINING_UNKNOWNS="${REMAINING_UNKNOWNS}${unknown}\n"
    done <<< "$UNKNOWNS"
    n1_emit_question_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" "analysis" "scope" "asked" "codebase,web"
    # Decide for me: "decide-for-me" "codebase,web,prescribed"
fi
```
`UNKNOWN_COUNT=0`: skip. Inherited: emit `[auto]` telemetry+ledger, `### Clarifications`. **Preamble:** `"{Title}: {Core Ask}."` Bug+root-cause: prepend. **Batch** (max 4):
```
{PREAMBLE} During analysis, {UNKNOWN_COUNT} unresolved:

1. <unknown> — tried: codebase, web — <why>
   (Recommended) <recommended>

Answer / "skip" / "Decide for me" / "use recommended" = accept all.
```
"Decide for me": search+apply `[auto-decided]`. After: `### Clarifications`.

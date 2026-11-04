<!-- n1:step-snippet-exception: agent-dispatch boundaries and output-dependent routing across cache/LITE/cross-repo gates -->

> **After this step's agent returns, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user. (Orchestrator-only: a fork ignores this.)**

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/cache.sh"; source "$N1_ROOT/lib/related.sh"; source "$N1_ROOT/lib/context.sh"
n1_step_begin "analysis" 2
CACHE_ENABLED=$(n1_config_val ".analysisCache.enabled" "$N1_HOME/config.json"); CACHE_ENABLED="${CACHE_ENABLED:-true}"
SNAPSHOT_PATH=$(n1_snapshot_path "$N1_HOME"); CACHE_STATE="cold"
[ "$CACHE_ENABLED" = "true" ] && CACHE_STATE=$(n1_snapshot_check_freshness "$SNAPSHOT_PATH" "$N1_HOME/config.json")
TIER=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier"); TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
DESC_QUALITY=$(n1_read_signal "$N1_HOME/memory/$ID/ticket.md" "description_quality"); LITE_MODE=false
[ "$TIER" = "simple" ] && { [ "$DESC_QUALITY" = "adequate" ] || [ "$DESC_QUALITY" = "weak" ]; } && { [ "$TYPE" = "task" ] || [ "$TYPE" = "chore" ]; } && LITE_MODE=true
n1_record_decision lite-analysis-gate "$LITE_MODE" '{"all":[{"frontmatter":"tier","eq":"simple"},{"signal":"ticket.description_quality","neq":"empty"},{"signal":"ticket.description_quality","neq":"skeletal"},{"any":[{"frontmatter":"type","eq":"task"},{"frontmatter":"type","eq":"chore"}]}]}' "tier=$TIER" "type=$TYPE" "quality=$DESC_QUALITY"
IFS=$'\t' read -r SA_MODEL SA_EFFORT < <(n1_resolve_agent solution-architect analysis)
n1_write_context
RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json"); PROJECT_MAP_PATH=$(n1_project_map_path "$N1_HOME"); echo "RELATED_ENABLED=$RELATED_ENABLED"
echo "LITE_MODE=$LITE_MODE CACHE_STATE=$CACHE_STATE"
```
`LITE_MODE=true`: log to `## Key Decisions`.

If `RELATED_ENABLED=true`, read `procedures/analysis-xrepo.md` now (before the SA spawn) and follow it; it also owns the cross-repo end of this step.

Run `procedures/rules-injection.md`: `agent_name=solution-architect`.

**Spawn SA** with `$SA_MODEL` and `$SA_EFFORT` (context `analysis`): scratch `$N1_HOME/memory/<ID>/tests/`; unknowns: A=tag, B=codebase→web→cmd, C=silent; lite→touched files+callers ≤300w, `LITE_ESCALATED:<reason>` if ≥3/cross-module/security/API. Write analysis.md; return `n1:signals tier: [SNAPSHOT_DRIFT:]`+summary. Cold/stale+cache+non-lite: write project map `<PROJECT_MAP_PATH>` (## Modules, ## API Surface, ## Exports & Shared Types, ## Integration Points, ## Key Files; 300-500 tokens). Append `$RULES_BLOCK`.

**Cold/stale:** use `research-standards.md`. Cache: `## [PROJECT]`+`## [TICKET]`; persist [PROJECT] via `n1_snapshot_write`.

**Fresh:**
```bash
source ~/.n1/preamble.sh
SNAPSHOT_BODY=$(n1_snapshot_read_body "$SNAPSHOT_PATH"); SNAPSHOT_SHA=$(n1_read_frontmatter "$SNAPSHOT_PATH" "git_sha_short"); SNAPSHOT_AGE_RAW=$(n1_read_frontmatter "$SNAPSHOT_PATH" "generated_at")
```
Spawn SA: "SNAPSHOT (age:{SNAPSHOT_AGE_RAW} sha:{SNAPSHOT_SHA}): {SNAPSHOT_BODY}\n\nAnalyze ticket. No re-scan. Flag SNAPSHOT_DRIFT:<desc>. Write [TICKET]. {directives}"

**Observability** (skip if LITE): append providers; bugs→`### Observability Findings`; append `$RELATED_CONTEXT`.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/cache.sh"; source "$N1_ROOT/lib/related.sh"; source "$N1_ROOT/lib/context.sh"
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
BLAST=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "blast_radius"); FILES_CHANGED_A=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "files_changed")
SECURITY=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "security_relevant"); HAS_ROOT_CAUSE=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "has_bug_root_cause")
CONTRADICTIONS=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "ticket_contradictions"); CONTRADICTIONS="${CONTRADICTIONS:-0}"
[ "$CONTRADICTIONS" -gt 0 ] && echo "Ticket contradictions found: $CONTRADICTIONS"
SIMPLE_PATH=false; [ "$TIER" = "simple" ] && [ "$BLAST" = "low" ] && [ "${FILES_CHANGED_A:-999}" -lt 3 ] && [ "$SECURITY" != "true" ] && { [ "$TYPE" = "task" ] || [ "$TYPE" = "chore" ] || { [ "$TYPE" = "bug" ] && [ "$HAS_ROOT_CAUSE" = "true" ]; }; } && SIMPLE_PATH=true
n1_record_decision simple-path "$SIMPLE_PATH" '{"all":[{"frontmatter":"tier","eq":"simple"},{"signal":"analysis.blast_radius","eq":"low"},{"signal":"analysis.files_changed","lt":3},{"signal":"analysis.security_relevant","neq":"true"},{"any":[{"frontmatter":"type","eq":"task"},{"frontmatter":"type","eq":"chore"},{"all":[{"frontmatter":"type","eq":"bug"},{"signal":"analysis.has_bug_root_cause","eq":"true"}]}]}]}' "tier=$TIER" "type=$TYPE" "blast=$BLAST" "files_changed=${FILES_CHANGED_A:-}" "security_relevant=${SECURITY:-}" "has_bug_root_cause=${HAS_ROOT_CAUSE:-}"
n1_write_context
[ "$SIMPLE_PATH" = "true" ] && echo "Simple-path: skipping brainstorm and plan"
XREPO_PENDING_FILE="$N1_HOME/memory/$ID/xrepo-pending.tsv"; rm -f "$XREPO_PENDING_FILE"
```

**Contradiction gate:** `CONTRADICTIONS > 0`: show `### Ticket Validation`; 1=Continue 2=Redirect(Recommended); log `[asked]` ledger row. Zero or all unverifiable: skip. **Headless:** `procedures/autonomy-headless.md § Headless Guard`.

Missing/empty: re-prompt once; fallback. DRIFT: delete snapshot. Write frontmatter; `CONTEXT_BLOCK` → replace `## Context`. **Print Gate 1** (`SIMPLE_PATH=true`: `analysis → developer → qa → review → pr`). `SELF_RESOLVED>0`: `[auto]` ledger. Then `procedures/ticket-watch.md § Seed`. Headless: continue immediately past Gate 1 into the next step — do not end the turn.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/related.sh"; source "$N1_ROOT/lib/queue.sh"
RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json")
TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
UNKNOWNS=$(grep -oE '<!-- n1:unknown: [^>]+ -->' "$N1_HOME/memory/$ID/analysis.md" | sed 's/<!-- n1:unknown: //;s/ -->//'); UNKNOWN_COUNT=$(echo "$UNKNOWNS" | grep -c '.' 2>/dev/null | head -1); UNKNOWN_COUNT="${UNKNOWN_COUNT:-0}"
if [ "$RELATED_ENABLED" = "true" ]; then XREPO_EXPLORED_BOOL=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "cross_repo_explored" 2>/dev/null || echo false); fi
[ "$RELATED_ENABLED" = "true" ] || n1_step_end "analysis" 2 success
```

`UNKNOWN_COUNT=0`: skip. Inherited→`[auto]` telemetry+ledger. Preamble: `"{Title}: {Core Ask}."` Bug: prepend root-cause. Batch (max 4): unknown — tried — why — (Recommended). Options: answer / "skip" / "Decide for me" / "use recommended" (all). "Decide for me"→search+apply `[auto-decided]`. After: `### Clarifications`.

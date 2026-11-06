<!-- n1:step-snippet-exception: agent-dispatch boundaries and output-dependent routing across cache/LITE/cross-repo gates -->

> **After this step's agent returns, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user. (Orchestrator-only: a fork ignores this.)**

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/analysis.sh"
n1_step_begin "analysis" 2
n1_analysis_entry
```
Output: `RELATED_ENABLED=`, `LITE_MODE= CACHE_STATE=`, `SA_MODEL= SA_EFFORT=`, `SNAPSHOT_PATH=`, `PROJECT_MAP_PATH=`; use these printed values below (the call also records `lite-analysis-gate` and persists the ticket context).
`LITE_MODE=true`: log to `## Key Decisions`.

If `RELATED_ENABLED=true`, read `procedures/analysis-xrepo.md` now (before the SA spawn) and follow it; it also owns the cross-repo end of this step.

Run `procedures/rules-injection.md`: `agent_name=solution-architect`.

**Spawn SA** with the printed `SA_MODEL` and `SA_EFFORT` (context `analysis`): scratch `$N1_HOME/memory/<ID>/tests/`; unknowns: A=tag, B=codebase→web→cmd, C=silent; lite→touched files+callers ≤300w, `LITE_ESCALATED:<reason>` if ≥3/cross-module/security/API. Write analysis.md; return `n1:signals tier: [SNAPSHOT_DRIFT:]`+summary. Cold/stale+cache+non-lite: write project map `<PROJECT_MAP_PATH>` (## Modules, ## API Surface, ## Exports & Shared Types, ## Integration Points, ## Key Files; 300-500 tokens). Append `$RULES_BLOCK`.

**Cold/stale:** use `research-standards.md`. Cache: `## [PROJECT]`+`## [TICKET]`; persist [PROJECT] via `n1_snapshot_write`.

**Fresh:**
```bash
source ~/.n1/preamble.sh
SNAPSHOT_BODY=$(n1_snapshot_read_body "$SNAPSHOT_PATH"); SNAPSHOT_SHA=$(n1_read_frontmatter "$SNAPSHOT_PATH" "git_sha_short"); SNAPSHOT_AGE_RAW=$(n1_read_frontmatter "$SNAPSHOT_PATH" "generated_at")
```
Spawn SA: "SNAPSHOT (age:{SNAPSHOT_AGE_RAW} sha:{SNAPSHOT_SHA}): {SNAPSHOT_BODY}\n\nAnalyze ticket. No re-scan. Flag SNAPSHOT_DRIFT:<desc>. Write [TICKET]. {directives}"

**Observability** (skip if LITE): append providers; bugs→`### Observability Findings`; append `$RELATED_CONTEXT`.

Write the SA's full returned text to `$N1_HOME/memory/$ID/sa-return.md` with the file-write mechanism (never paste it into a shell command or string), then:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/analysis.sh"
n1_analysis_finalize "<ticket URL, or empty>" < "$N1_HOME/memory/$ID/sa-return.md"
```
Output, each only when it applies: `Snapshot persistence failed.`, `Project map persistence failed.`, `SNAPSHOT_DRIFT:<desc>` (snapshot already deleted), `LITE_ESCALATED:<reason>`, `Ticket contradictions found: N`, `Simple-path: skipping brainstorm and plan`; always `SELF_RESOLVED=N SIMPLE_PATH=true|false`; the SA context block between `CONTEXT_BLOCK<<` and `CONTEXT_BLOCK>>`.

**Contradiction gate:** `CONTRADICTIONS > 0`: show `### Ticket Validation`; 1=Continue 2=Redirect(Recommended): cite the contradicting file:line; Continue works when every contradiction is minor (format: <N1_ROOT>/references/question-format.md); log `[asked]` ledger row. Zero or all unverifiable: skip. **Headless:** `procedures/autonomy-headless.md § Headless Guard`.

Missing/empty: re-prompt once; fallback. SNAPSHOT_DRIFT printed: snapshot already deleted. Write frontmatter; the lines between `CONTEXT_BLOCK<<` and `CONTEXT_BLOCK>>` → replace `## Context`. **Print Gate 1** (`SIMPLE_PATH=true`: `analysis → developer → qa → review → pr`). `SELF_RESOLVED>0`: `[auto]` ledger. Then `procedures/ticket-watch.md § Seed`. Headless: continue immediately past Gate 1 into the next step — do not end the turn.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/related.sh"; source "$N1_ROOT/lib/queue.sh"
RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json")
TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
UNKNOWNS=$(grep -oE '<!-- n1:unknown: [^>]+ -->' "$N1_HOME/memory/$ID/analysis.md" | sed 's/<!-- n1:unknown: //;s/ -->//'); UNKNOWN_COUNT=$(echo "$UNKNOWNS" | grep -c '.' 2>/dev/null | head -1); UNKNOWN_COUNT="${UNKNOWN_COUNT:-0}"
if [ "$RELATED_ENABLED" = "true" ]; then XREPO_EXPLORED_BOOL=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "cross_repo_explored" 2>/dev/null || echo false); fi
[ "$RELATED_ENABLED" = "true" ] || n1_step_end "analysis" 2 success
```

`UNKNOWN_COUNT=0`: skip. Inherited→`[auto]` telemetry+ledger. Preamble: `"{Title}: {Core Ask}."` Bug: prepend root-cause. Batch (max 4): unknown — tried — why — (Recommended) answer with its evidence, per <N1_ROOT>/references/question-format.md. Options: answer / "skip" / "Decide for me" / "use recommended" (all). "Decide for me"→search+apply `[auto-decided]`. After: `### Clarifications`.

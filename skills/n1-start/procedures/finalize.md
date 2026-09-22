# Procedure: Finalize Memory

## Finalize Memory (Step 12)

Update overview.md: all checkboxes checked; `step: done`; add `docs_updated` field if doc updates occurred; add final status line.

**Telemetry (if enabled):**
```bash
source "$N1_ROOT/lib/preamble.sh"
RESOLVED_TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type" 2>/dev/null || true)
echo '{"layer":"envelope_close","run_id":"'"$N1_RUN_ID"'","n1_version":"'"$N1_VERSION"'","ticket_id":"'"$ID"'","completed_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","final_outcome":"'"$FINAL_OUTCOME"'","estimated_tier":"'"$ESTIMATED_TIER"'","type":"'"$RESOLVED_TYPE"'"}' >> "${N1_HOME}/memory/$ID/telemetry/raw/steps/$N1_RUN_ID.jsonl"
```
`$FINAL_OUTCOME`: `pr_created`, `escalated`, or `failed`. `$ESTIMATED_TIER`: estimation tier or empty.

```bash
source "$N1_ROOT/lib/preamble.sh"
bash "$N1_ROOT/hooks/telemetry-merge.sh" "$N1_RUN_ID" "${N1_HOME}/memory/$ID/telemetry" 2>&1 || echo "⚠ Telemetry merge failed" >&2
MERGED="${N1_HOME}/memory/$ID/telemetry/runs/$N1_RUN_ID.jsonl"
source "$N1_ROOT/lib/telemetry.sh"
[ -s "$MERGED" ] && n1_remove_run_lock "${N1_HOME}/memory/$ID/telemetry" "$N1_RUN_ID"
```

Clear active-run:
```bash
source "$N1_ROOT/lib/preamble.sh"
n1_active_run_clear
```

**Emit Gate 3** (`procedures/output-gates.md § Gate 3`). Sources:
1. `$N1_HOME/memory/$ID/implementation.md` — `## Implementation Summary`
2. `$N1_HOME/memory/$ID/qa.md` — verdict + Evidence (verbatim)
3. `$N1_HOME/memory/$ID/local-testing.md` — report (verbatim, or SKIPPED line)
4. `$N1_HOME/memory/$ID/overview.md` — `## Pending` for PR URL; frontmatter `ticket_url` for tracker link

Copy test commands and result lines verbatim. Every skipped step gets `SKIPPED — <reason>`. `Ticket:` omitted when `ticket_url` is empty. PR URL is Gate 3's final field. Investigation tickets: use investigation-mode variant.

# Procedure: Finalize Memory

Covers Step 12 FINALIZE MEMORY: overview update, telemetry finalization, active-run clear, and Gate 3 emission.

## Finalize Memory (Step 12)

Update overview.md:
- All checkboxes checked
- Frontmatter: `step: done`
- Add `docs_updated` field from n1-pr's Phase 1 results (if any doc updates occurred)
- Final status line added

**Telemetry finalization (if enabled):**

1. Update the run envelope with completion data:
   ```bash
   echo '{"layer":"envelope_close","run_id":"'"$N1_RUN_ID"'","n1_version":"'"$N1_VERSION"'","ticket_id":"'"$ID"'","completed_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","final_outcome":"'"$FINAL_OUTCOME"'","estimated_tier":"'"$ESTIMATED_TIER"'"}' >> "${N1_HOME}/memory/$ID/telemetry/raw/steps/$N1_RUN_ID.jsonl"
   ```
   Where `$FINAL_OUTCOME` is one of: `pr_created`, `escalated`, `failed`. `$ESTIMATED_TIER` is the tier from the estimation step (or empty if estimation was skipped).

2. Run the merge script:
   ```bash
   N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
   bash "$N1_ROOT/hooks/telemetry-merge.sh" "$N1_RUN_ID" "${N1_HOME}/memory/$ID/telemetry" 2>&1 || echo "⚠ Telemetry merge failed" >&2
   ```
   After the merge, remove the lock only if the merged output exists and is non-empty:
   ```bash
   MERGED="${N1_HOME}/memory/$ID/telemetry/runs/$N1_RUN_ID.jsonl"
   [ -s "$MERGED" ] && rm -f "${N1_HOME}/memory/$ID/telemetry/telemetry.lock"
   ```

After finalizing, clear the active-run pointer:
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
n1_active_run_clear
```

**Emit Gate 3** (see `procedures/output-gates.md § Gate 3 — Done/Tested Summary`):

Read sources in this order:
1. `$N1_HOME/memory/$ID/implementation.md` — `## Implementation Summary` section (files changed, what was built)
2. `$N1_HOME/memory/$ID/qa.md` — verdict line and Evidence section (verbatim test commands and results)
3. `$N1_HOME/memory/$ID/local-testing.md` — local-test report (verbatim commands and results, or SKIPPED line)
4. `$N1_HOME/memory/$ID/overview.md` — `## Pending` section for PR URL

**Rules (stated here so a later reader cannot delete them as optional):**
- Copy test commands and result lines verbatim. Do not paraphrase or summarise to "tests pass".
- Every step that did not run gets a `SKIPPED — <reason>` line. Missing steps are never silent.
- The PR URL is Gate 3's final field; `steps/pr.md`'s CHECKPOINT line folds here.
- For investigation tickets use the investigation-mode variant (see Gate 3 definition in `procedures/output-gates.md`).
- Apply the Gate 3 budget (20 lines, ~1 200 characters). If the Findings section (investigation mode) would exceed budget, print the first 15 lines then: `(full text: $N1_HOME/memory/<ID>/investigation.md)`.


**Telemetry (if enabled):** Emit `started_at` for step 10 (`fix`) before any other work in this step:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "fix" 10 "${N1_HOME}/memory/$ID/telemetry" started_at=now
```

**Ensure dependencies (worktree mode).** Run the **Ensure Dependencies(`<ID>`)**
procedure before spawning the developer. Marker-guarded no-op if already installed
or if no worktree is active, but keeps a resumed/partial pipeline (entering directly
at fix in a fresh worktree) safe.

> The fix-target inference (reading `overview.md`'s `step:` to decide whether to route back to QA or review) corresponds to the `{"overview_step": ...}` routing edges in `pipeline.json` — this prose must match that declaration. No behavior change.

If the combined Step-7 verdict is FAIL:

**Spawn agent:** developer

Resolve model for `developer` with context `fix`.

Pass to developer:
- Combined review findings (Critical + High only)
- List of affected files
- Output-path directive: "After applying fixes, record your 'Fixes Applied' report (your standard Fix Cycle output format) in `$N1_HOME/memory/<ID>/implementation.md` yourself, under a `## Fix Cycle <N>` heading where `<N>` is the current `review_fix_cycle` value. If a `## Fix Cycle <N>` section for this N already exists, REPLACE it (idempotent upsert — safe on re-run), never duplicate it. Return to the orchestrator ONLY: the list of commit SHAs with one-line summaries, and `Findings fixed: N/M`."

After developer returns:
- Run via Bash (so the bound survives a resume):
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
  n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle"
  ```
- Go back to **Step 7** (REVIEW) — re-run both reviewers
- **Oscillation guard:** fingerprint each confirmed Critical/High finding (file + line + title). If a fix attempt does NOT reduce the confirmed Critical/High count, or the same fingerprint reappears after being marked fixed, escalate early — don't burn the remaining cycles making negative progress.
- The bound is `review.maxFixAttempts` (config in `$N1_HOME/config.json`, default 3); when `review_fix_cycle` reaches it, escalate to the user.

**Step-mode escalation protocol.** In step mode there is no interactive channel — do NOT print a question for the user. When this step must escalate (a blocking ambiguity it cannot resolve):

1. Write `$N1_HOME/memory/<ID>/escalation/request.json` (create the directory if needed):
   ```json
   {
     "run_id": "<value of the N1_RUN_ID environment variable>",
     "step": "fix",
     "questions": [{
       "id": "fix_blocked",
       "text": "<one-paragraph description of what is blocked and why, with concrete specifics>",
       "options": ["Retry with guidance: another fix attempt with your instructions", "Accept as-is: proceed with remaining findings documented in review.md", "Abort: stop the pipeline"],
       "recommendation": "<the option you would pick, with a one-line reason>",
       "context": "<cycles used, remaining [TQ-N]/[CR-N]/[SEC-N]/[CX-N] findings, error excerpts>"
     }]
   }
   ```
2. Run via Bash:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
   n1_emit_step_result "fix" "escalation" "null" "{\"review_fix_cycle\":$review_fix_cycle}" "" "$N1_HOME/memory/$ID"
   ```
   Then STOP.
3. **On re-run:** check `$N1_HOME/memory/<ID>/escalation/response.json`. If it exists and its `run_id` matches `N1_RUN_ID`, apply the answer for `fix_blocked`:
   - "Retry with guidance" → raise the ceiling to double the review-cycle bound (`review.maxFixAttempts` × 2, default 3 × 2 = 6) (hard ceiling, same pattern as n1-ci), record the guidance in overview `## Escalations`, and continue the fix loop using it.
   - "Accept as-is" → record the decision in overview `## Escalations` and emit `outcome: "pass"` (the pipeline proceeds with the issue documented in this step's memory file).
   - "Abort" → record it and emit `outcome: "error"` with `next_step: null`.

In full pipeline mode this protocol does NOT apply — keep the interactive prompt below unchanged.

In full pipeline mode: "The developer encountered an ambiguity during this fix cycle that requires your input: [details]. Please advise."

If the combined Step-7 verdict is PASS:
- Run via Bash:
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
  n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "clean_passes"
  ```
- Resolve `MIN_CLEAN=$(n1_config_val '.review.minCleanPasses')`; if empty, default to `1` (never re-run reviewers that already returned PASS — the config knob remains for anyone wanting belt-and-suspenders, only the default is 1).
- If `clean_passes` < `MIN_CLEAN`: go back to Step 7
- If `clean_passes` >= `MIN_CLEAN`: proceed

Update overview: `[x] Review`, set `step: review`

**Step result (step mode):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
FIX_TARGET=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "step")
if [ "$FIX_TARGET" = "qa" ]; then
    NEXT="qa"
else
    NEXT="review"
fi
n1_emit_step_result "fix" "pass" "$NEXT" "null" "" "$N1_HOME/memory/$ID"
```

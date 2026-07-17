
**Telemetry (if enabled):** Emit `started_at` for step 8 (`qa`) before spawning the qa-engineer. This applies to both the initial run and any re-entry after a QA fix cycle:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "qa" 8 "${N1_HOME}/memory/$ID/telemetry" started_at=now
```

**Ensure dependencies (step mode).** Run the **Ensure Dependencies(`<ID>`)**
procedure before running any tests. Marker-guarded — a no-op if implementation
already installed, but keeps a resumed/partial pipeline (entering directly at QA
in a fresh worktree) safe.

**Spawn agent:** qa-engineer

Resolve model for `qa-engineer` with context `qa`.

Run `n1_config_val '.testCoverage.tier'` (default `"maintain"` if `testCoverage` block is absent or `tier` key is missing).

Spawn the qa-engineer agent with:
- The paths to its inputs — instruct the agent: "Read these files yourself: `$N1_HOME/memory/<ID>/ticket.md` (acceptance criteria), `$N1_HOME/memory/<ID>/implementation.md` (what was built, files changed), and `$N1_HOME/memory/<ID>/plan.md` if it exists, else `$N1_HOME/memory/<ID>/brainstorm.md` (scope context). Their content is NOT inlined here."
- The `## Key Decisions` and `## Escalations` slices of `overview.md` (NOT the whole file) — so QA knows which choices were deliberate and why, instead of re-litigating them
- `testCoverage.tier` value
- Directive: "You are operating in **{tier}** mode." (substitute the actual tier value)
- Directive: "Scratch-artifact policy: write any throwaway benchmark or investigative/spike test (one that answers a current question rather than verifying committed code) under `$N1_HOME/memory/<ID>/benchmarks/` or `$N1_HOME/memory/<ID>/tests/` (both gitignored; create the directory if needed) — never into the repo's test suite. Tests that verify the implementation still go into the repo as usual. When unsure, default to scratch."
- Output-path directive: "Write your full QA Report (your standard Output Format) to `$N1_HOME/memory/<ID>/qa.md` yourself, as a full overwrite (never append). Return to the orchestrator ONLY this compact block:
  `Verdict: PASS|FAIL` / `Bugs found: yes|no` (one line per bug if yes) / `TQ-relevant notes: <one line or none>` / a 3–5 sentence summary of the test work. Do NOT return the full report."

After the agent returns:

**Extract and persist signals:**
Parse the qa-engineer's compact return for a line starting with `n1:signals `:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
SIGNAL_LINE=$(echo "$AGENT_OUTPUT" | grep -m1 '^n1:signals ')
if [ -n "$SIGNAL_LINE" ]; then
    PAIRS=$(echo "$SIGNAL_LINE" | sed 's/^n1:signals //')
    n1_write_signals "$N1_HOME/memory/$ID/qa.md" $PAIRS
fi
```

**Compact implementation memory for review:**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/memory.sh"
n1_compact_memory "$N1_HOME/memory/$ID/implementation.md" "implementation summary,completed tasks,files changed,test results,decisions"
```

- The agent wrote `$N1_HOME/memory/<ID>/qa.md` itself. Verify it:
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
  n1_verify_dependencies "$N1_HOME/memory/$ID" qa.md
  ```
  If missing/empty (agent failed to write), write the returned summary block to `qa.md` as a fallback and note the gap in overview's `## Key Decisions`.
- Update overview: `[x] QA`, set `step: qa`
- **Maintain-mode skip path:** If tier is `maintain` AND QA verdict is PASS with "No test work needed" → skip the QA bug-fix loop below and proceed to Step 7 (Review). The code-reviewer still receives `qa.md` and evaluates the absence of new tests against the `maintain` tier expectation (zero new tests is correct).
- If QA verdict is FAIL (test reveals a bug):
  - Report bug details to the user
  - Spawn developer agent (resolve model for `developer`) to fix the bug, passing:
    - The bug details from the returned verdict block
    - List of affected files
    - Output-path directive: "After applying fixes, record your 'Fixes Applied' report (your standard Fix Cycle output format) in `$N1_HOME/memory/<ID>/implementation.md` yourself, under a `## QA Fix Cycle <N>` heading where `<N>` is the current `qa_fix_cycle` value. If a `## QA Fix Cycle <N>` section for this N already exists, REPLACE it (idempotent upsert — safe on re-run), never duplicate it. Return to the orchestrator ONLY: the list of commit SHAs with one-line summaries, and `Findings fixed: N/M`."
  - Run via Bash, then re-run QA:
    ```bash
    source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
    n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle"
    ```
  - **Bounded loop:** stop after `qa.maxFixAttempts` cycles (config, default 3). On exhaustion, escalate instead of looping forever. The counter is persisted, so the bound survives a resume. The bound and its default are declared in `pipeline.json` `loops[]` (`qa_fix`).

**Step-mode escalation protocol.** In step mode there is no interactive channel — do NOT print a question for the user. When this step must escalate (fix-loop bound exhausted, or a blocking ambiguity it cannot resolve):

1. Write `$N1_HOME/memory/<ID>/escalation/request.json` (create the directory if needed):
   ```json
   {
     "run_id": "<value of the N1_RUN_ID environment variable>",
     "step": "qa",
     "questions": [{
       "id": "qa_fix_exhausted",
       "text": "<one-paragraph description of what is blocked and why, with concrete specifics>",
       "options": ["Retry with guidance: another fix attempt with your instructions", "Accept as-is: proceed to review with the failure documented in qa.md", "Abort: stop the pipeline"],
       "recommendation": "<the option you would pick, with a one-line reason>",
       "context": "<cycles used, remaining findings/failures, error excerpts>"
     }]
   }
   ```
2. Run via Bash:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
   n1_emit_step_result "qa" "escalation" "null" "{\"qa_fix_cycle\":$qa_fix_cycle}"
   ```
   Then STOP.
3. **On re-run:** check `$N1_HOME/memory/<ID>/escalation/response.json`. If it exists and its `run_id` matches `N1_RUN_ID`, apply the answer for `qa_fix_exhausted`:
   - "Retry with guidance" → raise the loop ceiling to `maxFixAttempts × 2` (hard ceiling, same pattern as n1-ci), record the guidance in overview `## Escalations`, and continue the fix loop using it.
   - "Accept as-is" → record the decision in overview `## Escalations` and emit `outcome: "pass"` (the pipeline proceeds with the issue documented in this step's memory file).
   - "Abort" → record it and emit `outcome: "error"` with `next_step: null`.

In full pipeline mode this protocol does NOT apply — keep the interactive prompt below unchanged.

In full pipeline mode: "After <N> QA fix cycles this test still fails: [details]. Please advise."


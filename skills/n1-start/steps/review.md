
**Ensure dependencies (step mode).** Run the **Ensure Dependencies(`<ID>`)**
procedure before any reviewer that may execute lint/typecheck tooling.
Marker-guarded no-op on the normal path.

**Shared review core:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/review-core.md` with `<BASE_BRANCH>` = the recorded branch point when available, else the `git.defaultBranch` value from `$N1_HOME/config.json`:
```bash
BP_FILE="$N1_HOME/memory/<ID>/branch-point"
BASE_BRANCH=$( [ -f "$BP_FILE" ] && cat "$BP_FILE" || echo "<git.defaultBranch from config>" )
```
(The branch-point file pins the review diff to THIS ticket's commits; diffing against `git.defaultBranch` balloons to the whole parent branch when the run started from a non-default branch.) It defines the diff-surface classification (DOC_CONFIG_ONLY, SECURITY_RELEVANT), reviewer selection with skip-recording, the Codex probe + CODEX_ACTIVE gating with retry, and the code-reviewer scope-narrowing directive.

**Spawn agents in PARALLEL:** code-reviewer + security-reviewer (+ Codex reviewer if enabled)

Resolve models for code-reviewer and security-reviewer.

Prepare review context (curated per reviewer, not one identical bundle):
- **Shared:** the PATHS `$N1_HOME/memory/<ID>/ticket.md`, `$N1_HOME/memory/<ID>/implementation.md`, `$N1_HOME/memory/<ID>/qa.md` (instruct each reviewer: "Read these files yourself; their content is NOT inlined here"), the default branch name, and the `## Key Decisions` + `## Escalations` slices of `overview.md` inline — so neither reviewer flags a deliberate, recorded choice as a defect.
- **code-reviewer also receives** the path `$N1_HOME/memory/<ID>/brainstorm.md` (read it yourself) — design intent matters for a design-quality review.
- **code-reviewer also receives** `testCoverage.tier` value (same value read in Step 6) — for Test Quality evaluation calibration.
- **security-reviewer does NOT receive** `brainstorm.md` or `testCoverage.tier` — the design narrative and test tier are low-signal for vulnerability scanning. Keep its context lean: acceptance criteria + changed-file list + the diff are its high-signal inputs.

Spawn all selected reviewers simultaneously:
- **code-reviewer** with the code review context (scoped per the rule above) — always.
- **security-reviewer** with the security review context — only if `SECURITY_RELEVANT`.
- **Codex review command** — only if CODEX_ACTIVE conditions are met.

After ALL return, merge findings:
- Combine outputs into `$N1_HOME/memory/<ID>/review.md`
- Prefix code-reviewer findings with [CR-N], security-reviewer with [SEC-N], codex-adapter with [CX-N]
- Combined verdict: FAIL if any reviewer returned FAIL
- **Partial-failure handling:** if any reviewer errors, times out, or returns malformed output, retry that reviewer once. If it still fails, proceed with the remaining reviewers' findings, record the gap explicitly in review.md (e.g., "⚠ Codex review did not complete — review incomplete"), and do NOT treat the missing reviewer as a PASS.

### 7b. TQ FIX LOOP (if TQ findings exist)

After merging review findings, check code-reviewer output for `[TQ-N]` findings at Medium severity or above.

**If no TQ findings at Medium+:** Skip to Step 8.

**If TQ findings at Medium+ exist:**

1. Extract the TQ findings from `review.md`
2. Spawn **qa-engineer** (not developer) with:
   - The TQ findings (what to fix/remove)
   - The path to current `qa.md` — instruct the agent: "Read `$N1_HOME/memory/<ID>/qa.md` yourself — your original test work. Its content is NOT inlined here."
   - `testCoverage.tier` value
   - Directive: "**TQ Fix Mode — skip your standard 6-step process.** The code-reviewer flagged these test quality issues. Your only task: remove or rewrite the specific tests identified in the TQ findings below. After making those changes, run the test suite to confirm no regressions. Do not follow Steps 1–5 of your normal process."
   - Output-path directive: "Write your full QA Report (your standard Output Format) to `$N1_HOME/memory/<ID>/qa.md` yourself, as a full overwrite (never append). Return to the orchestrator ONLY this compact block:
     `Verdict: PASS|FAIL` / `Bugs found: yes|no` (one line per bug if yes) / `TQ-relevant notes: <one line or none>` / a 3–5 sentence summary of the test work. Do NOT return the full report."
3. After QA returns:
   - The qa-engineer updated `$N1_HOME/memory/<ID>/qa.md` itself (verify non-empty as in Step 6; fallback-write the returned summary if not)
   - Run via Bash:
     ```bash
     source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
     n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle"
     ```
4. **If any TQ findings were High** (pre-existing assertion rewriting = potential bug): re-run code-reviewer's TQ dimension only. This is a targeted re-check of test quality, not a full code re-review. Spawn code-reviewer with:
   - Updated `qa.md`
   - `testCoverage.tier`
   - Directive: "Re-evaluate Test Quality only. Check whether the TQ-High findings (assertion rewriting) were resolved. Do not re-review code quality, design, or security."
   - If new TQ-High findings emerge, loop back to step 1
5. **If TQ findings were Medium/Low only:** No re-review needed. Proceed to Step 8.
6. **Bounded:** same `qa.maxFixAttempts` (config, default 3) counter as the QA bug-fix loop. On exhaustion, escalate instead of looping forever.

**Step-mode escalation protocol (TQ fix loop).** In step mode there is no interactive channel — do NOT print a question for the user. When the TQ fix loop exhausts its bound:

1. Write `$N1_HOME/memory/<ID>/escalation/request.json` (create the directory if needed):
   ```json
   {
     "run_id": "<value of the N1_RUN_ID environment variable>",
     "step": "review",
     "questions": [{
       "id": "tq_fix_exhausted",
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
   n1_emit_step_result "review" "escalation" "null" "{\"qa_fix_cycle\":$qa_fix_cycle}"
   ```
   Then STOP.
3. **On re-run:** check `$N1_HOME/memory/<ID>/escalation/response.json`. If it exists and its `run_id` matches `N1_RUN_ID`, apply the answer for `tq_fix_exhausted`:
   - "Retry with guidance" → raise the loop ceiling to `maxFixAttempts × 2` (hard ceiling, same pattern as n1-ci), record the guidance in overview `## Escalations`, and continue the fix loop using it.
   - "Accept as-is" → record the decision in overview `## Escalations` and emit `outcome: "pass"` (the pipeline proceeds with the issue documented in this step's memory file).
   - "Abort" → record it and emit `outcome: "error"` with `next_step: null`.

In full pipeline mode this protocol does NOT apply — keep the interactive prompt below unchanged.

In full pipeline mode: "After <N> QA fix cycles these TQ findings remain: [list]. Please advise."

**After Step 7b completes, recompute the merged verdict:** If the original FAIL was caused solely by TQ-High findings and Step 7b resolved them (no TQ-High findings remain), AND there are no CR-Critical, CR-High, SEC, or CX-Critical/CX-High findings in `review.md`, update the merged verdict to PASS and skip Step 8. Proceed directly to Step 9 (LOCAL TESTING) or Step 10 (PR CREATION).

If combined verdict remains FAIL after Step 7b, proceed to Step 8 (FIX) — unless in step mode with `review_fix_cycle` at its bound, in which case escalate using the protocol below. The bound is `review.maxFixAttempts` (config in `$N1_HOME/config.json`, default 3 — the `review_fix` `max_default` in `pipeline.json`).

**Step-mode escalation protocol (main review loop).** In step mode there is no interactive channel — do NOT print a question for the user. When combined verdict is FAIL and `review_fix_cycle` has reached `review.maxFixAttempts` (config, default 3):

1. Write `$N1_HOME/memory/<ID>/escalation/request.json` (create the directory if needed):
   ```json
   {
     "run_id": "<value of the N1_RUN_ID environment variable>",
     "step": "review",
     "questions": [{
       "id": "review_fix_exhausted",
       "text": "<one-paragraph description of what is blocked and why, with concrete specifics>",
       "options": ["Retry with guidance: another fix attempt with your instructions", "Accept as-is: proceed with remaining findings documented in review.md", "Abort: stop the pipeline"],
       "recommendation": "<the option you would pick, with a one-line reason>",
       "context": "<cycles used, remaining [CR-N]/[SEC-N]/[CX-N] findings, error excerpts>"
     }]
   }
   ```
2. Run via Bash:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
   n1_emit_step_result "review" "escalation" "null" "{\"review_fix_cycle\":$review_fix_cycle}"
   ```
   Then STOP.
3. **On re-run:** check `$N1_HOME/memory/<ID>/escalation/response.json`. If it exists and its `run_id` matches `N1_RUN_ID`, apply the answer for `review_fix_exhausted`:
   - "Retry with guidance" → raise the ceiling to double the review-cycle bound (`review.maxFixAttempts` × 2, default 3 × 2 = 6) (hard ceiling, same pattern as n1-ci), record the guidance in overview `## Escalations`, and continue the fix loop using it.
   - "Accept as-is" → record the decision in overview `## Escalations` and emit `outcome: "pass"` (the pipeline proceeds with the issue documented in this step's memory file).
   - "Abort" → record it and emit `outcome: "error"` with `next_step: null`.

In full pipeline mode this protocol does NOT apply — keep the interactive prompt unchanged.

In full pipeline mode: "After `review.maxFixAttempts` (default 3) review cycles, these findings remain unresolved: [list]. Please advise."


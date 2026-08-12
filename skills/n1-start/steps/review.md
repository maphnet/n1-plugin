
**Telemetry (if enabled):** Emit `started_at` for step 9 (`review`) before spawning reviewers. This applies to both the initial review and any re-review pass after a fix cycle:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "review" 9 "${N1_HOME}/memory/$ID/telemetry" started_at=now
```

**Ensure dependencies (step mode).** Run the **Ensure Dependencies(`<ID>`)**
procedure before any reviewer that may execute lint/typecheck tooling.
Marker-guarded no-op on the normal path.

**Shared review core:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/review-core.md` with `<BASE_BRANCH>` = the recorded branch point when available, else the `git.defaultBranch` value from `$N1_HOME/config.json`:
```bash
BP_FILE="$N1_HOME/memory/<ID>/branch-point"
BASE_BRANCH=$( [ -f "$BP_FILE" ] && cat "$BP_FILE" || echo "<git.defaultBranch from config>" )
```
(The branch-point file pins the review diff to THIS ticket's commits; diffing against `git.defaultBranch` balloons to the whole parent branch when the run started from a non-default branch.) It defines the diff-surface classification (DOC_CONFIG_ONLY, SECURITY_RELEVANT), reviewer selection with skip-recording, the Codex probe + CODEX_EXPECTED/CODEX_ACTIVE gating with retry and partial-failure recovery, and the code-reviewer scope-narrowing directive.

**Spawn agents in PARALLEL:** code-reviewer + security-reviewer (+ Codex reviewer if enabled)

Resolve models for code-reviewer (with context `review`) and security-reviewer (with context `review`).

Prepare review context (curated per reviewer, not one identical bundle):
- **Shared:** the PATHS `$N1_HOME/memory/<ID>/ticket.md`, `$N1_HOME/memory/<ID>/implementation.md`, `$N1_HOME/memory/<ID>/qa.md` (instruct each reviewer: "Read these files yourself; their content is NOT inlined here"), the default branch name, and the `## Key Decisions` + `## Escalations` slices of `overview.md` inline — so neither reviewer flags a deliberate, recorded choice as a defect.
- **code-reviewer also receives** the path `$N1_HOME/memory/<ID>/brainstorm.md` (read it yourself) — design intent matters for a design-quality review.
- **code-reviewer also receives** `testCoverage.tier` value (same value read in Step 6) — for Test Quality evaluation calibration.
- **security-reviewer does NOT receive** `brainstorm.md` or `testCoverage.tier` — the design narrative and test tier are low-signal for vulnerability scanning. Keep its context lean: acceptance criteria + changed-file list + the diff are its high-signal inputs.

Spawn all selected reviewers simultaneously:
- **code-reviewer** with the code review context (scoped per the rule above) — always.
- **security-reviewer** with the security review context — only if `SECURITY_RELEVANT`.
- **Codex review command** — only if CODEX_EXPECTED.

After ALL return, merge findings:
- Combine outputs into `$N1_HOME/memory/<ID>/review.md`
- Prefix code-reviewer findings with [CR-N], security-reviewer with [SEC-N], codex-adapter with [CX-N]. Code-reviewer `[RULE-N]` findings keep their prefix (not remapped).
- Combined verdict: FAIL if any confirmed **Critical or High** findings exist across all reviewers, or any `[RULE-N]` findings exist. Medium and Low findings are reported in `review.md` but do not block the pass — consistent with n1-review Phase 4 threshold.
- **Partial-failure handling:** if any reviewer errors, times out, or returns malformed output, retry that reviewer once. If it still fails, proceed with the remaining reviewers' findings, record the gap explicitly in review.md (e.g., "⚠ Codex review did not complete — review incomplete"), and do NOT treat the missing reviewer as a PASS. **Codex-specific recovery:** when code-reviewer was narrowed because Codex was expected (`CODEX_EXPECTED`) but Codex permanently failed (`NOT CODEX_ACTIVE`), review-core.md requires a complement re-spawn of code-reviewer covering the correctness dimensions the first pass skipped — see § Partial-failure recovery.

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
4. After QA fixes TQ findings, proceed to Step 8. No re-review needed — TQ findings are non-blocking.
5. **Bounded:** same `qa.maxFixAttempts` (config, default 3) counter as the QA bug-fix loop. On exhaustion:

   **Autonomy gate (full pipeline only):** → § Autonomy Gate (qualityEscalations) with step=`review`, action=`log remaining TQ findings in review.md and proceed to Step 8`, ledger_context=`<TQ findings that remained unresolved after N attempts>`.

   If `QE` is `ask`: log remaining TQ findings in `review.md` and proceed to Step 8 — non-blocking findings do not stall the pipeline.

If combined verdict remains FAIL after Step 7b, proceed to Step 8 (FIX) — unless in step mode with `review_fix_cycle` at its bound, in which case escalate using the protocol below. The bound is `review.maxFixAttempts` (config in `$N1_HOME/config.json`, default 3 — the `review_fix` `max_default` in `pipeline.json`).

**Step-mode escalation protocol (main review loop).** In step mode there is no interactive channel — do NOT print a question for the user. When combined verdict is FAIL and `review_fix_cycle` has reached `review.maxFixAttempts` (config, default 3): → § Step-Mode Escalation Protocol with step=`review`, id=`review_fix_exhausted`, options=["Retry with guidance: another fix attempt with your instructions", "Accept as-is: proceed with remaining findings documented in review.md", "Abort: stop the pipeline"], context=cycles used + remaining [CR-N]/[SEC-N]/[CX-N] findings.

**Step result override:** In SKILL.md § Step-Mode Escalation Protocol step 2, use this command instead:
`n1_emit_step_result "review" "escalation" "null" "{\"review_fix_cycle\":$review_fix_cycle}" "" "$N1_HOME/memory/$ID"`

**On re-run**, apply the answer for `review_fix_exhausted`:
- "Retry with guidance" → raise the ceiling to `review.maxFixAttempts` × 2 (default 6, hard ceiling), record guidance in overview `## Escalations`, continue the fix loop.
- "Accept as-is" → record in overview `## Escalations`, emit `outcome: "pass"`.
- "Abort" → record it, emit `outcome: "error"` with `next_step: null`.

**Autonomy gate (full pipeline only):** → § Autonomy Gate (qualityEscalations) with step=`review`, action=`accept remaining findings and continue`, ledger_context=`<findings that remained unresolved after N fix cycles>`.

If `QE` is `ask`: "After `review.maxFixAttempts` (default 3) review cycles, these findings remain unresolved: [list]. Please advise."

**Step result (step mode) — pass path:**

When combined review verdict is PASS:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
LT=$(n1_config_val '.localTesting.enabled')
if [ "${LT:-false}" = "true" ]; then
    NEXT="local-testing"
else
    NEXT="pr"
fi
n1_emit_step_result "review" "pass" "$NEXT" "null" "" "$N1_HOME/memory/$ID"
```

When combined review verdict is FAIL and fix loop is within bound (not escalated):
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
new_count=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle")
n1_emit_step_result "review" "fail" "fix" "{\"review_fix_cycle\":$new_count}" "" "$N1_HOME/memory/$ID"
```

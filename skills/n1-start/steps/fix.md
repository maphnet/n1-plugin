
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

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
DEVELOPER_MODEL=$(n1_resolve_model developer fix)
echo "DEVELOPER_MODEL=$DEVELOPER_MODEL"
```

Spawn the developer with model `$DEVELOPER_MODEL` (resolved above — do NOT substitute a different model).

Pass to developer:
- Combined review findings (Critical + High only)
- List of affected files
- Output-path directive: "After applying fixes, record your 'Fixes Applied' report (your standard Fix Cycle output format) in `$N1_HOME/memory/<ID>/implementation.md` yourself, under a `## Fix Cycle <N>` heading where `<N>` is the current `review_fix_cycle` value. If a `## Fix Cycle <N>` section for this N already exists, REPLACE it (idempotent upsert — safe on re-run), never duplicate it. Return to the orchestrator ONLY: the list of commit SHAs with one-line summaries, and `Findings fixed: N/M`."

**Fix-the-class directive (security-shaped findings):** Before spawning the developer, scan the confirmed Critical/High findings. If ANY of the following conditions is true — a finding tagged `[SEC-N]`, OR a finding tagged `[CX-N]` whose title contains any of: injection, XSS, CSRF, authentication, authorization, traversal, deserialization, command execution, SSRF, open redirect, SQL injection, path traversal, RCE — append this directive to the developer spawn prompt:

> "One or more findings are security-shaped. When fixing a security finding, do NOT fix only the specific instance reported. Instead, fix the entire CLASS of the vulnerability: search the codebase for all variants of the same pattern (e.g., all injection points, all unsanitized inputs of the same type, all instances of the same auth bypass pattern) and fix them all in one pass. This prevents variant whack-a-mole where fixing one instance exposes the next variant in the subsequent review cycle."

After developer returns:
- Record the fix commit SHA for delta re-review:
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
  LAST_FIX_SHA=$(git rev-parse HEAD)
  n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "last_fix_sha" "$LAST_FIX_SHA"
  ```
- Run via Bash (so the bound survives a resume):
  ```bash
  n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle"
  ```
- Go back to **Step 7** (REVIEW) — re-run both reviewers
- The bound is `review.maxFixAttempts` (config in `$N1_HOME/config.json`, default 3); when `review_fix_cycle` reaches it, escalate to the user.

**Step-mode escalation protocol.** In step mode there is no interactive channel — do NOT print a question for the user. When this step must escalate (a blocking ambiguity it cannot resolve):

1. Write `$N1_HOME/memory/<ID>/escalation/request.json` (create the directory if needed):

   **Problem preamble:** Before writing, compose a 1-2 sentence summary:
   - Extract the title from the `# <ID>: <Title>` heading in `$N1_HOME/memory/<ID>/overview.md`.
   - Extract the first non-blank line under `### Core Ask` in `$N1_HOME/memory/<ID>/ticket.md`.
   - Format: `"{Title}: {Core Ask (≤1 sentence)}."` — call this `PREAMBLE`. If either part is unavailable omit it.
   - **Bug root cause (bug tickets only):** Source `"${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"` first, then: if `$N1_HOME/memory/<ID>/analysis.md` contains a `### Bug Investigation` section AND the `has_bug_root_cause` signal is strictly `true` (read via `n1_read_signal`), prepend one sentence summarizing the root cause: `"Root cause: {root cause}. "` — prepend this to `PREAMBLE`. If the signal is `false`, absent, or any other value, omit the root cause line entirely — do not fall back to parsing the section body.
   - Prepend `PREAMBLE` (followed by a space) to `text`.

   ```json
   {
     "run_id": "<value of the N1_RUN_ID environment variable>",
     "step": "fix",
     "questions": [{
       "id": "fix_blocked",
       "text": "{PREAMBLE} <one-paragraph description of what is blocked and why, with concrete specifics>",
       "options": ["Retry with guidance: another fix attempt with your instructions", "Accept as-is: proceed with remaining findings documented in review.md", "Abort: stop the pipeline"],
       "recommendation": "<the option you would pick, with a one-line reason>",
       "context": "<cycles used, remaining [TQ-N]/[CR-N]/[SEC-N]/[CX-N] findings, error excerpts>"
     }]
   }
   ```
1.5. If `n1_escalation_val channel` is `tracker` or `both`, also run the **Post-to-Tracker procedure** (see `skills/n1-start/references/tracker-escalation.md`).

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

**Autonomy gate (full pipeline only):** read the policy first:

```bash
QE=$(n1_autonomy_val 'qualityEscalations')
```

If `QE` is `auto-accept` AND the situation is NOT security/architecture/public-API related (those always block): take the recommended action instead of asking — accept the developer's best-effort resolution as-is, note the ambiguity, and append a Decision Ledger row to `$N1_HOME/memory/$ID/overview.md` per `skills/n1-start/ledger.md`:

`| fix | quality | A | [auto] | <ambiguity the developer encountered during fix cycle> | Accept developer resolution, proceed | Ask user, Abort | qualityEscalations=auto-accept; surfaced for PR review |`

Then continue the pipeline as if the user had chosen the recommended option. Otherwise (policy `block`, or safety-relevant): ask as below.

In full pipeline mode: compose `PREAMBLE` as described in the step-mode escalation protocol above (title + Core Ask; append root cause sentence only if the `has_bug_root_cause` signal is strictly `true` — do not parse section body prose as a fallback). Then: "{PREAMBLE} The developer encountered an ambiguity during this fix cycle that requires your input: [details]. Please advise."

If the combined Step-7 verdict is PASS:
- Run via Bash:
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
  n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "clean_passes"
  ```
- Resolve `MIN_CLEAN=$(n1_config_val '.review.minCleanPasses')`; if empty, default to `1` (never re-run reviewers that already returned PASS — the config knob remains for anyone wanting belt-and-suspenders, only the default is 1).
- If `clean_passes` < `MIN_CLEAN`: go back to Step 7
- If `clean_passes` >= `MIN_CLEAN`: proceed

**Full-suite regression check (orchestrator-side, once at PASS transition):**

Discover the full-suite test command using the same detection as the qa-engineer agent (Step 2: Find test conventions): inspect the project root for `package.json` (`scripts.test`), `pytest.ini`, `pyproject.toml`, `setup.cfg`, `phpunit.xml`, `go.mod` (→ `go test ./...`), and a `Makefile` `test` target — first match wins.

- **No test configuration found:** append one line to the current `## Fix Cycle <N>` section in `$N1_HOME/memory/<ID>/implementation.md` (where `<N>` is `review_fix_cycle`): `Full-suite check skipped: no test configuration detected.` Then proceed.
- **Test configuration found:** run via Bash and capture the exit code:
  ```bash
  <discovered-test-command> 2>&1; FULL_SUITE_EXIT=$?
  ```
  Append one line to the current `## Fix Cycle <N>` section in `$N1_HOME/memory/<ID>/implementation.md`:
  ```
  **Full-suite run:** exit code <FULL_SUITE_EXIT> — <PASS|FAIL>
  ```
  - **Exit code 0 (pass):** proceed.
  - **Exit code non-zero (fail):** surface the failure output to the user: "Full test suite failed after fix cycle <N> (exit code <FULL_SUITE_EXIT>) — potential regression introduced during fix cycles. Fix failing tests before proceeding, or acknowledge explicitly."
    - **Full pipeline mode:** read `MP=$(n1_autonomy_val 'mechanicalPrompts')`. If `MP` is `auto`: auto-spawn the developer agent once to fix the regression (same spawn parameters as the fix cycle above, with additional context: "Full test suite failed — fix the regressions introduced during fix cycles before returning"). Append a Decision Ledger row: `| fix | mechanical | B | [auto] | Full-suite regression after fix cycle <N> | Spawn developer to fix regression | Ask user, Proceed with regression | mechanicalPrompts=auto; regression fix attempted once |`. After developer returns, re-run the full-suite check once more; if it still fails, fall through to the interactive prompt below. If `MP` is `ask` (default) or the re-run still fails: ask: "Fix the regression now (re-spawn developer) or proceed anyway (regression will land in CI)?"
    - **Step mode:** escalate with id `full_suite_regression` (options: `["Fix: spawn developer to resolve", "Proceed: acknowledge regression"]`, recommendation: `Fix`). Emit step result and STOP.
    - Do NOT silently proceed on a non-zero exit.

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

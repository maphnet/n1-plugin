
**Telemetry (if enabled):** Emit `started_at` for step 8 (`qa`) before spawning the qa-engineer. This applies to both the initial run and any re-entry after a QA fix cycle:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "qa" 8 "${N1_HOME}/memory/$ID/telemetry" started_at=now
```

**Ensure dependencies (worktree mode).** Run the **Ensure Dependencies(`<ID>`)**
procedure before running any tests. Marker-guarded — a no-op if implementation
already installed or if no worktree is active, but keeps a resumed/partial pipeline
(entering directly at QA in a fresh worktree) safe.

> **ORCHESTRATOR GUARDRAIL (qa): do not run tests, coverage, or lint commands in this step — not before spawning the qa-engineer, not after it returns "to double-check". The qa-engineer's report is the source of truth; if it looks wrong, re-spawn the qa-engineer with the specific concern.**

**Rules injection:** Prepare rules block per SKILL.md § Rules Injection with agent_name=`qa-engineer`, changed_files_source=`diff_surface` from `implementation.md`.

**Spawn agent:** qa-engineer

Resolve model for `qa-engineer` with context `qa`.

Run `n1_config_val '.testCoverage.tier'` (default `"maintain"` if `testCoverage` block is absent or `tier` key is missing).

Spawn the qa-engineer agent with:
- The paths to its inputs — instruct the agent: "Read these files yourself: `$N1_HOME/memory/<ID>/ticket.md` (acceptance criteria), `$N1_HOME/memory/<ID>/implementation.md` (what was built, files changed), and `$N1_HOME/memory/<ID>/plan.md` if it exists, else `$N1_HOME/memory/<ID>/brainstorm.md` (scope context). Their content is NOT inlined here."
- The `## Key Decisions` and `## Escalations` slices of `overview.md` (NOT the whole file) — so QA knows which choices were deliberate and why, instead of re-litigating them
- `testCoverage.tier` value
- Directive: "You are operating in **{tier}** mode." (substitute the actual tier value)
- Directive: "Scratch-artifact policy: write any throwaway benchmark or investigative/spike test (one that answers a current question rather than verifying committed code) under `$N1_HOME/memory/<ID>/benchmarks/` or `$N1_HOME/memory/<ID>/tests/` (both gitignored; create the directory if needed) — never into the repo's test suite. Tests that verify the implementation still go into the repo as usual. When unsure, default to scratch."
- **When `$RULES_BLOCK` is non-empty**, append it to the agent's prompt.
- Output-path directive: "Write your full QA Report (your standard Output Format) to `$N1_HOME/memory/<ID>/qa.md` yourself, as a full overwrite (never append). Return to the orchestrator ONLY this compact block:
  `Verdict: PASS|FAIL` / `Bugs found: yes|no` (one line per bug if yes) / `TQ-relevant notes: <one line or none>` / a 3–5 sentence summary of the test work. Do NOT return the full report — followed by your n1:signals line per your Signal Emission section."

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
  If missing/empty (agent failed to write), write the returned summary block to `qa.md` as a fallback, set `QA_DEGRADED=1`, and note the gap in overview's `## Key Decisions`.

- **Untested-functionality gate.** After qa.md is confirmed present, parse `new_functionality_untested` and read `qa.blockUntestedFeatures` (default `false`):
  ```bash
  NEW_FUNC_UNTESTED=$(echo "${SIGNAL_LINE}" | grep -o 'new_functionality_untested=[^ ]*' | cut -d= -f2)
  source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
  BLOCK_UNTESTED=$(n1_config_val '.qa.blockUntestedFeatures' 'false')
  ```

  If `NEW_FUNC_UNTESTED` is `true`:

  - Append a tier-B Decision Ledger row to `$N1_HOME/memory/$ID/overview.md` per `skills/n1-start/ledger.md`:

    `| qa | quality | B | [auto] | New functionality shipped without test coverage | Accepted — no new tests added (maintain tier) | Add tests (minimal / standard tier) | maintain mode: new_functionality_untested signal; tests_added=0 alone cannot distinguish untested-new from nothing-new |`

  - If `BLOCK_UNTESTED` is `true`, override the QA verdict to FAIL. Append to `$N1_HOME/memory/$ID/qa.md` a note: "QA FAIL override: new functionality is untested and `qa.blockUntestedFeatures` is enabled." Record the override in overview `## Key Decisions` via `n1_append_key_decision`:
    ```bash
    # qa.blockUntestedFeatures: boolean (default false). When true, a maintain-tier run where
    # new functionality was added without test coverage fails the QA step, preventing silent
    # shipment of untested features. The Decision Ledger row is written regardless of this flag.
    if [ "${BLOCK_UNTESTED}" = "true" ]; then
        source "${CLAUDE_PLUGIN_ROOT}/lib/memory.sh"
        n1_append_key_decision "$N1_HOME/memory/$ID/overview.md" \
            "QA FAIL override: new_functionality_untested=true and qa.blockUntestedFeatures=true — verdict forced to FAIL"
    fi
    ```
    Then treat the QA result as FAIL for all downstream logic (bug-fix loop, step result).

- **Evidence check.** After qa.md is confirmed present and non-empty, verify it contains an Evidence subsection:
  ```bash
  if ! grep -q "^### Evidence" "$N1_HOME/memory/$ID/qa.md" || [ "${QA_DEGRADED:-0}" = "1" ]; then
      QA_DEGRADED=1
      # Record in overview frontmatter so review step can read it without grep
      source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
      n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_verdict_unverified" "true"
      # Append degraded-verdict Key Decision to overview.md
      source "${CLAUDE_PLUGIN_ROOT}/lib/memory.sh"
      n1_append_key_decision "$N1_HOME/memory/$ID/overview.md" \
          "QA degraded: unevidenced verdict — Evidence section absent or stub-fallback qa.md written"
  fi
  ```
  Surface to the user at the QA gate output: if `QA_DEGRADED=1`, print:
  ```
  ⚠ QA evidence missing — verdict is agent-transcribed, not machine-captured. Review step will flag this.
  ```

- **verifyGate (optional hardening).** Read `qa.verifyGate` from config (default `false`):
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
  VERIFY_GATE=$(n1_config_val '.qa.verifyGate' 'false')
  ```
  When `true`, re-execute the test suite via Bash and compare exit codes:
  ```bash
  if [ "${VERIFY_GATE}" = "true" ]; then
      # Derive runner command from Evidence section; fall back to first n1:signals runner hint
      RUNNER_CMD=$(grep "^Runner command:" "$N1_HOME/memory/$ID/qa.md" | sed 's/Runner command: //' | tr -d '`')
      if [ -n "$RUNNER_CMD" ]; then
          VERIFY_LOG="$N1_HOME/memory/$ID/qa-verify.log"
          eval "$RUNNER_CMD" > "$VERIFY_LOG" 2>&1
          ACTUAL_EXIT=$?
          REPORTED_EXIT=$(grep "^Exit code:" "$N1_HOME/memory/$ID/qa.md" | head -1 | grep -o '[0-9]*' | head -1)
          if [ "$ACTUAL_EXIT" != "$REPORTED_EXIT" ]; then
              source "${CLAUDE_PLUGIN_ROOT}/lib/memory.sh"
              source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
              n1_append_key_decision "$N1_HOME/memory/$ID/overview.md" \
                  "QA verifyGate mismatch: agent reported exit code ${REPORTED_EXIT}, re-execution exited ${ACTUAL_EXIT}. Log: $VERIFY_LOG"
              n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_verdict_unverified" "true"
              QA_DEGRADED=1
          fi
      else
          # Evidence present but no parseable "Runner command:" line — gate cannot run; say so, don't skip silently
          source "${CLAUDE_PLUGIN_ROOT}/lib/memory.sh"
          n1_append_key_decision "$N1_HOME/memory/$ID/overview.md" \
              "QA verifyGate skipped: no 'Runner command:' line parseable from qa.md Evidence section"
      fi
  fi
  # Note: without verifyGate, evidence is agent-transcribed, not machine-captured.
  # qa.verifyGate: boolean (default false). When true, the orchestrator re-executes
  # the test suite after QA, compares the exit code to the agent-reported one, and
  # records any mismatch in overview Key Decisions. Log stored under $N1_HOME/memory/<ID>/
  # (never inlined into context). Enable for projects where hallucinated pass verdicts
  # are a higher risk than the added execution time.
  ```
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

**Step-mode escalation** (if QA fix loop exhausted):
Apply the Step-Mode Escalation Protocol (see SKILL.md § Step-Mode Escalation Protocol) with:
- id: `qa_fix_exhausted`
- step: `qa`
- options: ["Retry with guidance: another fix attempt with your instructions", "Accept as-is: proceed to review with the failure documented in qa.md", "Abort: stop the pipeline"]
- context: QA fix cycles completed, specific failing tests, qa.md content summary

Note: override the shared procedure's step result to pass the cycle count:
`n1_emit_step_result "qa" "escalation" "null" "{\"qa_fix_cycle\":$qa_fix_cycle}" "" "$N1_HOME/memory/$ID"`

**On escalation response (step mode):**
- "Retry with guidance" → raise the loop ceiling to `maxFixAttempts × 2` (hard ceiling, same pattern as n1-ci), record the guidance in overview `## Escalations`, and continue the fix loop using it.
- "Accept as-is" → record the decision in overview `## Escalations` and emit `outcome: "pass"` (the pipeline proceeds with the issue documented in this step's memory file).
- "Abort" → record it and emit `outcome: "error"` with `next_step: null`.

**Autonomy gate (full pipeline only):** Apply per SKILL.md § Autonomy Gate with step=`qa`, action=`accept current test state`, ledger_context=`<failing test names and counts>`.

**If ask (default):** Prompt the user: "After <N> QA fix cycles this test still fails: [test name/details]. Please advise: Retry / Accept as-is / Abort?"

**Step result (step mode) — pass path:**

When QA verdict is PASS (no bugs, no test failures):
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_emit_step_result "qa" "pass" "review" "null" "" "$N1_HOME/memory/$ID"
```

When QA verdict is FAIL and fix loop is within bound (not escalated):
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
new_count=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle")
n1_emit_step_result "qa" "fail" "fix" "{\"qa_fix_cycle\":$new_count}" "" "$N1_HOME/memory/$ID"
```

> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user. (Orchestrator-only: a fork ignores this.)**

```bash
source ~/.n1/preamble.sh
n1_step_begin "qa" 8
n1_verify_dependencies "$N1_HOME/memory/$ID" implementation.md
```

Run **Ensure Dependencies(`<ID>`)** before spawning. > **ORCHESTRATOR GUARDRAIL (qa): do not run tests, coverage, or lint in this step**

Run `procedures/rules-injection.md`: `agent_name=qa-engineer`, `changed_files_source=diff_surface` from `implementation.md`.

**Spawn qa-engineer** (context `qa`; test-coverage tier `maintain`). Inputs: ticket.md, implementation.md, plan/brainstorm.md, `$N1_HOME/memory/$ID/analysis.md`; Key Decisions+Escalations inline; `$RULES_BLOCK`. Output: `qa.md`; return `Verdict: PASS|FAIL`, `Bugs found:`, `TQ-relevant notes:`, summary, `n1:signals`.

qa.md missing/empty: write the returned summary to it. Write the qa-engineer's full returned text to `$N1_HOME/memory/$ID/qa-return.md` with the file-write mechanism (never paste it into a shell command or string), then:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/qa-step.sh"
n1_qa_verify
n1_qa_break_check "$(git rev-parse --show-toplevel)" || exit 1
```
Output: `NEW_FUNC_UNTESTED=`, `QA_DEGRADED=0|1` (the call writes the return's signals to qa.md and re-runs the named tests isolated), `BC_VERDICT=`, `BC_MSG=` when set, the TQ list between `BREAK_CHECK_TQ<<` and `BREAK_CHECK_TQ>>` (`BREAK_CHECK_TQ` below); it writes `break_check_verdict`. Non-zero exit (invalid story base): stop the step. `NEW_FUNC_UNTESTED=true`: B-tier ledger row. `QA_DEGRADED=1`: print `⚠ QA evidence missing`.
Append `## Break-check`. `BC_VERDICT` not `red-then-green`/`no-diff`/`skipped` → `QA_RESULT=FAIL` (`no-diff`: test-only diff, no revert possible; `skipped`: non-bug, mode `bugs`, no `Regression test:` line). Non-bug: `BC_MODE==all`→blocking; else pass `BREAK_CHECK_TQ` to review. Maintain+PASS+"No test work needed"→skip fix loop. Loop exit only (PASS, cap or stall), once: run the final block below. **FAIL:** `procedures/stall-stop.md § QA` first; stalled → its exit. `qa_fix_cycle` ≥ `qa.maxFixAttempts` (default 3) → § Autonomy Gate, no increment. Else `n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle"`, then spawn developer ("Record `## QA Fix Cycle <N>`", N = new `qa_fix_cycle`). Append the developer's `Findings deferred` per `<N1_ROOT>/references/followup-filing.md` § Append (source `qa`). **Headless:** `procedures/autonomy-headless.md § Headless Guard`.
```bash
source ~/.n1/preamble.sh
n1_step_end "qa" 8 <success|failed> "{\"loop_iteration\":<qa_fix_cycle>}"
```

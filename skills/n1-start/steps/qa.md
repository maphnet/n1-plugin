
> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user.**

```bash
source "$N1_ROOT/lib/preamble.sh"
source "$N1_ROOT/lib/memory.sh"
n1_step_begin "qa" 8
SIGNAL_LINE=$(echo "$AGENT_OUTPUT" | grep -m1 '^n1:signals ')
[ -n "$SIGNAL_LINE" ] && { PAIRS=$(echo "$SIGNAL_LINE" | sed 's/^n1:signals //'); n1_write_signals "$N1_HOME/memory/$ID/qa.md" $PAIRS; }
n1_compact_memory "$N1_HOME/memory/$ID/implementation.md" "implementation summary,completed tasks,files changed,test results,decisions"
n1_verify_dependencies "$N1_HOME/memory/$ID" implementation.md
```

Run **Ensure Dependencies(`<ID>`)** before spawning. > **ORCHESTRATOR GUARDRAIL (qa): do not run tests, coverage, or lint commands in this step**

Run `procedures/rules-injection.md`: `agent_name=qa-engineer`, `changed_files_source=diff_surface` from `implementation.md`.

**Spawn qa-engineer** (context `qa`; tier from `testCoverage.tier`, default `maintain`). Inputs: ticket.md, implementation.md, plan/brainstorm.md; Key Decisions+Escalations inline; `$RULES_BLOCK`. Output: `qa.md`; return `Verdict: PASS|FAIL`, `Bugs found:`, `TQ-relevant notes:`, summary, `n1:signals`.

> **Wait contract applies** (see `procedures/output-gates.md § Wait Contract`). Idle until the qa-engineer persona returns.

qa.md missing/empty: write returned summary as fallback, `QA_DEGRADED=1`.

```bash
source "$N1_ROOT/lib/preamble.sh"
source "$N1_ROOT/lib/memory.sh"
NEW_FUNC_UNTESTED=$(echo "${SIGNAL_LINE}" | grep -o 'new_functionality_untested=[^ ]*' | cut -d= -f2)
BLOCK_UNTESTED=$(n1_config_val '.qa.blockUntestedFeatures' 'false')
if ! grep -q "^### Evidence" "$N1_HOME/memory/$ID/qa.md" || [ "${QA_DEGRADED:-0}" = "1" ]; then
    QA_DEGRADED=1; n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_verdict_unverified" "true"
    n1_append_key_decision "$N1_HOME/memory/$ID/overview.md" "QA degraded: unevidenced verdict"
fi
VERIFY_GATE=$(n1_config_val '.qa.verifyGate' 'true')
if [ "${VERIFY_GATE}" = "true" ]; then
    RUNNER_CMD=$(grep "^Runner command:" "$N1_HOME/memory/$ID/qa.md" | sed 's/Runner command: //' | tr -d '`')
    if [ -z "$RUNNER_CMD" ]; then n1_append_key_decision "$N1_HOME/memory/$ID/overview.md" "QA verifyGate skipped: no 'Runner command:' in qa.md"
    else
        VERIFY_LOG="$N1_HOME/memory/$ID/qa-verify.log"; eval "$RUNNER_CMD" > "$VERIFY_LOG" 2>&1; ACTUAL_EXIT=$?
        REPORTED_EXIT=$(grep "^Exit code:" "$N1_HOME/memory/$ID/qa.md" | head -1 | grep -o '[0-9]*' | head -1)
        [ "$ACTUAL_EXIT" != "$REPORTED_EXIT" ] && { n1_append_key_decision "$N1_HOME/memory/$ID/overview.md" "QA verifyGate mismatch: reported ${REPORTED_EXIT}, actual ${ACTUAL_EXIT}. Log: $VERIFY_LOG"; n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_verdict_unverified" "true"; QA_DEGRADED=1; }
    fi
fi
```
`NEW_FUNC_UNTESTED=true`: B-tier ledger row. `BLOCK_UNTESTED=true`: verdict FAIL. `QA_DEGRADED=1`: print `⚠ QA evidence missing`.

```bash
source "$N1_ROOT/lib/preamble.sh"
source "$N1_ROOT/lib/memory.sh"; source "$N1_ROOT/lib/breakcheck.sh"
BC_MODE=$(n1_config_val '.qa.breakCheck' 'bugs'); BC_MAX=$(n1_config_val '.qa.breakCheckMaxTests' '5')
TASK_TYPE=$(n1_read_signal "$N1_HOME/memory/$ID/ticket.md" "task_type")
TESTS_ADDED=$(n1_read_signal "$N1_HOME/memory/$ID/qa.md" "tests_added"); TESTS_ADDED=${TESTS_ADDED:-0}
BP_FILE="$N1_HOME/memory/$ID/branch-point"; BC_BASE=$( [ -f "$BP_FILE" ] && cat "$BP_FILE" || n1_config_val '.git.defaultBranch' 'main' )
BC_LOG="$N1_HOME/memory/$ID/break-check.log"; BREAK_CHECK_TQ=""; BC_VERDICT="skipped"
REG_LINE=$(grep -m1 '^Regression test:' "$N1_HOME/memory/$ID/qa.md" || true)
REG_NAME=$(echo "$REG_LINE" | sed 's/^Regression test: *//; s/ *|.*//'); REG_CMD=$(echo "$REG_LINE" | sed 's/^[^|]*| *//' | tr -d '`')
if [ -z "$REG_NAME" ] || [ -z "$REG_CMD" ]; then BC_JSON='{"success":false,"error":{"kind":"inconclusive","message":"qa.md has no Regression test: line"},"verdict":"inconclusive"}'
else BC_JSON=$(n1_break_check "$BC_BASE" "$REG_CMD" "$REG_NAME" "$BC_LOG" "<worktree dir>" || true); fi
BC_VERDICT=$(echo "$BC_JSON" | jq -r '.verdict // "inconclusive"'); BC_MSG=$(echo "$BC_JSON" | jq -r '.error.message // empty')
grep '^New test:' "$N1_HOME/memory/$ID/qa.md" | head -n "$BC_MAX" | while IFS= read -r line; do
    N=$(echo "$line" | sed 's/^New test: *//; s/ *|.*//'); C=$(echo "$line" | sed 's/^[^|]*| *//' | tr -d '`')
    echo "$N $(n1_break_check "$BC_BASE" "$C" "$N" "$BC_LOG.$N" "<worktree dir>" 2>/dev/null | jq -r '.verdict // "inconclusive"')"
done > "$N1_HOME/memory/$ID/break-check.new-tests"
BREAK_CHECK_TQ=$(awk '$2 != "red-then-green" {print $1" ("$2")"}' "$N1_HOME/memory/$ID/break-check.new-tests")
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "break_check_verdict" "$BC_VERDICT"
n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle"
```
Append `## Break-check`. `BC_VERDICT != red-then-green` → `QA_RESULT=FAIL`. Non-bug: `BC_MODE==all`→blocking; else pass `BREAK_CHECK_TQ` to review. Update: `[x] QA`, `step: qa`. Maintain+PASS+"No test work needed"→skip fix loop. **FAIL:** spawn developer ("Record `## QA Fix Cycle <N>`"). Bounded `qa.maxFixAttempts` (default 3) → § Autonomy Gate. **Headless:** `procedures/autonomy-headless.md § Headless Guard`.

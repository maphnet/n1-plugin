<!-- n1:step-snippet-exception: loop-exit end block -->

> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user. (Orchestrator-only: a fork ignores this.)**

```bash
source ~/.n1/preamble.sh
n1_step_begin "qa" 8
SIGNAL_LINE=$(echo "$AGENT_OUTPUT" | grep -m1 '^n1:signals ')
[ -n "$SIGNAL_LINE" ] && { PAIRS=$(echo "$SIGNAL_LINE" | sed 's/^n1:signals //'); n1_write_signals "$N1_HOME/memory/$ID/qa.md" $PAIRS; }
n1_verify_dependencies "$N1_HOME/memory/$ID" implementation.md
```

Run **Ensure Dependencies(`<ID>`)** before spawning. > **ORCHESTRATOR GUARDRAIL (qa): do not run tests, coverage, or lint in this step**

Run `procedures/rules-injection.md`: `agent_name=qa-engineer`, `changed_files_source=diff_surface` from `implementation.md`.

**Spawn qa-engineer** (context `qa`; test-coverage tier `maintain`). Inputs: ticket.md, implementation.md, plan/brainstorm.md, `$N1_HOME/memory/$ID/analysis.md`; Key Decisions+Escalations inline; `$RULES_BLOCK`. Output: `qa.md`; return `Verdict: PASS|FAIL`, `Bugs found:`, `TQ-relevant notes:`, summary, `n1:signals`.

qa.md missing/empty: write returned summary, `QA_DEGRADED=1`.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/memory.sh"; source "$N1_ROOT/lib/breakcheck.sh"; QD="$N1_HOME/memory/$ID"; rm -f "$QD/qa-verify.log"
NEW_FUNC_UNTESTED=$(echo "${SIGNAL_LINE}" | grep -o 'new_functionality_untested=[^ ]*' | cut -d= -f2)
if ! grep -q "^### Evidence" "$QD/qa.md" || [ "${QA_DEGRADED:-0}" = "1" ]; then
    QA_DEGRADED=1; n1_write_frontmatter "$QD/overview.md" "qa_verdict_unverified" "true"
    n1_append_key_decision "$QD/overview.md" "QA degraded: unevidenced verdict"
fi
VCMDS=$(grep -E '^(New|Regression|Fixed) test:' "$QD/qa.md" | while IFS= read -r l; do n1_break_check_parse_line "$l" cmd 2>/dev/null; done | grep .)
if [ -z "$VCMDS" ]; then n1_append_key_decision "$QD/overview.md" "QA verifyGate skipped: no named tests in qa.md"
else
    VERIFY_LOG="$QD/qa-verify.log"; ACTUAL_EXIT=0
    while IFS= read -r RUNNER_CMD; do env -i HOME="$HOME" PATH="$PATH" bash -c "$RUNNER_CMD" < /dev/null || ACTUAL_EXIT=1; done <<< "$VCMDS" > "$VERIFY_LOG" 2>&1
    REPORTED_EXIT=$(grep -m1 "^Exit code:" "$QD/qa.md" | grep -o '[0-9]*' | head -1)
    [ "${REPORTED_EXIT:-0}" = 0 ] && [ "$ACTUAL_EXIT" != 0 ] && { n1_append_key_decision "$QD/overview.md" "QA verifyGate mismatch: reported 0/none, named test failed. Log: $VERIFY_LOG"; n1_write_frontmatter "$QD/overview.md" "qa_verdict_unverified" "true"; QA_DEGRADED=1; }
fi
```
`NEW_FUNC_UNTESTED=true`: B-tier ledger row. `QA_DEGRADED=1`: print `⚠ QA evidence missing`.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/breakcheck.sh"; QD="$N1_HOME/memory/$ID"
BC_MODE=$(n1_config_val '.qa.breakCheck'); BC_MODE=${BC_MODE:-bugs}; BC_MAX=$(n1_config_val '.qa.breakCheckMaxTests'); BC_MAX=${BC_MAX:-5}
TASK_TYPE=$(n1_read_signal "$QD/ticket.md" "task_type")
TESTS_ADDED=$(n1_read_signal "$QD/qa.md" "tests_added"); TESTS_ADDED=${TESTS_ADDED:-0}
BC_DEF=$(n1_config_val '.git.defaultBranch'); BC_BASE=$(n1_break_check_base "$QD/branch-point" "${BC_DEF:-main}" "<worktree dir>")
BC_LOG="$QD/break-check.log"; BREAK_CHECK_TQ=""; BC_VERDICT="skipped"
REG_LINE=$(grep -m1 '^Regression test:' "$QD/qa.md" || true)
REG_NAME=$(n1_break_check_parse_line "$REG_LINE" name); REG_CMD=$(n1_break_check_parse_line "$REG_LINE" cmd)
if [ -z "$REG_NAME" ] || [ -z "$REG_CMD" ]; then BC_JSON='{"success":false,"error":{"kind":"inconclusive","message":"qa.md has no Regression test: line"},"verdict":"inconclusive"}'
else BC_JSON=$(n1_break_check "$BC_BASE" "$REG_CMD" "$REG_NAME" "$BC_LOG" "<worktree dir>" || true); fi
BC_VERDICT=$(echo "$BC_JSON" | jq -r '.verdict // "inconclusive"'); BC_MSG=$(echo "$BC_JSON" | jq -r '.error.message // empty')
grep '^New test:' "$QD/qa.md" | head -n "$BC_MAX" | while IFS= read -r line; do
    N=$(n1_break_check_parse_line "$line" name); C=$(n1_break_check_parse_line "$line" cmd)
    printf '%s\t%s\n' "$N" "$(n1_break_check "$BC_BASE" "$C" "$N" "$BC_LOG.${N//[^[:alnum:]._-]/_}" "<worktree dir>" 2>/dev/null | jq -r '.verdict // "inconclusive"')"
done > "$QD/break-check.new-tests"
BREAK_CHECK_TQ=$(awk -F'\t' '$2 !~ /^(red-then-green|no-diff)$/ {print $1" ("$2")"}' "$QD/break-check.new-tests")
n1_write_frontmatter "$QD/overview.md" "break_check_verdict" "$BC_VERDICT"
```
Append `## Break-check`. `BC_VERDICT` not `red-then-green`/`no-diff` → `QA_RESULT=FAIL` (`no-diff`: test-only diff, no revert possible). Non-bug: `BC_MODE==all`→blocking; else pass `BREAK_CHECK_TQ` to review. Maintain+PASS+"No test work needed"→skip fix loop. Loop exit only (PASS, cap or stall), once: run the final block below. **FAIL:** `procedures/stall-stop.md § QA` first; stalled → its exit. `qa_fix_cycle` ≥ `qa.maxFixAttempts` (default 3) → § Autonomy Gate, no increment. Else `n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle"`, then spawn developer ("Record `## QA Fix Cycle <N>`", N = new `qa_fix_cycle`). `qualityEscalations=auto-accept`: append the developer's `Findings deferred` per `<N1_ROOT>/references/followup-filing.md` § Append (source `qa`). **Headless:** `procedures/autonomy-headless.md § Headless Guard`.
```bash
source ~/.n1/preamble.sh
n1_step_end "qa" 8 <success|failed> "{\"loop_iteration\":<qa_fix_cycle>}"
```

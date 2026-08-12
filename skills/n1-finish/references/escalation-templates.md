# Escalation Templates (step mode only)

Write `$N1_HOME/memory/<ID>/escalation/request.json`:

## merge_wait_timeout

```json
{
  "run_id": "<value of the N1_RUN_ID environment variable>",
  "step": "finish",
  "questions": [{
    "id": "merge_wait_timeout",
    "text": "PR <url> is not merged after <waitForMergeMinutes> minutes. It is waiting on reviewer approval.",
    "options": ["Retry: poll again for the merge", "Abort: end the run, re-run finish later"],
    "recommendation": "Abort — re-run the finish step after the reviewer merges",
    "context": "<PR URL, CI state, mergeOnFinish value>"
  }]
}
```

## deploy_watch_timeout

Same shape: text describes the still-running run(s), options are "Retry: keep watching" / "Abort: end the run".

## Emit and resume

After writing `request.json`, if `n1_escalation_val channel` is `tracker` or `both`, also run the **Post-to-Tracker procedure** (see `skills/n1-start/references/tracker-escalation.md`). Then emit the step result via Bash and STOP:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_emit_step_result "finish" "escalation" "null" "null" "" "$N1_HOME/memory/$ID"
```

On re-run with `response.json` present and `run_id` matching `N1_RUN_ID`: "Retry" → re-enter the step that timed out (Step 2c poll or Step 3 watch); "Abort" → record in overview `## Escalations` and emit `outcome: "fail"`.

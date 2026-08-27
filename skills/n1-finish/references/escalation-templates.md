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

## pr_comments_unresolved

```json
{
  "run_id": "<value of the N1_RUN_ID environment variable>",
  "step": "finish",
  "questions": [{
    "id": "pr_comments_unresolved",
    "text": "PR <url> has <N> unresolved reviewer comments:\n<full analysis with per-comment fix/skip recommendations>",
    "options": ["Proceed: merge with unresolved comments", "Fix: address comments and re-run"],
    "recommendation": "Fix -- address the comments flagged for fixing",
    "context": "<PR URL, comment count, reviewer list>"
  }]
}
```

On re-run with `response.json` present and answer for `pr_comments_unresolved`: "Proceed" → record in overview `## Finish` as `Comments: <N> unresolved, user approved merge`, skip the comment check, continue to merge; "Fix" → record in overview `## Escalations` and emit `outcome: "fail"`.

## Emit and resume

After writing `request.json`, if `n1_escalation_val channel` is `tracker` or `both`, also run the **Post-to-Tracker procedure** (see `skills/n1-start/references/tracker-escalation.md`). Then emit the step result via Bash and STOP:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_emit_step_result "finish" "escalation" "null" "null" "" "$N1_HOME/memory/$ID"
```

On re-run with `response.json` present and `run_id` matching `N1_RUN_ID`: "Retry" → re-enter the step that timed out (Step 2d poll or Step 3 watch); "Abort" → record in overview `## Escalations` and emit `outcome: "fail"`.

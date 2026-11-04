# Procedure: Telemetry

Telemetry is always on.

```bash
source ~/.n1/preamble.sh
if n1_owner_check "$ID"; then
n1_run_begin "$ID"
n1_active_run_write "$ID" "${N1_RUN_ID:-none}" "${WORKTREE_PATH:-null}" "${BRANCH:-}"
fi
```
`owner:live <sid> <pid>` (here or from `n1_step_begin`): another live session runs `<ID>`; write nothing more. Interactive: ask the user once per run to stop or continue; on continue, rerun the two writes without the `if`. Headless: comment on the ticket with marker `n1-esc:<ID>:owner` and end the run; no blocked move, no `step:` write.

Carry `N1_SESSION_ID` and `N1_RUN_ID` from the session routing context and `n1_run_begin` into every subsequent helper invocation. Never infer identity from the shared discovery file. Missing identity remains unknown. The run's opening envelope is authoritative during finalization.

**Step markers:** each `steps/*.md` file calls `n1_step_begin "<step_name>" <N>` in its first bash block and `n1_step_end "<step_name>" <N> <success|skipped|failed> ['<metadata JSON>']` on every exit path, skips and failures included (`lib/step.sh`; begin sets `current_step:`; end sets `step:`, clears it, ticks the checkbox). `<N>` must match the table: merge pairs events by number, first start and first end win, so a looping step ends once, at loop exit. Raw `n1_emit_step_event` is only for events outside `steps/` (n1-finish verification).

| step_number | step_name | metadata fields |
|-------------|-----------|-----------------|
| 1 | `ticket` | `{}`; `{"skip_reason":"investigation_moved"}` on skip |
| 2 | `analysis` | `{}`; cross_repo fields when `relatedProjects.enabled` (analysis.md) |
| 3 | `brainstorm` | `{"planning_need":"plan\|direct"}` |
| 4 | `plan` | `{}` |
| 5 | `plan-review` | `{"verdict":"CLEAN\|FIXED"}` |
| 7 | `implementation` | `{}` |
| 8 | `qa` | `{"loop_iteration":<N>}` |
| 9 | `review` | `{"head":"<HEAD sha>"}` (success and SKIP ends) |
| 10 | `fix` | `{}` |
| 11 | `local-testing` | run: `{"action_type":"live\|test_only","infra_started":<bool>,"app_started":<bool>,"services":[...],"scenario_types":[...],"qa_overlap_pct":<int\|null>}`; skip: `{"action_type":"skipped\|smoke_deferred","skip_reason":"<reason>"}` |
| 12 | `pr` | `{}` |
| 13 | `ci` | `{}` |
| 14 | `finish` | `{}` |
| 15 | `release` | `{}` |
| 16 | `investigation-deliverable` | `{}` |
| 17 | `post_deploy_verification` | `{"action_type":"post_deploy_verification","result":"PASS\|FAIL\|SKIPPED"}` (raw, n1-finish 03-deploy) |
| 0 | `head` | `{"head":"<sha>","from":"<sha>"}` (raw, `n1_head_record`: SOFT-ONLY pass, n1-pr doc commit and clean rebase; review-pin head chain) |

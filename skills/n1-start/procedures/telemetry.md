# Procedure: Telemetry

Telemetry is always on.

```bash
source ~/.n1/preamble.sh
n1_run_begin "$ID"
n1_active_run_write "$ID" "${N1_RUN_ID:-none}" "${WORKTREE_PATH:-null}" "${BRANCH:-}"
```

Carry `N1_SESSION_ID` and `N1_RUN_ID` from the session routing context and `n1_run_begin` into every subsequent helper invocation. Never infer identity from the shared discovery file. Missing identity remains unknown. The run's opening envelope is authoritative during finalization.

**Step markers:** each `steps/*.md` file calls `n1_step_begin "<step_name>" <N>` in its first bash block and `n1_step_end "<step_name>" <N> <success|skipped|failed> ['<metadata JSON>']` on every exit path, skips and failures included (`lib/step.sh`; the end also sets `step:` and ticks the overview checkbox). `<N>` must match the table: merge pairs events by number, first start and first end win, so a looping step ends once, at loop exit. Raw `n1_emit_step_event` is only for events outside `steps/` (n1-finish verification).

| step_number | step_name | metadata fields |
|-------------|-----------|-----------------|
| 1 | `ticket` | `{}`; `{"skip_reason":"investigation_moved"}` on skip |
| 2 | `analysis` | `{}`; cross_repo fields when `relatedProjects.enabled` (analysis.md) |
| 3 | `brainstorm` | `{"planning_need":"plan\|direct"}` |
| 4 | `plan` | `{}` |
| 5 | `plan-review` | `{"verdict":"CLEAN\|FIXED"}` |
| 7 | `implementation` | `{}` |
| 8 | `qa` | `{"loop_iteration":<N>}` |
| 9 | `review` | `{}` |
| 10 | `fix` | `{}` |
| 11 | `local-testing` | run: `{"action_type":"live\|test_only","infra_started":<bool>,"app_started":<bool>,"services":[...],"scenario_types":[...],"qa_overlap_pct":<int\|null>}`; skip: `{"action_type":"skipped\|smoke_deferred","skip_reason":"<reason>"}` |
| 12 | `pr` | `{}` |
| 13 | `ci` | `{}` |
| 14 | `finish` | `{}` |
| 15 | `release` | `{}` |
| 16 | `investigation-deliverable` | `{}` |
| 17 | `post_deploy_verification` | `{"action_type":"post_deploy_verification","result":"PASS\|FAIL\|SKIPPED"}` (raw, n1-finish 03-deploy) |

# Procedure: Telemetry

Read `telemetry.enabled` from `$N1_HOME/config.json` (default `false`).

**If `true`:**
```bash
source ~/.n1/root/lib/preamble.sh
n1_run_begin "$ID"
n1_active_run_write "$ID" "${N1_RUN_ID:-none}" "${WORKTREE_PATH:-null}" "${BRANCH:-}"
```

**If `false`:** skip all telemetry shell calls. Do not generate `N1_RUN_ID`.

Carry `N1_HOST`, `N1_SESSION_ID`, and `N1_RUN_ID` from the session routing context and `n1_run_begin` into every subsequent helper invocation. Never infer identity from the shared discovery file. Missing identity remains unknown. The run's opening envelope is authoritative during finalization.

**Step markers:** Start (before spawning agents): `source "$N1_ROOT/lib/telemetry.sh"; n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "<step_name>" <N> "${N1_HOME}/memory/$ID/telemetry" started_at=now`. End (after updating overview.md): `n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "<step_name>" <N> "${N1_HOME}/memory/$ID/telemetry" completed_at=now outcome=<pass|fail|skip> loop_iteration=<N|null> metadata='<JSON>'`. Skipped steps: `outcome=skip`.

| step_number | step_name | metadata fields |
|-------------|-----------|-----------------|
| 1 | `ticket` | `{}` |
| 2 | `analysis` | `{}` — when `relatedProjects.enabled`, analysis.md owns end event with cross_repo fields |
| 3 | `brainstorm` | `{"planning_need":"plan\|direct"}` |
| 4 | `plan` | `{}` |
| 5 | `plan-review` | `{"verdict":"CLEAN\|FIXED"}` |
| 6 | `estimation` | `{"tier":"XS\|S\|M\|L\|XL"}` |
| 7 | `implementation` | `{"execution_path":"direct\|sdd"}` (+ cross_repo_runtime fields from cross-repo.md §5b) |
| 8 | `qa` | `{"loop_iteration":<N>}` |
| 9 | `review` | `{"findings_total":<N>,"findings_critical":<N>}` (+ cross_repo_xrepo_findings from cross-repo.md §7b) |
| 10 | `fix` | `{"loop_iteration":<N>}` |
| 11 | `local-testing` | `{"action_type":"live\|test_only\|skipped\|smoke_deferred","infra_started":<bool>,"app_started":<bool>,"services":[...],"scenario_types":[...],"qa_overlap_pct":<int\|null>}` |
| 12 | `pr` | `{}` |
| 13 | `ci` | `{}` |
| 14 | `finish` | `{}` |
| 17 | `smoke` | `{"action_type":"smoke_executed","endpoint_status":<string\|null>,"tests_total":<int>,"tests_passed":<int>}` |

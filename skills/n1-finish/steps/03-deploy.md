# Step 3: Deploy Watch

`POST_DEPLOY_VERIFICATION_ARTIFACT` is initialized at the n1-finish entry point and becomes `true` only after this invocation writes a canonical fallback artifact or validates a verifier artifact.

**Local-merge path (Step 2b):** skip this entire file — deploy `skipped (local merge)`, verification `n/a`. Go to Step 4. Do not dispatch post-deploy verification.

**Pre-check (no deploy workflow).** Fill `<workflowName>` from the entry's `finishWork.deployWatch.workflowName` (empty when unset):
```bash
WN='<workflowName>'; WF=$(git rev-parse --show-toplevel 2>/dev/null)/.github/workflows
if [ -n "$WN" ] || [ "$WF" = /.github/workflows ]; then echo precheck:watch
elif [ ! -d "$WF" ]; then echo precheck:none
else grep -qsE '(^|[^[:alnum:]_-])(push|workflow_run)([^[:alnum:]_-]|$)' "$WF"/*.y*ml; [ $? = 1 ] && echo precheck:none || echo precheck:watch; fi
```
`precheck:none` → deploy status `skipped (no deploy workflow)`; no helper call, no post-deploy verification; go to Step 4. A grep error or an empty workflows dir prints `precheck:watch` (never a false skip). Path/branch filters and reusable workflows are not parsed; those fall back to the grace below.

1. **Watch the merge-commit runs (5-minute registration grace, then up to 30 minutes total)** in one foreground call per chunk. First call: `<grace>` = `5`, `<remaining-minutes>` = `30`. Pass `workflowName` single-quoted as the fourth argument when set, else `''`. The fifth argument is always `any`: runs of every event on the merge commit count.
   ```bash
   source ~/.n1/preamble.sh
   source "$N1_ROOT/lib/poll.sh"
   n1_wait_release_runs <sha> <grace> <remaining-minutes> '<workflowName>' any
   ```
   The helper retries failed `gh` calls (TLS timeouts) as no information, never as "no runs" or a deploy failure, and returns within 8 minutes. Run every call with the maximum command timeout (600000 ms): the default is shorter than one chunk and would kill the wait. Never background it and never end the turn while it prints `pending` or `unknown`: re-invoke with `<remaining-minutes>` reduced by 8 per prior call, until it prints `none`, `success`, `failed` or `skipped`, or the budget is spent. `<grace>` = `0` on re-invocation only after a prior `pending`; after a prior `unknown` keep `5`. A `none` right after a prior `pending` means the runs vanished transiently: treat it as `unknown` and re-invoke. Do not use scheduled wakeups or one model turn per poll for this wait.
2. **Read the result:** the first output line is the token; after `pending`, `success`, `failed` and `skipped`, each further line is `<conclusion-or-status> <run URL>`.
3. Outcomes:
   - **All `conclusion: success`** (token `success` and every run line is `success`) → deploy status `succeeded`. Run Step 3b before Step 4.
   - **Any `failure`** (token `failed` with a `failure` or `timed_out` run line) → fetch logs: `gh run view <run-id> --log-failed 2>&1 | head -200` (`<run-id>` is the number at the end of the run URL). Report the failed run + URL. Add tracker comment (when tracker configured): "Deployment failed after merging <PR URL>: <run URL>". **Do not close the ticket. STOP.** Do not dispatch post-deploy verification.
   - **Any `cancelled`, `neutral`, `skipped`, or other non-`success` conclusion** (token `failed` without a `failure`/`timed_out` line, token `skipped`, or token `success` with any `neutral`/`skipped` run line beside the successes) → deploy status `not deployed (<conclusion>)`. Report the affected run URLs, do not dispatch post-deploy verification, and continue to Step 4. Completed non-success runs are terminal; do not keep polling them. If any run line is still `in_progress`, `queued`, `waiting` or `pending`, the deploy is still running: report those run URLs; "Deploy still running — re-run `/n1:n1-finish` to resume watching." **STOP.**
   - **Token `none`** → deploy status `none triggered` ("no deployment workflow ran for this merge" — when `workflowName` is set, name it). This is not a failure — continue to Step 4. Do not dispatch post-deploy verification.
   - **Timeout with runs still in progress** (budget spent, last token `pending`) → report the still-running run URLs; "Deploy still running — re-run `/n1:n1-finish` to resume watching." **STOP.** Do not dispatch post-deploy verification.
   - **Budget spent, last token `unknown`** (including a `none` that followed a `pending`) → deploy status `could not verify (gh unreachable)`; this is not a deploy failure. "Could not verify the deploy — re-run `/n1:n1-finish` to resume watching." **STOP.** Do not dispatch post-deploy verification.

# Step 3b: Post-Deploy Verification

Run this section only after Step 3 records deploy status `succeeded`. A verifier `FAIL` or `SKIPPED` is informational and still proceeds to Step 4; `FAIL` and `SKIPPED` do not prevent Step 4 from closing the ticket. Only the deployment failure, timeout and could-not-verify exits above stop before closure.

Set the canonical memory paths. All paths passed to the verifier are absolute, including optional files that do not exist: `ticket.md`, `analysis.md`, `local-test-plan.md`, `post-deploy-pr.diff`, `config.json`, and `dev-access.md`.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/config.sh"
MEM="$N1_HOME/memory/$ID"
TICKET_PATH="$MEM/ticket.md"
ANALYSIS_PATH="$MEM/analysis.md"
LOCAL_TEST_PLAN_PATH="$MEM/local-test-plan.md"
DIFF_PATH="$MEM/post-deploy-pr.diff"
CONFIG_PATH="$N1_HOME/config.json"
DEV_ACCESS_PATH="$N1_HOME/dev-access.md"
VERIFICATION_PATH="$MEM/post-deploy-verification.md"
```

**Canonical fallback artifact:** whenever this section does not receive a valid verifier artifact, overwrite `$VERIFICATION_PATH` with an overall `SKIPPED` summary and exactly one table row per acceptance criterion from `$TICKET_PATH`:

```markdown
# Post-Deploy Verification

Overall: SKIPPED (<reason>)

| Acceptance criterion | Status | Check / evidence | Reason |
|---|---|---|---|
| <criterion text> | SKIPPED | - | <reason> |
```

Use this same canonical shape for every fallback. The disabled path writes `SKIPPED (disabled)` for every acceptance criterion. Failed diff capture uses `SKIPPED (PR diff capture failed)`. A missing, malformed, or incomplete verifier artifact uses `SKIPPED (<artifact reason>)`; incomplete means it does not contain every ticket acceptance criterion exactly once with `PASS`, `FAIL`, or `SKIPPED`. Never convert an unavailable check into `PASS`. After writing and validating a fallback artifact, set `POST_DEPLOY_VERIFICATION_ARTIFACT=true`.

1. Evaluate the tri-state-aware gate:
   ```bash
   VERIFICATION_ENABLED=$(n1_post_deploy_verification_enabled)
   ```
   When it is `false`, do not dispatch a verifier. Write the canonical fallback artifact with `SKIPPED (disabled)` rows, set verification outcome to `skipped (disabled)`, and continue to Step 4.
2. When it is `true`, capture the merged PR diff before dispatch. For the merged PR number `<n>`:
   ```bash
   if ! gh pr diff <n> --patch > "$DIFF_PATH"; then
       : # Write the canonical fallback artifact and continue to Step 4 without dispatching.
   fi
   ```
   A failed or empty capture is not evidence of a pass. Preserve no raw command output in the artifact or tracker comment.
3. When the diff exists, remove any prior canonical artifact before dispatch so the returned artifact must have been produced by this invocation, then read the compatibility inputs from config without executing them in the controller:
   ```bash
   rm -f "$VERIFICATION_PATH"
   SMOKE_ENDPOINT=$(n1_config_val '.localTesting.smokeEndpoint')
   SMOKE_TESTS=$(n1_config_val '.localTesting.smokeTests')
   ```
   Resolve the verifier model and effort, then dispatch `post-deploy-verifier` without a prompt and wait for it to finish:
   ```bash
   IFS=$'\t' read -r VERIFIER_MODEL VERIFIER_EFFORT < <(n1_resolve_agent post-deploy-verifier post-deploy-verification)
   ```
   Give it these six absolute paths in this exact order: `$TICKET_PATH`, `$ANALYSIS_PATH`, `$LOCAL_TEST_PLAN_PATH`, `$DIFF_PATH`, `$CONFIG_PATH`, `$DEV_ACCESS_PATH`; tell it to write `$VERIFICATION_PATH`; and pass legacy `smokeEndpoint=$SMOKE_ENDPOINT` and `smokeTests=$SMOKE_TESTS`. A missing `dev-access.md` (`$DEV_ACCESS_PATH`) must not suppress those legacy smoke endpoint or smoke command checks: they remain executable verifier inputs.
4. After the verifier returns, validate the artifact against the canonical table contract. A missing or malformed artifact, a failed verifier dispatch, or rows that do not cover every ticket acceptance criterion exactly once are fallback conditions: overwrite it with the canonical `SKIPPED (<artifact reason>)` rows. Otherwise retain its `PASS`, `FAIL`, and `SKIPPED` rows. Set `POST_DEPLOY_VERIFICATION_ARTIFACT=true` only after this validation or fallback write, then set the concise verification outcome and continue to Step 4 in every case.

**Telemetry:** replace smoke-only telemetry with the verification outcome. Do not put dev-access contents, credentials, raw commands, or raw command output in telemetry.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/telemetry.sh"
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "post_deploy_verification" 17 "${MEM}/telemetry" completed_at=now outcome=<pass|fail|skip> loop_iteration=null metadata='{"action_type":"post_deploy_verification","result":"<PASS|FAIL|SKIPPED>"}'
```

**Memory:** Step 6 persists the validated `post-deploy-verification.md` criterion table in `overview.md` `## Finish`; do not record a smoke-only status.

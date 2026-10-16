# Step 3: Deploy Watch

(PR path only, when `deployWatch.enabled` is `true`)

`POST_DEPLOY_VERIFICATION_ARTIFACT` is initialized at the n1-finish entry point and becomes `true` only after this invocation writes a canonical fallback artifact or validates a verifier artifact.

**Local-merge path (Step 2b):** skip this entire file — deploy `skipped (local merge)`, verification `n/a`. Go to Step 4. Do not dispatch post-deploy verification.

If `deployWatch.enabled` is `false` → skip to Step 4 with deploy status `skipped (not configured)`. Do not dispatch post-deploy verification.

1. **Registration grace (up to 5 min):** poll for runs on the merge commit — separate commands, `sleep 30` between:
   ```bash
   gh run list --commit <sha> --json databaseId,name,status,conclusion,url
   ```
   When `workflowName` is set, add `--workflow "<workflowName>"`.
   - No runs after 5 min → deploy status `none triggered` ("no deployment workflow ran for this merge" — when `workflowName` is set, name it). This is not a failure — continue to Step 4. Do not dispatch post-deploy verification.
2. **Watch until completion (up to `timeoutMinutes` total):** poll the same command; runs are done when every run has `status: completed`.
3. Outcomes:
   - **All `conclusion: success`** → deploy status `succeeded`. Run Step 3b before Step 4.
   - **Any `failure`** → fetch logs: `gh run view <databaseId> --log-failed 2>&1 | head -200`. Report the failed run + URL. Add tracker comment (when tracker configured): "Deployment failed after merging <PR URL>: <run URL>". **Do not close the ticket. STOP.** Do not dispatch post-deploy verification.
   - **Any `cancelled`, `neutral`, `skipped`, or other non-`success` conclusion** → deploy status `not deployed (<conclusion>)`. Report the affected run URLs, do not dispatch post-deploy verification, and continue to Step 4. Completed non-success runs are terminal; do not keep polling them.
   - **Timeout with runs still in progress** → report the still-running run URLs; "Deploy still running — re-run `/n1:n1-finish` to resume watching." **STOP.** Do not dispatch post-deploy verification.

# Step 3b: Post-Deploy Verification

Run this section only after Step 3 records deploy status `succeeded`. A verifier `FAIL` or `SKIPPED` is informational and still proceeds to Step 4; `FAIL` and `SKIPPED` do not prevent Step 4 from closing the ticket. Only the deployment failure and timeout exits above stop before closure.

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

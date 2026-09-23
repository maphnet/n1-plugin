# Step 3: Deploy Watch

(PR path only, when `deployWatch.enabled` is `true`)

If `deployWatch.enabled` is `false` → skip to Step 4 with deploy status `skipped (not configured)`.

1. **Registration grace (up to 5 min):** poll for runs on the merge commit — separate commands, `sleep 30` between:
   ```bash
   gh run list --commit <sha> --json databaseId,name,status,conclusion,url
   ```
   When `workflowName` is set, add `--workflow "<workflowName>"`.
   - No runs after 5 min → deploy status `none triggered` ("no deployment workflow ran for this merge" — when `workflowName` is set, name it). This is **not** a failure — continue to Step 4.
2. **Watch until completion (up to `timeoutMinutes` total):** poll the same command; runs are done when every run has `status: completed`.
3. Outcomes:
   - **All `conclusion: success` (or `neutral`/`skipped`)** → deploy status `succeeded`. Continue to Step 4.
   - **Any `failure`** → fetch logs: `gh run view <databaseId> --log-failed 2>&1 | head -200`. Report the failed run + URL. Add tracker comment (when tracker configured): "Deployment failed after merging <PR URL>: <run URL>". **Do not close the ticket.** **STOP.**
   - **Timeout with runs still in progress** → report the still-running run URLs; "Deploy still running — re-run `/n1:n1-finish` to resume watching." **STOP.**

# Step 3b: Post-Deploy Smoke Verification

(when `localTesting.mode` is `"smoke"`)

**Gate:** read `localTesting.mode` from config. If mode is not `"smoke"` -> skip to Step 4.
Also skip if deploy status from Step 3 is `failed` (deployment failed -- no point in smoke testing).

**Smoke execution:**

1. If `localTesting.smokeEndpoint` is configured, run a health check:
   ```bash
   HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "<smokeEndpoint>")
   echo "Smoke endpoint status: $HTTP_STATUS"
   ```
   - 2xx -> PASS
   - Other -> FAIL (report status code)

2. If `localTesting.smokeTests` array is non-empty, execute each command sequentially:
   ```bash
   # For each command in smokeTests array:
   eval "<command>" 2>&1
   # Record exit code: 0 = PASS, non-zero = FAIL
   ```
   Continue through all commands even if some fail.

3. If neither `smokeEndpoint` nor `smokeTests` is configured -> skip with message: "Smoke mode is configured but no smoke endpoint or tests defined. Configure `localTesting.smokeEndpoint` or `localTesting.smokeTests` in config." Proceed to Step 4.

**Results:**
- All PASS -> smoke status `passed`. Proceed to Step 4.
- Any FAIL -> smoke status `failed`. Report failures. Add tracker comment (when tracker configured): "Post-deploy smoke tests failed after merging <PR URL>: <failure details>". Proceed to Step 4 (do not block ticket close -- the code is already merged; failures are informational).

**Telemetry:**
```bash
source ~/.n1/root/lib/preamble.sh
source "$N1_ROOT/lib/telemetry.sh"
SMOKE_OUTCOME=$( [ "$SMOKE_ALL_PASSED" = "true" ] && echo "pass" || echo "fail" )
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "smoke" 17 "${N1_HOME}/memory/$ID/telemetry" completed_at=now outcome=$SMOKE_OUTCOME loop_iteration=null metadata="{\"action_type\":\"smoke_executed\",\"endpoint_status\":\"$HTTP_STATUS\",\"tests_total\":$TESTS_TOTAL,\"tests_passed\":$TESTS_PASSED}"
```

**Memory:** Add to the `## Finish` section in overview.md:
```markdown
- **Smoke:** <passed | failed (<details>) | skipped (not configured) | skipped (deploy failed)>
```

# Step 3: Deploy Watch

`POST_DEPLOY_VERIFICATION_ARTIFACT` is initialized at the n1-finish entry point and becomes `true` only after this invocation writes a canonical fallback artifact or validates a verifier artifact.

**Local-merge path (Step 2b):** skip this entire file — deploy `skipped (local merge)`, verification `n/a`. Go to Step 4. Do not dispatch post-deploy verification.

**Pre-check (no deploy workflow).** Fill `<workflowName>` from the entry's `finishWork.deployWatch.workflowName` (empty when unset) and `<sha>` with the merge commit SHA. Workflows are read at that commit, not the checkout:
```bash
WN='<workflowName>'; S='<sha>'
git cat-file -e "$S^{commit}" 2>/dev/null || git fetch -q origin "$S" 2>/dev/null
L=$(git ls-tree --name-only "$S" .github/workflows/ 2>/dev/null); R=$?; F=$(grep -E '\.ya?ml$' <<<"$L")
C=$(for f in $F; do git show "$S:$f" || exit 1; done 2>/dev/null); X=$?
if [ -n "$WN" ] || [ $R != 0 ] || [ $X != 0 ]; then echo precheck:watch
elif [ -z "$F" ]; then echo precheck:none 0
else set -- $F; N=$#; grep -qE '[^[:alnum:]_-](push|workflow_run)([^[:alnum:]_-]|$)' <<<"$C"; [ $? = 1 ] && echo precheck:none $N || echo precheck:watch; fi
```
`precheck:none <N>` (`<N>` = workflow files inspected) → deploy status `skipped (no deploy workflow: precheck:none, <N> workflows inspected)`; no helper call, no post-deploy verification; go to Step 4. Only `push`/`workflow_run` triggers are recognised; an unavailable SHA or any git/grep error prints `precheck:watch`. Repos that deploy via another trigger set `finishWork.deployWatch.workflowName`, which forces the watch. Path/branch filters and reusable workflows are not parsed; those fall back to the grace below.

1. **Watch the merge-commit runs (5-minute registration grace, then up to 30 minutes total)** in one foreground call per chunk. First call: `<grace>` = `5`, `<remaining-minutes>` = `30`. Pass `workflowName` single-quoted as the fourth argument when set, else `''`. The fifth argument is always `any`: runs of every event on the merge commit count. Never narrow it to one event: `gh run list --event` takes a single event, and a deploy may run on `push` or on a `workflow_run` chained from CI (the pre-check accepts both). Runs are already scoped to the merge SHA, and `workflowName` narrows them by name.
   ```bash
   source ~/.n1/preamble.sh
   source "$N1_ROOT/lib/poll.sh"
   n1_wait_release_runs <sha> <grace> <remaining-minutes> '<workflowName>' any
   ```
   The helper retries failed `gh` calls (TLS timeouts) as no information, never as "no runs" or a deploy failure, and returns within 8 minutes. Run every call with the maximum command timeout (600000 ms): the default is shorter than one chunk and would kill the wait. Never background it and never end the turn while it prints `pending` or `unknown`: re-invoke with `<remaining-minutes>` reduced by 8 per prior call, until it prints `none`, `success`, `failed` or `skipped`, or the budget is spent. `<grace>` = `0` on re-invocation only after a prior `pending`; after a prior `unknown` keep `5`. A `none` right after a prior `pending` means the runs vanished transiently: treat it as `unknown` and re-invoke. Do not use scheduled wakeups or one model turn per poll for this wait.
2. **Read the result:** the first output line is the token; after `pending`, `success`, `failed` and `skipped`, each further line is `<conclusion-or-status> <run URL>`.
3. Outcomes:
   - **All `conclusion: success`** (token `success` and every run line is `success`) → deploy status `succeeded`. Run Step 3b before Step 4: read `<N1_ROOT>/skills/n1-finish/references/post-deploy-verification.md` now (it is not read at entry) and follow it.
   - **Any `failure`** (token `failed` with a `failure` or `timed_out` run line) → fetch logs: `gh run view <run-id> --log-failed 2>&1 | head -200` (`<run-id>` is the number at the end of the run URL). Report the failed run + URL. Add tracker comment (when tracker configured): "Deployment failed after merging <PR URL>: <run URL>". **Do not close the ticket. STOP.** Do not dispatch post-deploy verification.
   - **Any `cancelled`, `neutral`, `skipped`, or other non-`success` conclusion** (token `failed` without a `failure`/`timed_out` line, token `skipped`, or token `success` with any `neutral`/`skipped` run line beside the successes) → deploy status `not deployed (<conclusion>)`. Report the affected run URLs, do not dispatch post-deploy verification, and continue to Step 4. Completed non-success runs are terminal; do not keep polling them. If any run line is still `in_progress`, `queued`, `waiting` or `pending`, the deploy is still running: report those run URLs; "Deploy still running — re-run `/n1:n1-finish` to resume watching." **STOP.**
   - **Token `none`** → deploy status `none triggered` ("no deployment workflow ran for this merge" — when `workflowName` is set, name it). This is not a failure — continue to Step 4. Do not dispatch post-deploy verification.
   - **Timeout with runs still in progress** (budget spent, last token `pending`) → report the still-running run URLs; "Deploy still running — re-run `/n1:n1-finish` to resume watching." **STOP.** Do not dispatch post-deploy verification.
   - **Budget spent, last token `unknown`** (including a `none` that followed a `pending`) → deploy status `could not verify (gh unreachable)`; this is not a deploy failure. "Could not verify the deploy — re-run `/n1:n1-finish` to resume watching." **STOP.** Do not dispatch post-deploy verification.

# Step 4: Close Ticket

**Queue final PR (N1-446):** head branch (`headRefName`) starts with `queue/` → no ticket, even when the name holds a ticket-like id: skip this step (the delivery gate below included) and Step 5; go to Step 6, which reports `Deploy: not watched; delivery not run (queue final PR)`; the user deploys by hand. Step 7 closes the queue's landed child tickets (N1-532); its cleanup deletes the local queue branch.

**Delivery gate (before anything else in this step):** follow `<N1_ROOT>/skills/n1-finish/steps/03b-ssh-deploy.md` (read at entry when `delivery.mode` is `"ssh"`). Continue below only when it says to return to Step 4; a successful delivery continues with the rest of Step 4, then Step 5 and Step 6, in this same run. It is a no-op unless `delivery.mode` is `"ssh"`.

**After-deploy actions (after the delivery gate returns; PR path only, skipped on the local-merge path):** follow `<N1_ROOT>/references/deployment-actions.md` (already read at entry; do not re-read) for the merged PR `<n>`. After a Step 1 pending-deploy resume, `<n>` is unknown; find it with `gh api "repos/{owner}/{repo}/commits/<SHA>/pulls" --jq '[.[] | select(.merged_at)] | .[0].number'`.
§ Parse with `PRS=<n>` and `OUT=$N1_HOME/scratch/deploy-actions-<n>.tsv` (`RELEASE_ROWS` stays `defer`). `deferred:0` with `unticked:0` → continue below. `fetch-failed` → warn "Could not read PR #<n>; after-deploy actions not checked." and continue below. Otherwise (`deferred:<M>` or `unticked:<N>` above 0): read `<N1_ROOT>/skills/n1-finish/references/after-deploy-actions.md` now (it is not read at entry) and follow it.

**Hard-skip gate** — when it holds, skip immediately with the stated reason and go to Step 5:
- `tracker.mcp` is null → "Ticket close skipped: no tracker configured."

**Runtime recovery** — when the hard-skip gate passes but `tracker.statuses.done` is absent from config: follow `<N1_ROOT>/skills/n1-finish/references/done-status-recovery.md` (listed in `read-also:` at entry in this case) for the full detection and prompt procedure.

**When `tracker.statuses.done` was already present in config, or after successful recovery above, proceed:**

**Call batching:** make the tracker calls below in two turns, each issued in parallel. Turn 1 (read-only): Jira `getTransitions`, plus `getComments` when `operations.getComments` exists. Turn 2: the status move and `addComment` together, after rendering the comment and running its idempotency check against the Turn 1 comments. Judge each result on its own (item 3): a failed move never cancels the comment.

1. **Move status** via the operations map:
   - Jira: `mcp__<tracker.mcp>__<operations.getTransitions>` → find the transition whose target status equals `tracker.statuses.done` → `mcp__<tracker.mcp>__<operations.moveStatus>` with that transition ID.
   - YouTrack: `mcp__<tracker.mcp>__<operations.moveStatus>` (`update_issue`) with the `done` state value.
   - If the ticket is already in the `done` status → skip the move silently (idempotent re-run).
2. **Add comment** via `mcp__<tracker.mcp>__<operations.addComment>`, one of:
   - `"PR merged: <PR URL>"` (deploy not watched)
   - `"PR merged: <PR URL>. Deployment succeeded: <run URL>"` (deploy watched)
   - `"Merged locally into <defaultBranch>, push pending."` (local merge path)
   When the delivery step deployed, append ` Deployed via delivery.<command | steps> (<verified | not verified>).` to the chosen comment.
   Only when `POST_DEPLOY_VERIFICATION_ARTIFACT=true`, append the verification table per `<N1_ROOT>/skills/n1-finish/references/post-deploy-verification.md` § Steps 4 and 6 (read in Step 3b); otherwise omit verification details.
   Render the complete comment, including the verification table, before idempotency. When `operations.getComments` exists, check recent comments first and skip only when an identical full rendered comment is already present (idempotent re-run); otherwise add best-effort once.
3. Tracker failures: **warn, never block** — the merge already happened. Record the failure in the report.

**Covered tickets (N1-528; last action of this step, before Step 5):** only when this run's delivery gate recorded `- **Delivery:** succeeded (`, read `<N1_ROOT>/skills/n1-finish/references/covered-close.md` now (it is not read at entry) and follow it with `<SHA>` (the delivered merge SHA) and this `<ID>`. Every exit of this step runs it first, including the `mode:runbook` exit (which goes to Step 6), the Hard-skip gate and the `Go to Step 5` exits of `done-status-recovery.md`.

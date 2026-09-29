# Step 4: Close Ticket

**Delivery gate (before anything else in this step):** read `<N1_ROOT>/skills/n1-finish/steps/03b-ssh-deploy.md` and follow it. Continue below only when it says to return to Step 4. It is a no-op unless `delivery.mode` is `"ssh"`.

**After-deploy actions (after the delivery gate returns; PR path only, skipped on the local-merge path):** follow `<N1_ROOT>/references/deployment-actions.md` for the merged PR `<n>`. After a Step 1 pending-deploy resume, `<n>` is unknown; find it with `gh api "repos/{owner}/{repo}/commits/<SHA>/pulls" --jq '[.[] | select(.merged_at)] | .[0].number'`.
1. § Parse with `PRS=<n>` and `OUT=$N1_HOME/scratch/deploy-actions-<n>.tsv`. `unticked:0` → continue below. `fetch-failed` → warn "Could not read PR #<n>; after-deploy actions not checked." and continue below.
2. **Deploy confirmed.** This means the Step 3 deploy status is `succeeded`, delivery is `succeeded`, or this run resumed a pending deploy in Step 1:
   - `mode:runbook` → § Runbook with `ID=<ID>` and `SHA=<SHA>`. Do not close the ticket. Skip the rest of Step 4 and Step 5, and go to Step 6.
   - `mode:walk` → § Walk with `PHASE=before` for any still-unticked `before` rows (the PR merged without them), then § Walk with `PHASE=after`. The PR is already merged: an aborted `PHASE=before` walk (including "No" to "Continue anyway?") only stops offering before-deploy items — it does not skip the `PHASE=after` walk that follows.
3. **Deploy not watched** (`none triggered` or `skipped (not configured)`): `mode:runbook` → leave the rows unticked for n1-release or a later run, and continue below. `mode:walk` → § Unwatched Deploy.
4. After any walk, complete or aborted, clear the pending flag and continue below. After-deploy actions never block the ticket close; unticked rows stay in the PR body.
   ```bash
   source ~/.n1/preamble.sh
   n1_write_frontmatter "$N1_HOME/memory/<ID>/overview.md" deploy_pending false || true
   ```

**Hard-skip gates** — when either holds, skip immediately with the stated reason and go to Step 5:
- `closeTicket` is `false` → "Ticket close skipped: closeTicket is false."
- `tracker.mcp` is null → "Ticket close skipped: no tracker configured."

**Runtime recovery** — when the hard-skip gates pass but `tracker.statuses.done` is absent from config: read `<N1_ROOT>/skills/n1-finish/references/done-status-recovery.md` for the full detection and prompt procedure.

**When `tracker.statuses.done` was already present in config, or after successful recovery above, proceed:**

1. **Move status** via the operations map:
   - Jira: `mcp__<tracker.mcp>__<operations.getTransitions>` → find the transition whose target status equals `tracker.statuses.done` → `mcp__<tracker.mcp>__<operations.moveStatus>` with that transition ID.
   - YouTrack: `mcp__<tracker.mcp>__<operations.moveStatus>` (`update_issue`) with the `done` state value.
   - If the ticket is already in the `done` status → skip the move silently (idempotent re-run).
2. **Add comment** via `mcp__<tracker.mcp>__<operations.addComment>`, one of:
   - `"PR merged: <PR URL>"` (deploy not watched)
   - `"PR merged: <PR URL>. Deployment succeeded: <run URL>"` (deploy watched)
   - `"Merged locally into <defaultBranch>, push pending."` (local merge path)
   When the delivery step deployed, append ` Deployed via delivery.<command | steps> (<verified | not verified>).` to the chosen comment.
   When `operations.getComments` exists, check recent comments first and skip if an identical comment is already present (idempotent re-run); otherwise add best-effort once.
3. Tracker failures: **warn, never block** — the merge already happened. Record the failure in the report.

# Step 4: Close Ticket

**Queue integration PR (N1-446):** when the PR's head branch (`headRefName`) starts with `queue/`, the PR is a queue runner final PR and carries no ticket, even when the head name contains a ticket-like id. Skip this step's ticket close and the Step 5 ticket work, and go to Step 6; the queue's landed child tickets are closed in Step 7 (N1-532); its cleanup deletes the local queue branch. This skip also bypasses the delivery gate below (deploy steps are keyed on `<ID>`), so Step 6 reports `Deploy: not watched; delivery not run (queue final PR)`; the user deploys by hand.

**Delivery gate (before anything else in this step):** follow `<N1_ROOT>/skills/n1-finish/steps/03b-ssh-deploy.md` (read at entry when `delivery.mode` is `"ssh"`). Continue below only when it says to return to Step 4; a successful delivery continues with the rest of Step 4, then Step 5 and Step 6, in this same run. It is a no-op unless `delivery.mode` is `"ssh"`.

**After-deploy actions (after the delivery gate returns; PR path only, skipped on the local-merge path):** follow `<N1_ROOT>/references/deployment-actions.md` (already read at entry; do not re-read) for the merged PR `<n>`. After a Step 1 pending-deploy resume, `<n>` is unknown; find it with `gh api "repos/{owner}/{repo}/commits/<SHA>/pulls" --jq '[.[] | select(.merged_at)] | .[0].number'`.
1. § Parse with `PRS=<n>` and `OUT=$N1_HOME/scratch/deploy-actions-<n>.tsv` (`RELEASE_ROWS` stays `defer`). When it printed `deferred:<M>` with M > 0, keep the items from its `deferred #<n> <item>` lines for the Step 6 Report's `Deferred to release:` line (a mid-step message is lost in hand-off mode); n1-finish never walks, ticks or writes them to the runbook. No line when `deferred:0`. Then: `unticked:0` → continue below. `fetch-failed` → warn "Could not read PR #<n>; after-deploy actions not checked." and continue below.
2. **Deploy confirmed.** This means the Step 3 deploy status is `succeeded`, delivery is `succeeded`, or this run resumed a pending deploy in Step 1:
   - `mode:runbook` → run § Check only when the Step 3 deploy status is `succeeded` or delivery is `succeeded` (a Step 1 resume alone does not count: no deploy was watched in this run, so run no check). When it applies, first, for each row with phase `after` that § Command classifies `check`, run § Check (no prompt; a failed or inconclusive check leaves the row). Then § Runbook with `ID=<ID>` and `SHA=<SHA>`. `runbook:none` (every unticked row was a passing check) → go to item 4 and close the ticket as usual. Any other output → do not close the ticket: when delivery is `succeeded`, run the covered-tickets paragraph at the end of this step first; skip the rest of Step 4 and Step 5, and go to Step 6.
   - `mode:walk` → § Walk with `PHASE=before` and `LATE=1` for any still-unticked `before` rows (the PR merged without them, so the deploy already ran; each is labeled and offered, never run silently), then § Walk with `PHASE=after` (its `check` rows run without a prompt). The PR is already merged: an aborted `PHASE=before` walk (including "No" to "Continue anyway?") only stops offering before-deploy items — it does not skip the `PHASE=after` walk that follows.
3. **Deploy not watched** (`none triggered` or `skipped (no deploy workflow…)`): `mode:runbook` → leave the rows unticked for n1-release or a later run (no check runs without a watched deploy), and continue below. `mode:walk` → § Unwatched Deploy.
4. After any walk, complete or aborted, or after `runbook:none`, clear the pending flag and continue below. After-deploy actions never block the ticket close; unticked rows stay in the PR body. Keep each item's outcome (ticked with its evidence, skipped, failed, or left in the runbook) for the Step 6 Report's `Deployment actions:` line; a mid-step message is lost in hand-off mode.
   ```bash
   source ~/.n1/preamble.sh
   case "<ID>" in *[!A-Za-z0-9_-]*) echo id:invalid; exit 1;; esac
   n1_write_frontmatter "$N1_HOME/memory/<ID>/overview.md" deploy_pending false || true
   ```

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
   Only when `POST_DEPLOY_VERIFICATION_ARTIFACT=true`, append `\n\nPost-deploy verification:\n` and this invocation's validated per-criterion table from `$N1_HOME/memory/<ID>/post-deploy-verification.md` (criterion, `PASS`/`FAIL`/`SKIPPED`, concise evidence, and reason). Otherwise omit verification details. Do not include dev-access contents, credentials, raw commands, or raw command output. This table is informational: `FAIL` and `SKIPPED` still close the ticket normally.
   Render the complete comment, including the verification table, before idempotency. When `operations.getComments` exists, check recent comments first and skip only when an identical full rendered comment is already present (idempotent re-run); otherwise add best-effort once.
3. Tracker failures: **warn, never block** — the merge already happened. Record the failure in the report.

**Covered tickets (N1-528; last action of this step, before Step 5):** only when this run's delivery gate recorded `- **Delivery:** succeeded (`, read `<N1_ROOT>/skills/n1-finish/references/covered-close.md` now (it is not read at entry) and follow it with `<SHA>` (the delivered merge SHA) and this `<ID>`. Every exit of this step runs it first, including the `mode:runbook` exit (which goes to Step 6), the Hard-skip gate and the `Go to Step 5` exits of `done-status-recovery.md`. A pending, `not needed (repo-only paths)` or n/a delivery never runs it. It never changes this ticket's close.

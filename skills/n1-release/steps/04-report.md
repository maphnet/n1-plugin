# Step 6: Tracker Comment (best-effort)

Only when ALL hold:
- `tracker.mcp` is configured (not null)
- `tracker.operations.addComment` exists
- `RELEASE_TICKET_IDS` is non-empty

For each ticket in `RELEASE_TICKET_IDS`:

Post: `"Released as <TAG>"` via `mcp__<tracker.mcp>__<operations.addComment>`.

When `tracker.operations.getComments` exists, check recent comments on each ticket first and skip if an identical comment is already present (idempotent re-run).

Failure on any individual ticket -> warn and continue to the next; never block the release report.

# Step 7: Report

On built-in flow success:
```
Released <TAG>

Tag:     <TAG> (pushed to origin)
Release: <release URL>
Tickets: <RELEASE_TICKET_IDS comma-separated> -- comments posted / no tickets found / tracker not configured
<tracker release summary -- only when tracker.type is "jira" and RELEASE_TICKET_IDS is non-empty>
```

On custom procedure completion:
```
Release procedure complete.

Steps completed: <N>/<total>
Ticket: <ID> — comment posted / no ticket inferred / tracker not configured
```

**Tracker release summary** (appended to report when `tracker.type` is `"jira"` and Step 5b ran):

```
Tracker release:
  Version:     "<VERSION_NAME>" -- created and released / already existed / skipped (jc-mcp not configured) / skipped (createVersion disabled)
  Fix version: set on <IDs> / skipped (setFixVersion disabled) / skipped (jc-mcp not configured)
  Tickets:     <N> moved to "<target>" / skipped (moveTickets disabled) / skipped (no status configured)
```

On idempotent skip:
```
Release <TAG> already exists — nothing to do.
```

# Step 8: Deployment Check

Only runs after a **successful release** (built-in flow success or custom procedure completion). Skipped on idempotent skip.

1. Read `release.deploymentCheck` — if `false`, skip entirely.
2. Run deployment pipeline detection per `references/ci-detection.md`:
   - Read `.github/workflows/` contents.
   - Classify into one of the five categories.
3. **Category 5** (release-triggered deployment exists):
   Report: "Deployment pipeline: `<filename>` — triggered on release, targets `<environment>` (if detectable)."

   Read `release.deployWatch.enabled` from config (default `true`).

   **If `release.deployWatch.enabled` is `true` or absent:**

   a. Resolve the commit SHA for the just-created tag:
      ```bash
      git rev-parse <TAG>^{commit}
      ```

   b. Registration grace — poll until at least one run appears (up to 5 minutes):
      ```bash
      gh run list --commit <sha> --json databaseId,name,status,conclusion,url
      ```
      When `release.deployWatch.workflowName` is set, add `--workflow "<workflowName>"`.
      Sleep 30s between polls.
      After 5 minutes with no runs: report "No deployment workflow triggered — deploy watch timed out waiting for run registration." Continue to close-out.

   c. Watch until all runs reach `status: completed`, up to `release.deployWatch.timeoutMinutes` (default `30`) minutes:
      Poll the same `gh run list` command. Sleep 30s between polls.

   d. Outcomes:
      - All runs with `conclusion: success` (or `neutral`/`skipped`): report "Deployment succeeded." Go to Step 8b.
      - Any run with `conclusion: failure` or `cancelled`: fetch failure logs:
        ```bash
        gh run view <databaseId> --log-failed 2>&1 | head -200
        ```
        Report the failed run URL and log excerpt. After-deploy actions are not run; report them as left unticked (Step 8b wording). **STOP — do not proceed.**
      - Timeout (`timeoutMinutes` elapsed, runs still in progress): report still-running URLs. Suggest re-checking manually. After-deploy actions are not run; report them as left unticked (Step 8b wording). **STOP.**

   **If `release.deployWatch.enabled` is explicitly `false`:** report "Deploy watch disabled." Go to Step 8b.
4. **Categories 1-4** — present findings and ask:
   ```
   No release-triggered deployment pipeline detected.
   <category-specific context line from detection>

   Does this project need a deployment pipeline triggered on release?
   1 — Yes, help me set one up
   2 — No, this project doesn't deploy on release
   ```
   - **2 (No)** → set `release.deploymentCheck` to `false` in `$N1_HOME/config.json` via:
     ```bash
     source ~/.n1/preamble.sh
     jq '.release.deploymentCheck = false' "$N1_HOME/config.json" > "$N1_HOME/config.json.tmp" && mv "$N1_HOME/config.json.tmp" "$N1_HOME/config.json"
     ```
     Report: "Deployment check disabled for this project. Re-enable via n1-init or by setting `release.deploymentCheck: true` in config."
     Go to Step 8b.
   - **1 (Yes)** → follow the scaffolding options for the detected category per `references/ci-detection.md`. Inspect project context (existing workflows, Dockerfile, package manager, framework) and write the workflow conversationally. Commit the new/modified workflow file to the current branch. Report the file path and remind the user to review before pushing.

# Step 8b: After-deploy Actions

Runs only when `$N1_HOME/scratch/release-actions.tsv` has `after` rows, after a successful release, and when Step 8 did not STOP (a deploy failure or timeout ends the run before this step).

- Step 8 reported "Deployment succeeded." → follow `<N1_ROOT>/references/deployment-actions.md` § Walk with `PHASE=after` and `OUT=$N1_HOME/scratch/release-actions.tsv`.
- No deploy was watched (`release.deploymentCheck` is `false`, deploy watch disabled, no workflow triggered, or Categories 1–4) → § Unwatched Deploy.

An aborted walk or skipped items never undo the release. Report any unticked rows: "After-deploy actions left unticked: <rows>. Run them by hand and tick them in the PR bodies. The next release only scans PRs merged after <TAG>."

## Idempotency

Every path is safe to re-run: existing release causes a skip; existing tag skips tag creation; existing tracker comment is not duplicated (when comments are readable). Deployment actions: only unticked PR-body items are collected and executed items are ticked, so a re-run never repeats them.

Tracker release operations are individually idempotent: existing versions are reused (not duplicated), fix versions already set are no-ops, and tickets already in the target status are skipped.

## Integration

**Called by:**
- **n1-start** -- step `release` (after finish), gated on `release.enabled`
- **Standalone** -- `/n1:n1-release`

**Invokes:**
- Inline: `gh` CLI (release view/create, auth status, PR body read/edit), git (tag, push), tracker MCP operations (comment, transitions, version create/release, fix version edit), `references/ci-detection.md` (deployment pipeline detection), `references/deployment-actions.md` (deployment actions)
- No agent spawns -- thin controller, orchestration only

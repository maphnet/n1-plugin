Run in order: Step 6, Step 8, Step 8b, Step 9. Never end the turn before Step 9 prints the final report; a failed or unverified deployment still gets the final report.

# Step 6: Tracker Comment (best-effort)

Only when ALL hold:
- `tracker.mcp` is configured (not null)
- `tracker.operations.addComment` exists
- `RELEASE_TICKET_IDS` is non-empty

For each ticket in `RELEASE_TICKET_IDS`:

Post: `"Released as <TAG>"` via `mcp__<tracker.mcp>__<operations.addComment>`.

When `tracker.operations.getComments` exists, check recent comments on each ticket first and skip if an identical comment is already present (idempotent re-run).

Failure on any individual ticket -> warn and continue to the next; never block the release report.

# Step 8: Deployment Check

Only runs after a **successful release** (built-in flow success or custom procedure completion). Skipped on idempotent skip.

Record the outcome as `DEPLOY` for the Step 9 `Deployment:` line.

1. Read `release.deploymentCheck` — if `false`, skip detection. Go to Step 8b. `DEPLOY` = `not configured`.
2. Run deployment pipeline detection per `references/ci-detection.md`:
   - Read `.github/workflows/` contents.
   - Classify into one of the five categories.
3. **Category 5** (release-triggered deployment exists):
   Report: "Deployment pipeline: `<filename>` — triggered on release, targets `<environment>` (if detectable)."

   a0. No `release` event can fire when the built-in flow created a draft (`release.draft` is `true`), or when the custom-flow Release line is `missing (declined)`, `missing (create failed)` or `missing (tag not on origin)`. A `not yet created (workflow still running)` Release is watched normally (a PAT or GitHub App token fires `release` events; the grace covers the wait for publication). Do not wait out the 5-minute grace: report "No GitHub Release was published, so no release-triggered deployment can run." `DEPLOY` = `not triggered`. Go to Step 8b.

   a. Resolve the commit SHA for the just-created tag:
      ```bash
      git rev-parse <TAG>^{commit}
      ```

   b. Watch the release-triggered runs in the foreground. First call: `<grace>` = `5`, `<remaining-minutes>` = `30`. Do not pass a workflow filter: `finishWork.deployWatch.workflowName` targets the n1-finish merge-commit deploy and would hide release-triggered runs.
      ```bash
      source ~/.n1/preamble.sh
      source "$N1_ROOT/lib/poll.sh"
      n1_wait_release_runs <sha> <grace> <remaining-minutes>
      ```
      The helper counts only `release`-event runs on the tag commit (push-triggered runs on the same commit are ignored), retries failed `gh` calls such as TLS timeouts, and returns within 8 minutes (a pending result may come slightly earlier, when the 30-second confirmation would overrun the chunk). Never background it and never end the turn while it prints `pending` or `unknown`: re-invoke with `<remaining-minutes>` reduced by 8 per prior call, until it prints `none`, `success`, `failed` or `skipped`, or the budget is spent. `<grace>` = `0` on re-invocation only after a prior `pending`; after a prior `unknown` keep `5` (grace starts once gh answers). A `none` right after a prior `pending` means the runs vanished transiently: treat it as `unknown` and re-invoke; never report "not triggered" once runs were seen. Confirmed all-skipped runs print `skipped`, which is terminal.

   c. Outcomes. The first output line is the token; after `pending`, `success`, `failed` and `skipped`, each further line is `<conclusion-or-status> <run URL>`.
      - `success`: report "Deployment succeeded." with the run URLs. `DEPLOY` = `succeeded — <run URL>`. Go to Step 8b.
      - `failed`: for each run whose conclusion is not `success`/`neutral`/`skipped`, fetch the failure logs (`<run-id>` is the number at the end of its run URL):
        ```bash
        gh run view <run-id> --log-failed 2>&1 | head -200
        ```
        Report the failed run URL and log excerpt. `DEPLOY` = `FAILED — <run URL>`. After-deploy actions are not run; report the `after` rows (if any) as left unticked (Step 8b wording). Skip Step 8b; go to Step 9.
      - `skipped`: report "Release-triggered workflow ran but all jobs were skipped — nothing deployed." with the run URLs. `DEPLOY` = `not triggered (all runs skipped)`. Go to Step 8b.
      - `none`: report "No deployment workflow triggered by this release (draft release, or no `release`-event run registered within 5 minutes)." `DEPLOY` = `not triggered`. Go to Step 8b.
      - Budget spent, last token `pending`: report the still-running run URLs and suggest re-checking with `gh run watch <run-id>`. `DEPLOY` = `timed out (still running) — <run URL>`. After-deploy actions are not run; report the `after` rows (if any) as left unticked (Step 8b wording). Skip Step 8b; go to Step 9.
      - Budget spent, last token `none` that followed a `pending` (treated as `unknown`), or last token `unknown`: report "Could not verify the deployment: GitHub was unreachable (gh errors). This is not a deploy failure; re-check with `gh run list --event release --commit <sha>`." `DEPLOY` = `could not verify (gh errors)`. After-deploy actions are not run; report the `after` rows (if any) as left unticked (Step 8b wording). Skip Step 8b; go to Step 9.
4. **Categories 1-4** — `DEPLOY` = `not configured`. Present findings and ask:
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
   - **1 (Yes)** → follow the scaffolding options for the detected category per `references/ci-detection.md`. Inspect project context (existing workflows, Dockerfile, package manager, framework) and write the workflow conversationally. Commit the new/modified workflow file to the current branch. Report the file path and remind the user to review before pushing. Go to Step 8b.

# Step 8b: After-deploy Actions

Runs only when `$N1_HOME/scratch/release-actions.tsv` has `after` rows, after a successful release, and when Step 8 did not skip it (a deploy failure, timeout or unverified watch skips this step).

- `mode:runbook` (§ Parse output; queue or headless run) → report the unticked `after` rows and leave them unticked; never walk.
- Step 8 reported "Deployment succeeded." → follow `<N1_ROOT>/references/deployment-actions.md` § Walk with `PHASE=after` and `OUT=$N1_HOME/scratch/release-actions.tsv`.
- No deploy was watched (`release.deploymentCheck` is `false`, no workflow triggered, no Release published, or Categories 1–4) → § Unwatched Deploy.

An aborted walk or skipped items never undo the release. Report any unticked rows: "After-deploy actions left unticked: <rows>. Run them by hand and tick them in the PR bodies. The next release only scans PRs merged after <TAG>."

Then go to Step 9.

# Step 9: Final Report

When `DEPLOY` starts with `FAILED`, open the closing message with `DEPLOYMENT FAILED: <run URL>` above the report block, so the user cannot miss it.

On built-in flow success:
```
Released <TAG>

Tag:        <TAG> (pushed to origin)
Release:    <release URL>
Deployment: <DEPLOY>
Tickets:    <RELEASE_TICKET_IDS comma-separated> -- comments posted / no tickets found / tracker not configured
Release notes: <NOTES>
<tracker release summary -- only when tracker.type is "jira" and RELEASE_TICKET_IDS is non-empty>
```

On custom procedure completion:
```
Release procedure complete.

Steps completed: <N>/<total>
Release: <release URL> / created <release URL> / missing (declined) / missing (create failed) / not yet created (workflow still running) / missing (tag not on origin)
Deployment: <DEPLOY>
Ticket: <ID> — comment posted / no ticket inferred / tracker not configured
Release notes: <NOTES>
```

`<NOTES>` is the value recorded by `03b-release-notes.md` § 5c-8 (notes file path -- Confluence URL or skip/failure reason).

After the report block (either flow), print `Slack-ready notes:` followed by the `## Slack` section of `$N1_HOME/releases/<TAG>.md`, verbatim:

```bash
source ~/.n1/preamble.sh
awk '/^## Slack$/{f=1; next} /^## /{f=0} f' "$N1_HOME/releases/<TAG>.md"
```


`<DEPLOY>` is one of: `succeeded — <run URL>`, `FAILED — <run URL>`, `timed out (still running) — <run URL>`, `could not verify (gh errors)`, `not triggered`, `not configured`.

**Tracker release summary** (appended to report when `tracker.type` is `"jira"` and Step 5b ran):

```
Tracker release:
  Version:     "<VERSION_NAME>" -- created and released / already existed / skipped (jc-mcp not configured)
  Fix version: set on <IDs> / skipped (jc-mcp not configured)
  Tickets:     <N> moved to "<target>" / skipped (no status configured)
```

On idempotent skip:
```
Release <TAG> already exists — nothing to do.
```

## Idempotency

Every path is safe to re-run: existing release causes a skip; existing tag skips tag creation; existing tracker comment is not duplicated (when comments are readable). Deployment actions: only unticked PR-body items are collected and executed items are ticked, so a re-run never repeats them.

Tracker release operations are individually idempotent: existing versions are reused (not duplicated), fix versions already set are no-ops, and tickets already in the target status are skipped.

Release notes are idempotent: the notes file is overwritten, the Confluence page is updated in place (stored page id first, then exact-title search), and only the GitHub Release body section above `<!-- n1:release-notes:end -->` is replaced. `/n1:n1-release --notes [<TAG>]` regenerates them for an existing release; a plain re-run still reports "nothing to do".

## Integration

**Called by:**
- **n1-start** -- step `release` (after finish), gated on `release.enabled`
- **Standalone** -- `/n1:n1-release`

**Invokes:**
- Inline: `gh` CLI (release view/create, auth status, PR body read/edit, run list/view), git (tag, push), tracker MCP operations (comment, transitions, version create/release, fix version edit, Confluence article search/get/create/update and space lookup for release notes), `lib/poll.sh` (`n1_wait_release_runs` deploy watch), `references/ci-detection.md` (deployment pipeline detection), `references/deployment-actions.md` (deployment actions)
- No agent spawns -- thin controller, orchestration only

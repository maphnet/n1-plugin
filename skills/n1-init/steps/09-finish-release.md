<!-- Purpose: Configure finish work (merge/deploy/close), release procedure, and deployment pipeline awareness. -->

## Finish Work Configuration

Ask whether N1 should run a finish step after CI: verify/perform the PR merge, optionally watch the deployment, and close the tracker ticket. **Default is No.**

Only ask when a tracker is configured — without one, finish work has nothing useful to do beyond merge verification; write `"finishWork": { "enabled": false }` silently.

```
Enable the finish step in the automated pipeline?
After CI passes, N1 can verify the PR merge, watch the deployment, and close the ticket.
1 — Yes
2 — No (default)
```

**If 2 (No) or default:**
```json
{
  "finishWork": {
    "enabled": false
  }
}
```

**If 1 (Yes)**, ask the follow-ups:

```
Auto-merge the PR on finish?
1 — No, a reviewer merges (default)
2 — Yes, N1 merges via gh pr merge --auto (branch protection still applies)
```

If auto-merge is Yes:
```
Merge method?
1 — squash (default)
2 — merge
3 — rebase
```

```
Watch the automated deployment after merge?
Requires a GitHub Actions workflow triggered by pushes to the default branch.
1 — No (default)
2 — Yes
```

If deploy watch is Yes: "Workflow name to watch? (enter = watch all runs on the merge commit)"

Write the block (omit `deployWatch.workflowName` when empty; `closeTicket` defaults to true — no question):
```json
{
  "finishWork": {
    "enabled": true,
    "mergeOnFinish": "<from auto-merge question>",
    "mergeMethod": "<from merge-method question, \"squash\" when not asked>",
    "deployWatch": {
      "enabled": "<from deploy-watch question>",
      "workflowName": "<name or null>",
      "timeoutMinutes": 30
    },
    "closeTicket": true,
    "waitForMergeMinutes": 10
  }
}
```

### On reconfiguration (n1-init re-run):

If `finishWork` already exists in the current config, show current state and offer:
```
Current finish work:
  enabled       → <true/false>
  mergeOnFinish → <true/false>
  deployWatch   → <true/false>

1 — Keep current
2 — Enable / change settings (re-ask the questions above)
3 — Disable
```
- **1** → leave unchanged.
- **2** → re-run the questions, overwrite the block.
- **3** → set `enabled: false`, keep the other keys.

If `finishWork` is absent from the current config, run the fresh-setup flow above.

## Release Configuration

Ask whether N1 should create a release (git tag + GitHub Release) after the pipeline completes. **Default is No.**

```
Enable releases?
/n1:n1-release can guide you through releasing a version after the pipeline completes.
1 — Yes
2 — No (default)
```

**If 2 (No) or default:**
```json
{
  "release": {
    "enabled": false,
    "deploymentCheck": false
  }
}
```

**If 1 (Yes):**

```
Release procedure?
1 — GitHub Release (default) — git tag + gh release create --generate-notes
2 — Custom — paste your multi-step procedure as markdown
```

**If 1 (GitHub Release):**

Write:
```json
{
  "release": {
    "enabled": true,
    "tagPrefix": "v",
    "procedure": null,
    "deploymentCheck": "<from deployment pipeline awareness answer>"
  }
}
```

**If 2 (Custom):**

Ask: "Tag prefix? (default: v)"

Then:
```
Paste your release procedure as markdown.
Use {{RELEASE_TAG}}, {{VERSION}}, {{MERGE_SHA}}, {{TICKET_ID}} as placeholders.

Example:
1. Build: `npm run build`
2. Push tag: `git push origin {{RELEASE_TAG}}`
3. Deploy to prod: `ssh prod@example.com "cd /app && git pull && pm2 restart all"`
4. Verify: `curl -f https://example.com/healthz`

Waiting for your procedure:
```

Write:
```json
{
  "release": {
    "enabled": true,
    "tagPrefix": "<from answer, default v>",
    "procedure": "<verbatim paste>",
    "deploymentCheck": "<from deployment pipeline awareness answer>"
  }
}
```

### Tracker Release Automation

**Only runs when `release.enabled` is `true` AND `tracker.type` is `"jira"`.** Skip this section entirely otherwise.

When conditions are met, write the `trackerRelease` block to the `release` config with default sub-flags:
```json
{
  "release": {
    "trackerRelease": {
      "versionName": "{serviceName} {version}",
      "moveTickets": true,
      "setFixVersion": true,
      "createVersion": true
    }
  }
}
```

No questions asked -- tracker release operations are on by default for Jira projects. Users can disable individual operations in config.json after init. Missing infrastructure (e.g., `versionMcp`) is configured inline by `/n1:n1-release` on first run.

### Deployment Pipeline Awareness

**Only runs when `release.enabled` is `true`.** Skip this section entirely if the user chose not to enable releases.

After release configuration is set (either fresh or reconfigured), run deployment pipeline detection per `references/ci-detection.md`.

Report current state:
```
Deployment pipelines:
<one of the following based on detection category>
  Category 1: "No GitHub Actions workflows found."
  Category 2: "Workflows found (CI/lint/test) but no deployment pipelines."
  Category 3: "Found: <filename> — deploys to <env> on <trigger>. No release-triggered deployment."
  Category 4: "Found: <filename> — deploys to <env> (prod) on <trigger>. Not triggered by release."
  Category 5: "Found: <filename> — deploys to <env> on release. Release deployment is configured."
```

Ask:
```
Check for deployment pipeline after each release?
1 — Yes (default for deployable services)
2 — No (default for libraries/plugins)
```

Default suggestion: `true` if any deployment workflows were detected (categories 3-5) or project has a Dockerfile / `docker-compose.yml`; `false` if project looks like a library/plugin (has `.claude-plugin/plugin.json` with no Dockerfile, or is an npm package with no deployment indicators).

Set `release.deploymentCheck` to the chosen value.

### On reconfiguration (n1-init re-run):

If `release` already exists in the current config, show current state and offer:
```
Current release:
  enabled         → <true/false>
  procedure       → GitHub Release (built-in) | custom (<N> steps)
  deploymentCheck → <true/false>

1 — Keep current
2 — Change settings
3 — Disable
```
- **1** → leave unchanged.
- **2** → re-run the questions above (including Deployment Pipeline Awareness), overwrite the block.
- **3** → set `enabled: false`, keep other keys.

If `release` is absent from the current config, run the fresh-setup flow above.

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

## Delivery (SSH deploy)

Ask whether changes reach a host through a deploy command after the merge. This covers infra or docs repos and services deployed over SSH. **Default is No.**

```
Does this project deploy to a host after merge (SSH or a similar command)?
1 — No (default)
2 — Yes: after each merge, N1 shows the deploy command, asks, runs it, and verifies
```

**If 1 (No) or default:** write nothing. An absent `delivery` block keeps today's behavior.

**If 2 (Yes)**, ask:
- "Deploy command? (the full command, e.g. `ssh myhost 'cd /srv/app && git pull && ./deploy.sh'`)". If the answer is empty, treat it as No.
- "Verify command? Exit code 0 means the deploy worked. Press enter to skip (the deploy's own exit code is then the only check)."

Then show this notice verbatim:
```
Note: queued runs (n1-queue) and headless runs never execute the deploy. They write a
runbook to N1 memory (not posted to the tracker) and leave the ticket awaiting you; run
n1-finish <ID> to deploy.
There is no deny hook for ssh/scp/rsync in queued runs. The guard is the delivery step
itself, so an agent in a queued run could still call ssh on its own.
Delivery commands must not contain secrets (passwords, tokens, keys) — the command text
can end up in local logs and self-checks; use SSH keys / agent auth instead.
```

Write the block, omitting `verifyCommand` when it is empty:
```json
{
  "delivery": {
    "mode": "ssh",
    "command": "<deploy command>",
    "verifyCommand": "<verify command>"
  }
}
```

### On reconfiguration (n1-init re-run):

If `delivery` already exists in the current config, show the current state and offer:
```
Current delivery:
  mode          → <mode>
  command       → <command>
  verifyCommand → <verifyCommand or none>

1 — Keep current
2 — Change settings (re-ask the questions above)
3 — Remove (back to no deploy step)
```
- **1**: leave unchanged.
- **2**: re-run the questions, show the notice, and overwrite the block.
- **3**: delete the `delivery` block.

If `delivery` is absent from the current config, run the fresh-setup flow above.

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

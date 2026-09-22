---
name: n1-release
description: "Release a version: create git tag and GitHub Release. Usage: /n1:n1-release"
model: sonnet
effort: low
---

# N1 Release

## Overview

Guide the user through releasing a version of the project. Creates a git tag and GitHub Release (built-in flow) or walks through a custom markdown procedure with placeholder substitution.

Standalone invocation is the primary pattern -- no ticket argument required. Pipeline step wiring exists but defaults off (`release.enabled: false`).

**Announce at start:** "I'm using the n1-release skill to create a release."

## N1_HOME Resolution

Resolve the N1 state directory at the start of every run. Run via Bash:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -n "$N1_ROOT" ] && [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty -- N1 is not configured; warn the user and STOP.

## Config Read

Read the `release` block via `n1_config_val`, applying defaults when keys are absent:

| Key | Default | Description |
|-----|---------|-------------|
| `.release.enabled` | `false` | |
| `.release.tagPrefix` | `"v"` | |
| `.release.versionSource` | `null` | Optional `{"file":"...","jq":"..."}` — auto-detects common files when absent |
| `.release.procedure` | `null` | |
| `.release.draft` | `false` | |
| `.release.deploymentCheck` | `true` | |
| `.release.deployWatch.enabled` | `true` | Watch the deployment pipeline triggered by the release |
| `.release.deployWatch.workflowName` | `null` | Filter to a specific workflow file name (e.g. `deploy.yml`) |
| `.release.deployWatch.timeoutMinutes` | `30` | Maximum minutes to watch before timing out |
| `.release.trackerRelease.versionName` | `"{serviceName} {version}"` | |
| `.release.trackerRelease.moveTickets` | `true` | |
| `.release.trackerRelease.setFixVersion` | `true` | |
| `.release.trackerRelease.createVersion` | `true` | |

Also read `git.defaultBranch`, `git.branchPattern`, `tracker.mcp`, `tracker.operations`, `tracker.prefix`, `tracker.projectKey`, `tracker.statuses`, `ticketTagging.service`.

For version operations (Jira only): read `tracker.versionMcp` (defaults to `null`). When non-null, version tool calls use `mcp__<tracker.versionMcp>__<operation>` instead of `mcp__<tracker.mcp>__<operation>`.

`release.enabled` gates only the pipeline step -- standalone invocation proceeds regardless.

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Branch Check & Resolve Metadata** — prerequisites, branch validation, version resolution, ticket discovery
   Read `<N1_ROOT>/skills/n1-release/steps/01-resolve-metadata.md`

2. **Confirmation Gate & Execute** — unconditional confirmation, idempotency check, built-in or custom procedure
   Read `<N1_ROOT>/skills/n1-release/steps/02-confirm-execute.md`

3. **Tracker Release Operations** — create/release Jira version, set fix version, move tickets (Jira only)
   Read `<N1_ROOT>/skills/n1-release/steps/03-tracker-release.md`

4. **Report & Deployment Check** — tracker comment, release report, deployment pipeline detection
   Read `<N1_ROOT>/skills/n1-release/steps/04-report.md`

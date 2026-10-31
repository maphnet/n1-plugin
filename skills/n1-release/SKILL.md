---
name: n1-release
description: "Release a version: create git tag, GitHub Release and stakeholder release notes. Usage: /n1:n1-release [--notes [<TAG>]]"
argument-hint: "[--notes [<TAG>]]"
model: sonnet
effort: low
---

# N1 Release

## Overview

Guide the user through releasing a version of the project. Creates a git tag and GitHub Release (built-in flow) or walks through a custom markdown procedure with placeholder substitution, then writes stakeholder release notes (Slack block, Confluence page, GitHub Release body section).

Standalone invocation is the primary pattern -- no ticket argument required. Pipeline step wiring exists but defaults off (`release.enabled: false`).

**Announce at start:** "I'm using the n1-release skill to create a release."

## N1_HOME Resolution

Resolve the N1 state directory at the start of every run. Run via Bash:

```bash
source ~/.n1/preamble.sh
[ -n "$N1_HOME" ] && echo "N1_HOME=$N1_HOME" || echo N1_NOT_CONFIGURED
```

If the output shows `N1_NOT_CONFIGURED` -- N1 is not configured; warn the user and STOP.

## Config Read

Read the `release` block via `n1_config_val`, applying defaults when keys are absent:

| Key | Default | Description |
|-----|---------|-------------|
| `.release.enabled` | `false` | |
| `.release.versionSource` | `null` | Optional `{"file":"...","jq":"..."}` — auto-detects common files when absent |
| `.release.procedure` | `null` | |
| `.release.draft` | `false` | |
| `.release.deploymentCheck` | `true` | |
| `.release.trackerRelease.versionName` | `"{serviceName} {version}"` | |

Also read `git.defaultBranch`, `git.branchPattern`, `tracker.type`, `tracker.mcp`, `tracker.operations`, `tracker.prefix`, `tracker.projectKey`, `tracker.statuses`, `ticketTagging.service`, `kb.enabled`, `kb.spaceId`, `kb.spaceKey`.

For version operations (Jira only): read `tracker.versionMcp` (defaults to `null`). When non-null, version tool calls use `mcp__<tracker.versionMcp>__<operation>` instead of `mcp__<tracker.mcp>__<operation>`.

`release.enabled` gates only the pipeline step -- standalone invocation proceeds regardless.

## `--notes` Routing

If the arguments contain `--notes`, optionally followed by a tag (e.g. `v1.4.0`): after N1_HOME Resolution and Config Read, run only step 3b below with `MODE=notes-only` and that tag (empty = latest `v*` tag), and STOP after its report. It regenerates the notes of an existing release and updates the Confluence page and GitHub Release body in place; it never creates a tag or a release. Without `--notes`, run every step in order, with step 3b in `MODE=normal`.

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Branch Check & Resolve Metadata** — prerequisites, branch validation, version resolution, ticket discovery
   Read `<N1_ROOT>/skills/n1-release/steps/01-resolve-metadata.md`

2. **Confirmation Gate & Execute** — unconditional confirmation, idempotency check, built-in or custom procedure
   Read `<N1_ROOT>/skills/n1-release/steps/02-confirm-execute.md`

3. **Tracker Release Operations** — create/release Jira version, set fix version, move tickets (Jira only)
   Read `<N1_ROOT>/skills/n1-release/steps/03-tracker-release.md`

3b. **Release Notes** — stakeholder notes file, Slack block, Confluence page, GitHub Release body section (always runs, even when step 3 is skipped)
   Read `<N1_ROOT>/skills/n1-release/steps/03b-release-notes.md`

4. **Deployment Check & Final Report** — tracker comment, deploy watch, final report with the deployment conclusion (mandatory; do not stop after step 2)
   Read `<N1_ROOT>/skills/n1-release/steps/04-report.md`

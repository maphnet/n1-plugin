---
name: n1-finish
description: "Finish work: verify or perform the PR merge, watch the automated deployment, close the tracker ticket, and clean up. Usage: /n1:n1-finish, /n1:n1-finish TRID-510, or /n1:n1-finish #123"
argument-hint: "[ticket-id or PR#]"
model: sonnet
effort: low
---

# N1 Finish Work

## Overview

Complete the development cycle after the PR/CI stage: confirm the PR is merged (or merge it when `finishWork.mergeOnFinish` is enabled), optionally watch the deployment workflow triggered by the merge commit, move the tracker ticket to Done, and clean up the branch/worktree.

The ticket is closed **only when the code is actually merged** — never on green-CI-but-open.

**Announce at start:** "I'm using the n1-finish skill to finish work on this task."

## N1_HOME Resolution

Resolve the N1 state directory at the start of every run. Run via Bash:

```bash
source ~/.n1/preamble.sh
```

If `N1_HOME` is empty — N1 is not configured; warn the user and STOP.

## Config Read

Read the `finishWork` block via `n1_config_val`, applying defaults when keys are absent:

| Key | Default |
|-----|---------|
| `.finishWork.mergeOnFinish` | `false` (takes effect only with `finishWork.enabled: true`; queue children use `queue.mergeOnFinish`, default `false`. Decided by `n1_merge_allowed`) |
| `.finishWork.mergeMethod` | `"squash"` (`"squash"` \| `"merge"` \| `"rebase"`) |
| `.finishWork.deployWatch.enabled` | `false` |
| `.finishWork.deployWatch.workflowName` | `null` (watch all runs on the merge commit) |
| `.finishWork.deployWatch.timeoutMinutes` | `30` |
| `.finishWork.closeTicket` | `true` |
| `.finishWork.waitForMergeMinutes` | `10` |
| `.localTesting.mode` | `null` (infer from startCommand) |
| `.localTesting.smokeEndpoint` | `null` |
| `.localTesting.smokeTests` | `[]` |

Also read `git.prMode` (fallback chain: `git.prMode` → `git.draftPR: false` = `"ready"` → `"draft"`), `git.defaultBranch`, `git.branchPattern`, `tracker.mcp`, `tracker.operations`, `tracker.statuses`.

`finishWork.enabled` gates only the pipeline step — standalone invocation proceeds regardless. If `finishWork` is entirely absent, all defaults apply and the skill still works as a merge-verify + close command. Whether this run may merge comes only from `n1_merge_allowed` (Step 2). Never infer it from config by hand.

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Resolve Target** — prerequisites check, PR lookup
   Read `<N1_ROOT>/skills/n1-finish/steps/01-resolve-target.md`

2. **Merge State Machine** — evaluate PR state, comment check, merge, wait; or Step 2b local merge when `prMode` is `"skip"` (no PR, no push)
   Read `<N1_ROOT>/skills/n1-finish/steps/02-merge.md`

3. **Deploy Watch & Smoke** — watch deployment workflow, run smoke verification
   Read `<N1_ROOT>/skills/n1-finish/steps/03-deploy.md`

4. **Close Ticket** — move tracker status to done, post comment
   Read `<N1_ROOT>/skills/n1-finish/steps/04-close-ticket.md`

5. **Telemetry Follow-Up** — create follow-up ticket when feature warrants telemetry check
   Read `<N1_ROOT>/skills/n1-finish/steps/05-telemetry-followup.md`

6. **Cleanup & Report** — branch/worktree cleanup, memory update, final report, release routing
   Read `<N1_ROOT>/skills/n1-finish/steps/06-cleanup.md`

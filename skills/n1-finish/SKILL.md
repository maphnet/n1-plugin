---
name: n1-finish
description: "Finish work: verify or perform the PR merge, watch the automated deployment, close the tracker ticket, and clean up. Usage: /n1:n1-finish, /n1:n1-finish TRID-510, or /n1:n1-finish #123"
argument-hint: "[ticket-id or PR#]"
model: sonnet
effort: low
---

# N1 Finish Work

## Overview

Complete the development cycle after the PR/CI stage: confirm the PR is merged (or merge it when `finishWork.mergeOnFinish` is enabled), optionally watch the deployment workflow triggered by the merge commit, optionally verify ticket acceptance criteria after a successful deployment, optionally deploy to the project's host with `delivery.command` or the ordered `delivery.steps` list (asks first, interactive runs only), move the tracker ticket to Done, and clean up the branch/worktree.

The ticket is closed **only when the code is actually merged** — never on green-CI-but-open.

**Announce at start:** "I'm using the n1-finish skill to finish work on this task."

## N1_HOME Resolution

Resolve the N1 state directory at the start of every run. Run via Bash:

```bash
source ~/.n1/preamble.sh
```

If `N1_HOME` is empty — N1 is not configured; warn the user and STOP.

Before resolving a target or reading any step, initialize the invocation-scoped verification artifact guard:

```bash
POST_DEPLOY_VERIFICATION_ARTIFACT=false
```

## Config Read

Read the `finishWork` block via `n1_config_val`, applying defaults when keys are absent:

| Key | Default |
|-----|---------|
| `.finishWork.mergeOnFinish` | `false` (takes effect only with `finishWork.enabled: true`; queue children use `queue.mergeOnFinish`, default `false`. Decided by `n1_merge_allowed`) |
| `.finishWork.mergeMethod` | `"squash"` (`"squash"` \| `"merge"` \| `"rebase"`) |
| `.finishWork.deployWatch.enabled` | `false` |
| `.finishWork.deployWatch.workflowName` | `null` (watch all runs on the merge commit) |
| `.finishWork.deployWatch.timeoutMinutes` | `30` |
| `.finishWork.postDeployVerification.enabled` | `false`; an absent key falls back to explicit `localTesting.mode: "smoke"`; explicit `false` takes precedence over the legacy smoke fallback |
| `.finishWork.closeTicket` | `true` |
| `.finishWork.waitForMergeMinutes` | `10` |
| `.delivery.mode` | `null` (`"ssh"` enables the delivery deploy at the start of Step 4; any other value is off) |
| `.delivery.command` | `null` (project-owned deploy command, run with confirmation in interactive runs only) |
| `.delivery.steps` | `null` (NP-240: ordered deploy steps, each `` `<command>` `` or `Manual: <text>`; used only when `.delivery.command` is empty; every step is confirmed before it runs, interactive runs only; resume point kept in overview `deploy_next_step`) |
| `.delivery.verifyCommand` | `null` (optional post-deploy check; exit code 0 = verified) |
| `.localTesting.mode` | `null` (infer from startCommand) |
| `.localTesting.smokeEndpoint` | `null` |
| `.localTesting.smokeTests` | `[]` |

Post-deploy verification dispatches only after a successful deployment. It receives the absolute paths for `ticket.md`, `analysis.md`, optional `local-test-plan.md`, `post-deploy-pr.diff`, `config.json`, and `dev-access.md`, and writes `post-deploy-verification.md`. Its `PASS`, `FAIL`, or `SKIPPED` results are informational: failures do not prevent normal ticket closure.

Also read `git.prMode` (fallback chain: `git.prMode` → `git.draftPR: false` = `"ready"` → `"draft"`), `git.defaultBranch`, `git.branchPattern`, `tracker.mcp`, `tracker.operations`, `tracker.statuses`.

`finishWork.enabled` gates only the pipeline step — standalone invocation proceeds regardless. If `finishWork` is entirely absent, all defaults apply and the skill still works as a merge-verify + close command. Whether this run may merge comes only from `n1_merge_allowed` (Step 2). Never infer it from config by hand.

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Resolve Target** — prerequisites check, PR lookup
   Read `<N1_ROOT>/skills/n1-finish/steps/01-resolve-target.md`

2. **Merge State Machine** — evaluate PR state, comment check, merge, wait; or Step 2b local merge when `prMode` is `"skip"` (no PR, no push)
   Read `<N1_ROOT>/skills/n1-finish/steps/02-merge.md`

3. **Deploy Watch & Verification** — watch deployment workflow, then run post-deploy verification after success
   Read `<N1_ROOT>/skills/n1-finish/steps/03-deploy.md`

4. **Close Ticket**: delivery deploy gate first (`03b-ssh-deploy.md`, no-op unless `delivery.mode` is `"ssh"`), then move the tracker status to done and post a comment
   Read `<N1_ROOT>/skills/n1-finish/steps/04-close-ticket.md`

5. **Telemetry Follow-Up** — create follow-up ticket when feature warrants telemetry check
   Read `<N1_ROOT>/skills/n1-finish/steps/05-telemetry-followup.md`

6. **Cleanup & Report** — branch/worktree cleanup, memory update, final report, release routing
   Read `<N1_ROOT>/skills/n1-finish/steps/06-cleanup.md`

---
name: n1-finish
description: "Finish work: verify or perform the PR merge, watch the automated deployment, close the tracker ticket, and clean up. Usage: /n1:n1-finish, /n1:n1-finish TRID-510, or /n1:n1-finish #123"
argument-hint: "[ticket-id or PR#]"
model: sonnet
effort: low
---

# N1 Finish Work

## Overview

Confirm or perform the PR merge, optionally watch the deployment and verify acceptance criteria, optionally deliver to the project's host (asks first, interactive runs only), close the tracker ticket, and clean up the branch/worktree.

The ticket is closed **only when the code is actually merged** — never on green-CI-but-open.

**Announce at start:** "I'm using the n1-finish skill to finish work on this task."

## Entry (one Bash call)

Fill `ID` (argument, else parsed from the branch name via `git.branchPattern` as in n1-pr Step 1; empty if unknown) and `PR` (a `#123`/`123` argument, else empty), then run via Bash:

```bash
source ~/.n1/preamble.sh
[ -n "$N1_HOME" ] || { echo n1-home:missing; exit 1; }
POST_DEPLOY_VERIFICATION_ARTIFACT=false
ID="<ID>"; PR="<PR>"; c() { n1_config_val ".$1"; }
P=$(c git.prMode); [ -n "$P" ] || { [ "$(c git.draftPR)" = false ] && P=ready || P=draft; }
echo "prMode=$P mechanicalPrompts=$(n1_autonomy_val mechanicalPrompts)"
for k in finishWork.{mergeMethod,waitForMergeMinutes,closeTicket,deployWatch.enabled} delivery.mode git.{defaultBranch,branchPattern} tracker.{mcp,versionMcp,statuses.done,operations} worktree.cleanup release.enabled; do echo "$k=$(c $k)"; done
n1_merge_allowed && echo merge:allowed || echo merge:denied; [ -z "${N1_QUEUE_RUN_ID:-}" ] || echo queue-run:yes; [ "${N1_HEADLESS:-}" != 1 ] || echo headless:yes
R=false; M="$N1_HOME/memory/$ID"
if [ -n "$ID" ]; then
  DP=$(n1_read_frontmatter "$M/overview.md" deploy_pending); SHA=$(n1_read_frontmatter "$M/overview.md" deploy_merge_sha); DB=$(c git.defaultBranch); V=false
  [[ "$SHA" =~ ^[0-9a-f]{7,40}$ ]] && git merge-base --is-ancestor "$SHA" "${DB:-main}" 2>/dev/null && V=true
  echo "deploy-pending:$DP sha:$SHA sha-valid:$V"; [ "$DP$V" = truetrue ] && R=true
fi
gh auth status >/dev/null 2>&1 && G=ok || G=unauthenticated; echo "gh:$G"
[ "$R$G" = falseok ] && { gh pr view ${PR:+"$PR"} --json number,state,mergedAt,mergeCommit,url,headRefName,baseRefName || echo pr:none; }
F=(steps/01-resolve-target steps/02-merge)
[ "$(c finishWork.deployWatch.enabled)" = true ] && F+=(steps/03-deploy)
[ "$(c delivery.mode)" = ssh ] && F+=(steps/03b-ssh-deploy)
[ -n "$(c tracker.mcp)" ] && [ -z "$(c tracker.statuses.done)" ] && F+=(references/done-status-recovery)
F+=(steps/04-close-ticket steps/05-telemetry-followup steps/06-cleanup ../../references/deployment-actions)
for f in "${F[@]}"; do echo "=== $f"; cat "$N1_ROOT/skills/n1-finish/$f.md" || echo "(missing)"; done
[ -z "$ID" ] || for f in ticket overview; do echo "=== memory/$f"; cat "$M/$f.md" 2>/dev/null; done
```

`n1-home:missing` → N1 is not configured; warn the user and STOP. Empty `ID` → resolve it from the printed `git.branchPattern`, then run Step 1's pending-deploy check on its own.

## Config Read

Defaults when keys are absent:

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

Post-deploy verification dispatches only after a successful deployment, receives absolute paths for `ticket.md`, `analysis.md`, optional `local-test-plan.md`, `post-deploy-pr.diff`, `config.json` and `dev-access.md`, and writes `post-deploy-verification.md`; its results are informational and never block ticket closure.

`finishWork.enabled` gates only the pipeline step: standalone runs proceed regardless, and with no `finishWork` block all defaults apply (merge-verify + close). Whether this run may merge comes only from `n1_merge_allowed` (printed at entry), never from config by hand.

## Steps

Follow the files printed at entry, in order. A file not printed, or printed as `(missing)`, is read from `<N1_ROOT>/skills/n1-finish/` only when its step applies.

1. Resolve Target: `steps/01-resolve-target.md`
2. Merge State Machine (Step 2b local merge when `prMode` is `"skip"`): `steps/02-merge.md`
3. Deploy Watch & Verification: `steps/03-deploy.md`, printed only when `deployWatch.enabled` is `true`; otherwise deploy is `skipped (not configured)` and no verification is dispatched
4. Close Ticket: `steps/04-close-ticket.md`, after the delivery gate `steps/03b-ssh-deploy.md` (printed only when `delivery.mode` is `"ssh"`; otherwise a no-op)
5. Telemetry Follow-Up: `steps/05-telemetry-followup.md`
6. Cleanup & Report: `steps/06-cleanup.md`

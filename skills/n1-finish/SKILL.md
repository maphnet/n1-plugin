---
name: n1-finish
description: "Finish work: verify or perform the PR merge, watch the automated deployment, close the tracker ticket, and clean up. Usage: /n1:n1-finish, /n1:n1-finish TRID-510, or /n1:n1-finish #123"
argument-hint: "[ticket-id or PR#]"
model: sonnet
effort: low
---

# N1 Finish Work

## Overview

Confirm or perform the PR merge, optionally watch the deployment, verify acceptance criteria and deliver to the project's host (asks first, interactive only), close the ticket, and clean up.

The ticket is closed **only when the code is actually merged** — never on green-CI-but-open.

**Announce at start:** "I'm using the n1-finish skill to finish work on this task."

## Entry (one Bash call + reads)

Fill `ID` (argument, else empty: derived from the branch) and `PR` (digits of a `#123`/`123` argument, else empty), then run via Bash. **In the same turn**, read these in parallel, not via Bash: `<N1_ROOT>/skills/n1-finish/steps/` files `01-resolve-target.md`, `02-merge.md`, `04-close-ticket.md`, `05-telemetry-followup.md`, `06-cleanup.md`, and `<N1_ROOT>/references/deployment-actions.md`.

```bash
source ~/.n1/preamble.sh
[ -n "$N1_HOME" ] || { echo n1-home:missing; exit 1; }
POST_DEPLOY_VERIFICATION_ARTIFACT=false
ID="<ID>"; PR="<PR>"; c() { n1_config_val ".$1"; }; S="$N1_ROOT/skills/n1-finish"
[[ "$PR" =~ ^[0-9]*$ ]] || PR=
TP=$(c tracker.prefix); [ -n "$ID" ] || [ -z "$TP" ] || ID=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | grep -oiE "$TP-[0-9]+" | head -1 | tr a-z A-Z)
case "$ID" in *[!A-Za-z0-9_-]*) echo id:invalid; exit 1;; esac
P=$(c git.prMode); [ -n "$P" ] || { [ "$(c git.draftPR)" = false ] && P=ready || P=draft; }
echo "id=$ID prMode=$P mechanicalPrompts=$(n1_autonomy_val mechanicalPrompts)"
for k in finishWork.{mergeMethod,waitForMergeMinutes,closeTicket,deployWatch.enabled} delivery.mode git.{defaultBranch,branchPattern} tracker.{mcp,versionMcp,statuses.done} worktree.cleanup release.enabled; do echo "$k=$(c $k)"; done
echo "tracker.operations=$(n1_config_ops .tracker.operations)"
n1_merge_allowed && echo merge:allowed || echo merge:denied; [ -z "${N1_QUEUE_RUN_ID:-}" ] || echo queue-run:yes; [ "${N1_HEADLESS:-}" != 1 ] || echo headless:yes
R=false; M="$N1_HOME/memory/$ID"
if [ -n "$ID" ]; then
  DP=$(n1_read_frontmatter "$M/overview.md" deploy_pending); SHA=$(n1_read_frontmatter "$M/overview.md" deploy_merge_sha); DB=$(c git.defaultBranch); V=false
  [[ "$SHA" =~ ^[0-9a-f]{7,40}$ ]] && git merge-base --is-ancestor "$SHA" "${DB:-main}" 2>/dev/null && V=true
  echo "deploy-pending:$DP sha:$SHA sha-valid:$V"; [ "$DP$V" = truetrue ] && R=true
fi
gh auth status >/dev/null 2>&1 && G=ok || G=unauthenticated; echo "gh:$G"
B=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); echo "branch=$B"; F=number,state,mergedAt,mergeCommit,url,headRefName,baseRefName
if [ "$R$G" = falseok ]; then
  if [ -z "$PR" ] && [ -n "$ID" ] && ! grep -qiF -- "$ID" <<<"$B"; then gh pr list --state all --limit 100 --json $F --jq "map(select(.headRefName|ascii_downcase|contains(\"${ID,,}\")))|first//empty" | grep . || echo pr:none
  else gh pr view ${PR:+"$PR"} --json $F || echo pr:none; fi
fi
RA=()
[ "$(c finishWork.deployWatch.enabled)" = true ] && RA+=("$S/steps/03-deploy.md")
[ "$(c delivery.mode)" = ssh ] && RA+=("$S/steps/03b-ssh-deploy.md")
[ -n "$(c tracker.mcp)" ] && [ -z "$(c tracker.statuses.done)" ] && [ "$(c finishWork.closeTicket)" != false ] && RA+=("$S/references/done-status-recovery.md")
[ -z "$ID" ] || for f in ticket overview; do [ -f "$M/$f.md" ] && RA+=("$M/$f.md"); done
echo "read-also: ${RA[*]}"
```

`n1-home:missing` → N1 is not configured: warn and STOP. `id:invalid` → STOP. Empty `id=` → resolve it from `git.branchPattern`, then run Step 1's check.

## Config Read

Defaults when keys are absent:

| Key | Default |
|-----|---------|
| `.finishWork.mergeOnFinish` | `false` (needs `finishWork.enabled: true`; queue children use `queue.mergeOnFinish`; see `n1_merge_allowed`) |
| `.finishWork.mergeMethod` | `"squash"` (`"squash"` \| `"merge"` \| `"rebase"`) |
| `.finishWork.deployWatch.enabled` | `false` |
| `.finishWork.deployWatch.workflowName` | `null` (watch all runs on the merge commit) |
| `.finishWork.deployWatch.timeoutMinutes` | `30` |
| `.finishWork.postDeployVerification.enabled` | `false`; an absent key falls back to explicit `localTesting.mode: "smoke"`; explicit `false` takes precedence over the legacy smoke fallback |
| `.finishWork.closeTicket` | `true` |
| `.finishWork.waitForMergeMinutes` | `10` |
| `.delivery.mode` | `null` (`"ssh"` enables the delivery deploy at the start of Step 4; any other value is off) |
| `.delivery.command` | `null` (see `steps/03b-ssh-deploy.md`) |
| `.delivery.steps` | `null` (ordered steps; used only when `.delivery.command` is empty; see `steps/03b-ssh-deploy.md`) |
| `.delivery.verifyCommand` | `null` (optional post-deploy check) |
| `.localTesting.mode` | `null` (infer from startCommand) |
| `.localTesting.smokeEndpoint` | `null` |
| `.localTesting.smokeTests` | `[]` |

Post-deploy verification dispatches only after a successful deployment, reads `ticket.md`, `analysis.md`, `local-test-plan.md`, `post-deploy-pr.diff`, `config.json`, `dev-access.md`, writes `post-deploy-verification.md`; never blocks closure.

`finishWork.enabled` gates only the pipeline step; standalone runs proceed regardless and absent keys use the defaults above. Merge permission comes only from `n1_merge_allowed` (printed at entry).

## Steps

Follow the files read at entry, in order.

1. Resolve Target: `steps/01-resolve-target.md`
2. Merge State Machine (Step 2b local merge when `prMode` is `"skip"`): `steps/02-merge.md`
3. Deploy Watch & Verification: `steps/03-deploy.md`, only when listed in `read-also:`; otherwise deploy is `skipped (not configured)` and no verification is dispatched
4. Close Ticket: `steps/04-close-ticket.md`, after the delivery gate `steps/03b-ssh-deploy.md` (only when listed in `read-also:`)
5. Telemetry Follow-Up: `steps/05-telemetry-followup.md`
6. Cleanup & Report: `steps/06-cleanup.md`

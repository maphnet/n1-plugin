---
name: n1-finish
description: "Finish work: verify or perform the PR merge, watch the automated deployment, close the tracker ticket, and clean up. Usage: /n1:n1-finish, /n1:n1-finish TRID-510, or /n1:n1-finish #123"
argument-hint: "[ticket-id or PR#]"
model: sonnet
effort: low
---

# N1 Finish Work

## Overview

Confirm or perform the PR merge, optionally watch the deployment and deliver to the project's host (asks first, interactive only), close the ticket, and clean up.

The ticket is closed **only when the code is actually merged** — never on green-CI-but-open.

**Announce at start:** "I'm using the n1-finish skill to finish work on this task."

## Entry (one Bash call + reads)

Fill `ID` (argument, else derived from the PR or branch) and `PR` (digits of a `#123`/`123` argument, else empty), then run via Bash. **In the same turn**, read these in parallel, not via Bash: `<N1_ROOT>/skills/n1-finish/steps/` files `01-resolve-target.md`, `02-merge.md`, `04-close-ticket.md`, `05-telemetry-followup.md`, `06-cleanup.md`, and `<N1_ROOT>/references/deployment-actions.md`.

```bash
source ~/.n1/preamble.sh
[ -n "$N1_HOME" ] || { echo n1-home:missing; exit 1; }
POST_DEPLOY_VERIFICATION_ARTIFACT=false
ID="<ID>"; PR="<PR>"; c() { n1_config_val ".$1"; }; S="$N1_ROOT/skills/n1-finish"
[[ "$PR" =~ ^[0-9]*$ ]] || PR=
TP=$(c tracker.prefix); B=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); F=number,state,mergedAt,mergeCommit,url,headRefName,baseRefName
tid() { grep -oiE "$TP-[0-9]+" | head -1 | tr a-z A-Z; }
[ -n "$ID" ] || [ -n "$PR" ] || [ -z "$TP" ] || ID=$(tid <<<"$B")
case "$ID" in *[!A-Za-z0-9_-]*) echo id:invalid; exit 1;; esac
gh auth status >/dev/null 2>&1 && G=ok || G=unauthenticated; R=false
look() { X="(^|[^a-z0-9])${ID,,}([^0-9]|$)"
  if [ -z "$PR" ] && [ -n "$ID" ] && ! grep -qiE "$X" <<<"$B"; then J=$(gh pr list --state all --limit 300 --json $F | jq -rc --arg x "$X" 'map(select(.headRefName|ascii_downcase|test($x)))|map(select(.state=="OPEN")) as $o|map(select(.state=="MERGED")) as $m|if length==1 then .[0] elif ($o|length)==1 then $o[0] elif ($o|length)==0 and ($m|length)==1 then $m[0] elif length==0 then empty else "pr:ambiguous "+(map(.number|tostring)|join(" ")) end')
  else J=$(gh pr view ${PR:+"$PR"} --json $F); fi; echo "${J:-pr:none}"; }
[ -z "$PR" ] || [ "$G" != ok ] || { look; [ -n "$ID" ] || [ -z "$TP" ] || ID=$(jq -r '.headRefName//empty' <<<"$J" 2>/dev/null | tid); }
M="$N1_HOME/memory/$ID"
if [ -n "$ID" ]; then
  DP=$(n1_read_frontmatter "$M/overview.md" deploy_pending); SHA=$(n1_read_frontmatter "$M/overview.md" deploy_merge_sha); DB=$(c git.defaultBranch); V=false
  [[ "$SHA" =~ ^[0-9a-f]{7,40}$ ]] && git merge-base --is-ancestor "$SHA" "${DB:-main}" 2>/dev/null && V=true
  echo "deploy-pending:$DP sha:$SHA sha-valid:$V"; [ "$DP$V" = truetrue ] && R=true
fi
[ -n "$PR" ] || [ "$R$G" != falseok ] || look
echo "gh:$G branch=$B"
P=$(c git.prMode); [ -n "$P" ] || { [ "$(c git.draftPR)" = false ] && P=ready || P=draft; }
echo "id=$ID prMode=$P mechanicalPrompts=$(n1_autonomy_val mechanicalPrompts)"
for k in finishWork.{mergeMethod,deployWatch.enabled} delivery.mode git.{defaultBranch,branchPattern} tracker.{mcp,versionMcp,statuses.done} release.enabled; do echo "$k=$(c $k)"; done
echo "tracker.operations=$(n1_config_ops .tracker.operations)"
n1_merge_allowed && echo merge:allowed || echo merge:denied; [ -z "${N1_QUEUE_RUN_ID:-}" ] || echo queue-run:yes; [ "${N1_HEADLESS:-}" != 1 ] || echo headless:yes
RA=()
[ "$(c finishWork.deployWatch.enabled)" = true ] && RA+=("$S/steps/03-deploy.md")
[ "$(c delivery.mode)" = ssh ] && RA+=("$S/steps/03b-ssh-deploy.md")
[ -n "$(c tracker.mcp)" ] && [ -z "$(c tracker.statuses.done)" ] && RA+=("$S/references/done-status-recovery.md")
[ -z "$ID" ] || for f in ticket overview; do [ -f "$M/$f.md" ] && RA+=("$M/$f.md"); done
echo "read-also: ${RA[*]}"
```

`n1-home:missing` → warn and STOP. `id:invalid` → STOP. Empty `id=` → resolve it from `git.branchPattern`, then run Step 1's check.

## Config Read

Defaults:

| Key | Default |
|-----|---------|
| `.finishWork.mergeMethod` | `"squash"` (`"squash"` \| `"merge"` \| `"rebase"`) |
| `.finishWork.deployWatch.enabled` | `false` |
| `.finishWork.deployWatch.workflowName` | `null` (watch all runs on the merge commit) |
| `.finishWork.deployWatch.timeoutMinutes` | `30` |
| `.finishWork.postDeployVerification.enabled` | `false`; absent → explicit `localTesting.mode: "smoke"` (legacy smoke); explicit `false` wins |
| `.delivery.mode` | `null` (`"ssh"` enables the Step 4 delivery deploy; else off) |
| `.delivery.command` | `null` (see `steps/03b-ssh-deploy.md`) |
| `.delivery.steps` | `null` (ordered; used only when `.delivery.command` is empty; see `steps/03b-ssh-deploy.md`) |
| `.delivery.verifyCommand` | `null` (optional post-deploy check) |
| `.localTesting.mode` | `null` (infer from startCommand) |
| `.localTesting.smokeEndpoint` | `null` |
| `.localTesting.smokeTests` | `[]` |

Post-deploy verification dispatches only after a successful deployment (`ticket.md` → `post-deploy-verification.md`; `steps/03-deploy.md`); never blocks closure.

Interactive runs never merge a PR: the human merges, then runs n1-finish. Only n1_merge_allowed (queue children) permits merging; prMode skip merges locally (Step 2b).

## Steps

Follow the files read at entry, in order.

1. Resolve Target: `steps/01-resolve-target.md`
2. Merge State Machine (Step 2b local merge when `prMode` is `"skip"`): `steps/02-merge.md`
3. Deploy Watch & Verification: `steps/03-deploy.md`, only when in `read-also:`; else deploy is `skipped (not configured)`, no verification
4. Close Ticket: `steps/04-close-ticket.md`, after the delivery gate `steps/03b-ssh-deploy.md` (when in `read-also:`)
5. Telemetry Follow-Up: `steps/05-telemetry-followup.md`
6. Cleanup & Report: `steps/06-cleanup.md`

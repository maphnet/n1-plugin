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
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty — N1 is not configured; warn the user and STOP.

## Config Read

Read the `finishWork` block via `n1_config_val`, applying defaults when keys are absent:

| Key | Default |
|-----|---------|
| `.finishWork.mergeOnFinish` | `false` |
| `.finishWork.mergeMethod` | `"squash"` (`"squash"` \| `"merge"` \| `"rebase"`) |
| `.finishWork.deployWatch.enabled` | `false` |
| `.finishWork.deployWatch.workflowName` | `null` (watch all runs on the merge commit) |
| `.finishWork.deployWatch.timeoutMinutes` | `30` |
| `.finishWork.closeTicket` | `true` |
| `.finishWork.waitForMergeMinutes` | `10` |

Also read `git.prMode` (fallback chain: `git.prMode` → `git.draftPR: false` = `"ready"` → `"draft"`), `git.defaultBranch`, `git.branchPattern`, `tracker.mcp`, `tracker.operations`, `tracker.statuses`.

`finishWork.enabled` gates only the pipeline step — standalone invocation proceeds regardless. If `finishWork` is entirely absent, all defaults apply and the skill still works as a merge-verify + close command.

## Step Mode Detection

When invoked from `n1-start --step finish`, the orchestrator passes step-mode context (`<ID>`, `N1_RUN_ID`). In step mode, escalation points write `$N1_HOME/memory/<ID>/escalation/request.json` instead of asking inline (see Escalation below). Standalone invocation asks/reports inline.

## Prerequisites

- `gh auth status` — if not authenticated AND the run needs a PR (prMode is not `"skip"`): "GitHub CLI is not authenticated. Run `gh auth login` first." **STOP.** (The local-merge path needs no `gh`.)
- Resolve `<ID>`: explicit argument, else parse from the current branch name using `git.branchPattern` (same extraction as n1-pr Step 1). A `#123`/`123` argument selects a PR number directly instead.

## Step 1: Resolve Target

- **PR number argument** → `gh pr view <n> --json number,state,mergedAt,mergeCommit,url,headRefName,baseRefName`.
- **No argument / ticket ID** → `gh pr view --json ...` (current branch), or `gh pr list --head <branch> --state all --json ...` when not on the branch.
- **No PR found:**
  - If `git.prMode` is `"skip"` → go to Step 2b (local merge path).
  - Otherwise → "No PR found for this branch — run /n1:n1-pr first." **STOP.**

## Step 2: Merge State Machine (PR path)

> **Polling discipline:** every poll is a separate, individual shell command; sleep between polls via standalone `sleep 30`. NEVER a bash `while` loop or background process.

Evaluate the PR state:

1. **`MERGED`** → capture the merge commit SHA (`.mergeCommit.oid`). Go to Step 3.
2. **`CLOSED`** (not merged) → report "PR #<n> was closed without merging — nothing to finish. The ticket stays open." **STOP** (step mode: `outcome: "fail"`).
3. **`OPEN`:**
   a. Check CI: `gh pr checks <n> --json name,state,conclusion`. If any check has `conclusion: FAILURE` → "CI is red on PR #<n> — run /n1:n1-ci first." **STOP** (step mode: `outcome: "fail"`).
   b. If `mergeOnFinish` is `true` → initiate the merge (once, not per poll):
      ```bash
      gh pr merge <n> --auto --<mergeMethod> --delete-branch
      ```
      `--auto` respects branch protection (required approvals, checks, merge queues). If the command itself is rejected (e.g. auto-merge disabled on the repo and checks pending), retry once with the direct form `gh pr merge <n> --<mergeMethod> --delete-branch`; if that is also rejected, before treating the failure as fatal re-check `gh pr view <n> --json state` — if the PR is `MERGED`, treat the merge as successful and continue to Step 3; otherwise report GitHub's error verbatim and **STOP** (step mode: `outcome: "fail"`).
   c. Bounded wait for merged state — up to `waitForMergeMinutes` total: poll `gh pr view <n> --json state,mergeCommit` (separate command), `sleep 30` between polls.
      - Becomes `MERGED` → capture SHA, go to Step 3.
      - Still `OPEN` at timeout:
        - **Standalone:** "PR #<n> is not merged yet — waiting on reviewer approval. Re-run `/n1:n1-finish` after the merge; the command is idempotent." **STOP.**
        - **Step mode:** escalate with id `merge_wait_timeout` (see Escalation), then emit `outcome: "escalation"` and **STOP.**

## Step 2b: Local Merge (no-PR path, `git.prMode == "skip"` only)

1. Detect worktree context: if `git rev-parse --show-toplevel` contains `/.claude/worktrees/`, resolve the main checkout (`MAIN_CHECKOUT=$(git worktree list --porcelain | grep '^worktree' | head -1 | sed 's/^worktree //')`) and run ALL subsequent Step 2b git commands from `$MAIN_CHECKOUT` (the default branch is checked out there — do not `git checkout <defaultBranch>` from inside the worktree; it always fails with "already checked out"). The clean-tree precondition applies to the main checkout's tree in this case. When NOT in a worktree (plain checkout), proceed as written below.
2. Preconditions: `git status --porcelain` must be empty (dirty tree → "Commit or stash changes first." STOP); the feature branch and `git.defaultBranch` must both exist locally.
3. Merge — from the default branch:
   ```bash
   git checkout <defaultBranch>
   ```
   Then by `mergeMethod`:
   - `squash`: `git merge --squash <branch> && git commit -m "<ID>: <ticket title>"`
   - `merge`: `git merge --no-ff <branch> -m "Merge branch '<branch>'"`
   - `rebase`: `git checkout <branch> && git rebase <defaultBranch> && git checkout <defaultBranch> && git merge --ff-only <branch>`
4. **Merge conflict** → `git merge --abort` (or `git rebase --abort`), report the conflicting files, switch back to the feature branch. **STOP** (step mode: `outcome: "fail"`).
5. **No push.** Report explicitly: "Merged `<branch>` into `<defaultBranch>` locally. Push manually when ready: `git push origin <defaultBranch>`."
6. Deploy watch is **skipped** on this path (nothing on the remote yet) — note it in the report.
7. Continue to Step 4 (close ticket). The tracker comment must say "merged locally, push pending".

## Step 3: Deploy Watch (PR path only, when `deployWatch.enabled` is `true`)

If `deployWatch.enabled` is `false` → skip to Step 4 with deploy status `skipped (not configured)`.

1. **Registration grace (up to 5 min):** poll for runs on the merge commit — separate commands, `sleep 30` between:
   ```bash
   gh run list --commit <sha> --json databaseId,name,status,conclusion,url
   ```
   When `workflowName` is set, add `--workflow "<workflowName>"`.
   - No runs after 5 min → deploy status `none triggered` ("no deployment workflow ran for this merge" — when `workflowName` is set, name it). This is **not** a failure — continue to Step 4.
2. **Watch until completion (up to `timeoutMinutes` total):** poll the same command; runs are done when every run has `status: completed`.
3. Outcomes:
   - **All `conclusion: success` (or `neutral`/`skipped`)** → deploy status `succeeded`. Continue to Step 4.
   - **Any `failure`** → fetch logs: `gh run view <databaseId> --log-failed 2>&1 | head -200`. Report the failed run + URL. Add tracker comment (when tracker configured): "Deployment failed after merging <PR URL>: <run URL>". **Do not close the ticket.** **STOP** (step mode: `outcome: "fail"`).
   - **Timeout with runs still in progress** →
     - **Standalone:** report the still-running run URLs; "Deploy still running — re-run `/n1:n1-finish` to resume watching." **STOP.**
     - **Step mode:** escalate with id `deploy_watch_timeout`, emit `outcome: "escalation"`, **STOP.**

## Step 4: Close Ticket

Gate — ALL must hold, otherwise skip with a one-line reason (e.g. "Ticket close skipped: `tracker.statuses.done` not configured — re-run /n1:n1-init to add it."):
- `closeTicket` is not `false`
- `tracker.mcp` is configured (not null)
- `tracker.statuses.done` is present in config

1. **Move status** via the operations map:
   - Jira: `mcp__<tracker.mcp>__<operations.getTransitions>` → find the transition whose target status equals `tracker.statuses.done` → `mcp__<tracker.mcp>__<operations.moveStatus>` with that transition ID.
   - YouTrack: `mcp__<tracker.mcp>__<operations.moveStatus>` (`update_issue`) with the `done` state value.
   - If the ticket is already in the `done` status → skip the move silently (idempotent re-run).
2. **Add comment** via `mcp__<tracker.mcp>__<operations.addComment>`, one of:
   - `"PR merged: <PR URL>"` (deploy not watched)
   - `"PR merged: <PR URL>. Deployment succeeded: <run URL>"` (deploy watched)
   - `"Merged locally into <defaultBranch>, push pending."` (local merge path)
   When `operations.getComments` exists, check recent comments first and skip if an identical comment is already present (idempotent re-run); otherwise add best-effort once.
3. Tracker failures: **warn, never block** — the merge already happened. Record the failure in the report.

## Step 5: Cleanup & Memory

1. **Local branch (branch mode, merged PR):** if currently on the feature branch: `git checkout <defaultBranch> && git pull`. Then `git branch -d <branch>` — safe delete only; if `-d` refuses (unmerged from the local default's perspective, e.g. squash merge before pull), leave the branch and note why. Never `-D`.
2. **Remote branch:** `--delete-branch` already handled it on the auto-merge path; on the reviewer-merge path leave remote deletion to the repo's settings — do not force it.
3. **Worktree (step mode):** normally already removed by n1-pr. If the current toplevel (`git rev-parse --show-toplevel`) contains `/.claude/worktrees/` and `worktree.cleanup` is `"after-pr"`, reuse the n1-pr Step 4b removal procedure (switch to the main checkout first, then `git worktree remove <path> --force`; on failure point at `/n1:n1-clean`).
4. **Memory** (when `$N1_HOME/memory/<ID>/` exists) — append to `overview.md`:
   ```markdown
   ## Finish
   - **Merged:** <sha> (<method>, by <auto-merge|reviewer|local merge>)
   - **Deploy:** <succeeded <run url> | failed <run url> | skipped (not configured) | none triggered>
   - **Ticket:** <moved to <done status> | left open (<reason>) | tracker not configured>
   ```
   If a `## Finish` section already exists, replace it (idempotent upsert, never duplicate). Set frontmatter:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
   n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "step" "finish"
   ```
   Standalone without memory: skip silently.

## Escalation (step mode only)

Write `$N1_HOME/memory/<ID>/escalation/request.json`:

```json
{
  "run_id": "<value of the N1_RUN_ID environment variable>",
  "step": "finish",
  "questions": [{
    "id": "merge_wait_timeout",
    "text": "PR <url> is not merged after <waitForMergeMinutes> minutes. It is waiting on reviewer approval.",
    "options": ["Retry: poll again for the merge", "Abort: end the run, re-run finish later"],
    "recommendation": "Abort — re-run the finish step after the reviewer merges",
    "context": "<PR URL, CI state, mergeOnFinish value>"
  }]
}
```

(`deploy_watch_timeout` uses the same shape: text describes the still-running run(s), options are "Retry: keep watching" / "Abort: end the run".)

Then emit the step result via Bash and STOP:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_emit_step_result "finish" "escalation" "null" "null"
```

On re-run with `response.json` present and `run_id` matching `N1_RUN_ID`: "Retry" → re-enter the step that timed out (Step 2c poll or Step 3 watch); "Abort" → record in overview `## Escalations` and emit `outcome: "fail"`.

## Report (final message)

```
Finish complete.

PR: <url> — merged (<method>, by <auto-merge|reviewer|local merge>)
Deploy: <succeeded <run url> | failed <run url> | skipped (not configured) | none triggered>
Ticket: <ID> → <done status> / left open (<reason>) / tracker not configured
Cleanup: <branch deleted | branch kept (<reason>) | worktree removed | nothing to do>
```

On non-complete exits, state exactly what stopped the flow and what the user should do (re-run command, fix CI, resolve conflict).

## Idempotency

Every path is safe to re-run: already-merged PR skips the merge; already-closed ticket skips the status move; already-present comment is not duplicated (when comments are readable); deleted branch/worktree cleanup steps no-op.

## Integration

**Called by:**
- **n1-start** — step `finish` (after CI watch), gated on `finishWork.enabled`
- **Standalone** — `/n1:n1-finish`, `/n1:n1-finish TRID-510`, `/n1:n1-finish #123`

**Invokes:**
- Inline: `gh` CLI (pr view/checks/merge, run list/view), git, tracker MCP operations
- No agent spawns — thin controller, orchestration only

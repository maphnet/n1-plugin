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

> **Polling discipline:** merge-waiting uses `n1_wait_pr_merged` from `lib/poll.sh` — an internal 30s loop bounded to 8-minute chunks per Bash call. Re-invoke until it prints a terminal state or the `waitForMergeMinutes` budget is spent. Never poll one-`gh`-call-per-model-turn.

Evaluate the PR state:

1. **`MERGED`** → capture the merge commit SHA (`.mergeCommit.oid`). Go to Step 3.
2. **`CLOSED`** (not merged) → report "PR #<n> was closed without merging — nothing to finish. The ticket stays open." **STOP.**
3. **`OPEN`:**
   a. Check CI: `gh pr checks <n> --json name,state,conclusion`. If any check has `conclusion: FAILURE` → "CI is red on PR #<n> — run /n1:n1-ci first." **STOP.**
   b. **PR comment check:** fetch unresolved review threads and pending change requests via a single GraphQL call:
      ```bash
      gh api graphql -f query='
        query($owner:String!,$repo:String!,$pr:Int!) {
          repository(owner:$owner,name:$repo) {
            pullRequest(number:$pr) {
              reviewThreads(first:100) {
                nodes {
                  isResolved
                  comments(first:10) {
                    nodes { author{login} body path line createdAt }
                  }
                }
              }
              reviews(first:50,states:[CHANGES_REQUESTED]) {
                nodes { author{login} body state createdAt }
              }
              latestOpinionatedReviews(first:50) {
                nodes { author{login} state }
              }
            }
          }
        }
      ' -f owner="<owner>" -f repo="<repo>" -F pr=<n>
      ```
      Extract `<owner>` and `<repo>` from `gh repo view --json owner,name --jq '.owner.login,.name'`.

      **What counts as unresolved:**
      - Review threads where `isResolved: false`
      - `CHANGES_REQUESTED` reviews from authors whose `latestOpinionatedReviews` entry is NOT `APPROVED`

      **When nothing is found:** skip silently, proceed to sub-item c.

      **When unresolved items exist,** analyze each inline (no agent spawn):
      1. Read the comment text and the referenced file/line (if inline thread).
      2. Check current code via `git show HEAD:<path>` at the referenced line range to see if the concern was already addressed.
      3. Produce a per-comment recommendation:
         - **Fix** — valid concern not yet addressed. Reasoning explains what needs to change.
         - **Skip** — already addressed in code, outdated (file/line no longer exists), or stylistic nitpick with no functional impact. Reasoning explains why it is safe to skip.

      Present grouped by reviewer:
      ```
      PR #<n> has unresolved reviewer feedback:

      @reviewer1 (CHANGES_REQUESTED):
        1. [path/to/file.ts:25] "Consider using a map here instead of forEach"
           -> Skip: stylistic preference, current implementation is correct.
        2. [path/to/file.ts:89] "This doesn't handle the null case"
           -> Fix: the null guard is still missing at line 89.

      @dependabot:
        3. [package.json:15] "Upgrade lodash to fix CVE-2024-XXXX"
           -> Fix: dependency is still at the vulnerable version.

      Recommendation: <M> comment(s) to address, <K> to skip.
      ```

      Ask inline — "Proceed with merge? (yes / no — fix first)"
      - **yes** → record in memory (`overview.md` `## Finish`): `Comments: <N> unresolved, user approved merge`. Proceed to sub-item c.
      - **no** → "Address the comments, push, then re-run `/n1:n1-finish`." **STOP.**

      **Pagination:** `first:100` threads covers virtually all PRs. If `reviewThreads.pageInfo.hasNextPage` is true, log: "PR has >100 review threads; only the first 100 were checked."

      **API failure:** warn and proceed to sub-item c. Comment check is advisory; never blocks merge due to API errors. Log: "Could not fetch PR review comments — skipping comment check."
   c. If `mergeOnFinish` is `true` → initiate the merge (once, not per poll):
      ```bash
      gh pr merge <n> --auto --<mergeMethod> --delete-branch
      ```
      `--auto` respects branch protection (required approvals, checks, merge queues). If the command itself is rejected (e.g. auto-merge disabled on the repo and checks pending), retry once with the direct form `gh pr merge <n> --<mergeMethod> --delete-branch`; if that is also rejected, before treating the failure as fatal re-check `gh pr view <n> --json state` — if the PR is `MERGED`, treat the merge as successful and continue to Step 3; otherwise report GitHub's error verbatim and **STOP.**
   d. Bounded wait for merged state — up to `waitForMergeMinutes` total:
      ```bash
      source "${CLAUDE_PLUGIN_ROOT}/lib/poll.sh"
      n1_wait_pr_merged <n> <remaining-minutes>
      ```
      Repeat the call (subtracting elapsed minutes) while it prints `open` and budget remains.
      - Prints `merged <sha>` → capture SHA, go to Step 3.
      - Prints `closed` → treat as Step 2 case 2 (closed without merging).
      - Budget exhausted, still `open` → "PR #<n> is not merged yet — waiting on reviewer approval. Re-run `/n1:n1-finish` after the merge; the command is idempotent." **STOP.**

## Step 2b: Local Merge (no-PR path, `git.prMode == "skip"` only)

1. Detect worktree context: if `git rev-parse --show-toplevel` contains `/.claude/worktrees/`, resolve the main checkout (`MAIN_CHECKOUT=$(git worktree list --porcelain | grep '^worktree' | head -1 | sed 's/^worktree //')`) and run ALL subsequent Step 2b git commands from `$MAIN_CHECKOUT` (the default branch is checked out there — do not `git checkout <defaultBranch>` from inside the worktree; it always fails with "already checked out"). The clean-tree precondition applies to the main checkout's tree in this case. When NOT in a worktree (plain checkout), proceed as written below.
2. Preconditions: `git status --porcelain` must be empty (dirty tree → "Commit or stash changes first." STOP); the feature branch and `git.defaultBranch` must both exist locally.
3. **Test-suite precondition:** Discover the full-suite test command using the same detection as the qa-engineer agent (inspect project root for `package.json` `scripts.test`, `pytest.ini`, `pyproject.toml`, `setup.cfg`, `phpunit.xml`, `go.mod` (→ `go test ./...`), Makefile `test` target — first match wins).
   - **No test configuration found:** note "no test suite detected — skipping test precondition" in the report and proceed.
   - **Test configuration found:** run via Bash:
     ```bash
     <discovered-test-command> 2>&1; SUITE_EXIT=$?
     ```
     If `SUITE_EXIT` is non-zero: report the failure output and output "Refusing to merge: test suite is failing (exit code <SUITE_EXIT>). Fix failing tests and re-run `/n1:n1-finish`." **STOP.**
4. Merge — from the default branch:
   ```bash
   git checkout <defaultBranch>
   ```
   Then by `mergeMethod`:
   - `squash`: `git merge --squash <branch> && git commit -m "<ID>: <ticket title>"`
   - `merge`: `git merge --no-ff <branch> -m "Merge branch '<branch>'"`
   - `rebase`: `git checkout <branch> && git rebase <defaultBranch> && git checkout <defaultBranch> && git merge --ff-only <branch>`
5. **Merge conflict** → `git merge --abort` (or `git rebase --abort`), report the conflicting files, switch back to the feature branch. **STOP.**
6. **No push.** Report explicitly: "Merged `<branch>` into `<defaultBranch>` locally. Push manually when ready: `git push origin <defaultBranch>`."
7. Deploy watch is **skipped** on this path (nothing on the remote yet) — note it in the report.
8. Continue to Step 4 (close ticket). The tracker comment must say "merged locally, push pending".

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
   - **Any `failure`** → fetch logs: `gh run view <databaseId> --log-failed 2>&1 | head -200`. Report the failed run + URL. Add tracker comment (when tracker configured): "Deployment failed after merging <PR URL>: <run URL>". **Do not close the ticket.** **STOP.**
   - **Timeout with runs still in progress** → report the still-running run URLs; "Deploy still running — re-run `/n1:n1-finish` to resume watching." **STOP.**

## Step 4: Close Ticket

**Hard-skip gates** — when either holds, skip immediately with the stated reason and go to Step 5:
- `closeTicket` is `false` → "Ticket close skipped: closeTicket is false."
- `tracker.mcp` is null → "Ticket close skipped: no tracker configured."

**Runtime recovery** — when the hard-skip gates pass but `tracker.statuses.done` is absent from config: read `references/done-status-recovery.md` for the full detection and prompt procedure.

**When `tracker.statuses.done` was already present in config, or after successful recovery above, proceed:**

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
3. **Worktree:** If the current toplevel (`git rev-parse --show-toplevel`) contains `/.claude/worktrees/`, read `worktree.cleanup` from config. If it is `"after-pr"` or `"after-merge"`, remove the worktree: switch to the main checkout first (`MAIN_CHECKOUT=$(git worktree list --porcelain | grep '^worktree' | head -1 | sed 's/^worktree //')`), then `git worktree remove <path> --force`. Success → "Worktree `<ID>` removed." Failure → warn, point at `/n1:n1-clean`.
4. **Memory** (when `$N1_HOME/memory/<ID>/` exists) — append to `overview.md`:
   ```markdown
   ## Finish
   - **Merged:** <sha> (<method>, by <auto-merge|reviewer|local merge>)
   - **Comments:** <N unresolved, user approved merge | all resolved | no unresolved comments | check skipped (API error) | n/a (already merged | local merge)>
   - **Deploy:** <succeeded <run url> | failed <run url> | skipped (not configured) | none triggered>
   - **Ticket:** <moved to <done status> | left open (<reason>) | tracker not configured>
   ```
   If a `## Finish` section already exists, replace it (idempotent upsert, never duplicate). Set frontmatter:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
   n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "step" "finish"
   ```
   Also delete the `## Pending` section from overview.md if present (the merge is no longer pending). If finish exits without a merge (timeout paths), instead update only its `last_checked` line with `date -u +%Y-%m-%dT%H:%M:%SZ`.

   Standalone without memory: skip silently.

## Report (final message)

```
Finish complete.

PR: <url> — merged (<method>, by <auto-merge|reviewer|local merge>)
Deploy: <succeeded <run url> | failed <run url> | skipped (not configured) | none triggered>
Ticket: <ID> → <done status> / left open (<reason>) / tracker not configured
Cleanup: <branch deleted | branch kept (<reason>) | worktree removed | nothing to do>
Next (manual): /n1:n1-release   ← only when release.enabled is true; N1 never runs releases automatically.
```

**Release routing (when `release.enabled` is `true` and the merge succeeded):** after printing the report, ask:

```
Release this now?
1 — Now: run /n1:n1-release (I will suggest it; you invoke it)
2 — Later: nothing recorded
3 — Batch: queue this ticket for the next release
```

- **1** → report `Next: /n1:n1-release` and STOP — do NOT invoke it yourself; releases are human-initiated.
- **2** → nothing to do.
- **3** → read `references/release-batching.md` for the append procedure.

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

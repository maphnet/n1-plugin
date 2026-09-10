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
| `.localTesting.mode` | `null` (infer from startCommand) |
| `.localTesting.smokeEndpoint` | `null` |
| `.localTesting.smokeTests` | `[]` |

Also read `git.prMode` (fallback chain: `git.prMode` → `git.draftPR: false` = `"ready"` → `"draft"`), `git.defaultBranch`, `git.branchPattern`, `tracker.mcp`, `tracker.operations`, `tracker.statuses`.

`finishWork.enabled` gates only the pipeline step — standalone invocation proceeds regardless. If `finishWork` is entirely absent, all defaults apply and the skill still works as a merge-verify + close command.

## Prerequisites

- `gh auth status` — if not authenticated: "GitHub CLI is not authenticated. Run `gh auth login` first." **STOP.**
- Resolve `<ID>`: explicit argument, else parse from the current branch name using `git.branchPattern` (same extraction as n1-pr Step 1). A `#123`/`123` argument selects a PR number directly instead.

## Step 1: Resolve Target

- **PR number argument** → `gh pr view <n> --json number,state,mergedAt,mergeCommit,url,headRefName,baseRefName`.
- **No argument / ticket ID** → `gh pr view --json ...` (current branch), or `gh pr list --head <branch> --state all --json ...` when not on the branch.
- **No PR found:** "No PR found for this branch — run /n1:n1-pr first." **STOP.**

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

## Step 3b: Post-Deploy Smoke Verification (when `localTesting.mode` is `"smoke"`)

**Gate:** read `localTesting.mode` from config. If mode is not `"smoke"` -> skip to Step 4.
Also skip if deploy status from Step 3 is `failed` (deployment failed -- no point in smoke testing).

**Smoke execution:**

1. If `localTesting.smokeEndpoint` is configured, run a health check:
   ```bash
   HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "<smokeEndpoint>")
   echo "Smoke endpoint status: $HTTP_STATUS"
   ```
   - 2xx -> PASS
   - Other -> FAIL (report status code)

2. If `localTesting.smokeTests` array is non-empty, execute each command sequentially:
   ```bash
   # For each command in smokeTests array:
   eval "<command>" 2>&1
   # Record exit code: 0 = PASS, non-zero = FAIL
   ```
   Continue through all commands even if some fail.

3. If neither `smokeEndpoint` nor `smokeTests` is configured -> skip with message: "Smoke mode is configured but no smoke endpoint or tests defined. Configure `localTesting.smokeEndpoint` or `localTesting.smokeTests` in config." Proceed to Step 4.

**Results:**
- All PASS -> smoke status `passed`. Proceed to Step 4.
- Any FAIL -> smoke status `failed`. Report failures. Add tracker comment (when tracker configured): "Post-deploy smoke tests failed after merging <PR URL>: <failure details>". Proceed to Step 4 (do not block ticket close -- the code is already merged; failures are informational).

**Telemetry:**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
SMOKE_OUTCOME=$( [ "$SMOKE_ALL_PASSED" = "true" ] && echo "pass" || echo "fail" )
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "smoke" 17 "${N1_HOME}/memory/$ID/telemetry" completed_at=now outcome=$SMOKE_OUTCOME loop_iteration=null metadata="{\"action_type\":\"smoke_executed\",\"endpoint_status\":\"$HTTP_STATUS\",\"tests_total\":$TESTS_TOTAL,\"tests_passed\":$TESTS_PASSED}"
```

**Memory:** Add to the `## Finish` section in overview.md:
```markdown
- **Smoke:** <passed | failed (<details>) | skipped (not configured) | skipped (deploy failed)>
```

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
   When `operations.getComments` exists, check recent comments first and skip if an identical comment is already present (idempotent re-run); otherwise add best-effort once.
3. Tracker failures: **warn, never block** — the merge already happened. Record the failure in the report.

## Step 5a: Telemetry Follow-Up Ticket

**Hard-skip gates** — when either holds, skip immediately without warning and go to Step 5:
- `tracker.mcp` is null or absent in `$N1_HOME/config.json`
- `N1_HEADLESS=1` is set in the environment

**Trigger judgment:** Read `$N1_HOME/memory/<ID>/ticket.md`. Inline LLM judgment: does the implemented feature warrant telemetry follow-up? Apply when the feature introduces:
- New telemetry signals or signal fields
- Token counting or cost measurement
- Model-selection or routing logic
- Agent-spawn patterns or timing measurements

Skip for: documentation updates, chore/version-bump-only commits, non-behavioral config changes. When uncertain, skip.

**Idempotency:** Read the `## Pending` section of `$N1_HOME/memory/<ID>/overview.md`. If any line starts with `telemetry_followup:`, skip the entire step (ticket was already created on a prior run) and go to Step 5.

**When trigger applies and no prior follow-up exists:**

1. **Compute check date** (run via Bash):

   ```bash
   CHECK_DATE=$(date -d "+7 days" +%Y-%m-%d 2>/dev/null)
   [ -z "$CHECK_DATE" ] && CHECK_DATE=$(date -v+7d +%Y-%m-%d)
   ```

   Default is 7 days. Use 14 or 30 days for features with low expected usage frequency (e.g., rarely invoked flags, optional integrations). Pick at model judgment — not configurable.

2. **Read plugin version** (run via Bash):

   ```bash
   MAIN_CHECKOUT=$(git worktree list --porcelain | grep '^worktree' | head -1 | sed 's/^worktree //')
   PLUGIN_VERSION=$(grep '"version"' "${MAIN_CHECKOUT}/.claude-plugin/plugin.json" | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
   ```

   If the worktree check is not applicable (standalone checkout), use `.claude-plugin/plugin.json` directly.

3. **Read PR URL** from the `## Pending` section of `$N1_HOME/memory/<ID>/overview.md` — the line recording the PR URL written by n1-pr.

4. **Read tracker config** (run via Bash):

   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   TRACKER_MCP=$(n1_config_val ".tracker.mcp" "$N1_HOME/config.json")
   PROJECT_KEY=$(n1_config_val ".tracker.projectKey" "$N1_HOME/config.json")
   TRACKER_TYPE=$(n1_config_val ".tracker.type" "$N1_HOME/config.json")
   ```

5. **Compose title:** `[Telemetry] <concise feature description> — check by <CHECK_DATE>`

   Where `<concise feature description>` is the originating ticket title from `ticket.md`, trimmed to ≤60 characters if needed (trim at a word boundary, append `…` if truncated).

6. **Compose body:**

   ```
   Telemetry follow-up for <ID>.
   PR: <PR URL from overview.md ## Pending>
   Plugin version: <PLUGIN_VERSION> (filter telemetry data to sessions at or above this version)

   ## What to validate
   <Infer from the feature: which signals, fields, or behaviors to confirm appear in telemetry.
   Example: "Verify that smoke step telemetry events appear in sessions using plugin >= vX.Y.Z.">

   ## How to check
   Open N1 telemetry. Filter to sessions where plugin version >= <PLUGIN_VERSION>. Confirm the expected signal/field is present. If usage is below ~50 sessions at check date, extend the window by another 7 days.
   ```

7. **Create the follow-up ticket** via `mcp__<tracker.mcp>__` prefix:

   - **YouTrack** (`tracker.type == "youtrack"`):
     Call `mcp__<tracker.mcp>__create_issue` with:
     ```json
     { "project": "<PROJECT_KEY>", "summary": "<title>", "description": "<body>" }
     ```
   - **Jira** (`tracker.type == "jira"`):
     Call `mcp__<tracker.mcp>__createJiraIssue` with:
     ```json
     { "projectKey": "<PROJECT_KEY>", "summary": "<title>", "description": "<body>", "issuetype": { "name": "Task" } }
     ```

   Extract the new ticket ID and URL from the response. If the response does not include a URL, construct it from the tracker base URL and ticket ID.

8. **Link to originating ticket** via tracker MCP (non-blocking — skip silently if the link operation is absent or fails):

   - **YouTrack:** Call `mcp__<tracker.mcp>__add_issue_link` with:
     ```json
     { "issueId": "<new ticket ID>", "targetIssueId": "<ID>", "type": "Relates" }
     ```
   - **Jira:** Call `mcp__<tracker.mcp>__<operations.createIssueLink>` (from `tracker.operations` in config) with:
     ```json
     { "inwardIssue": { "key": "<ID>" }, "outwardIssue": { "key": "<new ticket ID>" }, "type": { "name": "Relates" } }
     ```

9. **Record idempotency marker:** Append to the `## Pending` section of `$N1_HOME/memory/<ID>/overview.md`:
   ```
   telemetry_followup: <new ticket ID>
   ```
   Only append on successful ticket creation. If creation failed, do not write this line.

**Error handling:** All tracker calls in this step are **non-blocking** — same pattern as Step 4 Comment.
- On any failure: emit `> Warning: Telemetry follow-up ticket creation failed: <brief error>` and continue to Step 5.
- Do NOT set the idempotency marker on failure.
- Never abort n1-finish due to errors in this step.

## Step 5: Cleanup & Memory

1. **Local branch (branch mode, merged PR):** if currently on the feature branch: `git checkout <defaultBranch> && git pull`. Then `git branch -d <branch>` — safe delete only; if `-d` refuses (unmerged from the local default's perspective, e.g. squash merge before pull), leave the branch and note why. Never `-D`.
2. **Remote branch:** `--delete-branch` already handled it on the auto-merge path; on the reviewer-merge path leave remote deletion to the repo's settings — do not force it.
3. **Worktree:** If the current toplevel (`git rev-parse --show-toplevel`) contains `/.claude/worktrees/`, read `worktree.cleanup` from config. If it is `"after-pr"` or `"after-merge"`, remove the worktree: switch to the main checkout first (`MAIN_CHECKOUT=$(git worktree list --porcelain | grep '^worktree' | head -1 | sed 's/^worktree //')`), then `git worktree remove <path> --force`. Success → "Worktree `<ID>` removed." Failure → warn, point at `/n1:n1-clean`.
4. **Memory** (when `$N1_HOME/memory/<ID>/` exists) — append to `overview.md`:
   ```markdown
   ## Finish
   - **Merged:** <sha> (<method>, by <auto-merge|reviewer>)
   - **Comments:** <N unresolved, user approved merge | all resolved | no unresolved comments | check skipped (API error) | n/a (already merged)>
   - **Deploy:** <succeeded <run url> | failed <run url> | skipped (not configured) | none triggered>
   - **Smoke:** <passed | failed (<details>) | skipped (not configured) | skipped (deploy failed) | n/a>
   - **Ticket:** <moved to <done status> | left open (<reason>) | tracker not configured>
   ```
   If a `## Finish` section already exists, replace it (idempotent upsert, never duplicate). Set frontmatter:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
   n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "step" "done"
   ```
   Also delete the `## Pending` section from overview.md if present (the merge is no longer pending). If finish exits without a merge (timeout paths), instead set `step` to `finish` (not `done`) and update only its `last_checked` line with `date -u +%Y-%m-%dT%H:%M:%SZ`.

   Also clear the active-run pointer on successful completion (idempotent — safe even when n1-start also clears it in FINALIZE MEMORY):
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   n1_active_run_clear
   ```

   Standalone without memory: skip silently.

## Report (final message)

```
Finish complete.

PR: <url> — merged (<method>, by <auto-merge|reviewer>)
Deploy: <succeeded <run url> | failed <run url> | skipped (not configured) | none triggered>
Smoke: <passed | failed (<details>) | skipped (not configured) | skipped (deploy failed) | n/a (mode is not smoke)>
Ticket: <ID> → <done status> / left open (<reason>) / tracker not configured
Cleanup: <branch deleted | branch kept (<reason>) | worktree removed | nothing to do>
Next (manual): /n1:n1-release   ← only when release.enabled is true; N1 never runs releases automatically.
```

<!-- tailChain has no effect here: n1-release is never invoked automatically regardless of autonomy mode (NP-71). The steps below are always interactive/suggestion-only. -->
**Release routing (when `release.enabled` is `true` and the merge succeeded):** after printing the report, read the autonomy setting via Bash (source `lib/config.sh` first):

```bash
MP=$(n1_autonomy_val 'mechanicalPrompts')
```

**If `MP` is `auto`:** skip the question below and instead print:

```
Work complete. If you're ready to publish a release, run /n1:n1-release.
```

Write a Decision Ledger row to overview.md:
`| finish | mechanical | C | [auto] | Release now? | Suggest /n1:n1-release | Ask user | mechanicalPrompts=auto | --- |`

**If `MP` is `ask` (default):** ask:

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

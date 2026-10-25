<!-- Purpose: Push and create PR, update tracker, update memory, post-PR follow-ups, integration (Steps 4-6, 8), then hand off to step 3, which prints the PR report. -->

## Step 4: Push and Create PR

When the user starts or requests an N1 run (/n1:n1-start, /n1:n1-pr, n1-queue), that is their explicit request to commit, push the feature branch, and create the PR — do not ask to confirm; this does not authorize merge, release, or pushing the default branch, and all escalation, release, headless, and error gates still apply.

`prMode` already resolved (only `"draft"` or `"ready"` reaches here).

### Conflict check and rebase

Before pushing, verify the branch is compatible with `${DEFAULT_BRANCH}`:

```bash
git fetch origin ${DEFAULT_BRANCH}
```

Check if rebase is needed:
```bash
git merge-base --is-ancestor origin/${DEFAULT_BRANCH} HEAD
```

- Exit 0 → branch already includes all of `${DEFAULT_BRANCH}`; skip rebase.
- Exit 1 → rebase needed:

```bash
git rebase origin/${DEFAULT_BRANCH}
```

**If rebase succeeds (exit 0):** Branch is clean. Push using `--force-with-lease` (required because rebase rewrites history):

```bash
git push --force-with-lease -u origin ${CURRENT_BRANCH}
```

Then proceed to **Create PR** below.

**If rebase fails (conflicts detected):**

```bash
git rebase --abort
```

List the conflicting files (from `git status` or the rebase output), print a clear message:

```
Rebase conflicts detected — push halted.
Resolve the following conflicts manually, then re-run /n1:n1-pr:
  <list conflicting files>
```

**STOP — do not create the PR.**

### No-rebase path

When `merge-base` exit 0 (already up to date), push normally:

```bash
git push -u origin ${CURRENT_BRANCH}
```

Then proceed to **Create PR** below.

### Create PR

After a successful push (either path above), create the PR from the body file and register it in the same command, before tracker updates. This also covers hosts where the PR observation hook is unavailable. Put the title in single quotes, writing each `'` inside it as `'\''`:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/codex-review.sh"
PR_TITLE='<the PR title from prepare>'
PR_BODY_FILE="<the path from pr:body-file=>"
DEFAULT_BRANCH="<the default branch>"
PR_MODE="<draft or ready, from prepare>"
DRAFT_ARGS=(); [ "$PR_MODE" = "draft" ] && DRAFT_ARGS=(--draft)
[ -s "$PR_BODY_FILE" ] || { echo "PR body missing"; exit 1; }
PR_URL=$(gh pr create --title "$PR_TITLE" --body-file "$PR_BODY_FILE" --base "$DEFAULT_BRANCH" "${DRAFT_ARGS[@]}")
PR_RC=$?
if [ "$PR_RC" -eq 0 ] && [ -n "$PR_URL" ]; then
  n1_review_record "$PR_URL" skipped step-not-run false
  rm -f "$PR_BODY_FILE"
  printf '%s\n' "$PR_URL"
fi
```

On failure, stop. The fallback receipt is replaced by the runner's terminal outcome in step 3.

## Step 5: Update Tracker (if configured)

If `tracker.mcp` is not null:

1. **Move to code review:** `mcp__<tracker.mcp>__<operations.moveStatus>` with `tracker.statuses.codeReview`. Jira: get transition ID first via `getTransitions`. YouTrack: `update_issue` directly.
2. **Add comment:** `mcp__<tracker.mcp>__<operations.addComment>` — body: `PR created: <PR_URL>`
3. **Release queue tag** (queue children only): a ticket with a PR is no longer pending for the queue.
   ```bash
   source ~/.n1/preamble.sh
   printf 'TAG=%s\nOVERVIEW=%s\n' "${N1_QUEUE_TAG:-}" "$N1_HOME/memory/$ID/overview.md"
   ```
   Empty `TAG` -> skip (not launched by a tag-mode queue). Otherwise read and follow `<N1_ROOT>/skills/n1-queue/procedures/release-tag.md` with `ID`, `TAG`, `OVERVIEW` from the output above.

Tracker failures (including tag release): warn, don't block.

## Step 6: Update Memory

If N1 memory exists: update `overview.md` (mark PR done, add URL), add `docs_updated` list (file, confidence, action), set frontmatter `step: pr`.

## Step 8: Post-PR Follow-ups

> **ORCHESTRATOR GUARDRAIL (post-PR follow-ups):** after the PR exists, any user request that changes code, tests, docs, or config on the branch (rename a flag, tweak a message, "also handle X", address a review comment) is implemented by the **developer agent in fix mode** — never by the orchestrator with Edit/Write/`sed`, and never committed by the orchestrator. This holds even for one-line changes.

Procedure for a follow-up request:
1. Resolve the workspace: read `worktreePath` from this session's active-run file (`jq -r '.worktreePath // empty' "$(n1_active_run_file)"`). If the recorded path exists and is not under the worktree root (`n1_worktree_root`) (external worktree), use it directly. Otherwise, use `<main-checkout>/<worktree-root>/<ID>` (the worktree is still present — n1-pr no longer removes it).
2. Resolve model for `developer`. Spawn developer with: the user's request verbatim, the branch name and worktree path, `$N1_HOME/memory/<ID>/implementation.md` path, and the directive: "Implement exactly this follow-up on the existing branch. Update any docs that reference the changed behaviour (README, CLI help). Run the relevant tests. Commit with an imperative message and push to `<branch>`. Append a `## Follow-up <N>` section to `implementation.md` (idempotent). Return: commit SHAs + one-line summaries."
3. If the change touches public behaviour (CLI flags, API, config keys): spawn `code-reviewer` on `git diff <pre-follow-up SHA>..HEAD` and route any Critical/High finding back to the developer (max 2 cycles).
4. Post a tracker comment via `mcp__<tracker.mcp>__<operations.addComment>`: `Follow-up pushed to PR: <one-line summary>` (warn, don't block, on failure).

## Integration

**Called by:** n1-start (after review loop + local testing), standalone `/n1:n1-pr`
**Invokes:** n1 agent: tech-writer (Phase 1 doc update + Phase 2 PR content), developer (post-PR follow-ups); inline: git, gh, tracker MCP

## Next: Step 3 (Codex Review & Report)

The PR exists, but n1-pr is not finished. Do not print a report or CHECKPOINT here and do not return to the caller. Continue immediately with step 3: read `<N1_ROOT>/skills/n1-pr/steps/03-codex-review.md`

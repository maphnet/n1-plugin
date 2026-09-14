<!-- Purpose: Present verdicts, act on confirmed verdicts, report and memory update, integration (Steps 5-7). -->

## Step 5: Present Verdicts for User Confirmation

Display the full verdict table before taking any action:

```
## Review Response Verdicts — PR #<number>

| # | Author | Type | File:Line | Verdict | Proposed Action |
|---|--------|------|-----------|---------|-----------------|
| 1 | human  | inline | `src/foo.ts:42` | ACTIONABLE | Fix missing null check on line 42 |
| 2 | coderabbitai[bot] | inline | `lib/bar.ts:17` | NON-ACTIONABLE | Reply: "The guard is applied by the caller at call-site — redundant here." |
| 3 | human  | review-level | — | NON-ACTIONABLE | Reply: "This design is intentional: X avoids Y by ..." |

Skipped (resolved or outdated): <N>

Accept all verdicts? Enter y to accept, or list row numbers to override (e.g. "override 2,3"):
```

On override: re-prompt for each overridden row's verdict (`ACTIONABLE` / `NON-ACTIONABLE`) and proposed action text. Do NOT proceed to Step 6 until the user confirms.

## Step 6: Act on Confirmed Verdicts

### 6a: Fix ACTIONABLE Comments (if any)

Batch all ACTIONABLE comments into one developer agent spawn. Resolve model for `developer`.

**Developer instructions:**

```
You are responding to PR review comments that have been verified as technically valid.

Workspace: The worktree may have been removed after PR creation. Resolve your working directory:
- If `<WORKTREE_PATH>` exists, cd there.
- Otherwise, in `<MAIN_CHECKOUT>`: run `git fetch origin <BRANCH> && git checkout <BRANCH>`.
  If the main checkout has uncommitted changes, create a fresh worktree:
  `git worktree add <MAIN_CHECKOUT>/<worktree-root>/<ID> <BRANCH>`
Never work on the default branch.

Review comments to fix (each verified against the codebase as technically valid):
<numbered list: for each ACTIONABLE comment — file, line, original comment body, proposed fix description>

For each comment:
1. Read the referenced file at the noted location.
2. Implement the minimal change that addresses the reviewer's concern.
3. Do not refactor unrelated code.

Commit all fixes in a single commit: "fix: address PR review feedback (<ID>)"
Push to the PR branch after committing.

Output format:
## Review Fixes Applied
### Comment <N>: <file>:<line>
- **Issue:** <original concern>
- **Fix:** <what was changed>
- **Files:** <modified files>
## Summary
- Comments fixed: N
- Commit: <SHA>
```

Wait for the developer agent to return before proceeding to 6b.

### 6b: Post Rejection Replies for NON-ACTIONABLE Comments

Post replies sequentially. Do not batch — each needs its own API call.

For NON-ACTIONABLE **inline** comments, reply to the thread (pipe JSON via stdin to avoid shell injection):

```bash
jq -n --arg body "$REBUTTAL_TEXT" '{"body": $body}' | \
  gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments/${COMMENT_ID}/replies" \
  --method POST --input -
```

For NON-ACTIONABLE **review-level** comments (no inline thread to reply to), post a PR-level comment quoting the reviewer (pipe body via stdin to avoid shell injection):

```bash
printf "> %s\n\n%s" "$REVIEW_BODY_FIRST_LINE" "$REBUTTAL_TEXT" | \
  gh pr comment "$PR_NUMBER" --body-file -
```

On API error (non-2xx response): warn "Reply to comment #<id> failed (<status>). Continuing." Do not abort the loop.

## Step 7: Report and Memory Update

Write `$N1_HOME/memory/$ID/review-response.md`:

```markdown
# Review Response — PR #<PR_NUMBER>

**PR:** <PR_URL>
**Date:** <currentDate>

## Verdicts

| # | Author | Type | File:Line | Verdict | Action Taken |
|---|--------|------|-----------|---------|--------------|
<one row per processed comment>

## Skipped

| Reason | Count |
|--------|-------|
| Thread resolved | N |
| Bot thread outdated | N |

## Summary
- Total comments reviewed: N
- Skipped: N
- ACTIONABLE (fixed): N
- NON-ACTIONABLE (replied): N
- Fix commit: <SHA or N/A>
```

Final report to user:

```
Review response complete.
PR: <PR_URL>
Fixed: N comments (commit <SHA>)
Replied to: N comments
Skipped: N (resolved or outdated)
```

## Integration

**Standalone only:** `/n1:n1-review-response` or `/n1:n1-review-response #123`

**Invokes:**
- n1 agent: **developer** — applies fixes for ACTIONABLE comments (Step 6a, only when ACTIONABLE comments exist)

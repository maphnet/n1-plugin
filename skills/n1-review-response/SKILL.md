---
name: n1-review-response
description: "Respond to PR review comments. Verifies each comment against the codebase, fixes valid issues via developer agent, and posts inline rejection replies for invalid ones."
argument-hint: "[PR#]"
model: sonnet
effort: medium
---

# N1 Review Response

## Overview

Three-phase on-demand skill: **fetch → verify → act**. Fetches all open review comments on a PR, verifies each claim against codebase reality, presents verdicts for user confirmation, then fixes valid issues via the developer agent and posts inline rejection replies for invalid ones.

**Announce at start:** "I'm using the n1-review-response skill to respond to PR review comments."

## N1_HOME Resolution

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty — N1 is not configured; warn the user.

Config: `$N1_HOME/config.json`. Memory: `$N1_HOME/memory/$ID/`.

## Model Resolution

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
n1_resolve_model <agent-name>
```

## Prerequisites

```bash
gh auth status
```

Not authenticated → "Run `gh auth login` first." **STOP.**

## Step 1: Resolve PR Number and Context

- **Argument** (`#123` or `123`): strip `#`, use directly.
- **No argument:** `gh pr view --json number,headRefName --jq '.number'`. No PR → "No open PR found. Create one first or specify: `/n1:n1-review-response #123`" **STOP.**

```bash
PR_INFO=$(gh pr view --json number,url,headRefName,author)
PR_NUMBER=$(echo "$PR_INFO" | jq -r '.number')
PR_URL=$(echo "$PR_INFO" | jq -r '.url')
BRANCH=$(echo "$PR_INFO" | jq -r '.headRefName')
PR_AUTHOR=$(echo "$PR_INFO" | jq -r '.author.login')
REPO=$(gh repo view --json owner,name --jq '"\(.owner.login)/\(.name)"')
MAIN_CHECKOUT=$(jq -r '.mainCheckout // empty' "$N1_HOME/active-run.json" 2>/dev/null)
if [ -z "$MAIN_CHECKOUT" ]; then MAIN_CHECKOUT=$(git rev-parse --show-toplevel); fi
WORKTREE_PATH=$(jq -r '.worktreePath // empty' "$N1_HOME/active-run.json" 2>/dev/null)
if [ -z "$WORKTREE_PATH" ]; then
  _WT_SLUG=$(echo "$BRANCH" | grep -oE '^[A-Za-z]+-[0-9]+')
  if [ -z "$_WT_SLUG" ]; then
    echo "Warning: could not extract ticket ID segment from branch '${BRANCH}' — worktree path may be incorrect" >&2
    _WT_SLUG=$(echo "$BRANCH" | tr '/' '-')
  fi
  WORKTREE_PATH="${MAIN_CHECKOUT}/.claude/worktrees/${_WT_SLUG}"
fi
```

Derive ticket ID from branch (first `WORD-DIGITS` segment):

```bash
_ID_RAW=$(echo "$BRANCH" | grep -oE '^[A-Za-z]+-[0-9]+')
ID=${_ID_RAW:-$(echo "$BRANCH" | tr '/' '-')}
```

## Step 2: Fetch All PR Comments

Fetch inline review comments (thread roots only) and review-level bodies:

```bash
INLINE_RAW=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments" --paginate)
REVIEWS_RAW=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" --paginate)
_THREAD_RESP=$(gh api graphql -f query='
  query($owner:String!,$repo:String!,$number:Int!) {
    repository(owner:$owner,name:$repo) {
      pullRequest(number:$number) {
        reviewThreads(first:100) {
          pageInfo { hasNextPage endCursor }
          nodes { id isResolved isOutdated comments(first:1){ nodes { databaseId } } }
        }
      }
    }
  }
' -f owner="$(echo "$REPO" | cut -d/ -f1)" -f repo="$(echo "$REPO" | cut -d/ -f2)" -F number="$PR_NUMBER")
THREAD_STATE=$(echo "$_THREAD_RESP" | jq '.data.repository.pullRequest.reviewThreads.nodes')
if echo "$_THREAD_RESP" | jq -e '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' 2>/dev/null | grep -q true; then
  echo "Warning: PR #${PR_NUMBER} has more than 100 review threads — thread-state data is truncated. Resolved/outdated filtering may be incomplete for later threads." >&2
fi
```

Build the unified comment list:

**Inline comments** — from `INLINE_RAW`: root comments have no `in_reply_to_id`. Collect: `id`, `path`, `line` (or `original_line`), `body`, `user.login`, `diff_hunk`.

**Review-level comments** — from `REVIEWS_RAW`: reviews whose `body` is non-empty and `state` is `CHANGES_REQUESTED` or `COMMENTED`. Collect: `id`, `body`, `user.login`.

Do NOT collect PR-level conversation comments (`gh pr view --json comments`) — those are not review feedback.

## Step 3: Classify Authors and Filter Stale Threads

**Bot login patterns** (fixed-string case-insensitive substring match on `user.login` — use `grep -Fi` or equivalent, never regex, because patterns contain literal brackets):

| Login pattern | Source |
|---------------|--------|
| `coderabbitai[bot]` | CodeRabbit |
| `copilot-pull-request-reviewer` | GitHub Copilot Review |
| `github-advanced-security[bot]` | GitHub Advanced Security |

Example classification:
```bash
LOGIN="<user.login>"
if echo "$LOGIN" | grep -qFi "coderabbitai[bot]" || \
   echo "$LOGIN" | grep -qFi "copilot-pull-request-reviewer" || \
   echo "$LOGIN" | grep -qFi "github-advanced-security[bot]"; then
  AUTHOR_TYPE="bot"
elif [ "$LOGIN" = "$PR_AUTHOR" ]; then
  AUTHOR_TYPE="self"
else
  AUTHOR_TYPE="human"
fi
```

For each root comment, classify author as `bot`, `self` (login matches `PR_AUTHOR`), or `human`.

**Skip silently (log as "skipped"):**
- Inline comments whose thread appears in `THREAD_STATE` with `isResolved: true`
- Bot-authored comments whose thread appears in `THREAD_STATE` with `isOutdated: true`

All remaining comments proceed to Step 4. Skipped count is recorded for the final report.

## Step 4: Verify Each Comment Against the Codebase

For each remaining comment, apply the verify-then-decide pattern:

1. **Read the referenced code** — for inline comments, use the Read tool on `path` starting at `max(1, line - 10)` for 25 lines of context. For review-level comments, read any files the comment body explicitly names; if none named, treat as non-file-specific feedback.

2. **Evaluate the claim technically** — does the code at that location actually exhibit the problem described? Look for framework guarantees, existing validation, type-system protections, or test coverage that neutralizes the claim.

3. **Apply industry prefix signals** — scan the first 20 characters of `body` for:
   - `Blocking:` → strong signal toward ACTIONABLE
   - `Nit:`, `Optional:`, `FYI:` → strong signal toward NON-ACTIONABLE
   These are signals, not overrides — the codebase read takes precedence.

4. **Produce verdict** for each comment:
   - `ACTIONABLE` — the claim is technically correct and the code should change
   - `NON-ACTIONABLE` — the claim is incorrect, is a style/preference nit, is a false positive, or duplicates something already handled

5. **Draft the proposed action:**
   - ACTIONABLE: one-line description of what the fix should do
   - NON-ACTIONABLE: a one-to-two sentence technical rebuttal to post as a reply (reference the specific code or design reason)

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
  `git worktree add <MAIN_CHECKOUT>/.claude/worktrees/<ID> <BRANCH>`
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

<!-- Purpose: Prerequisites, resolve PR context, fetch comments, classify authors, verify claims (Steps 1-4). -->

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
AR_FILE=$(n1_active_run_file)
MAIN_CHECKOUT=$(jq -r '.mainCheckout // empty' "$AR_FILE" 2>/dev/null)
if [ -z "$MAIN_CHECKOUT" ]; then MAIN_CHECKOUT=$(git rev-parse --show-toplevel); fi
WORKTREE_PATH=$(jq -r '.worktreePath // empty' "$AR_FILE" 2>/dev/null)
if [ -z "$WORKTREE_PATH" ]; then
  _WT_SLUG=$(echo "$BRANCH" | grep -oE '^[A-Za-z]+-[0-9]+')
  if [ -z "$_WT_SLUG" ]; then
    echo "Warning: could not extract ticket ID segment from branch '${BRANCH}' — worktree path may be incorrect" >&2
    _WT_SLUG=$(echo "$BRANCH" | tr '/' '-')
  fi
  WORKTREE_PATH="${MAIN_CHECKOUT}/$(n1_worktree_root)/${_WT_SLUG}"
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

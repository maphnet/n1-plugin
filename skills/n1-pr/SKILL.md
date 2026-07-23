---
name: n1-pr
description: "Finalize the branch: update docs, push, create or skip PR based on config, and update tracker."
model: sonnet
effort: low
---

# N1 Pull Request Creation

## Overview

Create a pull request from the current feature branch. Spawns the tech-writer agent for PR content generation, then handles git push, PR creation via GitHub CLI, and tracker update.

**Announce at start:** "I'm using the n1-pr skill to finalize the branch."

## N1_HOME Resolution

Resolve the N1 state directory at the start of every run. Run via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty — N1 is not configured; warn the user.

All config reads use `$N1_HOME/config.json`. All memory paths use `$N1_HOME/memory/$ID/`.

## Model Resolution

When spawning any agent, resolve its model via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
n1_resolve_model <agent-name>
```

Returns the config override if set, otherwise the agent's frontmatter default.

## Prerequisites

Verify the working state:

```bash
CURRENT_BRANCH=$(git branch --show-current)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
```

- **On default branch?** → "You're on the default branch. Switch to a feature branch first." **STOP.**
- **Uncommitted changes?** → Commit them first. Summarize what's being committed and ask for confirmation.

## Standalone Skip Guard

Read `git.prMode` via `n1_config_val '.git.prMode'` using the fallback chain:
1. If `git.prMode` is present → use it directly (`"draft"`, `"ready"`, or `"skip"`)
2. Else if `git.draftPR` is `false` → treat as `"ready"`
3. Else (key absent or `true`) → treat as `"draft"`

If `prMode` is `"skip"`:

```
PR mode is set to "skip" for this project.
No push or PR will be created.
To change this, run /n1:n1-init to reconfigure.
```

**STOP.**

## Step 1: Collect Information

### Git context:
```bash
git log ${DEFAULT_BRANCH}..HEAD --oneline
git diff ${DEFAULT_BRANCH}...HEAD --stat
```

### N1 memory (if available):

Do NOT read the full report files into context — the tech-writer receives their paths in Steps 2–3 and reads them itself. Extract only what this session needs, in a single Bash call:

- `overview.md` — read in full (small: ticket title, status, key decisions)
- Verdict lines (review pass confirmation, QA line, local-testing line — the last only if the file exists):

```bash
grep -m1 -iE 'verdict' "$N1_HOME/memory/$ID/review.md" 2>/dev/null || true
grep -m1 -iE 'verdict|overall' "$N1_HOME/memory/$ID/qa.md" 2>/dev/null || true
grep -m1 -iE 'verdict|result' "$N1_HOME/memory/$ID/local-testing.md" 2>/dev/null || true
```

If a grep returns nothing (file missing or unexpected format), proceed — these lines feed the report text only; they gate nothing hard.

### N1 config:
Read `$N1_HOME/config.json` for:
- `tracker.prefix` — to detect ticket ID from branch name
- `tracker.mcp` — to know if tracker update is needed
- `git.defaultBranch` — confirmed default branch
- `git.branchPattern` — to extract ticket ID

### Extract ticket ID:
Parse from branch name using `git.branchPattern`. Example:
- Branch: `TRID-510` + pattern `{prefix}-{id}` → ticket = `TRID-510`

## Step 2: Documentation Update

**Spawn agent:** tech-writer (Phase 1 only)

Resolve model for `tech-writer`.

### Read doc config:
Read `$N1_HOME/config.json` → check for optional `docs` section:
- `docs.include` — additional doc paths to scan (array of globs)
- `docs.exclude` — doc paths to skip (array of globs)
- `docs.autoUpdate` — if `true`, skip user confirmation (default: `false`)

### Determine mode:
- If called with `docUpdateMode: "autonomous"` (passed from n1-start) → `autonomous`
- If `docs.autoUpdate` is `true` in config → `autonomous`
- Otherwise → `confirm`

### Spawn tech-writer for Phase 1:
Pass to tech-writer:
- Default branch name (from Step 1)
- Paths to memory files: `implementation.md` (if available)
- Git diff stat output from Step 1
- Doc config: `docs.include`, `docs.exclude` (if present)
- Doc update mode: the resolved mode from above

### If mode is `confirm`:
After tech-writer completes Phase 1 scan, present findings to the user:

```
Documentation scan complete.

Updates to apply:
- <file>: <what will be updated> (<confidence>)

Apply or skip? (apply/skip)
```

- **apply** → tech-writer commits the doc changes
- **skip** → discard doc changes, proceed to Step 3

### If mode is `autonomous`:
Tech-writer applies updates and commits without prompting.

### If no stale docs found:
Proceed directly to Step 3.

## Step 3: Generate PR Content

**If PR title and body are provided as input** (e.g., when called from n1-start after tech-writer already ran): skip tech-writer spawning and use the provided content directly.

**Otherwise (standalone invocation):**

**Spawn agent:** tech-writer

Resolve model for `tech-writer`.

Spawn tech-writer with:
- Ticket ID (extracted from branch name, if available)
- Paths to memory files: `overview.md`, `review.md`, `qa.md`, `local-testing.md` (if exists)
- Git diff stat output from Step 1
- Doc update report from Step 2 Phase 1 (updated/flagged/needs_review lists) — for the Documentation section in the PR body

The tech-writer agent returns a structured PR title and body.

Present the generated title and body to the user. Ask: **"Create PR with this content? (yes/edit/cancel)"**

## Step 4: Push and Create PR

Use `prMode` as already resolved by the Standalone Skip Guard above (only `"draft"` or `"ready"` reaches this step — `"skip"` exits at the Guard).

```bash
git push -u origin ${CURRENT_BRANCH}
```

If `prMode` is `"draft"`:

```bash
gh pr create \
  --title "<generated title>" \
  --body "<generated body>" \
  --base ${DEFAULT_BRANCH} \
  --draft
```

If `prMode` is `"ready"`:

```bash
gh pr create \
  --title "<generated title>" \
  --body "<generated body>" \
  --base ${DEFAULT_BRANCH}
```

Capture and display the PR URL.

## Step 4b: Worktree Cleanup

After a successful push and PR creation (or when `prMode` is `"ready"` and push succeeded), check whether a worktree should be removed:

1. Detect if the current working directory is inside a worktree under `.claude/worktrees/`:
   ```bash
   CURRENT_DIR=$(git rev-parse --show-toplevel)
   ```
   Check if `$CURRENT_DIR` contains `/.claude/worktrees/` (or `\.claude\worktrees\` on Windows).
2. If NOT inside a worktree (branch mode): skip silently — the branch remains after push/PR (standard git workflow).
3. If inside a worktree (step mode):
   1. Read `worktree.cleanup` from `$N1_HOME/config.json` (default: `"after-pr"`).
   2. If `worktree.cleanup != "after-pr"`: skip silently.
   3. Resolve the worktree path: `WORKTREE_PATH=$CURRENT_DIR`
   4. Find the main checkout: `MAIN_CHECKOUT=$(git worktree list --porcelain | grep '^worktree' | head -1 | sed 's/^worktree //')`
   5. Change to the main checkout: the subsequent remove command must be run from `$MAIN_CHECKOUT`, not from inside the worktree (removing the CWD always fails)
   6. Remove the worktree: `cd "$MAIN_CHECKOUT" && git worktree remove "$WORKTREE_PATH" --force`
   7. On success: report "Worktree `<ID>` removed."
   8. On failure: warn "Worktree cleanup failed (files may be locked). Run `/n1:n1-clean` to remove it manually." — do not abort the skill.
   Note: After successful removal, do not issue further bash commands that depend on the now-deleted `$WORKTREE_PATH`.

## Step 5: Update Tracker (if configured)

Read `$N1_HOME/config.json`. If `tracker.mcp` is not null:

1. **Move status to code review:**
   - Construct MCP tool call: `mcp__<tracker.mcp>__<tracker.operations.moveStatus>`
   - Use `tracker.statuses.codeReview` as the target status (this is "Code Review" if the tracker has it, or falls back to "In Progress")
   - For Jira: first call `mcp__<tracker.mcp>__<tracker.operations.getTransitions>` to get the transition ID for the `codeReview` status, then call `transitionJiraIssue`
   - For YouTrack: call `update_issue` with the `codeReview` status value

2. **Add PR link as comment:**
   - Construct MCP tool call: `mcp__<tracker.mcp>__<tracker.operations.addComment>`
   - Comment body: `PR created: <PR_URL>`

If tracker operations fail, warn but don't block — the PR is already created.

## Step 6: Update Memory

If N1 memory exists for this ticket:
- Update `overview.md`: mark PR step as done, add PR URL
- Add `docs_updated` to overview.md with the list of files updated, flagged, or skipped:
  ```yaml
  docs_updated:
    - file: README.md
      confidence: high
      action: updated
    - file: docs/migration.md
      confidence: none
      action: skipped
  ```
- Frontmatter: set `step: pr`

## Step 7: Report

When `prMode` is `"draft"`, the PR URL line is **bolded** to surface draft state:

```
**PR created (draft):** <PR_URL>
PR #: <number>

Title: <title>
Base: <default branch>
Tracker: <status updated / not configured / failed>

CHECKPOINT: Ready for Tech Lead review.
```

When `prMode` is `"ready"`:

```
PR created: <PR_URL>
PR #: <number>

Title: <title>
Base: <default branch>
Tracker: <status updated / not configured / failed>

CHECKPOINT: Ready for Tech Lead review.
```

## Integration

**Called by:**
- **n1-start** — after review loop passes (and local testing, when enabled)
- **Standalone** — `/n1:n1-pr`

**Invokes:**
- n1 agent: **tech-writer** — doc update (Phase 1) + PR content generation (Phase 2)
- Inline: git, gh, tracker MCP operations

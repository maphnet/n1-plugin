---
name: n1-clean
description: "Clean up N1 worktrees. Lists worktrees, classifies by status, and offers to remove non-active ones."
model: sonnet
effort: low
---

# N1 Worktree Cleanup

## Overview

Manage the lifecycle of N1 worktrees. Lists all worktrees created by N1 (under `.claude/worktrees/`), classifies them by status, and offers to remove completed or abandoned ones. Memory in `$N1_HOME` is always preserved — only the worktree directory and its checkout are removed.

**Announce at start:** "I'm using the n1-clean skill to manage worktrees."

## N1_HOME Resolution

Resolve the N1 state directory at the start of every run. Run via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty — N1 is not configured; warn the user.

All config reads use `$N1_HOME/config.json`. All memory paths use `$N1_HOME/memory/$ID/`.

- If `N1_HOME` is empty → "N1 is not configured. Run `/n1:n1-init` first." **STOP.**

## Step 1: Discover Worktrees

List all git worktrees:

```bash
git worktree list --porcelain
```

Parse the porcelain output. Each entry has:
- `worktree <path>` — the worktree directory
- `HEAD <hash>` — current commit
- `branch refs/heads/<name>` — branch name (if not detached)

Filter to entries whose path is under `.claude/worktrees/`. Extract the `<ID>` from the path (last component of the worktree path).

If no N1 worktrees found: "No N1 worktrees found. Nothing to clean up." **STOP.**

## Step 2: Classify Each Worktree

For each discovered worktree, determine its status:

### Stale
The worktree directory no longer exists on disk (git knows about it but the directory was deleted externally).
- Detection: `worktree <path>` but the path does not exist
- Action: mark for `git worktree prune`

### Completed
The corresponding task has finished (PR created or skipped).
- Detection: `$N1_HOME/memory/<ID>/overview.md` exists AND its frontmatter has `step: done` or `step: pr`
- Action: offer to remove

### Abandoned
The task was started but appears inactive.
- Detection: `$N1_HOME/memory/<ID>/overview.md` exists AND `step` is NOT `done` or `pr`, AND the branch has no commits in the last 7 days:
  ```bash
  LAST_COMMIT=$(git log -1 --format=%ct <branch> 2>/dev/null || echo 0)
  NOW=$(date +%s)
  DAYS_AGO=$(( (NOW - LAST_COMMIT) / 86400 ))
  ```
  If `DAYS_AGO >= 7` → abandoned.
- Action: flag and offer to remove (with warning)

### Active
The task is in progress with recent activity.
- Detection: not stale, not completed, not abandoned
- Action: skip (do not offer to remove)

## Step 3: Present Summary

```
N1 Worktree Status:

  Stale (directory missing):
    - <ID> (branch: <branch>)

  Completed (task done):
    - <ID> (branch: <branch>, step: done)

  Abandoned (no activity for 7+ days):
    - <ID> (branch: <branch>, step: <step>, last commit: <N> days ago)

  Active (in progress):
    - <ID> (branch: <branch>, step: <step>)

Removable: <N> worktrees (stale + completed + abandoned)
```

If no removable worktrees: "All worktrees are active. Nothing to clean up." **STOP.**

Ask:
```
Remove all removable worktrees?
1 — Yes, remove all
2 — Select which to remove
3 — Cancel
```

**If 1 (remove all):** proceed to Step 4 with all removable worktrees.
**If 2 (select):** present numbered list, let user pick by number.
**If 3:** **STOP.**

## Step 4: Remove Worktrees

For each worktree to remove:

1. **Stale entries:** just prune:
   ```bash
   git worktree prune
   ```

2. **Completed and abandoned entries:**
   ```bash
   git worktree remove "<worktree-path>" --force 2>/dev/null
   ```
   - If removal fails (Windows locked files): warn "Could not remove `<path>` — files may be locked. Try closing editors or terminals using that directory."
   - The branch is **preserved** — it may be needed for an open PR.
   - Memory in `$N1_HOME` is **preserved** — it contains task history.

3. Final prune:
   ```bash
   git worktree prune
   ```

## Step 5: Report

```
Cleanup complete.

Removed: <N> worktrees
  - <ID>: removed (was <status>)
  - <ID>: failed to remove (<reason>)

Preserved:
  - Branches (needed for open PRs)
  - Memory at $N1_HOME (task history)

Active worktrees: <N>
```

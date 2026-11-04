---
name: n1-clean
description: "Clean up N1 worktrees. With --ticket <ID>, removes that ticket's worktree once its PR is merged; without it, lists worktrees, classifies them and offers to remove merged ones. Usage: /n1:n1-clean [--ticket <ID>]"
model: sonnet
effort: low
---

# N1 Worktree Cleanup

## Overview

Removes worktrees of finished tickets. Two modes:
- **Ticket mode** (`--ticket <ID>`): one ticket, no prompt. Used by n1-queue for merged rows and safe to run by hand from any cwd inside the repository, including the target worktree.
- **General mode** (no argument): lists every linked worktree (plain git and workspace-manager ones), classifies them and offers to remove the merged ones.

Memory in `$N1_HOME` is always preserved. No worktree is ever removed with force: dirty or unmerged ones are kept, and locked ones too. Without a bound run the `- **Cleanup:**` overview line is the only record of a kept tree.

**Announce at start:** "I'm using the n1-clean skill to manage worktrees."

## N1_HOME Resolution

```bash
source ~/.n1/preamble.sh
[ -n "$N1_HOME" ] && echo "N1_HOME=$N1_HOME" || echo N1_NOT_CONFIGURED
```

If the output shows `N1_NOT_CONFIGURED` → "N1 is not configured. Run `/n1:n1-init` first." **STOP.**

## Step 0: Ticket Mode

When the arguments contain `--ticket <ID>`, after the N1_HOME check, run exactly one Bash call:

```bash
source ~/.n1/preamble.sh
ID="<ID>"; [[ "$ID" =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]] || { echo id:invalid; exit 1; }
n1_clean_ticket "$ID" "$([ -n "${N1_QUEUE_RUN_ID:-}" ] && echo queue || echo clean)"
```

Print the output lines verbatim as the final message and **STOP**. Never ask the user and write no Decision Ledger row. The helper requires the ticket's PR (overview `pr_url`) to be MERGED, removes only the worktree holding that PR's head branch, and records the result in overview `## Finish` (`- **Cleanup:**`). A workspace-manager removal from inside the target may end this session; the record is written before it. Re-running is safe.

Tokens: `cleanup:skipped (<invalid-id|no-pr|pr-not-merged|pr-unreadable>)` (nothing touched), else `worktree:removed | none | kept (<reason>) | remove-failed (<error>)` and `branch:deleted | none | kept (<not merged|checked out in <path>>)`.

## Step 1: Discover Worktrees

```bash
source ~/.n1/preamble.sh
git worktree list --porcelain | { p=; b=; while IFS= read -r l; do case $l in "worktree "*) p=${l#worktree } ;; "branch "*) b=${l#branch refs/heads/} ;; "") printf '%s\t%s\n' "$p" "$b"; p=; b= ;; esac; done; [ -z "$p" ] || printf '%s\t%s\n' "$p" "$b"; } | tail -n +2 |
while IFS=$'\t' read -r p b; do
  o=plain; n1_orca_owns "$p" && o=workspace-manager
  printf '%s\t%s\t%s\t%s\n' "$p" "${b:-detached}" "$o" "$([ -d "$p" ] && echo present || echo missing)"
done
```

Each line is `<path> <branch> <owner> <present|missing>`; the main checkout is excluded. `<ID>`: the last path component when it looks like a ticket id (`ABC-123`), else the first ticket id in the branch name; no id → listed as **Unknown** and never removed.

If no linked worktrees are found: "No worktrees found. Nothing to clean up." **STOP.**

## Step 2: Classify Each Worktree

- **Stale:** directory missing. Action: `git worktree prune`.
- **Completed:** `$N1_HOME/memory/<ID>/overview.md` has `step: done` or `step: pr` AND its PR is MERGED:
  ```bash
  URL=$(awk '/^## (Pending|Finish)/{f=1;next} /^## /{f=0} f && /^pr_url:/{sub(/^pr_url:[[:space:]]*/,""); print; exit}' "$N1_HOME/memory/<ID>/overview.md")
  [ -n "$URL" ] && gh pr view "$URL" --json state -q .state
  ```
  A ticket whose PR is still open is **Active (open PR)**, never removable.
- **Abandoned:** overview exists, `step` is not `done` or `pr`, and the branch has no commit for 7+ days:
  ```bash
  LAST_COMMIT=$(git log -1 --format=%ct <branch> 2>/dev/null || echo 0)
  DAYS_AGO=$(( ($(date +%s) - LAST_COMMIT) / 86400 ))
  ```
- **Active:** everything else (including Unknown). Never removed.

## Step 3: Present Summary

```
N1 Worktree Status:

  Stale (directory missing):
    - <ID> (branch: <branch>)
  Completed (PR merged):
    - <ID> (branch: <branch>, <owner>)
  Abandoned (no activity for 7+ days):
    - <ID> (branch: <branch>, step: <step>, last commit: <N> days ago, <owner>)
  Active (in progress or open PR):
    - <ID> (branch: <branch>, step: <step>)

Removable: <N> (stale + completed); Abandoned only by selection
```

If nothing is Stale, Completed or Abandoned: "All worktrees are active. Nothing to clean up." **STOP.**

**Autonomy gate:** read `MP=$(n1_autonomy_val 'mechanicalPrompts')`. If `MP` is `auto`: select option 1 without asking; auto mode never removes Abandoned worktrees. Write a Decision Ledger row to the relevant overview.md when one exists:
`| n1-clean | mechanical | C | [auto] | Remove merged worktrees? | Remove Stale and Completed | Select or Cancel | mechanicalPrompts=auto | --- |`
If `MP` is `ask`, ask the user:
```
Remove merged worktrees?
1 — Remove all Stale and Completed (Recommended: each Completed removal re-checks the merged PR; worktrees are never forced and kept when dirty or unmerged, per n1_clean_ticket in lib/config.sh)
2 — Select which to remove (Completed and Abandoned)
3 — Cancel
```
**1:** Step 4 with Stale and Completed. **2:** show a numbered list, let the user pick. **3:** **STOP.**

## Step 4: Remove Worktrees

1. **Stale:** `git worktree prune`.
2. **Completed:** one call per entry; record its tokens:
   ```bash
   source ~/.n1/preamble.sh
   n1_clean_ticket "<ID>" general
   ```
3. **Abandoned (user-selected only):** workspace-manager owned → `n1_orca_rm "<path>"`; otherwise `git worktree remove "<path>"`. A dirty or locked tree fails; report the error and keep it. The branch is kept.
4. Final `git worktree prune`.

## Step 5: Report

```
Cleanup complete.

  - <ID>: <tokens, e.g. worktree:removed, branch:deleted | worktree:kept (dirty), branch:kept (checked out in <path>)>
  - <ID>: removed (abandoned) | failed (<error>)

Preserved: memory at $N1_HOME; branches of Abandoned worktrees
Active worktrees: <N>
```

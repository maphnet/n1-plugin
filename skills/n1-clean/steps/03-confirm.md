# n1-clean Step 3: Confirm Removal

Ask the user (format: `<N1_ROOT>/references/question-format.md`):

```
Remove merged worktrees?
1 — Remove all Stale and Completed (Recommended: each Completed removal re-checks the merged PR; worktrees are never forced and kept when dirty or unmerged, per n1_clean_ticket in lib/config.sh)
2 — Select which to remove (Completed and Abandoned): works when you want to keep some Completed worktrees or remove Abandoned ones
3 — Cancel: works when nothing should be removed now
```

# N1 Worktree Cleanup: General Mode

Run after the N1_HOME check when no `--ticket` argument is given. Steps run in order.

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

If no linked worktrees are found, note "No linked worktrees." and continue with Step 2b.

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
- **Active:** everything else (including Unknown). Never removed. A worktree that Step 2b lists as `nopr-worktree` is shown under Leftovers instead.

## Step 2b: Scan for Other Leftovers

```bash
source ~/.n1/preamble.sh
n1_clean_scan
```

Removes nothing (it runs a best-effort `git fetch` to compare against origin). Each line is `<kind> <id> <ref> <detail>` (tab-separated, `-` = empty):
- `nopr-worktree <ID> <path> <branch>`: clean linked worktree whose ticket finished (`step: done`) without a PR, with its HEAD already on origin/<default>.
- `empty-dir - <path> -`: empty directory inside a worktree container (a directory holding only registered worktrees and empty directories) or under the N1 worktree root.
- `stale-marker <ID> <overview> -`: overview with `## Finish` that still carries the awaiting-merge marker.
- `remote-branch - <branch> <pr-url>`: head branch of a merged PR still on origin at the merged commit; ticket-keyed name, not checked out, not the head or base of an open PR, at most 20 per run.
- `note - - <text>`: a kind that could not be scanned; print the text in the summary.

## Step 3: Present Summary and Confirm

```
N1 Worktree Status:

  Stale (directory missing):
    - <ID> (branch: <branch>)
  Completed (PR merged):
    - <ID> (branch: <branch>, <owner>)
  Leftovers (merged, safe to remove):
    - <ID> (no-PR worktree: <path>, branch: <branch>)
    - empty directory: <full path>
    - <ID> (stale awaiting-merge marker)
  Remote branches of merged PRs:
    - <branch> (<pr-url>)
  Abandoned (no activity for 7+ days):
    - <ID> (branch: <branch>, step: <step>, last commit: <N> days ago, <owner>)
  Active (in progress or open PR):
    - <ID> (branch: <branch>, step: <step>)

Removable: <N> (stale + completed + leftovers); remote branches: <M>; Abandoned listed only, never removed by n1-clean
```

List the current worktree too, marked `(current)`. If nothing is Stale, Completed, Abandoned, a Leftover or a remote branch: "Nothing to clean up." **STOP.**

Run mode:

```bash
source ~/.n1/preamble.sh
{ [ "${N1_HEADLESS:-}" = 1 ] || [ -n "${N1_QUEUE_RUN_ID:-}" ]; } && echo mode:unattended || echo mode:interactive
```

- `mode:unattended` → **Autonomy gate:** select Stale and Completed without asking; this never removes Abandoned worktrees, and unattended runs never remove Leftovers or remote branches. Write a Decision Ledger row to the relevant overview.md when one exists:
  `| n1-clean | mechanical | C | [auto] | Remove merged worktrees? | Remove Stale and Completed | Select or Cancel | auto | --- |`
  Continue to Step 4 with Stale and Completed.
- `mode:interactive` → nothing has been removed yet. When Stale, Completed or Leftovers exist, ask the user:

  Remove the listed items?

  No recommendation. The options are equivalent given the available evidence; select based on team preference.
  1 — Remove the listed local items: Stale and Completed worktrees and Leftovers; works when every listed path is expected
  2 — Cancel: nothing is removed; works when a listed path is unexpected

  When remote branches are listed, ask the user separately:

  Delete the listed remote branches of merged PRs?

  No recommendation. The options are equivalent given the available evidence; select based on team preference.
  1 — Delete the listed remote branches: one `git push origin --delete` per branch; works when the merged PRs no longer need their branches
  2 — Skip: keep every remote branch; works when a listed branch is still in use

  Abandoned worktrees are never offered. Write one Decision Ledger row per answer to the relevant overview.md when one exists:
  `| n1-clean | mechanical | C | [asked] | Remove listed leftovers? | <answer> | Remove or Cancel | user | --- |`
  `| n1-clean | mechanical | C | [asked] | Delete merged remote branches? | <answer> | Delete or Skip | user | --- |`
  If every answer declines: "Nothing removed." **STOP.** Otherwise continue to Step 4 with the confirmed groups only.

## Step 4: Remove

Only the groups selected in Step 3. Process the worktree that contains the current directory last: a workspace-manager removal there ends this session (its record is written first).

1. **Stale:** `git worktree prune`.
2. **Completed:** one call per entry; record its tokens:
   ```bash
   source ~/.n1/preamble.sh
   n1_clean_ticket "<ID>" general
   ```
3. **No-PR worktrees** (interactive only): one call per entry; record its tokens:
   ```bash
   source ~/.n1/preamble.sh
   n1_clean_ticket "<ID>" merged-nopr
   ```
   Extra tokens: `cleanup:skipped (<spike|no-workspace|no-base|not-done>)`. Workspace-manager worktrees are removed through the workspace manager inside the helper (`n1_orca_owns`); never remove a worktree with plain git yourself.
4. **Empty directories** (interactive only): `rmdir -- "<path>"` per entry (never `rm -r`); a directory that is no longer empty stays.
5. **Stale markers** (interactive only): one call per entry:
   ```bash
   source ~/.n1/preamble.sh
   n1_pending_clear "<overview>" && echo marker:cleared || echo marker:failed
   ```
6. **Remote branches** (interactive, only after "Delete the listed remote branches"): one call per branch; report each result and continue after a failure:
   ```bash
   git push origin --delete "refs/heads/<branch>" && echo "remote:deleted <branch>" || echo "remote:failed <branch>"
   ```
7. Final `git worktree prune`.

## Step 5: Report

```
Cleanup complete.

  - <ID>: <tokens, e.g. worktree:removed, branch:deleted | worktree:kept (dirty), branch:kept (checked out in <path>)>
  - empty directory <path>: <removed | kept>
  - <ID> marker: <cleared | failed>
  - remote <branch>: <deleted | failed>

Preserved: memory at $N1_HOME
Active worktrees: <N>
```

---
name: n1-clean
description: "Clean up N1 worktrees. With --ticket <ID>, removes that ticket's worktree once its PR is merged; without it, scans for leftovers (merged worktrees, merged no-PR worktrees, empty directories, stale markers, merged remote branches), lists them and removes only after confirmation. Usage: /n1:n1-clean [--ticket <ID>]"
model: sonnet
effort: low
---

# N1 Worktree Cleanup

## Overview

Removes worktrees and other leftovers of finished tickets. Two modes:
- **Ticket mode** (`--ticket <ID>`): one ticket, no prompt. Used by n1-queue for merged rows and safe to run by hand from any cwd inside the repository, including the target worktree.
- **General mode** (no argument): lists every linked worktree (plain git and workspace-manager ones) plus other leftovers, classifies them, shows the list and asks before removing anything. Unattended runs (headless or queue) do not ask and remove only Stale and Completed worktrees.

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

Print the output lines verbatim as the final message and **STOP**. Never ask the user and write no Decision Ledger row. The helper requires the ticket's PR (overview `pr_url`) to be MERGED, removes the worktree holding that PR's head branch (else the overview `workspace_path` worktree, gated the same way), and records the result in overview `## Finish` (`- **Cleanup:**`). A workspace-manager removal from inside the target may end this session; the record is written before it. Re-running is safe.

Tokens: `cleanup:skipped (<invalid-id|no-pr|pr-not-merged|pr-unreadable>)` (nothing touched), else `worktree:removed | none | kept (<reason>) | remove-failed (<error>)` and `branch:deleted | none | kept (<not merged|checked out in <path>>)`.

## General Mode

When the arguments carry no `--ticket`, read `<N1_ROOT>/skills/n1-clean/general.md` (Discover, Classify, Scan, Confirm, Remove, Report) and follow it.

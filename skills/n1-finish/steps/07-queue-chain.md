# Step 7: Queue Chain (N1-447)

Run only on the queue final PR path (`headRefName` starts with `queue/`, see Step 1), after Step 2 confirmed the PR merged and before Step 6 prints the summary, so its lines appear in it. It rebases every queue branch that was cut from this queue branch and waits on this PR (a `## Predecessor` row with status `waiting` and this PR URL in another queue's queue.md), as `/n1:n1-queue --run <id>` would do for one queue. It never merges anything.

```bash
source ~/.n1/preamble.sh; bash "$N1_ROOT/scripts/n1-queue-chain.sh" --pred "<merged final PR url>" --all || true
```

Fill `<merged final PR url>` from Step 1's `gh pr view` url. Report each `queue chain:` line in the Step 6 summary. No line means no queue waited on this PR. A stop (predecessor closed or changed, rebase conflict, push refused) is already recorded in that queue's queue.md and sent as a needs-you notice. It does not fail this finish.

## Close landed children (N1-532)

Run after the chain command, in the repo of the merged final PR. A queue child that the runner merged into the queue branch stays open in the tracker until this PR merges; this section closes it. Read `steps/04-close-ticket.md` first when it is not already read (the entry lists it in `read-also:` only when `handoff:no`; a queue final PR path with `handoff:yes` loads `handoff.md` only), and read `references/done-status-recovery.md` when `tracker.statuses.done` is absent (the entry lists it then). This section never uses the hand-off worker.

```bash
source ~/.n1/preamble.sh; source "$N1_ROOT/lib/queue.sh"; n1_queue_final_landed "<merged final PR url>"
```

- `queue:none` or `queue:ambiguous`: close nothing. Report `Children: not closed (queue.md <none|ambiguous> for this PR)`. A queue closed with `--close ... abandon` before this finish lands here; move its tickets by hand. A multi-repo queue whose rows use another repo's N1 Home also lands here for that repo's final PR (queue.md lives under the first row's N1 Home), and its rows from another N1 Home print as `unlanded ... other N1 Home`; finish those by hand.
- For each `landed<TAB><T><TAB><child PR url>` line, in order:
  1. Move `<T>` to the done status through the tracker with Step 4 item 1 (Move status) and item 2 (Add comment, text `"PR merged: <child PR url>. Released to the default branch by the queue final PR <merged final PR url>"`), applying Step 4's hard-skip gate and runtime recovery (`tracker.statuses.done` absent) once for the whole list. `Ticket line` is `moved to <done status>`, or `tracker not configured` when the hard-skip gate holds.
  2. Only when the move succeeded, the ticket was already done, or no tracker is configured, run:
     ```bash
     source ~/.n1/preamble.sh; source "$N1_ROOT/lib/queue.sh"; n1_queue_finish_child "<T>" "<child PR url>" "<merged final PR url>" "<Ticket line>"
     ```
     A failed move skips this command: the child keeps `awaiting: merge`, so re-running `/n1:n1-finish <final PR>` finishes it.
- `unlanded<TAB><T><TAB><why>` lines are left unchanged.

Report in the Step 6 summary, after the chain lines: `Children closed: <T (cleanup tokens); ... | none>`, `Children not closed: <T (tracker move failed: <reason>); ... | none>`, `Children unchanged: <T (<why>); ... | none>`.

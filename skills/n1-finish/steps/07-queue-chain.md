# Step 7: Queue Chain (N1-447)

Run only on the queue final PR path (`headRefName` starts with `queue/`, see Step 1), right after Step 2 confirmed the PR merged (or after a pending-delivery resume skipped Step 2), before Step 3. It rebases every queue branch that was cut from this queue branch and waits on this PR (a `## Predecessor` row with status `waiting` and this PR URL in another queue's queue.md), as `/n1:n1-queue --run <id>` would do for one queue. It never merges anything.

```bash
source ~/.n1/preamble.sh; bash "$N1_ROOT/scripts/n1-queue-chain.sh" --pred "<merged final PR url>" --all || true
```

Fill `<merged final PR url>` from Step 1's `gh pr view` url. Report each `queue chain:` line in the Step 6 summary. No line means no queue waited on this PR. A stop (predecessor closed or changed, rebase conflict, push refused) is already recorded in that queue's queue.md. It does not fail this finish. Continue with § Queue deploy.

## Queue deploy (N1-462)

Bindings: `<QK>` is the entry's `queue-key:` value, `<SHA>` the final PR's merge SHA (Step 2, or `deploy_merge_sha` from `memory/<QK>/overview.md` on a pending-delivery resume), `<n>` the final PR number. Landed children are the `landed` lines of `n1_queue_final_landed "<merged final PR url>"` (command in § Close landed children); run it here first when a comment must go out before the close. Tracker comments use Step 4 item 2 mechanics (idempotency check included), one per landed child; with `tracker.mcp` null post none. In order, each item only when the previous one did not STOP:

1. Pending-delivery resume (entry printed `deploy-pending:true` and `sha-valid:true`): skip item 2; the deploy result is `not watched (delivery resume)`.
2. Step 3 deploy watch (`steps/03-deploy.md`) on `<SHA>`:
   - `succeeded <run url>`, `none triggered`, `skipped (no deploy workflow: ...)` or `not deployed (<conclusion>)`: that status is the deploy result. Verification: `skipped (queue final PR)`. Continue with item 3.
   - Failed: fetch logs as Step 3 says, comment `"Deployment failed after merging <merged final PR url>: <run URL>"` on each landed child, close no child, report `Deploy: failed <run url>` and `Children: not closed (deploy failed)`. **STOP.**
   - Still running or could not verify: close no child, post no comment, report the run URLs and "re-run `/n1:n1-finish <n>` to resume the watch; the children close after it". **STOP.**
3. Step 4 queue subset (`steps/04-close-ticket.md`, Queue final PR line): delivery gate keyed on `<QK>` (a no-op unless `delivery.mode` is `"ssh"`), after-deploy actions for `<n>`, covered-close after a successful delivery. A pending, declined or failed delivery (headless runs always record pending): comment `"N1: Deploy pending for the queue final PR <merged final PR url> — resume with /n1:n1-finish <n> (runbook in N1 memory)."` on each landed child instead of 03b's `<ID>` comment, close no child, report `Children: not closed (delivery <pending | declined | failed>)`, go to Step 6. After a successful delivery append `; delivered via delivery.<command | steps> (<verified | not verified>)` to the deploy result.
4. § Close landed children with that deploy result.

Re-running `/n1:n1-finish <n>` resumes at the first unfinished item; the close is idempotent.

## Close landed children (N1-532)

Run only from § Queue deploy item 4, in the repo of the merged final PR. A queue child that the runner merged into the queue branch stays open in the tracker until this PR merges and deploys; this section closes it. The entry forces `handoff:no` on this path, so `steps/04-close-ticket.md` is already read; read `references/done-status-recovery.md` when `tracker.statuses.done` is absent (the entry lists it then). This section never uses the hand-off worker.

```bash
source ~/.n1/preamble.sh; source "$N1_ROOT/lib/queue.sh"; n1_queue_final_landed "<merged final PR url>"
```

- `queue:none` or `queue:ambiguous`: close nothing. Report `Children: not closed (queue.md <none|ambiguous> for this PR)`. A queue closed with `--close ... abandon` before this finish lands here; move its tickets by hand. A multi-repo queue whose rows use another repo's N1 Home also lands here for that repo's final PR (queue.md lives under the first row's N1 Home), and its rows from another N1 Home print as `unlanded ... other N1 Home`; finish those by hand.
- For each `landed<TAB><T><TAB><child PR url>` line, in order:
  1. Move `<T>` to the done status through the tracker with Step 4 item 1 (Move status) and item 2 (Add comment, text `"PR merged: <child PR url>. Released to the default branch by the queue final PR <merged final PR url>"`, plus `. Deployment succeeded: <run URL>` when the deploy result is `succeeded <run url>`, plus ` Deployed via delivery.<command | steps> (<verified | not verified>).` when this run's delivery gate deployed), applying Step 4's hard-skip gate and runtime recovery (`tracker.statuses.done` absent) once for the whole list. `Ticket line` is `moved to <done status>`, `already <done status>` when the ticket was already done, or `tracker not configured` when the hard-skip gate holds.
  2. Only when the move succeeded, the ticket was already done, or no tracker is configured, run (`<Deploy result>` is § Queue deploy's deploy result, plain text without quotes, `$` or backticks):
     ```bash
     source ~/.n1/preamble.sh; source "$N1_ROOT/lib/queue.sh"; n1_queue_finish_child "<T>" "<child PR url>" "<merged final PR url>" "<Ticket line>" "<Deploy result>"
     ```
     A failed move skips this command: the child keeps `awaiting: merge`, so re-running `/n1:n1-finish <final PR>` finishes it.
- `unlanded<TAB><T><TAB><why>` lines are left unchanged.

Report in the Step 6 summary, after the chain lines: `Children closed: <T (cleanup tokens); ... | none>`, `Children not closed: <T (tracker move failed: <reason>); ... | none>`, `Children unchanged: <T (<why>); ... | none>`.

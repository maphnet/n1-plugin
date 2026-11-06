# Step 7: Queue Chain (N1-447)

Run only on the queue final PR path (`headRefName` starts with `queue/`, see Step 1), after Step 2 confirmed the PR merged and before Step 6 prints the summary, so its lines appear in it. It rebases every queue branch that was cut from this queue branch and waits on this PR (a `## Predecessor` row with status `waiting` and this PR URL in another queue's queue.md), as `/n1:n1-queue --run <id>` would do for one queue. It never merges anything.

```bash
source ~/.n1/preamble.sh; bash "$N1_ROOT/scripts/n1-queue-chain.sh" --pred "<merged final PR url>" --all || true
```

Fill `<merged final PR url>` from Step 1's `gh pr view` url. Report each `queue chain:` line in the Step 6 summary. No line means no queue waited on this PR. A stop (predecessor closed or changed, rebase conflict, push refused) is already recorded in that queue's queue.md and sent as a needs-you notice. It does not fail this finish.

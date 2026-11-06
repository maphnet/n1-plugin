# Step 7: Queue Chain (N1-447)

Run only on the queue final PR path (`headRefName` starts with `queue/`, see Step 1), after Step 2 confirmed the PR merged and Step 6 finished. It rebases every queue branch that was cut from this queue branch and waits on it (a `## Predecessor` row with status `waiting` in another queue's queue.md), as `/n1:n1-queue --run <id>` would do for one queue. It never merges anything.

```bash
source ~/.n1/preamble.sh; N1_HOME="$N1_HOME" bash "$N1_ROOT/scripts/n1-queue-chain.sh" --all || true
```

Report each `queue chain:` line in the summary. No line means no queue waited on this PR. A stop (predecessor closed or changed, rebase conflict, push refused) is already recorded in that queue's queue.md and sent as a needs-you notice. It does not fail this finish.

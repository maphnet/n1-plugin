# Preview

Resolve the merge mode for each distinct N1 Home among the candidates (the same value run.md writes to the `N1 Home` column):

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
for h in <distinct N1 Home paths>; do printf '%s=%s\n' "$h" "$(N1_HOME="$h" n1_queue_val mergeOnFinish)"; done
```

`MERGE_MODE` is `Merge after CI: disabled (queue.mergeOnFinish=false)` when every line ends in `false`, or `Merge after CI: enabled (queue.mergeOnFinish=true)` when every line ends in `true`. When the homes disagree, it is `Merge after CI: ` followed by `<repo> enabled|disabled`, separated by `; `.

Print the plan table:

```
## Queue <QUEUE_ID>
Each ticket stops after PR + CI. <MERGE_MODE>
| # | Ticket | Title | Repo | Model | Reason |
|---|--------|-------|------|-------|--------|
| 1 | ... |

Excluded:
| Ticket | Reason |
|--------|--------|
| ... | blocked by X-123 |
```

If `--dry-run`: print "Dry run -- nothing launched." **STOP** (do not write queue.md).

Otherwise ask the user:
- **Start** -> proceed to run step.
- **Edit** -> free text: remove tickets, reorder, change model (`KEY=opus|sonnet`). Apply changes, re-print the table, ask again. Log each edit as `| preview | edit | <text> |` in a pending Decision Ledger list.
- **Cancel** -> **STOP.**

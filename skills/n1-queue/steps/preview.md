# Preview

Print the plan table:

```
## Queue <QUEUE_ID>
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

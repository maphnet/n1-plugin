# Close (--close [<id>])

Verifies that a queue run is settled, then removes its state: the worktree of each merged row (when its overview.md records the merged PR), every row's queue identity and session pointers, and the queue directory. Nothing is archived. A refusal removes nothing. Interactive sessions only.

```bash
source ~/.n1/preamble.sh
[ "${N1_HEADLESS:-}" = 1 ] && echo HEADLESS
```

If the output shows `HEADLESS`: print "--close needs an interactive session." **STOP.**

`CLOSE_ID` is the `--close` `<id>` argument (validated in SKILL.md § Input), or empty. Without an id the most recently modified queue is used; its path is printed, and a queue that is running or not settled is refused.
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/frontmatter.sh"
source "$N1_ROOT/lib/queue.sh"
CLOSE_ID='<id or empty>'
if [ -n "$CLOSE_ID" ]; then QUEUE_FILE="$N1_HOME/queue/$CLOSE_ID/queue.md"
else QUEUE_FILE=$(find "$N1_HOME/queue" -name queue.md -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-); fi
echo "queue file: ${QUEUE_FILE:-none}"
n1_queue_close "$QUEUE_FILE" 2>&1; echo "close:rc=$?"
```

Print the output verbatim.
- `close:rc=0`: the queue is closed; the output lists the removed directory, identity files and worktree results. A `cleanup:skipped (...)` worktree result is not an error: that worktree stays for `/n1:n1-clean`. **STOP.**
- `close:rc=1`: nothing was removed; the listed rows (open PRs, active workers, unstarted rows, final PR) block the close. **STOP.**
- `close:rc=2`: the runner died mid-run. Continue below.

This question is an unconditional gate: always ask the user and never auto-resolve it. Ask the user: "Queue <queue_id> was interrupted (its runner is gone) with the unfinished rows listed above. Abandon it and remove its files? Unstarted rows are dropped, merged rows' worktrees are removed, and nothing is archived."

No recommendation. The options are equivalent given the available evidence; select based on team preference.

Options:
- Abandon and remove
- Cancel

Anything but "Abandon and remove": print "Close cancelled; nothing changed." **STOP.**

Confirmed. `<QUEUE_FILE>` is the path from the `queue file:` line above:
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/frontmatter.sh"
source "$N1_ROOT/lib/queue.sh"
QUEUE_FILE='<QUEUE_FILE>'
n1_queue_close "$QUEUE_FILE" abandon 2>&1; echo "close:rc=$?"
```

Print the output verbatim. `close:rc=1` means a row became active or a PR is still open: nothing was removed. **STOP.**

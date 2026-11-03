# Stop (--stop [<id>])

Stops the workers of a queue run after the user confirms. Interactive sessions only: a headless or queue-child session never stops workers.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/frontmatter.sh"
source "$N1_ROOT/lib/queue.sh"
[ "${N1_HEADLESS:-}" = 1 ] && echo HEADLESS
```

If the output shows `HEADLESS`: print "--stop needs an interactive session." **STOP.**

`QUEUE_FILE`: with `<id>`, `$N1_HOME/queue/<id>/queue.md` (the id was validated in SKILL.md § Input); otherwise the most recently modified one:
```bash
source ~/.n1/preamble.sh
QUEUE_FILE=$(find "$N1_HOME/queue" -name queue.md -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
```
No queue file: "No queue runs found." **STOP.**

List the run's unsettled workers (ticket, PR, PR state):
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/frontmatter.sh"
source "$N1_ROOT/lib/queue.sh"
n1_orca_unsettled "$QUEUE_FILE" | while IFS=$'\t' read -r num t h task d; do
    url=$(n1_queue_child_pr_url "$h/memory/$t/overview.md")
    printf '%s\t%s\t%s\n' "$t" "${url:-no PR}" "$(n1_queue_pr_state "$url")"
done
```
No rows: "No live workers to stop in queue <queue_id>." **STOP.**

Print the list, then ask the user: "Stop <N> worker(s) of queue <queue_id>? Each worker's own terminal is closed, its row is recorded `stopped` and its queue identity is removed. A worker with an OPEN PR may be mid finish-chain (CI, review, merge); stopping it can leave that PR unmerged. A worker whose PR already merged is only recorded as merged." Options:
- Stop workers
- Cancel

No recommendation. The options are equivalent given the available evidence; select based on team preference.

Anything but "Stop workers": print "Stop cancelled; nothing changed." **STOP.**

Confirmed:
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/frontmatter.sh"
source "$N1_ROOT/lib/queue.sh"
if n1_queue_runner_alive "$(n1_read_frontmatter "$QUEUE_FILE" pid)" "$QUEUE_FILE"; then
    : > "$(dirname "$QUEUE_FILE")/.stop" && echo "stop:queued"
else
    ORCA_RUN=$(n1_read_frontmatter "$QUEUE_FILE" orca_run_id); rc=0
    while IFS=$'\t' read -r -u 3 num t h task d; do
        n1_orca_stop_worker "$QUEUE_FILE" "$num" "$t" "$h" "$task" "$d" "$ORCA_RUN" </dev/null || rc=1
    done 3< <(n1_orca_unsettled "$QUEUE_FILE")
    echo "stop:rc=$rc"
fi
```

Print the output verbatim. `stop:queued`: "Stop requested; the runner closes the workers at its next poll, then halts. Check with `/n1:n1-queue --status <queue_id>`." A `stop failed:` line means that worker's terminal was not closed (also the result when the workspace manager is unavailable): its row and identity are unchanged; close it in the workspace manager, then run `--status`.

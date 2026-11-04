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
    url=$(n1_queue_attested_pr "$QUEUE_FILE" "$t" "$h")
    printf '%s\t%s\t%s\n' "$t" "${url:-no PR}" "$(n1_queue_pr_state "$url")"
done
```
No rows: "No live workers to stop in queue <queue_id>." **STOP.**

Print the list. This question is an unconditional gate: always ask the user, even when `autonomy.mode` is `hands-off`, and never auto-resolve it. Ask the user: "Stop <N> worker(s) of queue <queue_id>? Each worker's own terminal is closed (a worker whose terminal is already gone is only recorded), its row is recorded `stopped` and its queue identity is removed. A worker with an OPEN PR may be mid finish-chain (CI, review, merge); stopping it can leave that PR unmerged. A worker whose PR already merged is only recorded as merged."

No recommendation. The options are equivalent given the available evidence; select based on team preference.

Options:
- Stop workers
- Cancel

Anything but "Stop workers": print "Stop cancelled; nothing changed." **STOP.**

Confirmed. The marker carries the queue's run_id (the runner ignores any other content) and the runner consumes it within one poll; a runner that is gone or past its supervise loop never does, so then the workers are stopped directly:
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/frontmatter.sh"
source "$N1_ROOT/lib/queue.sh"
STOPF="$(dirname "$QUEUE_FILE")/.stop"; QUEUED=0
if n1_queue_runner_alive "$(n1_read_frontmatter "$QUEUE_FILE" pid)" "$QUEUE_FILE"; then
    printf '%s' "$(n1_read_frontmatter "$QUEUE_FILE" run_id)" > "$STOPF"
    POLL=$(n1_queue_val pollSeconds); [[ "$POLL" =~ ^[0-9]+$ ]] || POLL=30
    for _ in $(seq 1 $((2 * POLL + 5))); do
        [ -e "$STOPF" ] || { QUEUED=1; break; }
        sleep 1
    done
    [ "$QUEUED" = 1 ] && echo "stop:queued" || rm -f "$STOPF"
fi
if [ "$QUEUED" = 0 ]; then
    ORCA_RUN=$(n1_read_frontmatter "$QUEUE_FILE" orca_run_id); rc=0
    while IFS=$'\t' read -r -u 3 num t h task d; do
        n1_orca_stop_worker "$QUEUE_FILE" "$num" "$t" "$h" "$task" "$d" "$ORCA_RUN" </dev/null || rc=1
    done 3< <(n1_orca_unsettled "$QUEUE_FILE")
    echo "stop:rc=$rc"
fi
```

Print the output verbatim. `stop:queued`: "The runner took the stop and is closing the workers, then halts. Check with `/n1:n1-queue --status <queue_id>`; a row still `in-progress` there means its close failed (the runner also sends a needs-you notice)." A `note: <ticket> worker terminal already gone` line means the workspace manager no longer lists that worker or reports its terminal missing: its row is recorded `stopped` with nothing to close. A `stop failed:` line means that worker's terminal was not closed (the worker list was unreadable, the listed worker has no safe terminal handle, or the close failed; also the result when the workspace manager is unavailable): its row and identity are unchanged; close it in the workspace manager, then run `--status`.

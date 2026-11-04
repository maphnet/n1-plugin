# Retry (`--retry <ticket>`)

Resets one `failed` or `escalated` Plan row to `pending` so the next `--run` relaunches it. A ticket whose overview.md `workspace_path` is its workspace-manager worktree resumes there with its branch and memory. Every other row stays unchanged. The runner is not started here.

`<ticket>` is the `--retry` argument. If it does not match `^[A-Za-z][A-Za-z0-9_]*-[0-9]+$`, print "Invalid ticket id: <ticket>." **STOP.**

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
RETRY_TICKET='<ticket>'
# Newest queue.md that has a row for the ticket.
QUEUE_FILE=$(find "$N1_HOME/queue" -name queue.md -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2- \
    | while IFS= read -r f; do grep -qF "| $RETRY_TICKET |" "$f" && { printf '%s\n' "$f"; break; }; done)
n1_queue_retry "$QUEUE_FILE" "$RETRY_TICKET"
```

Relay the output line to the user as is.
- On success it reads `Retry queued: /n1:n1-queue --run <queue-id>`. Tell the user to run that command to relaunch the row under the same queue run.
- On a refusal, the line names the reason and nothing changed:
  - invalid id
  - "No queue runs found."
  - the queue is running
  - the queue step cannot be retried
  - no row for the ticket
  - the row is in another status

**STOP.**

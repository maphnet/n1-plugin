# Run

Busy guard first: if `$QUEUE_DIR/queue.md` exists and its frontmatter `pid` is alive, print "Queue <QUEUE_ID> is already running (pid <pid>). Check: `/n1:n1-queue --status <QUEUE_ID>`." **STOP.**

```bash
source ~/.n1/preamble.sh
OLD_PID=$(n1_read_frontmatter "$QUEUE_DIR/queue.md" pid 2>/dev/null); [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null && echo "busy:$OLD_PID"
```

Write `$QUEUE_DIR/queue.md` with EXACT section order (the runner assumes `## Runs` is last):

```markdown
---
queue_id: <QUEUE_ID>
mode: tag|story
story_id: <ID or empty>
step: plan
started: <date -u +%Y-%m-%dT%H:%M:%SZ>
---
# Queue <QUEUE_ID>

## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | <KEY> | <title> | <repo> | <n1 home> | <model> | pending | |
...

## Excluded
| Ticket | Reason |
|--------|--------|
...

## Decision Ledger
| Step | Decision | Detail |
|------|----------|--------|
(preview edits from the preview step)

## Runs
| Ticket | Started | Exit | Outcome | PR |
|--------|---------|------|---------|----|
```

Launch the runner:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
QUEUE_FILE="$QUEUE_DIR/queue.md"
nohup bash "$N1_ROOT/scripts/n1-queue-run.sh" "$QUEUE_FILE" > "$QUEUE_DIR/runner.log" 2>&1 &
RUNNER_PID=$!
echo "pid:$RUNNER_PID"
```

Print: "Queue <QUEUE_ID> started (<N> tickets, pid <PID>). Each ticket stops after PR + CI; nothing is merged. Check: `/n1:n1-queue --status <QUEUE_ID>`."

**End the turn.** Do not poll, do not sleep.

# Report (--status)

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
source "$N1_ROOT/lib/frontmatter.sh"
```

If a specific queue ID was given: `QUEUE_FILE="$N1_HOME/queue/<id>/queue.md"`.
Otherwise: find the most recently modified `queue.md` under `$N1_HOME/queue/`:
```bash
source ~/.n1/preamble.sh
QUEUE_FILE=$(find "$N1_HOME/queue" -name queue.md -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
```

If no queue file found: "No queue runs found." **STOP.**

Read frontmatter `step` and `queue_id`. Print:
- `Step: <step>` (plan/run/done/halted)
- The `## Plan` table from queue.md
- For each ticket in the Plan with status `pr`, `escalated`, or `failed`: read `$N1_HOME_COL/memory/<TICKET>/overview.md` and extract `## Escalations` content (if any). Print escalations grouped by ticket.

After printing the Plan table, compute and print decision counts, then write `telemetry.json`:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
QUEUE_DIR=$(dirname "$QUEUE_FILE")
QUEUE_ID=$(n1_read_frontmatter "$QUEUE_FILE" queue_id)
RUN_ID=$(n1_read_frontmatter "$QUEUE_FILE" run_id)
STEP=$(n1_read_frontmatter "$QUEUE_FILE" step)
COUNTS=$(n1_queue_decision_counts "$QUEUE_FILE")
PD=$(printf '%s' "$COUNTS" | cut -f1)
AD=$(printf '%s' "$COUNTS" | cut -f2)
ES=$(printf '%s' "$COUNTS" | cut -f3)
printf 'Decisions: plan=%s autonomous=%s escalations=%s\n' "$PD" "$AD" "$ES"
printf '{"queue_id":"%s","run_id":"%s","step":"%s","plan_decisions":%s,"autonomous_decisions":%s,"escalations":%s}\n' \
    "$QUEUE_ID" "$RUN_ID" "$STEP" "$PD" "$AD" "$ES" > "$QUEUE_DIR/telemetry.json"
```

## Story summary comment

In story mode, when `step` is `done` or `halted`:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
STORY_ID=$(n1_read_frontmatter "$QUEUE_FILE" story_id)
QUEUE_ID=$(n1_read_frontmatter "$QUEUE_FILE" queue_id)
RUN_ID=$(n1_read_frontmatter "$QUEUE_FILE" run_id)
MARKER="n1-queue-summary:${QUEUE_ID}:${RUN_ID}"
```

Check via `mcp__<TRACKER_MCP>__<GET_COMMENTS_OP>` whether a comment with `MARKER` already exists on the story. If not, post a summary comment via `mcp__<TRACKER_MCP>__<COMMENT_OP>` listing ticket -> outcome -> PR (one line per Plan row). End with the marker string. Keep the comment under 15 lines.

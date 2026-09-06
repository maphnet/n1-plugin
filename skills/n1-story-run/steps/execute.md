# Execute

Loop over `## Plan` rows with Status `pending`, in table order, starting at frontmatter `current_index` (0-based among pending rows). Read timing config once:
```bash
POLL=$(n1_story_val pollSeconds); SUB_TIMEOUT=$(n1_story_val subtaskTimeoutMinutes)
MERGE_POLL=$(n1_story_val mergePollMinutes); MERGE_TIMEOUT=$(n1_story_val mergeTimeoutMinutes)
```
Per row: `KEY`, `REPO`, `SUB_HOME` (N1 Home column), `MODEL`. `OVERVIEW="$SUB_HOME/memory/$KEY/overview.md"`, `LOG="$STORY_MEM/runs/$KEY.jsonl"`.

## 1. Pre-check (idempotent resume)
```bash
STATUS=$(n1_story_child_status "$OVERVIEW" 0)
```
- `merged` -> mark row `merged`, record PR via `n1_story_child_pr_url`, advance (section 7).
- `awaiting-merge` -> go to section 5.
- Otherwise, if `## Runs` has a row for `KEY` with a PID and `kill -0 <PID>` succeeds -> re-attach: go to section 3 with that PID.
- Busy guard: if `$SUB_HOME/active-run.json` exists and its `ticketId` != `KEY` -> AskUserQuestion "Repo <REPO> has an active N1 run for <other>. **Wait & retry** / **Launch anyway** / **Pause story**."

## 2. Launch
```bash
CMD=$(n1_story_child_cmd "$REPO" "$KEY" "$MODEL" "$STORY_ID" "$LOG")
```
Run `bash -c "$CMD"` with the Bash tool in background mode; capture the PID it reports. Append `## Runs` row: `| KEY | <date -u +%Y-%m-%dT%H:%M:%SZ> | pid:<PID> | running | | |`. Print `>>> [i/N] <KEY> -- <service> -- <MODEL>`.

## 3. Monitor
Repeat until the process exits or `SUB_TIMEOUT` minutes pass. Each iteration is one short Bash call (never exceed one call per poll; do not block longer than `POLL` seconds in a single call):
```bash
sleep "$POLL"; kill -0 "$PID" 2>/dev/null && ALIVE=1 || ALIVE=0
STEP=$(n1_read_frontmatter "$OVERVIEW" step)
```
Print `  . <KEY> step: <STEP>` only when `STEP` changed since the last poll. On timeout: `kill -TERM -- -"$PID" 2>/dev/null; sleep 5; kill -KILL -- -"$PID" 2>/dev/null`, set outcome `timeout`, go to section 6.
When the process exits, `EXIT=$(tail -1 "$LOG" | grep -q '"is_error":true' && echo 1 || echo 0)`; if the process was launched via `bash -c` and its exit code is available from the background task result, prefer that.

## 4. Classify
```bash
OUTCOME=$(n1_story_child_status "$OVERVIEW" "$EXIT"); PR_URL=$(n1_story_child_pr_url "$OVERVIEW")
```
`running` after exit counts as `failed`. Then: `merged` -> section 7; `awaiting-merge` -> section 5; `escalated` / `failed` -> section 6.

## 5. Wait for merge
Poll every `MERGE_POLL` minutes (one Bash call per poll, `sleep $((MERGE_POLL*60))` max) up to `MERGE_TIMEOUT` minutes:
```bash
STATE=$(cd "$REPO" && gh pr view "$PR_URL" --json state,mergedAt -q '.state')
```
- `MERGED` -> run the finish child: `cd "$REPO" && N1_HEADLESS=1 N1_AUTONOMY_PRESET=autonomous claude -p "/n1:n1-finish $KEY" --permission-mode bypassPermissions --output-format stream-json --verbose > "$STORY_MEM/runs/$KEY.finish.jsonl" 2>&1` (background, monitor as section 3 with a 30-minute cap). Regardless of the finish child's outcome, the subtask is `merged`; a failed finish is noted in the Runs row (`finish: failed`) but does not pause the story. -> section 7.
- `CLOSED` -> outcome `failed`, reason "PR closed without merge" -> section 6.
- Timeout -> outcome `awaiting-merge` (kept), reason "PR <PR_URL> not merged after <MERGE_TIMEOUT> minutes" -> section 6.

## 6. Escalate / pause
Append to `## Escalations` in `story.md`:
`- <date> <KEY>: <OUTCOME> -- <reason>. Child step: <STEP>. Log: <LOG>. Overview: <OVERVIEW>. <child ## Escalations text if any, first 3 lines>`
Update the row Status to `<OUTCOME>`, set frontmatter `step: paused` (keep `current_index`). Post a tracker comment on `STORY_ID` via `mcp__<TRACKER_MCP>__<COMMENT_OP>`: `N1 story run paused at <KEY>: <OUTCOME> -- <reason>`. Print a report with the escalation lines and: "Fix or merge, then re-run `/n1:n1-story-run <STORY_ID>` to resume. To skip <KEY>, change its Status to `skip` in <story.md path>." **STOP.**

## 7. Advance
Update the Runs row: exit code, outcome, PR URL, merged time (`gh pr view --json mergedAt -q .mergedAt`). Set row Status `merged`. `current_index += 1` via `n1_write_frontmatter`. Print `[ok] [i/N] <KEY> merged -- <PR_URL>`.
After the last pending row: `n1_write_frontmatter "$STORY_MEM/story.md" step summarize`.

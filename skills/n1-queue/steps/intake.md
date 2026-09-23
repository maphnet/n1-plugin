# Intake

Builds the candidate list for the queue. Two modes: tag (search tracker) or story (subtasks of a parent).

## Tag mode

Search via `mcp__<TRACKER_MCP>__<SEARCH_OP>`:
- **YouTrack:** query `project: {PREFIX} tag: {<tag>} State: {<TODO_STATUS>}`, max results `n1_queue_val maxTickets`.
- **Jira:** JQL `project = <PROJECT_KEY> AND labels = "<tag>" AND status = "<TODO_STATUS>"`, maxResults `n1_queue_val maxTickets`. Include `cloudId` when set.

For each result, call `mcp__<TRACKER_MCP>__<READ_OP>` to get `key`, `title`, `description`, `status`, `size` (estimation field if available).

Repo and N1 Home for all candidates: current repo root (`git rev-parse --show-toplevel`) and `$N1_HOME`.

## Story mode

Call `mcp__<TRACKER_MCP>__<READ_OP>` for the story ID. Record `STORY_TITLE`.

Enumerate subtasks (same logic as tag mode but via parent link):
- **Jira:** call `mcp__<TRACKER_MCP>__<SEARCH_OP>` with JQL `parent = <STORY_ID> ORDER BY created ASC`. Include `cloudId`.
- **YouTrack:** call `mcp__<TRACKER_MCP>__<LINKS_OP>` for the story ID; keep links of type `subtask` where the story is the parent; targets are the subtasks. Call `READ_OP` on each.

Status classification: a status whose lowercase name is one of `done`, `closed`, `resolved`, `fixed`, `verified` -> `done-before-run`. Everything else -> candidate.

For each candidate in story mode:
```bash
source "$N1_ROOT/lib/preamble.sh"
source "$N1_ROOT/lib/queue.sh"
SERVICE=$(n1_story_parse_service "$TITLE")
if [ -n "$SERVICE" ]; then
  if HIT=$(n1_story_find_repo "$SERVICE"); then CFG_PATH=${HIT%%$'\t'*}; REPO=${HIT#*$'\t'}; N1_HOME_SUB=$(dirname "$CFG_PATH"); else CFG_PATH=""; REPO=""; fi
else
  MY_SERVICE=$(n1_config_val '.ticketTagging.service')
  if [ -z "$MY_SERVICE" ]; then CFG_PATH="$N1_HOME/config.json"; N1_HOME_SUB="$N1_HOME"; REPO=$(n1_config_val '.repoPath'); [ -z "$REPO" ] && REPO=$(git rev-parse --show-toplevel); else CFG_PATH=""; REPO=""; fi
fi
```
- No matching config -> ask the user: **Enter path**, **Skip** (Status `skip`, reason "no repo"), **Cancel**.
- Matched config but empty `REPO` -> ask for path, validate, backfill.

## Story check (tag mode only)

For each candidate call `mcp__<TRACKER_MCP>__<LINKS_OP>` (skip when `LINKS_OP` is empty). If the candidate is the parent of any `subtask` link whose target is not done -> exclude with reason `story: run with --story <ID>`. A tagged story is never expanded into the queue; the user runs it explicitly in story mode.

## Blocker check

For each candidate call `mcp__<TRACKER_MCP>__<LINKS_OP>` (when `LINKS_OP` is empty, i.e. config predates the `getIssueLinks` operation, skip link checks and rely on the description grep; say so in the preview). A candidate whose inbound dependency (`depends on`, `is blocked by`) points at ANY ticket that is not done -> excluded with reason `blocked by <ID>`.

Additionally grep the description: a line matching `(after|depends|blocked|requires|needs).*<PREFIX>-[0-9]+` (case-insensitive) naming a ticket that is not done -> same exclusion.

Excluded tickets are left for a later run (no toposort).

## Description quality

For each remaining candidate, assess the description: if the description is empty or has fewer than 30 words (whitespace-split), exclude with reason `description too thin`.

## Model per ticket

```bash
source "$N1_ROOT/lib/preamble.sh"
source "$N1_ROOT/lib/queue.sh"
MODEL=$(n1_story_pick_model "$SIZE")
```

If no size field, default to `sonnet`.

## Output

Build two lists:
- **Candidates**: `#`, `Ticket`, `Title`, `Repo`, `N1 Home`, `Model`
- **Excluded**: `Ticket`, `Reason` (blocked, story, description too thin, skip, done-before-run)

If no candidates: "No actionable tickets found." **STOP.**

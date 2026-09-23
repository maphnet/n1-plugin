---
name: n1-queue
description: "Use when a batch of tracker tickets tagged for unattended work should run through the pipeline one after another without merging. Usage: /n1:n1-queue [--tag <tag>] [--story <ID>] [--dry-run] [--status [<id>]]"
argument-hint: "[--tag <tag>] [--story <ID>] [--dry-run] [--status [<id>]]"
model: sonnet
---

# N1 Queue

**Host vocabulary:** "ask the user" / "user prompt" means the host's question mechanism from the HOST ROUTING block in session context. "Dispatch persona `<name>`" and "invoke skill `<x>`" likewise follow HOST ROUTING.

Launches a batch of tracker tickets through `n1-start` sequentially via a background bash runner. Each ticket stops after PR + CI; nothing is merged. The skill handles intake and preview; the runner (`scripts/n1-queue-run.sh`) handles execution.

**Announce at start:** "I'm using the n1-queue skill to process queue <QUEUE_ID>."

## Preamble

```bash
source "$N1_ROOT/lib/preamble.sh"
source "$N1_ROOT/lib/queue.sh"
```

If `N1_HOME` is empty: "N1 is not configured for this project. Run `/n1:n1-init` to set it up." **STOP.**

## Input

Parse arguments: `--tag <tag>` (tag mode), `--story <ID>` (story mode, accept tracker URLs via `n1_extract_ticket_from_url`), `--dry-run`, `--status [<id>]`.

`QUEUE_ID` = the tag (tag mode) or the story ID (story mode). Default tag: `n1_queue_val tag` (i.e. `n1-auto`). `QUEUE_DIR="$N1_HOME/queue/$QUEUE_ID"`; `mkdir -p "$QUEUE_DIR"`.

## Tracker gate

```bash
source "$N1_ROOT/lib/preamble.sh"
source "$N1_ROOT/lib/queue.sh"
TRACKER_MCP=$(n1_config_val '.tracker.mcp'); TRACKER_TYPE=$(n1_config_val '.tracker.type')
SEARCH_OP=$(n1_config_val '.tracker.operations.search'); READ_OP=$(n1_config_val '.tracker.operations.readTicket')
COMMENT_OP=$(n1_config_val '.tracker.operations.addComment'); GET_COMMENTS_OP=$(n1_config_val '.tracker.operations.getComments')
LINKS_OP=$(n1_config_val '.tracker.operations.getIssueLinks')
PREFIX=$(n1_config_val '.tracker.prefix'); PROJECT_KEY=$(n1_config_val '.tracker.projectKey')
TODO_STATUS=$(n1_config_val '.tracker.statuses.todo'); CLOUD_ID=$(n1_config_val '.tracker.cloudId')
```
If `TRACKER_MCP` is empty: "No tracker configured. Run `/n1:n1-init`." **STOP.**

## Steps

1. **Status check.** If `--status`: read and follow `<N1_ROOT>/skills/n1-queue/steps/report.md`. **STOP.**
2. **INTAKE** -- read and follow `<N1_ROOT>/skills/n1-queue/steps/intake.md`. Produces the candidate list.
3. **PREVIEW** -- read and follow `<N1_ROOT>/skills/n1-queue/steps/preview.md`. User confirms or cancels.
4. **RUN** -- read and follow `<N1_ROOT>/skills/n1-queue/steps/run.md`. Writes queue.md, launches runner, ends the turn.

## Error Recovery

Transient tracker failures: retry twice with brief backoff. Anything else: report and **STOP**.

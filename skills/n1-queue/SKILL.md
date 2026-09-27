---
name: n1-queue
description: "Use when a batch of tracker tickets tagged for unattended work should run through the pipeline one after another without merging. Usage: /n1:n1-queue [--tag <tag>] [--story <ID>] [--plan] [--run <queue-id>] [--dry-run] [--status [<id>]] [--watch [<id>]]"
argument-hint: "[--tag <tag>] [--story <ID>] [--plan] [--run <queue-id>] [--dry-run] [--status [<id>]] [--watch [<id>]]"
model: sonnet
---

# N1 Queue

**Host vocabulary:** "ask the user" / "user prompt" means the host's question mechanism from the HOST ROUTING block in session context. "Dispatch persona `<name>`" and "invoke skill `<x>`" likewise follow HOST ROUTING.

Launches a batch of tracker tickets through `n1-start` sequentially via a background bash runner. Each ticket stops after PR + CI and merges only when `queue.mergeOnFinish` is `true` (default `false`, independent of `finishWork.mergeOnFinish`). A PreToolUse hook enforces this, and the preview states the effective merge mode before Start. The skill plans (intake, preview, plan-time decisions) and persists the plan to `queue.md`; the runner (`scripts/n1-queue-run.sh`) handles execution. Bare `n1-queue` plans then runs (one Start prompt between); `--plan` saves the plan and stops; `--run <queue-id>` executes a saved plan; `--dry-run` prints the plan and persists nothing.

**Announce at start:** "I'm using the n1-queue skill to process queue <QUEUE_ID>."

## Preamble

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
```

If `N1_HOME` is empty: "N1 is not configured for this project. Run `/n1:n1-init` to set it up." **STOP.**

## Input

Parse arguments: `--tag <tag>` (tag mode), `--story <ID>` (story mode, accept tracker URLs via `n1_extract_ticket_from_url`), `--plan` (plan and save, do not launch), `--run <queue-id>` (execute a saved plan), `--dry-run` (wins over `--plan`), `--status [<id>]`, `--watch [<id>]` (status, then relay this run's events in this session).

`QUEUE_ID` = the `--run` argument, else the tag (tag mode) or the story ID (story mode). Default tag: `n1_queue_val tag` (i.e. `n1-auto`). A `--run` id must match `^[A-Za-z0-9][A-Za-z0-9._-]*$`; otherwise print "Invalid queue id: <id>." **STOP.** `QUEUE_DIR="$N1_HOME/queue/$QUEUE_ID"`; `mkdir -p "$QUEUE_DIR"` except under `--run` (a saved plan's dir already exists).

## Tracker gate

```bash
source ~/.n1/preamble.sh
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

1. **Status check.** If `--status` or `--watch`: read and follow `<N1_ROOT>/skills/n1-queue/steps/report.md`. **STOP.**
2. **Saved plan.** If `--run <queue-id>`: read and follow `<N1_ROOT>/skills/n1-queue/steps/run.md` (it starts with § Saved plan). Skip steps 3-5.
3. **INTAKE** -- read and follow `<N1_ROOT>/skills/n1-queue/steps/intake.md`. Produces the candidate list.
4. **PREVIEW** -- read and follow `<N1_ROOT>/skills/n1-queue/steps/preview.md`. `--dry-run` stops there; otherwise Plan-Resolve records plan-time decisions and the user confirms or cancels.
5. **RUN** -- read and follow `<N1_ROOT>/skills/n1-queue/steps/run.md` from § Write plan. Writes queue.md (`step: planned`); `--plan` stops there; bare launches the runner and ends the turn.

## Error Recovery

Transient tracker failures: retry twice with brief backoff. Anything else: report and **STOP**.

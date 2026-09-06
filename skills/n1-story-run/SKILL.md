---
name: n1-story-run
description: "Run a whole story: validate subtasks, order them, execute /n1:n1-start per subtask headlessly in the right repo, wait for merges, post a summary comment. Usage: /n1:n1-story-run STORY-12 [--dry-run]"
argument-hint: "<story-id> [--dry-run]"
model: sonnet
---

# N1 Story Orchestrator

Runs every open subtask of a story sequentially through `n1-start`, each in its own headless Claude process launched from the subtask's repository, then posts a technical summary on the story.

**Announce at start:** "I'm using the n1-story-run skill to implement story <STORY-ID>."

## N1_HOME Resolution

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/story.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty: "N1 is not configured for this project. Run `/n1:n1-init` to set it up." **STOP.**

## Input

`STORY_ID` = first argument (accept tracker URLs via `n1_extract_ticket_from_url` from `lib/validation.sh`, as n1-start does). `DRY_RUN=true` when `--dry-run` is present.

`STORY_MEM="$N1_HOME/memory/$STORY_ID"`; `mkdir -p "$STORY_MEM/runs"`.

## Tracker gate

```bash
TRACKER_MCP=$(n1_config_val '.tracker.mcp'); TRACKER_TYPE=$(n1_config_val '.tracker.type')
READ_OP=$(n1_config_val '.tracker.operations.readTicket'); COMMENT_OP=$(n1_config_val '.tracker.operations.addComment')
GET_COMMENTS_OP=$(n1_config_val '.tracker.operations.getComments'); LINKS_OP=$(n1_config_val '.tracker.operations.getIssueLinks')
VERSION_MCP=$(n1_config_val '.tracker.versionMcp'); CLOUD_ID=$(n1_config_val '.tracker.cloudId')
```
If `TRACKER_MCP` is empty: "No tracker configured. Run `/n1:n1-init`." **STOP.**

## Orchestrator Output Discipline

Between subtasks print only: the launch line, step-change lines, the outcome line. Never summarize child output. `story.md` carries state.

## Steps

1. **Resume check.** If `$STORY_MEM/story.md` exists and its frontmatter `step` is `execute`, `paused`, or `summarize`: print the `## Plan` table, say "Resuming story <STORY_ID> at subtask #<current_index+1>", and skip to step 3 (or 4 when `step: summarize`). If `step: done`: "Story <STORY_ID> already completed -- summary was posted." **STOP.**
2. **VALIDATE** -- read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-story-run/steps/validate.md`. Ends with `story.md` written and `step: execute`, or STOP on cancel / dry-run.
3. **EXECUTE** -- read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-story-run/steps/execute.md`. Ends with `step: summarize` or `step: paused` (STOP).
4. **SUMMARIZE** -- read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-story-run/steps/summarize.md`. Ends with `step: done`.

## Error Recovery

Transient tracker/`gh` failures: retry twice with brief backoff. Anything else: record under `## Escalations` in `story.md`, set `step: paused`, report, STOP. Re-running `/n1:n1-story-run <STORY_ID>` resumes.

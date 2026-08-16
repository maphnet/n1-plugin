---
name: n1-story
description: "Create a story with subtask tickets from conversation context: /n1:n1-story [description]"
argument-hint: "[description or brain dump text]"
model: sonnet
effort: medium
---

# N1 Story from Context

Create a story with subtask tickets from the current conversation context and/or a provided description. All tickets are created as backlog items — no status transitions, no branch creation.

**Announce at start:** "I'm using the n1-story skill to create a story with subtasks."

## N1_HOME Resolution

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty — N1 is not configured. Tell the user: "N1 is not configured for this project. Run `/n1:n1-init` to set it up." **STOP.**

## Step 1: Context Capture

Two input sources — combine both when available:

1. **Argument** — the text passed after the command (brain dump). This is the primary intent signal.
2. **Conversation** — prior messages in this Claude Code session. Summarize relevant context that relates to the argument or, if no argument, identify the main actionable outcome.

**Empty context guard:** If there is no argument AND no meaningful prior conversation, ask: "Please describe the feature or initiative you'd like to create a story for." Wait for the response, then use it as the argument.

Combine into a story seed:
- **Goal** — high-level what and why (1-2 sentences)
- **Known requirements** — bullet list from conversation context
- **Rough task breakdown** — initial decomposition as understood so far

Present the story seed to the user for confirmation: "Here's the story scope I captured — does this look right?" If the user corrects anything, revise and re-present.

## Step 2: Sanity Check

Review the story seed. If it looks like a single atomic task with no meaningful subtask decomposition, suggest:

"This looks like a single task rather than a multi-part story. Would you like to use `/n1:n1-ticket` instead?"

Soft gate — if the user says no, proceed with a story.

## Step 3: Tracker Gate

```bash
TRACKER_MCP=$(n1_config_val '.tracker.mcp')
TRACKER_TYPE=$(n1_config_val '.tracker.type')
PROJECT_KEY=$(n1_config_val '.tracker.projectKey')
```

If `TRACKER_MCP` is empty or null, tell the user: "No tracker configured. Run `/n1:n1-init` to set up a tracker." **STOP.**

Read tracker operations:
```bash
CREATE_ISSUE_OP=$(n1_config_val '.tracker.operations.createIssue')
GET_USER_OP=$(n1_config_val '.tracker.operations.getCurrentUser')
ASSIGN_OP=$(n1_config_val '.tracker.operations.assign')
ASSIGN_TO_CREATOR=$(n1_config_val '.tracker.assignToCreator')
LINK_OP=$(n1_config_val '.tracker.operations.linkIssues')
VERSION_MCP=$(n1_config_val '.tracker.versionMcp')
EDIT_OP=$(n1_config_val '.tracker.operations.editTicket')
EST_ENABLED=$(n1_config_val '.estimation.writeToTracker')
```

**Jira subtask linking guard:** If `TRACKER_TYPE` is `jira` and `VERSION_MCP` is empty or null, warn: "Subtask linking requires jc-mcp (`tracker.versionMcp`). Subtasks will be created as standalone tickets without a parent link. Configure jc-mcp via `/n1:n1-init` to enable linking. Continue anyway?" Soft gate — proceed if user accepts.

## Step 4: Analysis

Spawn the `solution-architect` agent with **standard effort** for a deeper codebase analysis.

Resolve model:
```bash
MODEL=$(n1_resolve_model 'solution-architect' 'standard')
```

Spawn with these instructions:
- Scope: the story goal, requirements, and rough breakdown from Step 1
- Deliverable: a structured analysis (under 800 words) covering:
  - Technical feasibility assessment
  - Affected components and integration points (with file:line references)
  - Risks with confidence tags: `confident` / `uncertain` / `unknown`
  - Dependencies between the rough subtasks
- Do NOT propose solutions — analyze the landscape and flag gaps

## Step 5: Discovery

Review the analysis from Step 4 for gaps. Check the confidence tags:

**If there are `uncertain` or `unknown` tags:**

Run a short interactive interview — one question at a time, multiple choice when possible. Focus on resolving the unknowns that affect subtask scoping.

Rules:
- Maximum 5 questions (prefer fewer)
- Early exit: if the user says "that's enough" or "let's proceed", stop immediately
- Multiple choice preferred, open-ended when the answer space is too broad

**If all tags are `confident`:** skip this step entirely and say "Analysis looks solid — no gaps to resolve. Moving to design."

## Step 6: Design

Using the enriched context (story seed + analysis + discovery answers), structure the story:

**Story level:**
- Title (imperative, concise)
- Description (2-3 paragraphs covering the overall goal, approach, and scope)

**Subtasks** — each gets:
- Title (imperative, concise)
- Description (1-2 paragraphs)
- Scope — which components/files are affected
- Acceptance criteria — checklist format (3-5 items per subtask)
- Size estimate — XS / S / M / L / XL

Order subtasks by dependency (independent tasks first, dependent tasks after their prerequisites).

## Step 7: Approval Gate

Present the story preview using AskUserQuestion:

```
## Story Preview

**Story:** <story title>
**Type:** Story
**Project:** <PROJECT_KEY>

**Description:**
<story-level description>

### Subtasks (<count>)
1. **<subtask 1 title>** (<size>)
   <short description>
   Acceptance criteria:
   - [ ] ...

2. **<subtask 2 title>** (<size>)
   <short description>
   Acceptance criteria:
   - [ ] ...

...
```

Options:
1. **Create all** — proceed with story + subtask creation
2. **Edit items** — user specifies changes to individual subtasks; revise and re-present
3. **Remove items** — user specifies subtasks to drop; revise and re-present
4. **Cancel** — abort without creating anything

## Step 8: Create Story

**Resolve ticket tagging:**
```bash
TAGGING_ENABLED=$(n1_config_val '.ticketTagging.enabled')
TAGGING_SERVICE=$(n1_config_val '.ticketTagging.service')
```

If `TAGGING_ENABLED` is `true` and `TAGGING_SERVICE` is non-empty:
- `summary` = `<TAGGING_SERVICE> | <title>` (skip prefix if title already starts with `<TAGGING_SERVICE> |`)
- Prepend `**Service:** <TAGGING_SERVICE>` line to description

Otherwise: `summary` = title as-is.

**Escape description for JSON:**
```bash
DESC_ESCAPED=$(escape_json_val "$DESCRIPTION")
```

**Create the story ticket:**

- **Jira:**
  1. Resolve `cloudId`:
     ```bash
     CLOUD_ID=$(n1_config_val '.tracker.cloudId')
     ```
     If `CLOUD_ID` is empty, call `mcp__<TRACKER_MCP>__getAccessibleAtlassianResources` and extract the `id` field.
  2. Call `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with: `cloudId`, `projectKey: <PROJECT_KEY>`, `issueTypeName: "Story"`, `summary`, `description: DESC_ESCAPED`.

- **YouTrack:**
  1. Call `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with: `project: <PROJECT_KEY>`, `summary`, `description: DESC_ESCAPED`.

Store the returned story ticket ID as `STORY_ID`.

**Assign story to creator** (if configured):

Skip if ANY of: `ASSIGN_TO_CREATOR` is `false`, `GET_USER_OP` is empty, `ASSIGN_OP` is empty.

1. Call `mcp__<TRACKER_MCP>__<GET_USER_OP>` (no args).
   - Jira: extract `account_id`
   - YouTrack: extract `login`
2. Call `mcp__<TRACKER_MCP>__<ASSIGN_OP>`:
   - Jira: `cloudId`, `issueIdOrKey: <STORY_ID>`, `assignee_account_id: <account_id>`
   - YouTrack: `issueId: <STORY_ID>`, `assigneeLogin: <login>`
3. On failure: warn, do not roll back.

## Step 9: Create Subtasks

Create each subtask sequentially, linked to the parent story.

For each subtask:

1. **Build summary and description:**
   - Apply ticket tagging (same logic as story)
   - Description = subtask description + acceptance criteria formatted as checklist
   - Escape the description:
     ```bash
     SUBTASK_DESC_ESCAPED=$(escape_json_val "$SUBTASK_DESCRIPTION")
     ```

2. **Create the subtask:**
   - **Jira (with jc-mcp):** If `VERSION_MCP` is available, call `mcp__<VERSION_MCP>__jcm_createIssue` with: `projectKey: <PROJECT_KEY>`, `issueType: "Task"`, `summary`, `description: SUBTASK_DESC_ESCAPED`, `parentKey: <STORY_ID>`.
   - **Jira (without jc-mcp):** If `VERSION_MCP` is empty, call `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with: `cloudId`, `projectKey: <PROJECT_KEY>`, `issueTypeName: "Task"`, `summary`, `description: SUBTASK_DESC_ESCAPED`. Warn after creation: "⚠ Subtask <SUBTASK_ID> created without parent link (jc-mcp not configured)."
   - **YouTrack:** Call `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with: `project: <PROJECT_KEY>`, `summary`, `description: SUBTASK_DESC_ESCAPED`. Then link to story: call `mcp__<TRACKER_MCP>__<LINK_OP>` with `issueId: <subtask_id>`, `targetIssueId: <STORY_ID>`, `linkType: "subtask"` (or "Subtask" — use the link type name the YouTrack instance recognizes).

3. **Assign to creator** (if configured): same pattern as story assignment, substituting `<subtask_id>` for the issue identifier.

4. **Write estimate** (if `EST_ENABLED` is true and `EDIT_OP` is non-empty):
   - **Jira:** Call `mcp__<TRACKER_MCP>__<EDIT_OP>` with the estimation field for the subtask's size.
   - **YouTrack:** Call `mcp__<TRACKER_MCP>__<EDIT_OP>` with `issueId: <subtask_id>` and the estimation field.

5. Report each subtask as created: "  Created **[<SUBTASK_ID>]**: <title>"

No per-subtask approval — all were approved in Step 7.

## Step 10: Done

Report the full summary:

```
## Created

**Story:** [<STORY_ID>](<url>) — <story title>

**Subtasks:**
1. [<SUB_1_ID>](<url>) — <title> (<size>)
2. [<SUB_2_ID>](<url>) — <title> (<size>)
...
```

Then mention: "Run `/n1:n1-start <ID>` on any subtask when you're ready to start working on it."

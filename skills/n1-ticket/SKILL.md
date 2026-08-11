---
name: n1-ticket
description: "Create a single backlog ticket from conversation context and/or brain dump: /n1:n1-ticket [description]"
argument-hint: "[description or brain dump text]"
model: sonnet
effort: medium
---

# N1 Ticket from Context

Create a single tracker ticket (Task or Bug) from the current conversation context and/or a provided description. The ticket is created as a backlog item — no status transitions, no branch creation.

**Announce at start:** "I'm using the n1-ticket skill to create a backlog ticket."

## N1_HOME Resolution

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty — N1 is not configured. Tell the user: "N1 is not configured for this project. Run `/n1:n1-init` to set it up." **STOP.**

## Step 1: Context Capture

Two input sources — combine both when available:

1. **Argument** — the text passed after the command (brain dump). This is the primary intent signal.
2. **Conversation** — prior messages in this Claude Code session. Summarize relevant context from the conversation that relates to the argument or, if no argument, identify the main actionable outcome.

**Empty context guard:** If there is no argument AND no meaningful prior conversation (e.g., this is the first message in the session), ask: "Please describe what you'd like to create a ticket for." Wait for the response, then use it as the argument.

Combine into a structured summary:
- **Title** — imperative mood, concise (under 80 chars)
- **Type** — `Task` or `Bug`. Auto-detect from context: bug indicators are broken behavior, regressions, errors, exceptions, crash reports. Default to `Task` when ambiguous.
- **Description** — 2-3 paragraphs covering what, why, and how
- **Acceptance criteria** — bulleted checklist (3-7 items)

Present the summary to the user for confirmation: "Here's what I captured — does this look right?" If the user corrects anything, revise and re-present.

## Step 2: Sanity Check

Review the summary. If it contains multiple independent deliverables (e.g., "add CSV export AND redesign the settings page"), suggest:

"This looks like it contains multiple independent tasks. Would you like to use `/n1:n1-story` instead to create a story with subtasks?"

This is a soft gate — if the user says no, proceed with a single ticket.

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
```

## Step 4: Light Analysis

Spawn the `solution-architect` agent with **low effort** for a quick codebase pass focused on the ticket scope.

Resolve model:
```bash
MODEL=$(n1_resolve_model 'solution-architect' 'light')
```

Spawn with these instructions:
- Scope: the ticket title and description from Step 1
- Deliverable: a short analysis (under 300 words) covering:
  - Relevant components and files (with file:line references)
  - Basic feasibility assessment (straightforward / needs investigation / risky)
  - Key integration points
- Do NOT propose solutions — just map the landscape

Fold the analysis findings into the ticket description as a "Technical Context" section.

## Step 5: Light Discovery + Web Research

**Skip condition:** If the task is purely internal/codebase-specific (refactoring, renaming, config changes, fixing typos, internal tooling), skip this step entirely.

For tasks where external best practices add value (new features, architecture decisions, security patterns, API design):

Run 1-2 targeted web searches using WebSearch for:
- Current best practices relevant to the task
- Recent approaches or patterns in the ecosystem

Fold relevant findings into the description as brief enrichment (1-2 sentences each). Do not bloat the description — only include findings that inform implementation.

## Step 6: Bug Type Detection

If Step 1 classified the type as `Bug`:

**Jira:** Use `issueTypeName: "Bug"` directly — Jira natively supports Bug as an issue type.

**YouTrack:** Query project issue types to check Bug availability:
- Call `mcp__<TRACKER_MCP>__get_project_fields` with `projectId: <PROJECT_KEY>`
- Look for a field of type "enum" named "Type" that includes a "Bug" value
- If Bug type exists: use it when creating the issue
- If Bug type does not exist: fall back to default issue type and add a note in the description: "**Note:** Bug type not available in project — created as default type."

The detected type is shown in the approval gate. The user can override it there.

## Step 7: Approval Gate

Present the ticket preview using AskUserQuestion:

```
## Ticket Preview

**Title:** <title>
**Type:** <Task or Bug>
**Project:** <PROJECT_KEY>

**Description:**
<enriched description with technical context + web research>

**Acceptance Criteria:**
- [ ] criterion 1
- [ ] criterion 2
...
```

Options:
1. **Create** — proceed with ticket creation
2. **Edit** — user provides corrections inline; revise and re-present this gate (no loop limit)
3. **Cancel** — abort without creating anything

## Step 8: Create Ticket

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
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
DESC_ESCAPED=$(escape_json_val "$DESCRIPTION")
```

**Create the ticket:**

- **Jira:**
  1. Resolve `cloudId`: call `mcp__<TRACKER_MCP>__getAccessibleAtlassianResources`, extract the `id` field.
  2. Determine `issueTypeName`: `"Bug"` if type is Bug, `"Task"` otherwise.
  3. Call `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with: `cloudId`, `projectKey: <PROJECT_KEY>`, `issueTypeName`, `summary`, `description`.

- **YouTrack:**
  1. Call `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with: `project: <PROJECT_KEY>`, `summary`, `description`.

**Assign to creator** (if configured):

Skip if ANY of: `ASSIGN_TO_CREATOR` is `false`, `GET_USER_OP` is empty, `ASSIGN_OP` is empty.

1. Call `mcp__<TRACKER_MCP>__<GET_USER_OP>` (no args).
   - Jira: extract `account_id`
   - YouTrack: extract `login`
2. Call `mcp__<TRACKER_MCP>__<ASSIGN_OP>`:
   - Jira: `cloudId`, `issueIdOrKey: <ticketId>`, `assignee_account_id: <account_id>`
   - YouTrack: `issueId: <ticketId>`, `assigneeLogin: <login>`
3. On failure: warn, do not roll back.

## Step 9: Done

Report: "Created **[<TICKET_ID>](<ticket URL>)**: <title>"

Then mention: "Run `/n1:n1-start <TICKET_ID>` when you're ready to start working on it."

<!-- Purpose: Approval gate, create story, create subtasks, done (Steps 7-10). -->

## Step 7: Approval Gate

**Autonomy gate:** Read `MP=$(n1_autonomy_val 'mechanicalPrompts')` via Bash (source `lib/config.sh` first). If `MP` is `auto`: skip this prompt and auto-select **Create all** (option 1). Write a Decision Ledger row to the relevant overview.md if one is available (or skip ledger if no overview exists yet):
`| n1-story | mechanical | C | [auto] | Story approval gate | Create all | Edit, Remove, or Cancel | mechanicalPrompts=auto | --- |`
If `MP` is `ask`: continue to the approval gate below.

Present the story preview by asking the user (HOST ROUTING: ask the user):

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
   - **Jira formatting:** If `TRACKER_TYPE == "jira"`, convert any checkbox syntax in the description: replace `- [ ] ` with `- ` and `- [x] ` with `- ` (Jira does not support GitHub-flavored Markdown checkboxes and silently strips the brackets).
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

Then mention: "Run `/n1:n1-story-run <STORY_ID>` to implement all subtasks in order, or `/n1:n1-start <ID>` on a single subtask."

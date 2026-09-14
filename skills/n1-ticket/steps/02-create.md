<!-- Purpose: Bug type detection, approval gate, create ticket, done (Steps 6-9). -->

## Step 6: Bug Type Detection

If Step 1 classified the type as `Bug`:

**Jira:** Use `issueTypeName: "Bug"` directly — Jira natively supports Bug as an issue type.

**YouTrack:** Query project issue types to check Bug availability:

```bash
GET_PROJECT_FIELDS_OP=$(n1_config_val '.tracker.operations.getProjectFields')
```

If `GET_PROJECT_FIELDS_OP` is non-empty:
- Call `mcp__<TRACKER_MCP>__<GET_PROJECT_FIELDS_OP>` with `projectId: <PROJECT_KEY>`
- Look for a field of type "enum" named "Type" that includes a "Bug" value
- If Bug type exists: use it when creating the issue
- If Bug type does not exist: fall back to default issue type and add a note in the description: "**Note:** Bug type not available in project — created as default type."

If `GET_PROJECT_FIELDS_OP` is empty: skip bug type querying. Use the type from Step 1 as-is and note in the approval gate: "Bug type availability could not be verified (getProjectFields operation not configured)."

The detected type is shown in the approval gate. The user can override it there.

## Step 7: Approval Gate

**Autonomy gate:** Read `MP=$(n1_autonomy_val 'mechanicalPrompts')` via Bash (source `lib/config.sh` first). If `MP` is `auto`: skip this prompt and auto-select **Create** (option 1). Write a Decision Ledger row to the relevant overview.md if one is available (or skip ledger if no overview exists yet):
`| n1-ticket | mechanical | C | [auto] | Ticket approval gate | Create ticket | Edit or Cancel | mechanicalPrompts=auto | --- |`
If `MP` is `ask`: continue to the approval gate below.

Present the ticket preview by asking the user (HOST ROUTING: ask the user):

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

**Jira formatting:** If `TRACKER_TYPE == "jira"`, convert any checkbox syntax in the description before creating: replace `- [ ] ` with `- ` and `- [x] ` with `- ` (Jira does not support GitHub-flavored Markdown checkboxes and silently strips the brackets).

**Escape description for JSON:**
```bash
DESC_ESCAPED=$(escape_json_val "$DESCRIPTION")
```

**Create the ticket:**

- **Jira:**
  1. Resolve `cloudId`:
     ```bash
     CLOUD_ID=$(n1_config_val '.tracker.cloudId')
     ```
     If `CLOUD_ID` is empty, call `mcp__<TRACKER_MCP>__getAccessibleAtlassianResources` and extract the `id` field.
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

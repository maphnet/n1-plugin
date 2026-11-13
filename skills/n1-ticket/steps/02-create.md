<!-- Purpose: Type detection, approval gate, duplicate check, create ticket, done (Steps 6-9). -->

## Step 6: Type Detection

If `TICKET_TYPE` is `Bug`, `Story` or `Epic`:

**Jira:** these are native issue types; pass `TICKET_TYPE` as the type in Step 8 (parameter name per the configured create op, see `<N1_ROOT>/references/ticket-scope.md` § Create-call parameters).

**YouTrack:** Query project issue types to check that the type exists:

```bash
GET_PROJECT_FIELDS_OP=$(n1_config_val '.tracker.operations.getProjectFields')
```

If `GET_PROJECT_FIELDS_OP` is non-empty:
- Call `mcp__<TRACKER_MCP>__<GET_PROJECT_FIELDS_OP>` with `projectId: <PROJECT_KEY>`
- Look for a field of type "enum" named "Type" that includes the `TICKET_TYPE` value
- If the value exists: use it when creating the issue
- If it does not exist: fall back to default issue type and add a note in the description: "**Note:** <TICKET_TYPE> type not available in project — created as default type."

If `GET_PROJECT_FIELDS_OP` is empty: skip type querying. Use `TICKET_TYPE` as-is and print this note with the Type in Step 7: "<TICKET_TYPE> type availability could not be verified (getProjectFields operation not configured)."

The detected type is shown in Step 7.

**Pre-creation scope check:** re-run the `<N1_ROOT>/references/ticket-scope.md` classification on the latest confirmed scope before Step 7. A changed `SCOPE_TYPE` updates `TICKET_TYPE` per `01-compose.md` Step 2, and Step 7 uses the new type; unresolved scope returns to analysis/discovery. No tracker write happens before this check.

## Step 7: Approval Gate

**Task or Bug:** skip this prompt and auto-select **Create** (option 1). Write a Decision Ledger row to the relevant overview.md if one is available (or skip ledger if no overview exists yet):
`| n1-ticket | mechanical | C | [auto] | Ticket approval gate | Create ticket | Edit or Cancel | auto | --- |`
Show the resulting **Type: Task** (or **Bug** for a defect report) before creation.

**Story or Epic:** always ask the user; never auto-select. Show the summary and **Type: <TICKET_TYPE>**, then ask in the `<N1_ROOT>/references/question-format.md` layout "Create this as <TICKET_TYPE>?":

1 — Create as <TICKET_TYPE> (Recommended): matches the `<N1_ROOT>/references/ticket-scope.md` classification (or the type the user named in Step 1).
2 — Create as Story: works when `TICKET_TYPE=Epic` and one repository covers the scope (offer only then).
3 — Create as Task: works when the work is one deliverable without the larger structure.
4 — Edit: works when the summary is wrong; revise it, re-run Step 2, then ask again.
5 — Cancel: works when nothing should be filed; create nothing and stop.

A pick of Story or Task sets `TICKET_TYPE` to it and re-runs Step 6 for the new type. Write a Decision Ledger row when an overview exists:
`| n1-ticket | mechanical | C | [asked] | Ticket type gate | <picked option> | <other options> | user answer | --- |`

**Headless:** under `N1_HEADLESS=1` this question is never auto-resolved: create nothing, print "Escalation: <TICKET_TYPE> creation needs a user answer; re-run /n1:n1-ticket attended." and stop.

## Step 7.5: Duplicate Check

Follow `<N1_ROOT>/references/duplicate-check.md` § Check with `CONTEXT=create`, `TEXT` = approved title + description, and `SELF_ID` / `OVERVIEW` empty. Keep the returned `DUP_LINKS` for Step 8.

## Step 8: Create Ticket

n1-ticket creates exactly one ticket and never child tickets; never pass `parentKey`.

**Ticket tagging:** apply `<N1_ROOT>/references/ticket-tagging.md` § Resolve to build `summary` and the description.

**Jira formatting:** If `TRACKER_TYPE == "jira"`, convert any checkbox syntax in the description before creating: replace `- [ ] ` with `- ` and `- [x] ` with `- ` (Jira does not support GitHub-flavored Markdown checkboxes and silently strips the brackets).

**Escape description for JSON:**
```bash
DESC_ESCAPED=$(escape_json_val "$DESCRIPTION")
```

**Create the ticket:**

- **Jira, `CREATE_ISSUE_OP` starts with `jcm_`** (jc-mcp; see `<N1_ROOT>/references/ticket-scope.md` § Create-call parameters):
  1. Call `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with: `projectKey: <PROJECT_KEY>`, `issueType` (set to `TICKET_TYPE`), `summary`, `description`. No `cloudId`.

- **Jira, any other op:**
  1. Resolve `cloudId`:
     ```bash
     CLOUD_ID=$(n1_config_val '.tracker.cloudId')
     ```
     If `CLOUD_ID` is empty, call `mcp__<TRACKER_MCP>__getAccessibleAtlassianResources` and extract the `id` field.
  2. Set `issueTypeName` to `TICKET_TYPE`.
  3. Call `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with: `cloudId`, `projectKey: <PROJECT_KEY>`, `issueTypeName`, `summary`, `description`.

- **YouTrack:**
  1. Call `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with: `project: <PROJECT_KEY>`, `summary`, `description`; if Step 6 verified the `TICKET_TYPE` value (Bug, Story or Epic), also set the project's "Type" field to it.

If a Jira create fails because the project has no `<TICKET_TYPE>` issue type, print the tracker's error and stop; nothing is created and the type is never downgraded silently. Re-running and picking **Create as Task** at Step 7 files it as a Task.

**Label:** apply `<N1_ROOT>/references/ticket-tagging.md` § Label after create with `<ticketId>`.

**Assign to creator** (if configured):

Skip if ANY of: `ASSIGN_TO_CREATOR` is `false`, `GET_USER_OP` is empty, `ASSIGN_OP` is empty (warning already shown at compose).

1. Call `mcp__<TRACKER_MCP>__<GET_USER_OP>` (no args).
   - Jira: extract `account_id`
   - YouTrack: extract `login`
2. Call `mcp__<TRACKER_MCP>__<ASSIGN_OP>`:
   - Jira: `cloudId`, `issueIdOrKey: <ticketId>`, `assignee_account_id: <account_id>`
   - YouTrack: `issueId: <ticketId>`, `assigneeLogin: <login>`
3. On failure: warn, do not roll back.

**Link matches:** if `DUP_LINKS` is non-empty, follow `<N1_ROOT>/references/duplicate-check.md` § Apply Links with `SOURCE_ID=<ticketId>`.

## Step 9: Done

Report: "Created **[<TICKET_ID>](<ticket URL>)**: <title>"

**Story or Epic:** ask the user, in the `<N1_ROOT>/references/question-format.md` layout, "Break it down now with n1-refine?":

1 — Yes, run n1-refine now (Recommended): `<N1_ROOT>/skills/n1-refine/steps/03-write.md` creates the children confirmed in its loop per `<N1_ROOT>/references/ticket-scope.md` § Decomposition by ticket type, and the new <TICKET_TYPE> has none yet.
2 — Later: works when the breakdown waits for more scoping.

Yes: invoke skill `n1-refine` with `<TICKET_ID>`; if that fails, print "Run `/n1:n1-refine <TICKET_ID>` to break it down." Later (and always under `N1_HEADLESS=1`, because n1-refine needs a user answer): print "Run `/n1:n1-refine <TICKET_ID>` to break it down before `/n1:n1-start`." Skip the Task/Bug lines below.

**Task or Bug:** mention "Run `/n1:n1-start <TICKET_ID>` when you're ready to start working on it."
If the Step 4 light analysis (`01-compose.md`) rated feasibility "needs investigation" or "risky", also say: "Consider `/n1:n1-refine <TICKET_ID>` first to settle open decisions." Do not prompt.

<!-- Purpose: Approval gate, create story, create subtasks, done (Steps 7-10). -->

**Pre-creation scope guard:** Follow `<N1_ROOT>/references/ticket-scope.md` before Step 7 and after every edit or removal. Only `SCOPE_TYPE=Story` may proceed to Steps 8-10. Task scope performs the standalone Task handoff and ends this flow; unresolved scope returns to analysis/discovery. Apply this guard before auto-selecting **Create all**, too. Adopted keys (`ADOPT_KEYS`) count as children.

## Step 7: Approval Gate

**Autonomy gate:** Read `MP=$(n1_autonomy_val 'mechanicalPrompts')` via Bash (source `lib/config.sh` first). If `MP` is `auto`: skip this prompt and auto-select **Create all** (option 1). Write a Decision Ledger row to the relevant overview.md if one is available (or skip ledger if no overview exists yet):
`| n1-story | mechanical | C | [auto] | Story approval gate | Create all | Edit, Remove, or Cancel | mechanicalPrompts=auto | --- |`
If `MP` is `ask`: continue to the approval gate below. In either mode, show the resulting **Type: Story** and child count before creation; Task handoffs show the standalone ticket preview instead.

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

### Adopt existing tickets (<adopt count>)
- <KEY> — <summary, only if already known>
```

Omit the Adopt section when `ADOPT_KEYS` is empty. Omit the Subtasks section when there are no new subtasks.

Options:
1. **Create all** — proceed with story + subtask creation, then adopt `ADOPT_KEYS`
2. **Edit items** — user specifies changes; revise, rerun the scope guard, then present the resulting ticket preview
3. **Remove items** — user specifies subtasks or adopted keys to drop; revise, rerun the scope guard, then present the resulting ticket preview
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

- **Jira, `CREATE_ISSUE_OP` starts with `jcm_`** (jc-mcp; see `<N1_ROOT>/references/ticket-scope.md` § Create-call parameters):
  1. Call `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with: `projectKey: <PROJECT_KEY>`, `issueType: "Story"`, `summary`, `description: DESC_ESCAPED`. No `cloudId`.

- **Jira, any other op:**
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

Skip if ANY of: `ASSIGN_TO_CREATOR` is `false`, `GET_USER_OP` is empty, `ASSIGN_OP` is empty (warning already shown at collect).

1. Call `mcp__<TRACKER_MCP>__<GET_USER_OP>` (no args).
   - Jira: extract `account_id`
   - YouTrack: extract `login`
2. Call `mcp__<TRACKER_MCP>__<ASSIGN_OP>`:
   - Jira: `cloudId`, `issueIdOrKey: <STORY_ID>`, `assignee_account_id: <account_id>`
   - YouTrack: `issueId: <STORY_ID>`, `assigneeLogin: <login>`
3. On failure: warn, do not roll back.

**Link matches:** if `DUP_LINKS` is non-empty, follow `<N1_ROOT>/references/duplicate-check.md` § Apply Links with `SOURCE_ID=<STORY_ID>`.

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
   - **Jira, `CREATE_ISSUE_OP` starts with `jcm_`:** call `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with: `projectKey: <PROJECT_KEY>`, `issueType: "Task"`, `summary`, `description: SUBTASK_DESC_ESCAPED`, `parentKey: <STORY_ID>`.
   - **Jira, other op, `VERSION_MCP` non-empty:** call `mcp__<VERSION_MCP>__jcm_createIssue` with: `projectKey: <PROJECT_KEY>`, `issueType: "Task"`, `summary`, `description: SUBTASK_DESC_ESCAPED`, `parentKey: <STORY_ID>` (no `cloudId`).
   - **Jira, other op, `VERSION_MCP` empty:** call `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with: `cloudId`, `projectKey: <PROJECT_KEY>`, `issueTypeName: "Task"`, `summary`, `description: SUBTASK_DESC_ESCAPED`. Warn after creation: "⚠ Subtask <SUBTASK_ID> created without parent link (jc-mcp not configured)."
   - **YouTrack:** Call `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with: `project: <PROJECT_KEY>`, `summary`, `description: SUBTASK_DESC_ESCAPED`. Then link to the story: call `mcp__<TRACKER_MCP>__<LINK_OP>` with source = `<subtask_id>`, target = `<STORY_ID>`, link type = `subtask of` (the YouTrack direction name for subtask → parent), using the tool's own argument names. On failure: warn "Could not link <subtask_id> → <STORY_ID>: <error>" and continue — do not block subtask creation.

3. **Assign to creator** (if configured): same pattern as story assignment, substituting `<subtask_id>` for the issue identifier.

4. **Write estimate** (if `EST_ENABLED` is true and `EDIT_OP` is non-empty):
   - **Jira:** Call `mcp__<TRACKER_MCP>__<EDIT_OP>` with the estimation field for the subtask's size.
   - **YouTrack:** Call `mcp__<TRACKER_MCP>__<EDIT_OP>` with `issueId: <subtask_id>` and the estimation field.

5. Report each subtask as created: "  Created **[<SUBTASK_ID>]**: <title>"

No per-subtask approval — all were approved in Step 7.

## Step 9b: Adopt Existing Tickets

Skip if `ADOPT_KEYS` is empty or `VERSION_MCP` is empty. Adopted tickets keep their current assignee and estimate (no Step 9 sub-steps 3-4). Never create a ticket for a key that fails to adopt.

1. **Type name:** set `SUBTASK_TYPE` to the sub-task type name the user gave in this run, else `Sub-task`.
2. **Convert all keys in one call:** call `mcp__<VERSION_MCP>__jcm_convertIssueType` with: `issueKeys: <ADOPT_KEYS>`, `issueTypeName: <SUBTASK_TYPE>`, `parentKey: <STORY_ID>`.
   If the call errors because the type name is unknown, read the available type names the error lists, set `SUBTASK_TYPE` to the one matching `sub-?task` (case-insensitive), and repeat the same call once. No match: handle it as an error (last bullet below).
3. **Handle the result.** Never abort. Step 10 always runs.
   - `ok: true`: for each key in `keys`, report "  Adopted **[<KEY>]** as <issueType> under <STORY_ID>".
   - `ok: false` with a non-empty `failed`: warn per entry "⚠ Could not adopt <KEY>: <reason>". If `status` is `COMPLETE` and `invalidOrInaccessibleIssueCount` is 0 or absent, report the other `ADOPT_KEYS` as adopted; otherwise list them as unconfirmed ("confirm with `jcm_getIssue <KEY>`") and do not report them as adopted.
   - `ok: false` with `status` `COMPLETE`, empty `failed`, and `invalidOrInaccessibleIssueCount` > 0: "⚠ N key(s) were invalid or inaccessible" and list the `ADOPT_KEYS` not in `failed` as unconfirmed ("confirm with `jcm_getIssue <KEY>`"); do not report them as adopted.
   - `ok: false` with `status` `RUNNING`, `ENQUEUED`, or `CANCEL_REQUESTED`: "⚠ Move still <status> (task <taskId>); confirm later with `jcm_getIssue <KEY>`". The keys are pending, not adopted.
   - `ok: false` with `message` and no `status` (the user declined the tool's confirmation): "Adoption declined; <keys> not moved under <STORY_ID>."
   - Any other `ok: false`, or an error (a cross-project key, an unknown type after the retry, or a jc-mcp older than 0.9.0 that rejects `issueKeys`): "⚠ Could not adopt <keys>: <error or message>. Convert them manually or upgrade jc-mcp (0.9.0 or newer)."

## Step 10: Done

Report the full summary:

```
## Created

**Story:** [<STORY_ID>](<url>) — <story title>

**Subtasks:**
1. [<SUB_1_ID>](<url>) — <title> (<size>)
2. [<SUB_2_ID>](<url>) — <title> (<size>)
...

**Adopted:**
- [<KEY>](<url>) — <summary, if known>

**Not adopted:**
- <KEY> — <reason, or "pending: <status>">
```

Omit **Subtasks**, **Adopted** or **Not adopted** when it would be empty.

Then mention: "Run `/n1:n1-queue --story <STORY_ID>` to implement all subtasks in order, or `/n1:n1-start <ID>` on a single subtask."

# Step 7: Decompose

## Parse Design Document

Read `$MEMORY_DIR/story-design.md` and extract the task list. For each task, parse:
- Task number (sequential across phases)
- Phase number and name
- Task title
- Description (1-2 sentences)
- Repo
- Scope
- Acceptance criteria (Gherkin format)
- Estimate (tier + time)

Build an ordered list of tasks.

## Check for Resume

Read the `## Task Mapping` section from `$MEMORY_DIR/story-overview.md`. If it contains already-created tickets, skip those tasks (they were created in a previous run). Start from the first task with status other than `created`.

## Tracker Setup

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
TRACKER_TYPE=$(n1_config_val '.tracker.type' "$CONFIG_FILE")
TRACKER_MCP=$(n1_config_val '.tracker.mcp' "$CONFIG_FILE")
CREATE_OP=$(n1_config_val '.tracker.operations.createIssue' "$CONFIG_FILE")
LINK_OP=$(n1_config_val '.tracker.operations.linkIssues' "$CONFIG_FILE")
ASSIGN_TO_CREATOR=$(n1_config_val '.tracker.assignToCreator' "$CONFIG_FILE")
```

If no tracker is configured or `createIssue` operation is absent, inform the user: "No tracker configured — cannot create tickets. The design document at `$MEMORY_DIR/story-design.md` contains the task list for manual creation." Emit `outcome: "pass"` and stop.

## One-by-One Ticket Creation

For each task (skipping already-created ones):

### Present Task

```
Task <N>/<total> (Phase <P>: <phase-name>): "<task-title>"
Repo: <repo>
Estimate: <tier> (<time>)
Acceptance criteria:
  - Given <precondition>, when <action>, then <result>
  - ...

Create this ticket? (1) Yes  (2) Yes, with edits  (3) Skip  (4) Stop here
```

Use `AskUserQuestion` tool with these four options.

### Option 1: Yes

Build ticket description:
```markdown
## <Task title>

<1-2 sentence description>

**Repo:** `<repo>`
**Scope:** <scope>
**Phase:** <phase-number> — <phase-name>
**Story:** <story-ticket-ID>

## Acceptance Criteria

- Given <precondition>, when <action>, then <result>
- ...
```

Create via MCP:

For YouTrack:
```
mcp__<TRACKER_MCP>__create_issue
```
Parameters: `project` (from tracker config), `summary` (task title), `description` (built above).

For Jira:
```
mcp__<TRACKER_MCP>__createJiraIssue
```
Parameters: `cloudId`, `projectKey`, `summary`, `description`, `issueTypeName: "Task"`, `parentKey: <story-ticket-ID>` (for subtask linking).

Capture returned ticket ID.

#### Post-creation:

1. **Set estimate** (same pattern as n1-estimate):
   - YouTrack: `mcp__<TRACKER_MCP>__update_issue` with `Estimation` field
   - Jira: `mcp__<TRACKER_MCP>__editJiraIssue` with `originalEstimate`

2. **Assign to creator** (if `assignToCreator` is not `false`):
   Resolve current user via `getCurrentUser` operation, assign via `assign` operation. Non-fatal on failure.

3. **Link to story** (if `linkIssues` operation exists):
   - YouTrack: `mcp__<TRACKER_MCP>__link_issues` — create "subtask of" link
   - Jira: parent link was set during creation via `parentKey`

4. **Link to previous task** (if `linkIssues` operation exists AND this is not the first task AND the previous task was created):
   Create "depends on" link to the previous task's ticket ID.

5. **Update task mapping** in `story-overview.md`:
   Append or update the row in the `## Task Mapping` table:
   ```
   | <N> | <phase> | <title> | <ticket-ID> | created |
   ```

### Option 2: Yes, with edits

Ask user what to change. Apply edits to the title and/or description. Then proceed with creation as in Option 1.

### Option 3: Skip

Update task mapping with status `skipped`:
```
| <N> | <phase> | <title> | — | skipped |
```
Continue to next task.

### Option 4: Stop here

Update task mapping for remaining tasks with status `deferred`:
```
| <N> | <phase> | <title> | — | deferred |
```

Emit step result with `outcome: "partial"` and stop.

## Completion

After all tasks are processed, count results:

```
Story <ID> decomposed: <created> tickets created, <skipped> skipped, <deferred> deferred.
<if article_id> Design doc: <article_id> (YouTrack KB)
<if design_storage=local> Design doc: <design_path>/<ID>-design.md

To start working on the first task:
  /n1:n1-start <first-created-ticket-ID>
```

Update `story-overview.md`:
- Mark Decompose checkbox complete
- Update `step: decompose`
- Update `tasks_count` with actual number of tasks

**Step result:** `outcome: "pass"` (all created/skipped) or `outcome: "partial"` (user stopped early), `next_step: null`

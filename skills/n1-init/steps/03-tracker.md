<!-- Purpose: Configure issue tracker (Jira/YouTrack/None), KB support, and assign-to-creator setting. -->

## Tracker Setup

### Pre-detection gate

If a tracker type was detected in step 02's Consolidated Detection:

- **Jira detected (MCP connected):** Present as a confirmation rather than an open question:
  ```
  Detected Jira via Atlassian MCP.
  1 -- Use Jira
  2 -- Use a different tracker
  3 -- No tracker
  ```
  If 1 -> skip to **Select project** below (MCP connectivity already verified).
  If 2 -> fall through to the full tracker question below.
  If 3 -> set `tracker.type` to `"none"`, `tracker.mcp` to `null`, skip remaining tracker setup.

- **YouTrack detected:** Same confirmation pattern -- confirm or override.

- **Ambiguous (both detected) / None detected / No pre-detection available (targeted upgrade):** Fall through to the full tracker question below.

Ask: **"Which issue tracker do you use?"**

```
1 — Jira (via Atlassian MCP)
2 — YouTrack (via YouTrack MCP)
3 — None (no tracker integration)
```

### If Jira:

**Verify MCP and get projects:**

Call `mcp__plugin_atlassian_atlassian__getVisibleJiraProjects` — this simultaneously checks connectivity and retrieves the project list.

- **Success** → MCP is connected. Proceed to project selection.
- **Failure (tool not found or error):**
  1. Tell the user: "The Atlassian MCP server is not connected or not configured."
  2. Ask: **"Would you like me to help set it up? 1 — Yes / 2 — Skip tracker"**
  3. If **1:** Guide the user through adding the Atlassian MCP server to their Claude Code MCP settings. **CRITICAL: NEVER store, save, log, or transmit API keys, tokens, or credentials anywhere — the user must enter them directly into their own MCP configuration only.** After setup, retry `getVisibleJiraProjects`. If still fails — report the error, set `tracker.mcp` to `null`, skip remaining tracker setup.
  4. If **2:** Set `tracker.mcp` to `null`, skip remaining tracker setup.

**Select project:**

Display the project list from `getVisibleJiraProjects` as numbered options:
```
Available Jira projects:
1 — TRID (Trident)
2 — PROJ (Project Alpha)
3 — BACK (Backend Services)
...
```

Ask: **"Which project should N1 use?"**

Set both `tracker.projectKey` and `tracker.prefix` from the selected project's key.

**Branch prefix:**

Ask: **"Use {KEY} as branch prefix? (e.g., branch name: {KEY}-123) 1 — Yes (default) / 2 — No"**

- If **1** (or enter/default): set `git.branchPattern` to `{prefix}-{id}`
- If **2**: set `git.branchPattern` to `{id}`

**Auto-detect workflow statuses:**

Detect statuses via MCP — do NOT ask the user to type status names:

1. Try calling `mcp__plugin_atlassian_atlassian__fetch` with the Jira REST endpoint `/rest/api/3/project/{projectKey}/statuses` to get all workflow statuses for the project. The response is an array of issue-type objects, each containing a `statuses` array — flatten and deduplicate by status name across all issue types to build the full status list.
2. If that fails or returns empty: find sample issues in **distinct statuses** via `mcp__plugin_atlassian_atlassian__searchJiraIssuesUsingJql` (JQL: `project = {KEY} ORDER BY status ASC`, maxResults: 5), then call `mcp__plugin_atlassian_atlassian__getTransitionsForJiraIssue` on each and union all transition target statuses. A single issue only exposes transitions reachable from its current state — scanning multiple issues in different states covers end-of-workflow statuses (e.g. "Released") that are invisible from early states like "To Do".

Auto-map detected statuses to N1 workflow slots by matching common names:
- **todo**: "To Do", "Open", "New", "Backlog", "Created"
- **inProgress**: "In Progress", "In Development", "Active", "In Work"
- **codeReview**: "Code Review" — if no exact match found, fall back to the `inProgress` value (N1 uses this after PR creation; the tracker's "Review"/"QA" columns are reserved for human QA outside the orchestrator)
- **done**: "Done", "Closed", "Resolved", "Fixed", "Complete", "Completed" — if no match found, run the **Done Fallback Picker** after the main confirmation (see below)
- **released**: "Released", "Deployed", "Live" — if no match found, omit from config (runtime falls back to `done`)

Show the detected mapping for confirmation. When `done` was not auto-matched, omit it from the table:
```
Detected workflow statuses:
  todo       → To Do
  inProgress → In Progress
  codeReview → Code Review (or In Progress if no Code Review status)
  done       → Done        ← include only when a match was found
  released   → Released    ← include only when a match was found

Correct? 1 — Yes / 2 — No, let me specify manually
```

- If **1**: use detected values. If `done` was not matched, run the **Done Fallback Picker** below.
- If **2** or auto-detection failed entirely: ask the user for the 3 status names (todo, inProgress, codeReview) as text prompts, then run the **Done Fallback Picker** below.

**Done Fallback Picker:**

Present all raw statuses fetched from the tracker. Sort: names matching any of ("Done", "Closed", "Resolved", "Fixed", "Complete", "Completed") — case-insensitive substring — appear first annotated `← best match`. Remaining statuses follow in their original order.

```
No status matched "done" automatically. Available statuses in your project:
1 — Closed   ← best match
2 — Resolved
3 — Won't Fix
4 — Obsolete
0 — Disable ticket closing (/n1:n1-finish will skip this step)

Which status represents a closed/resolved ticket?
```

- **Numbered pick** → set as `tracker.statuses.done`.
- **Pick 0** → omit `tracker.statuses.done` from config. Warn: "Ticket closing disabled. Re-run `/n1:n1-init` to configure it later."

**Detect Atlassian Cloud ID:**

Call `mcp__plugin_atlassian_atlassian__getAccessibleAtlassianResources`.

- **Single resource returned:** auto-select it. Set `tracker.cloudId` from the resource's `id` field.
- **Multiple resources:** present numbered list:
  ```
  Available Atlassian sites:
    1 — mycompany.atlassian.net
    2 — other-site.atlassian.net
  
  Which site should N1 use?
  ```
  Set `tracker.cloudId` from the selected resource's `id` field.
- **Failure or empty:** log "Could not detect Atlassian Cloud ID — Confluence KB features will be unavailable." Set `tracker.cloudId` to `null`.

**Detect jc-mcp server (for version operations):**

Look in the tool list (load the tool if deferred, per HOST ROUTING) for a tool matching `jcm_createVersion`. Extract the MCP server name from the tool name prefix (e.g., `mcp__publius-jc-mcp__jcm_createVersion` → `publius-jc-mcp`).

- **Found:** set `VERSION_MCP` to the detected server name.
- **Not found:** prompt:
  ```
  Version operations (create/release Jira versions) require jc-mcp.
  Enter your jc-mcp MCP server name (e.g., publius-jc-mcp), or leave blank to skip:
  ```
  If blank or skipped → set `VERSION_MCP` to `null` and omit `versionMcp` from the config block. Version operations will be unavailable until configured.

Set config:
```json
{
  "tracker": {
    "type": "jira",
    "mcp": "plugin_atlassian_atlassian",
    "cloudId": "<detected or null>",
    "prefix": "<from project selection>",
    "projectKey": "<from project selection>",
    "assignToCreator": true,
    "versionMcp": "<VERSION_MCP — omit key if null>",
    "operations": {
      "readTicket": "getJiraIssue",
      "getTransitions": "getTransitionsForJiraIssue",
      "moveStatus": "transitionJiraIssue",
      "addComment": "addCommentToJiraIssue",
      "getComments": "getIssueComments",
      "search": "searchJiraIssuesUsingJql",
      "createIssue": "createJiraIssue",
      "getCurrentUser": "atlassianUserInfo",
      "lookupUser": "lookupJiraAccountId",
      "assign": "editJiraIssue",
      "editTicket": "editJiraIssue",
      "linkIssues": "linkJiraIssues",
      "createArticle": "createConfluencePage",
      "getArticle": "getConfluencePage",
      "updateArticle": "updateConfluencePage",
      "createVersion": "jcm_createVersion",
      "releaseVersion": "jcm_releaseVersion",
      "listVersions": "jcm_listVersions",
      "getIssueLinks": "jcm_getIssueLinks"
    },
    "statuses": {
      "todo": "<detected or manual>",
      "inProgress": "<detected or manual>",
      "codeReview": "<detected or inProgress fallback>",
      "done": "<detected or manual — omit key entirely when absent>",
      "released": "<detected or omit key entirely when absent>"
    }
  }
}
```

**Verify comment ops availability:** Confirm in the tool list (load the tools if deferred, per HOST ROUTING) that `mcp__plugin_atlassian_atlassian__addCommentToJiraIssue` and `mcp__plugin_atlassian_atlassian__getIssueComments` are visible in the tool list. If `getIssueComments` is absent, log: "Note: getComments op not found in Jira MCP — comment reading (ticket intake, idempotent re-run checks) will be unavailable." Do not block setup.

### If YouTrack:

**Verify MCP and get projects:**

Call `mcp__youtrack__find_projects`.

- **Success** → MCP is connected. Proceed to project selection.
- **Failure:**
  1. Tell the user: "The YouTrack MCP server is not connected or not configured."
  2. Ask: **"Would you like me to help set it up? 1 — Yes / 2 — Skip tracker"**
  3. If **1:** Guide the user through adding the YouTrack MCP server. **CRITICAL: NEVER store, save, log, or transmit API keys, tokens, or credentials.** After setup, retry `find_projects`. If still fails — set `tracker.mcp` to `null`, skip tracker setup.
  4. If **2:** Set `tracker.mcp` to `null`, skip remaining tracker setup.

**Select project:**

Display projects from `find_projects` as numbered options. Ask: **"Which project should N1 use?"**

Set `tracker.projectKey` and `tracker.prefix` from the selected project's short name / ID.

**Branch prefix:**

Ask: **"Use {KEY} as branch prefix? (e.g., branch name: {KEY}-123) 1 — Yes (default) / 2 — No"**

Same config effect as Jira above.

**Auto-detect workflow statuses:**

Detect statuses via MCP — do NOT ask the user to type status names:

1. Try `mcp__youtrack__get_issue_fields_schema` — look for the State field and extract its bundle values (all possible states in the workflow).
2. If that doesn't return state values: search for sample issues in **distinct states** via `mcp__youtrack__search_issues` (query: `project: {shortName}`, limit: 5, `sort by: State asc`), then collect all State field values from the results to build the full status list.

Same auto-mapping and confirmation flow as Jira above.

Set config:
```json
{
  "tracker": {
    "type": "youtrack",
    "mcp": "youtrack",
    "prefix": "<from project selection>",
    "projectKey": "<from project selection>",
    "assignToCreator": true,
    "operations": {
      "readTicket": "get_issue",
      "getComments": "get_issue_comments",
      "moveStatus": "update_issue",
      "addComment": "add_issue_comment",
      "search": "search_issues",
      "createIssue": "create_issue",
      "getCurrentUser": "get_current_user",
      "lookupUser": "search_users",
      "assign": "change_issue_assignee",
      "editTicket": "update_issue",
      "createArticle": "create_article",
      "getArticle": "get_article",
      "updateArticle": "update_article",
      "linkIssues": "link_issues",
      "getIssueLinks": "get_issue_links"
    },
    "statuses": {
      "todo": "<detected or manual>",
      "inProgress": "<detected or manual>",
      "codeReview": "<detected or inProgress fallback>",
      "done": "<detected or manual — omit key entirely when absent>",
      "released": "<detected or omit key entirely when absent>"
    }
  }
}
```

**Verify comment ops availability:** Confirm in the tool list (load the tools if deferred, per HOST ROUTING) that `mcp__youtrack__add_issue_comment` and `mcp__youtrack__get_issue_comments` are visible in the tool list. If `get_issue_comments` is absent, log: "Note: getComments op not found in YouTrack MCP — comment reading (ticket intake, idempotent re-run checks) will be unavailable." Do not block setup.

### If None:

```json
{
  "tracker": {
    "mcp": null
  }
}
```

## Knowledge Base Configuration

Detect KB support based on the configured tracker. Runs immediately after tracker setup.

### If Jira:

**Prerequisite:** `tracker.cloudId` must be non-null (detected in tracker setup). If null, set `kb.enabled: false` and skip.

Call `mcp__plugin_atlassian_atlassian__getConfluenceSpaces` with `cloudId` from `tracker.cloudId`.

- **Spaces found:** present numbered list:
  ```
  Confluence spaces detected:
    1 — Engineering (ENG)
    2 — Platform (PLAT)
    ...
  
  Which Confluence space should N1 use for knowledge base articles?
  (Select a space, or 0 to skip KB support)
  ```
  - **Numbered pick:** set `kb.enabled: true`, `kb.spaceId` from selected space's numeric ID, `kb.spaceKey` from selected space's key.
  - **Pick 0:** set `kb.enabled: false`.

- **No spaces or failure:** log "No Confluence spaces found — KB features disabled." Set `kb.enabled: false`.

Set config:
```json
{
  "kb": {
    "enabled": true,
    "spaceId": "<from selection>",
    "spaceKey": "<from selection>"
  }
}
```

Or when disabled:
```json
{
  "kb": {
    "enabled": false
  }
}
```

### If YouTrack:

Look for `create_article` among the youtrack MCP tools (load it if deferred, per HOST ROUTING).

- **Found:** log "YouTrack KB article support detected." Set `kb.enabled: true`.
- **Not found:** log "YouTrack KB article support not detected — KB features disabled." Set `kb.enabled: false`.

Set config:
```json
{
  "kb": {
    "enabled": true
  }
}
```

Or when disabled:
```json
{
  "kb": {
    "enabled": false
  }
}
```

### If no tracker:

Omit `kb` block entirely from config.

### On reconfiguration (n1-init re-run):

If `kb` already exists in the current config, show current state and offer:
```
Current KB configuration:
  enabled  → <true/false>
  space    → <spaceKey> (Jira only)

1 — Keep current
2 — Reconfigure
3 — Disable
```

- **1** → leave unchanged.
- **2** → re-run the detection and questions above, overwrite the block.
- **3** → set `enabled: false`. Remove `spaceId`/`spaceKey` if present.

If `kb` is absent from the current config, run the fresh-setup flow above.

## Assign to Creator Configuration

Ask whether N1 should auto-assign tickets it creates to the user running it. **Default is Yes.**

```
Auto-assign tickets N1 creates to you? 1 — Yes (default) / 2 — No
```

- **1 (Yes) or default:**
```json
{ "tracker": { "assignToCreator": true } }
```
- **2 (No):**
```json
{ "tracker": { "assignToCreator": false } }
```

Store the value on the `tracker` block (alongside `mcp`/`operations`). Skip this question entirely when `tracker.mcp` is `null` (no tracker configured).

### On reconfiguration (n1-init re-run):

If `assignToCreator` already exists on the `tracker` block, show it and offer:
```
Auto-assign created tickets to you: <true/false>
1 — Keep current
2 — Toggle
```
- **1** → leave unchanged.
- **2** → flip the boolean.

If `tracker.assignToCreator` is absent from the current config, run the fresh-setup flow above. Skip entirely when `tracker.mcp` is `null`.

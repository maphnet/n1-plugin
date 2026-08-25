---
name: n1-init
description: "Set up N1 for a project. Creates externalized state at ~/.n1/<project>/, config.json, sets git config n1.home, and enriches CLAUDE.md with project conventions."
model: sonnet
effort: low
---

# N1 Project Setup

## Overview

Initialize N1 for the current project. This creates the externalized N1 state directory at `~/.n1/<project-name>/`, generates `config.json` with tracker and git settings, sets `git config n1.home`, configures worktree setup, and optionally enriches CLAUDE.md with detected project conventions.

**Announce at start:** "I'm using the n1-init skill to set up N1 for this project."

**UX rules:**
- Do NOT show step numbers to the user — they are internal structure only.
- All choice questions MUST offer numbered options (e.g., `1 — Yes / 2 — No`) so the user can answer with just a number.

## Prerequisites

Check if CLAUDE.md exists in the project root:
- **If missing:** Tell the user: "CLAUDE.md not found. Run `/init` first to create one, then re-run `/n1:n1-init`." **STOP.**
- **If exists:** Continue.

### Detect Existing Configuration

Check for N1 configuration in priority order:

1. **New-format config:** Run `git config n1.home`. If it returns a path, expand `~` and check if `$N1_HOME/config.json` exists.
   - **If exists:** Load the config and check for missing top-level keys against the **Expected Config Keys** list below. Then branch:
     - **If no missing keys:** Tell the user: "N1 is already configured for this project (state at `$N1_HOME`). Current config:" then show the config. Ask: "Reconfigure? **1** — Yes / **2** — No". If no — **STOP.** If yes — continue to **Analyze Repository**, then walk all config sections using their "On reconfiguration" sub-flows.
     - **If missing keys found:** Tell the user: "N1 is already configured for this project (state at `$N1_HOME`). Current config:" then show the config. Then show:

       ```
       N1 config is missing sections added in newer versions:
         → <comma-separated missing key names>

       1 — Add missing sections (walks through only the new ones)
       2 — Full reconfigure (re-ask everything)
       3 — Skip
       ```

       - **If 1 (Add missing sections):** Run the **Targeted Upgrade** flow below.
       - **If 2 (Full reconfigure):** Continue to **Analyze Repository**, then walk all config sections using their "On reconfiguration" sub-flows (which now handle absent blocks via the implicit-else fix).
       - **If 3 (Skip):** **STOP.**

2. **Old-format config (migration candidate):** Check if `.n1/n1.config.json` exists on disk.
   - **If exists:** Proceed to **Migration Flow** below.

3. **No config found:** Continue with **Fresh Setup**.

### Expected Config Keys

The canonical set of top-level config keys. Used by the completeness check to detect missing sections. When adding a new config section to n1-init, add its key here.

```
worktree, tracker, git, ticketTagging, observability, estimation,
localTesting, finishWork, release, codex, testCoverage, telemetry,
analysisCache, rules, escalation, autonomy, review, ciChecks, planReview, memory, models
```

### Targeted Upgrade

For each missing key, run that key's **fresh-setup** flow (the primary section, not the "On reconfiguration" variant). Process missing keys in the same order as the full n1-init flow:

1. `tracker` → **Tracker Setup**
2. `git` → **Git Configuration**
3. `ticketTagging` → **Ticket Tagging Configuration** (fresh-setup portion)
4. `observability` → **Observability Configuration** (fresh-setup portion)
5. `estimation` → **Estimation Configuration** (fresh-setup portion)
6. `localTesting` → **Local Testing Configuration** (fresh-setup portion)
7. `finishWork` → **Finish Work Configuration** (fresh-setup portion)
8. `release` → **Release Configuration** (fresh-setup portion)
9. `codex` → **Codex Review Configuration** (fresh-setup portion)
10. `testCoverage` → **Test Coverage Configuration** (fresh-setup portion)
11. `telemetry` → **Telemetry Configuration** (fresh-setup portion)
12. `analysisCache` → **Analysis Cache Configuration** (fresh-setup portion)
13. `rules` → **Rules Configuration** (fresh-setup portion)
14. `worktree` → **Worktree Setup Detection** (silent detection, no prompt)
15. `escalation` → **Escalation Channel Configuration** (asks channel question when tracker is configured; writes defaults silently when no tracker)
16. `autonomy` → **Autonomy Configuration** (fresh-setup portion: offer preset selection)
17. `review`, `ciChecks`, `planReview`, `memory`, `models` → write defaults silently (see **Write Configuration and Structure** for default values)

Skip keys that are already present in the config. Preserve all existing keys and their values untouched.

**Special case:** If `rules` is among the missing keys, run **Analyze Repository** first (rules starter generation needs detection results). Otherwise skip Analyze Repository and CLAUDE.md enrichment.

After all missing sections are processed, merge results into the existing `config.json` at the top level and show the summary (same format as **Confirm**, but listing only the added sections).

### Migration Flow (existing `.n1/n1.config.json`)

When an old `.n1/n1.config.json` is detected:

1. Compute project name:
   ```bash
   PROJECT_NAME=$(basename "$(git rev-parse --show-toplevel)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
   ```

2. Prompt:
   ```
   Found existing N1 state at .n1/ in the project root.
   N1 2.0 stores state externally at ~/.n1/<project-name>/.

   Migrate to ~/.n1/<project-name>/?
   1 — Yes, migrate
   2 — No, keep current setup (state stays in project root)
   ```

3. **If 1 (Yes — migrate):**
   a. Create the external state directory:
      ```bash
      mkdir -p "$HOME/.n1/$PROJECT_NAME/memory"
      ```
   b. Read `.n1/n1.config.json`, update it:
      - Add `"version": "2.0.0"` field
      - Remove `worktree.enabled` if present (always on in v2.0.0)
   c. Write the updated config to `$HOME/.n1/$PROJECT_NAME/config.json`
   d. Move existing memory if present:
      ```bash
      if [ -d ".n1/memory" ] && [ "$(ls -A .n1/memory 2>/dev/null)" ]; then
          cp -r .n1/memory/* "$HOME/.n1/$PROJECT_NAME/memory/" 2>/dev/null || true
      fi
      ```
   e. Set git config:
      ```bash
      git config n1.home "$HOME/.n1/$PROJECT_NAME"
      ```
   f. Auto-detect `worktree.setup` (see **Worktree Setup Detection** below) and add to config
   g. Add `.claude/worktrees/` to gitignore (see **`.gitignore` configuration** below)
   h. Clean up the old location (the copy in step d preserved the originals):
      ```bash
      rm -rf .n1/memory .n1/n1.config.json 2>/dev/null || true
      ```
      Then optionally remove the `.n1/` directory (ask user or leave it — the `.gitignore` entry was already addressed in step 3g above)
   i. Prune any `models.<agent>` entries in the migrated config that equal the agent's frontmatter default (removes stale hardcoded values from old configs):
      ```bash
      CFG="$HOME/.n1/$PROJECT_NAME/config.json"
      for f in "${CLAUDE_PLUGIN_ROOT}"/agents/*.md; do a=$(basename "$f" .md)
        def=$(awk 'NR==1&&/^---$/{x=1;next} x&&/^---$/{exit} x&&/^model:/{sub(/^model:[ \t]*/,"");gsub(/\r/,"");print;exit}' "$f")
        cur=$(jq -r ".models[\"$a\"] // empty" "$CFG")
        if [ -n "$cur" ] && [ "$cur" = "$def" ]; then
          jq "del(.models[\"$a\"])" "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
          echo "pruned models.$a=$cur (equals frontmatter default)"
        fi
      done
      ```
   j. Report: "Migrated N1 state to `~/.n1/$PROJECT_NAME/`. Config, memory, and telemetry moved."
   k. Continue to **Analyze Repository** (skip the fresh setup sections that the migration already handled)

4. **If 2 (No — decline migration):**
   a. Set git config explicitly to relative path:
      ```bash
      git config n1.home .n1
      ```
   b. Rename config file in place:
      ```bash
      mv .n1/n1.config.json .n1/config.json
      ```
   c. Update the config content: add `"version": "2.0.0"` field
   d. Warn: "State will remain in the project root. Step-mode worktrees (used by n1-loop) require externalized state — run n1-init again to migrate later."
   e. Continue to **Analyze Repository** (for CLAUDE.md enrichment and any new config fields)

## Analyze Repository

Explore the project to detect:

1. **Stack:** Look for `package.json`, `composer.json`, `Cargo.toml`, `go.mod`, `requirements.txt`, `pyproject.toml`, `Gemfile`, `pom.xml`, `build.gradle`, etc.
2. **Docker:** Check for `Dockerfile`, `docker-compose.yml`, `docker-compose.yaml`
3. **Monorepo:** Check for `lerna.json`, `pnpm-workspace.yaml`, `turbo.json`, or multiple `package.json` files
4. **Test runner:** Look in config files and scripts for test commands
5. **Linter/formatter:** Look for `.eslintrc*`, `.prettierrc*`, `phpcs.xml`, `rustfmt.toml`, `.flake8`, etc.
6. **CI/CD:** Check `.github/workflows/`, `.gitlab-ci.yml`, `Jenkinsfile`, etc.

Read existing CLAUDE.md content to identify what's already documented.

## Worktree Setup Detection

Auto-detect the appropriate setup command for new worktrees based on the project's package manager:

| Detected file | Suggested command |
|---|---|
| `package-lock.json` | `npm ci` |
| `yarn.lock` | `yarn install --frozen-lockfile` |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
| `package.json` (no lockfile) | `npm install` |
| `Cargo.toml` | `cargo fetch` |
| `requirements.txt` | `pip install -r requirements.txt` |
| `go.mod` | `go mod download` |
| None of the above | `null` (no setup) |

Silently derive the setup command from the detection table above — do NOT prompt.
Store the derived value as `worktree.setup` in config (store `null` when the table
yields no command). Store `"after-pr"` as `worktree.cleanup` (default).

The command is reported (not asked) in the init summary — see the summary block below,
which already prints `Worktree setup: <command or "none">`. Non-standard projects
(monorepo bootstrap, `make setup`, private-registry auth, env files, DB migrations)
override `worktree.setup` in `config.json` after init.

## Enrich CLAUDE.md (if gaps found)

Compare what was detected vs. what's documented in CLAUDE.md.

If gaps exist, propose additions as a structured block. **Only add tool-agnostic information** — no N1-specific config in CLAUDE.md.

Present proposed additions to the user:
```
I found the following gaps in your CLAUDE.md:

## Proposed additions:

### Commands
docker compose exec app php artisan test
docker compose exec app ./vendor/bin/phpunit
npm run dev

### Project Structure
- app/Http/Controllers/ — HTTP controllers
- app/Services/ — Business logic
...

Add these to CLAUDE.md?
1 — Yes
2 — No
3 — Edit first
```

If approved (1), append to CLAUDE.md. If edit (3) — ask what to change first.

## Tracker Setup

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
- **blocked**: "Blocked", "On Hold", "Waiting", "Paused" — if no match found, omit from config (runtime recovery handles the miss; see `skills/n1-start/references/blocked-status-recovery.md`)
- **released**: "Released", "Deployed", "Live" — if no match found, omit from config (runtime falls back to `done`)

Show the detected mapping for confirmation. When `done` or `blocked` was not auto-matched, omit it from the table:
```
Detected workflow statuses:
  todo       → To Do
  inProgress → In Progress
  codeReview → Code Review (or In Progress if no Code Review status)
  done       → Done        ← include only when a match was found
  blocked    → On Hold     ← include only when a match was found
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

Use ToolSearch to find a tool matching `jcm_createVersion`. Extract the MCP server name from the tool name prefix (e.g., `mcp__publius-jc-mcp__jcm_createVersion` → `publius-jc-mcp`).

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
      "listVersions": "jcm_listVersions"
    },
    "statuses": {
      "todo": "<detected or manual>",
      "inProgress": "<detected or manual>",
      "codeReview": "<detected or inProgress fallback>",
      "done": "<detected or manual — omit key entirely when absent>",
      "blocked": "<detected or omit key entirely when absent>",
      "released": "<detected or omit key entirely when absent>"
    }
  }
}
```

**Verify comment ops availability:** Use ToolSearch to confirm that `mcp__plugin_atlassian_atlassian__addCommentToJiraIssue` and `mcp__plugin_atlassian_atlassian__getIssueComments` are visible in the tool list. If `getIssueComments` is absent, log: "Note: getComments op not found in Jira MCP — tracker escalation replies will fall back to interactive." Do not block setup.

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
      "linkIssues": "link_issues"
    },
    "statuses": {
      "todo": "<detected or manual>",
      "inProgress": "<detected or manual>",
      "codeReview": "<detected or inProgress fallback>",
      "done": "<detected or manual — omit key entirely when absent>",
      "blocked": "<detected or omit key entirely when absent>",
      "released": "<detected or omit key entirely when absent>"
    }
  }
}
```

**Verify comment ops availability:** Use ToolSearch to confirm that `mcp__youtrack__add_issue_comment` and `mcp__youtrack__get_issue_comments` are visible in the tool list. If `get_issue_comments` is absent, log: "Note: getComments op not found in YouTrack MCP — tracker escalation replies will fall back to interactive." Do not block setup.

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

Use ToolSearch to look for `create_article` in the youtrack MCP tools.

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

## Escalation Channel Configuration

**Gate:** only run this section when `tracker.mcp` is configured (not null). If no tracker, set `escalation.channel: "interactive"` silently and skip.

Ask:
```
When N1 blocks on a question in step mode, where should it post the escalation?

1 — Interactive only (default): surface the question to the user in the terminal
2 — Tracker: post questions as a tracker comment and move ticket to Blocked status
3 — Both: post to tracker AND wait for interactive reply
```

- **1** (or default): set `escalation.channel: "interactive"`.
- **2**: set `escalation.channel: "tracker"`.
- **3**: set `escalation.channel: "both"`.

When `tracker` or `both` is selected, ask:
```
Should N1 mention you in escalation comments? 1 — Yes (default) / 2 — No
```
- **1**: set `escalation.mentionUser: true`.
- **2**: set `escalation.mentionUser: false`.

These values are written into the `escalation` block in config (alongside the existing `checkpoints` and `alwaysAskOn` defaults).

### On reconfiguration (n1-init re-run):

If `escalation.channel` is already set, show current value and re-ask the channel question.

## Git Configuration

Detect **defaultBranch** automatically:
- Run `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'`
- Fall back to checking `main`/`master` branch existence

**branchPattern:**
- If a tracker was configured above → already set during Tracker Setup (branch prefix question)
- If no tracker (None) → default to `feature/{slug}`

```json
{
  "git": {
    "defaultBranch": "main",
    "branchPattern": "<from tracker setup or feature/{slug}>"
  }
}
```

## PR Mode Configuration

Ask how N1 should handle PRs. **Default is Draft.**

```
How should N1 handle PRs?
1 — Draft (default) — create PR immediately as draft
2 — Ready — create PR ready to merge
3 — Skip — I merge branches manually
```

**If 1 (Draft) or default:**
```json
{
  "git": {
    "prMode": "draft"
  }
}
```

**If 2 (Ready):**
```json
{
  "git": {
    "prMode": "ready"
  }
}
```

**If 3 (Skip):**
```json
{
  "git": {
    "prMode": "skip"
  }
}
```

### On reconfiguration (n1-init re-run):

If `git.prMode` already exists in the config, show its current value and offer. If only `git.draftPR` exists (legacy config), derive the display value: `true` → `"draft"`, `false` → `"ready"`. If neither key exists, treat as `"draft"` (the default).

```
PR mode: <draft/ready/skip>
1 — Keep current
2 — Draft (create PR as draft)
3 — Ready (create PR immediately)
4 — Skip (merge manually)
```
- **1** → leave unchanged.
- **2** → set `prMode: "draft"`.
- **3** → set `prMode: "ready"`.
- **4** → set `prMode: "skip"`.

When writing any of options 2–4, also remove the `git.draftPR` key if it is present in the config (it is superseded by `prMode`).

## Ticket Tagging Configuration

Ask whether to tag N1-created tickets with a service (repo) name. **Default is No** — do not enable unless the user opts in.

```
Tag created tickets with a service name? (e.g. "payments-api | Add CSV export")
1 — Yes
2 — No (default)
```

**If 2 (No) or default:**
```json
{
  "ticketTagging": {
    "enabled": false
  }
}
```

**If 1 (Yes):**

Derive a default service name, then confirm it:
1. Run `git remote get-url origin 2>/dev/null`. If it succeeds, take the last path segment and strip a trailing `.git` (e.g. `git@github.com:org/payments-api.git` → `payments-api`, `https://github.com/org/payments-api` → `payments-api`).
2. If there is no `origin` remote, fall back to the current directory's base name.
3. Show and confirm:
   ```
   Detected service name: <detected>
   (from git remote origin)

   Use this? 1 — Yes / 2 — Enter a different name
   ```
   - **1** → use `<detected>`.
   - **2** → ask: "Service name:" and use the entered value (trimmed).

```json
{
  "ticketTagging": {
    "enabled": true,
    "service": "<confirmed name>"
  }
}
```

### On reconfiguration (n1-init re-run):

If `ticketTagging` already exists in the current config, show it and offer:
```
Current ticket tagging:
  enabled → <true/false>
  service → <value or "(none)">

1 — Keep current
2 — Update service name
3 — Disable tagging
```
- **1** → leave unchanged.
- **2** → run the derive+confirm flow above, set `enabled: true`.
- **3** → set `{ "enabled": false }`.

If `ticketTagging` is absent from the current config, run the fresh-setup flow above.

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

## Observability Configuration

Detect available observability MCP servers via dynamic discovery — scan all connected MCP servers, classify by observability category, infer environments from server names, and present a confidence-ranked selection list.

### Step 1 — Discovery

Use ToolSearch to enumerate all available MCP tools. Group tools by their MCP server prefix (the segment between `mcp__` and the next `__`). This produces a map of server name → list of tool names.

### Step 2 — Classification

For each server, match its tool names against the signature table:

| Category | Tool name patterns | Known providers |
|----------|-------------------|-----------------|
| Error tracking | `*sentry*`, `*error*issue*`, `*exception*` | Sentry |
| Log querying | `*loki*`, `*log*query*` | Loki |
| Tracing/APM | `*trace*`, `*observation*`, `*session*` combined with `*exception*` | Langfuse |

A server matches a category when 2+ of its tools hit any of the patterns for that category. Each tool counts at most once regardless of how many patterns it matches. This threshold prevents false positives from servers that happen to have one tool with a matching name.

Known provider names are also checked against the server name (e.g., server name contains "sentry" → Sentry).

### Step 3 — Environment inference

Parse the MCP server name for environment tokens by splitting on `-` and matching:

- Tokens: `dev`, `prod`, `production`, `staging`, `stg`, `stage`, `local`, `test`
- Examples: `publius-dev-loki-mcp` → `dev`, `publius-prod-loki-mcp` → `prod`, `publius-sentry` → `all`
- No token match → mark as `all` (single-MCP-for-all-envs)

### Step 4 — Confidence scoring

| Score | Criteria |
|-------|----------|
| high | Known provider exact match (server name contains the provider name AND tools match the signature) |
| medium | Category match via tool patterns but not a known provider name |
| low | Few matching tools or ambiguous pattern overlap |

Sort candidates descending by confidence.

### Step 5 — Present to user

**If no candidates detected:** set `"observability": null` silently and skip this section.

**If candidates detected:**

```
Observability MCP servers detected:

  1. [high]   sentry (publius-sentry) — error tracking, all envs
  2. [high]   loki (publius-dev-loki-mcp) — log querying, dev
  3. [high]   loki (publius-prod-loki-mcp) — log querying, prod
  4. [medium] langfuse (publius-dev-langfuse-mcp) — tracing/APM, dev

Select which to enable (comma-separated numbers, or 0 to skip):
```

**If 0 or no selection:**
```json
{
  "observability": null
}
```

### Step 6 — Environment confirmation

For servers marked `all` (no env in name), ask:

```
What environment does <provider> (<mcp-server>) serve?
1 — prod
2 — all (queries across environments)
3 — Enter custom name
```

When the user picks `all`, the provider is placed under every environment that has at least one other provider. If no other environments exist yet, place it under `prod`.

For servers with inferred environments, no confirmation needed — the inference is shown in the Step 5 list and the user's selection implicitly confirms it.

### Step 7 — Sentry intake fields

When a Sentry provider is among the selected servers:

1. Call `mcp__<detected-sentry-mcp>__list_projects` to get the project list.
2. Present selection — number each project, plus a manual-entry option:
   ```
   Select Sentry project:
   1 — my-backend (my-org)
   2 — my-frontend (my-org)
   3 — Enter manually
   ```
   - If numbered option: extract `orgSlug` and `projectSlug` from the selected project.
   - If "Enter manually": ask for `orgSlug` and `projectSlug` separately.
3. Auto-generate `urlPattern`: `sentry\\.io/issues/|<orgSlug>\\.sentry\\.io/issues/`
4. Store these intake fields on the Sentry provider entry alongside `mcp` and `operations`:
   ```json
   {
     "sentry": {
       "mcp": "publius-sentry",
       "operations": { "searchIssues": "search_sentry_issues" },
       "urlPattern": "sentry\\.io/issues/|my-org\\.sentry\\.io/issues/",
       "orgSlug": "my-org",
       "projectSlug": "my-backend"
     }
   }
   ```

### Step 8 — Auto-detect operations

For known providers, use preset operation maps:

| Provider | Key operations |
|----------|---------------|
| Sentry | `searchIssues=search_sentry_issues`, `getIssue=get_sentry_issue`, `getAiAnalysis=get_autofix_state`, `listProjects=list_projects` |
| Loki | `query=loki_query`, `labelNames=loki_label_names`, `labelValues=loki_label_values` |
| Langfuse | `findExceptions=find_exceptions`, `fetchTraces=fetch_traces`, `getSessionDetails=get_session_details` |

For unknown providers (discovered generically), store all tools that matched the observability category patterns as operations.

### Step 9 — Set default environment and confirm

Pick the environment with the most providers. If tied, prefer `prod`. If the only environment is `all`, use `prod` as the default.

**Ask about additional MCP servers:**

```
Add another observability MCP server not in the list? Enter MCP server name (or Enter to skip):
```

If entered: probe to identify provider type via ToolSearch, ask which env it serves, detect operations, add to config. Repeat until Enter.

**Confirm summary:**

```
Observability integration:
  Default: prod
  Environments:
    prod:
      sentry → publius-sentry (searchIssues)
      loki → publius-prod-loki-mcp (query, labelNames, labelValues)
    dev:
      langfuse → publius-dev-langfuse-mcp (findExceptions, fetchTraces, getSessionDetails)
```

Result config block:
```json
{
  "observability": {
    "default": "prod",
    "environments": {
      "prod": {
        "sentry": {
          "mcp": "publius-sentry",
          "operations": { "searchIssues": "search_sentry_issues" },
          "urlPattern": "sentry\\.io/issues/|my-org\\.sentry\\.io/issues/",
          "orgSlug": "my-org",
          "projectSlug": "my-backend"
        },
        "loki": {
          "mcp": "publius-prod-loki-mcp",
          "operations": { "query": "loki_query", "labelNames": "loki_label_names", "labelValues": "loki_label_values" }
        }
      },
      "dev": {
        "langfuse": {
          "mcp": "publius-dev-langfuse-mcp",
          "operations": { "findExceptions": "find_exceptions", "fetchTraces": "fetch_traces", "getSessionDetails": "get_session_details" }
        }
      }
    }
  }
}
```

### Migration from `errorTracking` + `logging`

**Gate:** Only when old blocks exist (`errorTracking` and/or `logging` are present and not null) but no `observability` block exists.

Auto-migration logic during n1-init:

1. **Convert `errorTracking`:** Create a provider entry `"sentry": { "mcp": "<errorTracking.mcp>", "operations": <errorTracking.operations>, "urlPattern": "<errorTracking.urlPattern>", "orgSlug": "<errorTracking.orgSlug>", "projectSlug": "<errorTracking.projectSlug>" }` under the environment `"prod"`. Copy all intake-specific fields (`urlPattern`, `orgSlug`, `projectSlug`) if present.

2. **Convert `logging`:** For each entry in `logging.environments`, create a provider entry `"<logging.type>": { "mcp": "<env.mcp>", "operations": <logging.operations> }` under the corresponding environment name.

3. **Merge:** Combine into a single `observability` block. Set `observability.default` to `logging.default` if it existed, otherwise `"prod"`.

4. **Clean up:** Remove old `errorTracking` and `logging` blocks from config.

5. **Present:** Show the migrated config using the reconfigure menu so the user can review and adjust.

### On reconfiguration (n1-init re-run):

If `observability` already exists and is not null:
```
Current observability:
  Default: prod
  Environments:
    prod: sentry, loki
    staging: loki
    dev: langfuse

1 — Keep current
2 — Add/remove providers or environments
3 — Change default environment
4 — Disable
```

- **1** — leave unchanged.
- **2** — re-run the full discovery scan (Steps 1–4). Show results with status labels:
  ```
  Observability MCP servers detected:

    1. [configured] sentry (publius-sentry) — error tracking, prod
    2. [configured] loki (publius-prod-loki-mcp) — log querying, prod
    3. [new]        loki (publius-staging-loki-mcp) — log querying, staging
    4. [new]        langfuse (publius-dev-langfuse-mcp) — tracing/APM, dev

  Add new providers (comma-separated numbers), or remove existing ones?
  Type + followed by numbers to add, - followed by numbers to remove, or Enter to keep as-is:
  ```
  Adding follows the same env confirmation → Sentry intake (if applicable) → operations flow. Removing deletes the provider entry from the environment; if the environment becomes empty, remove it too.
- **3** — select from configured environment names.
- **4** — set `"observability": null`.

If `observability` is `null` or absent (and no old blocks to migrate), re-run detection from scratch (Steps 1–9).

## Estimation Configuration

Ask whether N1 should estimate task complexity and write delivery time to the tracker. **Default is No.**

```
Enable estimation for tickets?
Estimates task complexity and writes delivery time to tracker.
1 — Yes
2 — No (default)
```

**If 2 (No) or default:**
```json
{
  "estimation": {
    "enabled": false
  }
}
```

**If 1 (Yes):**

Set `estimation.enabled: true` and `estimation.writeToTracker: true`.

Show the default mapping table:
```
Default delivery time mapping:
  XS  30m   (config change, typo, single-line fix)
  S   2h    (single file, clear scope, no migrations)
  M   6h    (2-5 files, may need tests, straightforward)
  L   2d    (multiple files, migrations, new tests)
  XL  5d    (cross-cutting, architectural, multi-subsystem)

Customize mapping? 1 — Use defaults (recommended) / 2 — Customize
```

**If 1 (Use defaults):** omit `mapping` from the config entirely — the orchestrator loads defaults from `defaults/estimation.json` at runtime.

**If 2 (Customize):** ask for each tier value as a time string (e.g., `"4h"`, `"3d"`). Only store tiers the user actually changed — partial overrides merge with defaults at runtime.

```json
{
  "estimation": {
    "enabled": true,
    "writeToTracker": true,
    "mapping": {
      "M": "8h",
      "L": "3d"
    }
  }
}
```

### On reconfiguration (n1-init re-run):

If `estimation` already exists in the current config, show current state and offer:
```
Current estimation:
  enabled → <true/false>
  mapping → <default/custom>

1 — Keep current
2 — Enable
3 — Disable
4 — Update mapping
```
- **1** → leave unchanged.
- **2** → set `enabled: true`, `writeToTracker: true`. If mapping was not previously set, leave it (uses defaults).
- **3** → set `enabled: false`. Remove `writeToTracker` and `mapping` keys.
- **4** → show current mapping (merged with defaults), ask for changes. Only store overridden tiers.

If `estimation` is absent from the current config, run the fresh-setup flow above.

## Local Testing Configuration

Ask whether N1 should run local end-to-end tests after implementation and review, before creating a PR. **Default is No.**

```
Enable local testing?
After implementation + review, N1 can start your app locally and exercise the changed flows before creating a PR.
Requires the app to be startable from the command line.
1 — Yes
2 — No (default)
```

**If 2 (No) or default:**
```json
{
  "localTesting": {
    "enabled": false
  }
}
```

**If 1 (Yes):**
```json
{
  "localTesting": {
    "enabled": true,
    "maxFixAttempts": 3
  }
}
```

### On reconfiguration (n1-init re-run):

If `localTesting` already exists in the current config, show current state and offer:
```
Current local testing:
  enabled → <true/false>
  maxFixAttempts → <value>

1 — Keep current
2 — Enable
3 — Disable
```
- **1** → leave unchanged.
- **2** → set `enabled: true`, `maxFixAttempts: 3`.
- **3** → set `enabled: false`. Remove `maxFixAttempts` key.

If `localTesting` is absent from the current config, run the fresh-setup flow above.

## Finish Work Configuration

Ask whether N1 should run a finish step after CI: verify/perform the PR merge, optionally watch the deployment, and close the tracker ticket. **Default is No.**

Only ask when a tracker is configured OR a PR mode other than "skip" is set — with neither, finish work has nothing to do; write `"finishWork": { "enabled": false }` silently.

```
Enable the finish step in the automated pipeline?
After CI passes, N1 can verify the PR merge, watch the deployment, and close the ticket.
1 — Yes
2 — No (default)
```

**If 2 (No) or default:**
```json
{
  "finishWork": {
    "enabled": false
  }
}
```

**If 1 (Yes)**, ask the follow-ups:

```
Auto-merge the PR on finish?
1 — No, a reviewer merges (default)
2 — Yes, N1 merges via gh pr merge --auto (branch protection still applies)
```

If auto-merge is Yes:
```
Merge method?
1 — squash (default)
2 — merge
3 — rebase
```

```
Watch the automated deployment after merge?
Requires a GitHub Actions workflow triggered by pushes to the default branch.
1 — No (default)
2 — Yes
```

If deploy watch is Yes: "Workflow name to watch? (enter = watch all runs on the merge commit)"

Write the block (omit `deployWatch.workflowName` when empty; `closeTicket` defaults to true — no question):
```json
{
  "finishWork": {
    "enabled": true,
    "mergeOnFinish": <from auto-merge question>,
    "mergeMethod": <from merge-method question, "squash" when not asked>,
    "deployWatch": {
      "enabled": <from deploy-watch question>,
      "workflowName": <name or null>,
      "timeoutMinutes": 30
    },
    "closeTicket": true,
    "waitForMergeMinutes": 10
  }
}
```

### On reconfiguration (n1-init re-run):

If `finishWork` already exists in the current config, show current state and offer:
```
Current finish work:
  enabled       → <true/false>
  mergeOnFinish → <true/false>
  deployWatch   → <true/false>

1 — Keep current
2 — Enable / change settings (re-ask the questions above)
3 — Disable
```
- **1** → leave unchanged.
- **2** → re-run the questions, overwrite the block.
- **3** → set `enabled: false`, keep the other keys.

If `finishWork` is absent from the current config, run the fresh-setup flow above.

## Release Configuration

Ask whether N1 should create a release (git tag + GitHub Release) after the pipeline completes. **Default is No.**

```
Enable releases?
/n1:n1-release can guide you through releasing a version after the pipeline completes.
1 — Yes
2 — No (default)
```

**If 2 (No) or default:**
```json
{
  "release": {
    "enabled": false,
    "deploymentCheck": false
  }
}
```

**If 1 (Yes):**

```
Release procedure?
1 — GitHub Release (default) — git tag + gh release create --generate-notes
2 — Custom — paste your multi-step procedure as markdown
```

**If 1 (GitHub Release):**

Write:
```json
{
  "release": {
    "enabled": true,
    "tagPrefix": "v",
    "procedure": null,
    "deploymentCheck": "<from deployment pipeline awareness answer>"
  }
}
```

**If 2 (Custom):**

Ask: "Tag prefix? (default: v)"

Then:
```
Paste your release procedure as markdown.
Use {{RELEASE_TAG}}, {{VERSION}}, {{MERGE_SHA}}, {{TICKET_ID}} as placeholders.

Example:
1. Build: `npm run build`
2. Push tag: `git push origin {{RELEASE_TAG}}`
3. Deploy to prod: `ssh prod@example.com "cd /app && git pull && pm2 restart all"`
4. Verify: `curl -f https://example.com/healthz`

Waiting for your procedure:
```

Write:
```json
{
  "release": {
    "enabled": true,
    "tagPrefix": "<from answer, default v>",
    "procedure": "<verbatim paste>",
    "deploymentCheck": "<from deployment pipeline awareness answer>"
  }
}
```

### Tracker Release Automation

**Only runs when `release.enabled` is `true` AND `tracker.type` is `"jira"`.** Skip this section entirely otherwise.

When conditions are met, write the `trackerRelease` block to the `release` config with default sub-flags:
```json
{
  "release": {
    "trackerRelease": {
      "versionName": "{serviceName} {version}",
      "moveTickets": true,
      "setFixVersion": true,
      "createVersion": true
    }
  }
}
```

No questions asked -- tracker release operations are on by default for Jira projects. Users can disable individual operations in config.json after init. Missing infrastructure (e.g., `versionMcp`) is configured inline by `/n1:n1-release` on first run.

### Deployment Pipeline Awareness

**Only runs when `release.enabled` is `true`.** Skip this section entirely if the user chose not to enable releases.

After release configuration is set (either fresh or reconfigured), run deployment pipeline detection per `references/ci-detection.md`.

Report current state:
```
Deployment pipelines:
<one of the following based on detection category>
  Category 1: "No GitHub Actions workflows found."
  Category 2: "Workflows found (CI/lint/test) but no deployment pipelines."
  Category 3: "Found: <filename> — deploys to <env> on <trigger>. No release-triggered deployment."
  Category 4: "Found: <filename> — deploys to <env> (prod) on <trigger>. Not triggered by release."
  Category 5: "Found: <filename> — deploys to <env> on release. Release deployment is configured."
```

Ask:
```
Check for deployment pipeline after each release?
1 — Yes (default for deployable services)
2 — No (default for libraries/plugins)
```

Default suggestion: `true` if any deployment workflows were detected (categories 3-5) or project has a Dockerfile / `docker-compose.yml`; `false` if project looks like a library/plugin (has `.claude-plugin/plugin.json` with no Dockerfile, or is an npm package with no deployment indicators).

Set `release.deploymentCheck` to the chosen value.

### On reconfiguration (n1-init re-run):

If `release` already exists in the current config, show current state and offer:
```
Current release:
  enabled         → <true/false>
  procedure       → GitHub Release (built-in) | custom (<N> steps)
  deploymentCheck → <true/false>

1 — Keep current
2 — Change settings
3 — Disable
```
- **1** → leave unchanged.
- **2** → re-run the questions above (including Deployment Pipeline Awareness), overwrite the block.
- **3** → set `enabled: false`, keep other keys.

If `release` is absent from the current config, run the fresh-setup flow above.

## Codex Review Configuration

Ask whether N1 should use Codex for cross-model code review alongside the Claude-based reviewers. **Default is No.**

```
Enable Codex cross-model review?
Adds a Codex-based reviewer alongside Claude reviewers for broader bug coverage.
Requires the Codex CLI to be installed and authenticated.
1 — Yes
2 — No (default)
```

**If 2 (No) or default:**
```json
{
  "codex": {
    "enabled": false
  }
}
```

**If 1 (Yes):**

1. Probe Codex CLI availability:
   ```bash
   codex --version
   ```

2. **If command fails (not installed):**
   ```
   Codex CLI is not installed.
   Would you like help setting it up?
   1 — Yes (guides you through /codex:setup)
   2 — Skip (disable Codex review for now)
   ```
   - **1:** Tell the user: "Run `/codex:setup` to install and configure the Codex CLI, then re-run `/n1:n1-init` to enable Codex review." Set `codex.enabled: false`.
   - **2:** Set `codex.enabled: false`.

3. **If command succeeds (installed) — check authentication:**
   Run `codex auth status` (or equivalent auth check). If not authenticated:
   ```
   Codex CLI is installed but not authenticated.
   Run `!codex login` to authenticate, then re-run `/n1:n1-init` to enable Codex review.
   ```
   Set `codex.enabled: false`.

4. **If installed and authenticated:**
   ```json
   {
     "codex": {
       "enabled": true
     }
   }
   ```

### On reconfiguration (n1-init re-run):

If `codex` or `codexReview` already exists in the current config, show current state and offer:
```
Current Codex review:
  enabled → <true/false>

1 — Keep current
2 — Enable
3 — Disable
```
- **1** → leave unchanged.
- **2** → run the probe flow above. Set `enabled: true` only if Codex CLI is installed and authenticated.
- **3** → set `enabled: false`.

If neither `codex` nor `codexReview` exists in the current config, run the fresh-setup flow above.

## Test Coverage Configuration

Ask what level of test work the QA agent should do. **Default is maintain** — fix and update existing tests, no new test creation.

```
Test coverage tier controls how much test work the QA agent does:
  maintain — Fix broken tests, update tests for changed functionality. No new tests. (default)
  minimal  — Acceptance-criteria-only behavioral tests (1-3 per feature)
  standard — Behavioral tests + edge cases + error paths (capped)

Select test coverage tier:
1 — maintain (default)
2 — minimal
3 — standard
```

**If 1 (maintain) or default:**
```json
{
  "testCoverage": {
    "tier": "maintain"
  }
}
```

**If 2 (minimal):**
```json
{
  "testCoverage": {
    "tier": "minimal"
  }
}
```

**If 3 (standard):**
```json
{
  "testCoverage": {
    "tier": "standard"
  }
}
```

### On reconfiguration (n1-init re-run):

If `testCoverage` already exists in the current config, show current state and offer:
```
Current test coverage tier: <current value>
1 — Keep current
2 — maintain
3 — minimal
4 — standard
```
- **1** → leave unchanged.
- **2** → set `tier: "maintain"`.
- **3** → set `tier: "minimal"`.
- **4** → set `tier: "standard"`.

If `testCoverage` is absent from the current config, run the fresh-setup flow above.

## Autonomy Configuration

Ask:

```
How autonomous should pipeline runs be?

1 — Interactive: the pipeline asks at every decision point (brainstorm design, branch/stash handling, acceptance gate)
2 — Hands-off (recommended): mechanical prompts auto-resolve with safe defaults; brainstorm runs autonomously with A-tier questions batched into one message; single-candidate status lookups auto-pick; full-suite regressions auto-spawn a fix cycle; the acceptance gate auto-confirms when the design is clear. Every autonomous decision is logged to a Decision Ledger and rendered in the PR body for review.
3 — Fully autonomous: same as Hands-off but quality-gate exhaustion also auto-accepts instead of blocking
```

- **1** → write:
  ```json
  "autonomy": {
    "brainstorm": "interactive",
    "mechanicalPrompts": "ask",
    "qualityEscalations": "block",
    "tailChain": "suggest",
    "acceptanceGate": "ask"
  }
  ```
- **2** → write:
  ```json
  "autonomy": {
    "brainstorm": "auto",
    "mechanicalPrompts": "auto",
    "qualityEscalations": "block",
    "tailChain": "auto",
    "acceptanceGate": "auto-when-clear",
    "escalationMargin": 0.10
  }
  ```
  Also set `"qa": { "blockUntestedFeatures": true }` — the compensating gate that prevents untested features from proceeding silently.
- **3** → write:
  ```json
  "autonomy": {
    "brainstorm": "auto",
    "mechanicalPrompts": "auto",
    "qualityEscalations": "auto-accept",
    "tailChain": "auto",
    "acceptanceGate": "auto-when-clear",
    "escalationMargin": 0.05
  }
  ```
  Also set `"qa": { "blockUntestedFeatures": true }` — the compensating gate.

Note in the summary output: security, architecture, and public-API escalations always block regardless of this setting, and releases are always manual.

### On reconfiguration (n1-init re-run):

If `autonomy` already exists in the current config, show current values and re-ask (following the same flow as fresh setup).

## Review Configuration

Use `minCleanPasses: 1` by default. **Do NOT ask** the user about this unless they explicitly requested review customization when invoking n1-init.

```json
{
  "review": {
    "minCleanPasses": 1
  }
}
```

## CI Checks Configuration

Use defaults. **Do NOT ask** the user about this unless they explicitly requested CI customization when invoking n1-init.

- `enabled: true` — CI watch runs automatically after PR creation in n1-start
- `maxFixAttempts: 3` — developer agent gets 3 cycles to fix CI failures before escalating to user
- `confidenceThreshold: 0.7` — for checks that don't match any known category, developer agent must exceed this confidence to auto-fix

```json
{
  "ciChecks": {
    "enabled": true,
    "maxFixAttempts": 3,
    "confidenceThreshold": 0.7
  }
}
```

Categories use built-in defaults (lint, typecheck, test, build, security, infra — all `auto-fix`). Teams can override by adding a `categories` block after running n1-init.

## Telemetry Configuration

Ask whether N1 should collect local telemetry for pipeline efficiency analysis. **Default is No.**

```
Enable telemetry?
Collects per-step timing, agent performance, and token usage into per-ticket telemetry directories for offline analysis.
Data stays local — no external transmission.
1 — Yes
2 — No (default)
```

**If 2 (No) or default:**
```json
{
  "telemetry": {
    "enabled": false
  }
}
```

**If 1 (Yes):**
```json
{
  "telemetry": {
    "enabled": true
  }
}
```

### On reconfiguration (n1-init re-run):

If `telemetry` already exists in the current config, show current state and offer:
```
Current telemetry:
  enabled → <true/false>

1 — Keep current
2 — Enable
3 — Disable
```
- **1** → leave unchanged.
- **2** → set `enabled: true`.
- **3** → set `enabled: false`.

If `telemetry` is absent from the current config, run the fresh-setup flow above.

## Analysis Cache Configuration

Ask whether N1 should cache project-level analysis snapshots to speed up sequential tickets. **Default is Yes.**

```
Enable analysis cache?
Caches project-level architecture analysis (file structure, dependencies, patterns) so subsequent tickets skip redundant discovery.
Cache is stored at $N1_HOME/cache/project-snapshot.md and auto-invalidated on structural changes.
1 — Yes (default)
2 — No
```

**If 2 (No):**
```json
{
  "analysisCache": {
    "enabled": false
  }
}
```

**If 1 (Yes) or default:**

Detect structural files by scanning the repo root for known markers:
```bash
# Check which structural file patterns actually exist in this repo
for pattern in package.json Cargo.toml go.mod pyproject.toml CLAUDE.md Dockerfile docker-compose.yml ".github/workflows/*"; do
  ls $pattern 2>/dev/null
done
```

Use detected files plus the defaults from `defaults/analysis-cache.json` to populate `structuralFiles`. Write:
```json
{
  "analysisCache": {
    "enabled": true,
    "ttl": "4h",
    "neutralThreshold": 15,
    "structuralFiles": ["<detected patterns + defaults>"]
  }
}
```

### On reconfiguration (n1-init re-run):

If `analysisCache` already exists in the current config, show current state and offer:
```
Current analysis cache:
  enabled → <true/false>
  ttl → <value>
  neutralThreshold → <value>
  structuralFiles → <count> patterns

1 — Keep current
2 — Enable
3 — Disable
```
- **1** → leave unchanged.
- **2** → set `enabled: true`, re-detect structural files if currently disabled.
- **3** → set `enabled: false`, preserve other settings.

If `analysisCache` is absent from the current config, run the fresh-setup flow above.

## Plan Review Configuration

Use defaults. **Do NOT ask** the user about this unless they explicitly requested plan review customization when invoking n1-init.

- `reviewPlan: true` — after plan creation, solution-architect is re-spawned in fresh context to review the plan against specific adversarial criteria with codebase access
- `requirePlanApproval: false` — if the plan review passes (clean or self-fixed), proceed to implementation without a user checkpoint

```json
{
  "planReview": {
    "reviewPlan": true,
    "requirePlanApproval": false
  }
}
```

## Rules Configuration

Ask whether N1 should generate project rules — authored, checkable conventions that drive review gates and deny hooks. **Default is Yes** for new setups, presented after all other config is written.

```
N1 can generate project rules from what it detects about your project.
Rules are checkable conventions — violations block reviews or deny tool calls.
1 — Yes, generate starter rules (recommended)
2 — No, skip rules for now
```

**If 2 (No) or skip:** Write `"rules": { "enabled": true }` to config and move on. No rules directory created.

**If 1 (Yes):**

1. Set `RULES_DIR="$N1_HOME/rules"`. Write `"rules": { "enabled": true }` to config.

2. Create the rules directory: `mkdir -p "$RULES_DIR"`

2b. **Seed default rules.** Scan `${CLAUDE_PLUGIN_ROOT}/defaults/rules/` for `.rule.md` files. For each file, check whether a rule with the same basename already exists in `$RULES_DIR/`. If it does, skip silently. If it does not, present it using the same Accept/Edit/Skip UX as detection-based rules:

   ```
   Default rule: <name>
     Description: <description field>
     Topic: <topic field>
     Applies to: <applies_to field>
     Enforcement: <enforcement field>
     Body:
       <rule body text>

   1 — Accept
   2 — Edit (modify before saving)
   3 — Skip
   ```

   - **1 (Accept):** Copy the file to `$RULES_DIR/<name>.rule.md`
   - **2 (Edit):** Let the user modify the description, body, and enforcement, then write the edited version
   - **3 (Skip):** Do not create this rule

   Default rules are presented before detection-based rules so universal conventions appear first.

3. Generate starter rules from existing detection results. For each detected characteristic, propose a rule with enforcement recommendation. Present **one at a time** for approval:

   **From lockfile/package manager detection:**
   - Propose a `deny` rule if a lockfile exists: "no direct edits to `<lockfile>`" with `deny.paths: ["<lockfile>"]`
     - `topic: ops`, `applies_to: [developer, implementer]`, `enforcement: deny`

   **From analysis cache snapshot (when available):**
   - If `$N1_HOME/cache/project-snapshot.md` exists, read its conventions section and propose `gate` rules for any convention that is checkable

   For each proposed rule, show:
   ```
   Proposed rule: <name>
     Description: <one-line>
     Topic: <topic>
     Applies to: <agents>
     Enforcement: <deny|gate>
     Body:
       <rule text>

   1 — Accept
   2 — Edit (modify before saving)
   3 — Skip
   ```

   - **1 (Accept):** Write the rule file to `$RULES_DIR/<name>.rule.md`
   - **2 (Edit):** Let the user modify the description, body, and enforcement, then write
   - **3 (Skip):** Do not create this rule

4. After all proposals: show count of accepted rules. If > 10, warn about cost-of-compliance.

5. If any accepted rules have `enforcement: deny`:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/rules.sh"
   HOOK_DIR="$N1_HOME/hooks"
   mkdir -p "$HOOK_DIR"
   HOOK_PATH="$HOOK_DIR/rules-deny.sh"
   n1_generate_deny_hook "$RULES_DIR" "$HOOK_PATH"
   n1_deny_hook_register "$HOOK_PATH"
   ```
   Tell the user: "Deny hook installed — matching tool calls will be blocked."

### CLAUDE.md Convention Migration (conditional)

**Only show this section when at least one rule was created in the Rules Configuration step above.**

Scan CLAUDE.md for behavioral convention blocks — lines that prescribe behavior (imperative mood: "always", "never", "must", "use X for Y") rather than state facts. For each identified block:

```
Found behavioral convention in CLAUDE.md:

  > <quoted block>

This could become a rule. Extract it?
1 — Yes, extract as gate rule
2 — Yes, extract as deny rule (if mechanically checkable)
3 — No, leave in CLAUDE.md
```

- **1 or 2:** Create a rule file, ask for `applies_to`, then ask:
  ```
  Remove this convention from CLAUDE.md now that it's a rule?
  1 — Yes, remove from CLAUDE.md
  2 — No, keep in both places
  ```
- **3:** Leave in place

**Do NOT add any "Project Rules" section to CLAUDE.md.** Do NOT remove factual content — only behavioral prescriptions the user explicitly chose to remove.

### On reconfiguration (n1-init re-run):

If `rules` already exists in the current config:

```
Current rules:
  count → <N> rules

1 — Keep current
2 — Re-generate starter rules (adds to existing, does not delete)
```

- **1** → leave unchanged.
- **2** → re-run default rule seeding (step 2b) and detection-based rule generation (step 3). Both skip rules that already exist by name in `$RULES_DIR/`.

**Repo→private migration:** If rules exist at `<root>/.n1/rules/` (legacy repo mode), detect and offer:
```
Found rules in <root>/.n1/rules/ (legacy repo mode).
Rules now always live in $N1_HOME/rules/.
1 — Move rules to $N1_HOME/rules/
2 — Leave as-is (rules will not be discovered)
```
If 1: move all `.rule.md` files, regenerate deny hook at new location, deregister old hook path.

If `rules` is absent from the current config, run the fresh-setup flow above. Run **Analyze Repository** first if it has not already been run this session (rules starter generation needs detection results).

## Agent Model Configuration

Use default models from agent frontmatter. **Do NOT ask** about model customization unless the user explicitly requested it when invoking n1-init.

If the user did request customization, derive the defaults table by reading the `model:` field from each agent's frontmatter in `${CLAUDE_PLUGIN_ROOT}/agents/*.md`, display it, and accept per-agent overrides (valid values: opus, sonnet, haiku) — only store overrides that differ from the frontmatter default.

To read an agent's default model from frontmatter:
```bash
def=$(awk 'NR==1&&/^---$/{x=1;next} x&&/^---$/{exit} x&&/^model:/{sub(/^model:[ \t]*/,"");gsub(/\r/,"");print;exit}' "${CLAUDE_PLUGIN_ROOT}/agents/<name>.md")
```

### On reconfiguration (n1-init re-run):

Prune every `models.<agent>` entry whose value equals the agent's frontmatter default, then print what was pruned. This is idempotent — running it multiple times has no additional effect.

```bash
CFG="$N1_HOME/config.json"
for f in "${CLAUDE_PLUGIN_ROOT}"/agents/*.md; do a=$(basename "$f" .md)
  def=$(awk 'NR==1&&/^---$/{x=1;next} x&&/^---$/{exit} x&&/^model:/{sub(/^model:[ \t]*/,"");gsub(/\r/,"");print;exit}' "$f")
  cur=$(jq -r ".models[\"$a\"] // empty" "$CFG")
  if [ -n "$cur" ] && [ "$cur" = "$def" ]; then
    jq "del(.models[\"$a\"])" "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    echo "pruned models.$a=$cur (equals frontmatter default)"
  fi
done
```

## Write Configuration and Structure

Create all files:

**`$N1_HOME/config.json`** — assembled from sections above (where `$N1_HOME` was set during Fresh Setup or Migration):
```json
{
  "version": "2.0.0",
  "worktree": {
    "mode": "worktree",
    "setup": "<detected or null>",
    "cleanup": "after-pr"
  },
  "tracker": { ... },
  "git": {
    "defaultBranch": "<detected>",
    "branchPattern": "<from tracker setup or feature/{slug}>",
    "prMode": "<from PR Mode Configuration selection>"
  },
  "ticketTagging": { ... },
  "observability": null,
  "estimation": {
    "enabled": false
  },
  "localTesting": {
    "enabled": false
  },
  "finishWork": {
    "enabled": false
  },
  "release": {
    "enabled": false
  },
  "codex": {
    "enabled": false
  },
  "testCoverage": {
    "tier": "maintain"
  },
  "telemetry": {
    "enabled": false
  },
  "rules": {
    "location": "private"
  },
  "kb": {
    "enabled": false
  },
  "escalation": {
    "channel": "<from Escalation Channel Configuration, default: interactive>",
    "mentionUser": "<true or false, default: true — omit when channel is interactive>",
    "checkpoints": ["pr"],
    "alwaysAskOn": ["security", "architecture", "public-api"]
  },
  "review": { ... },
  "ciChecks": {
    "enabled": true,
    "maxFixAttempts": 3,
    "confidenceThreshold": 0.7
  },
  "planReview": {
    "reviewPlan": true,
    "requirePlanApproval": false
  },
  "memory": {
    "ticketContext": true,
    "decisions": true
  },
  "models": {}
}
```

The `models` object is empty by default — agent model defaults come from agent frontmatter. Only store per-agent overrides here.

**Directory structure** (fresh setup only — migration handles this in the Migration Flow):
```bash
PROJECT_NAME=$(basename "$(git rev-parse --show-toplevel)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
N1_HOME="$HOME/.n1/$PROJECT_NAME"
mkdir -p "$N1_HOME/memory"
git config n1.home "$N1_HOME"
```

Note: The `.n1/decisions/` directory is removed — it was unused in v1 and is not carried forward.

**`.gitignore` configuration** — detect existing coverage, then ask the user:

**Detection (run in order):**

1. Run `git config --global core.excludesFile` to get the global excludes file path.
   - If a path is returned AND the file exists, check whether it contains a line matching `.claude/worktrees/` or `.claude/worktrees`.
   - If `core.excludesFile` is unset, check Git's default location: `${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore`. If that file exists, check it for the same pattern.
2. If `.claude/worktrees/` was not found in any global excludes file, check `.gitignore` in the project root for a line matching `.claude/worktrees/` or `.claude/worktrees`.

**If already gitignored:**
- Found globally → tell the user: "`.claude/worktrees/` is already gitignored globally via `<path>`." Move on.
- Found in project `.gitignore` → tell the user: "`.claude/worktrees/` is already gitignored in this project's `.gitignore`." Move on.

**If NOT gitignored anywhere**, ask:

```
.claude/worktrees/ directory is not gitignored. Where would you like to add it?
1 — Globally (user-scoped gitignore, applies to all repos)
2 — Project-level (.gitignore in this repo)
```

**If 1 (Global):**

1. Run `git config --global core.excludesFile`.
2. **If set** → append the entry to that file (with duplicate check):
   ```bash
   # only if .claude/worktrees entry not already present in the file:
   echo "" >> "<excludesFile>"
   echo "# N1 worktree directories" >> "<excludesFile>"
   echo ".claude/worktrees/" >> "<excludesFile>"
   ```
   Tell the user: "Added `.claude/worktrees/` to global gitignore (`<path>`)."
   Then check project `.gitignore` for a stale `.claude/worktrees` entry (see **Project-level cleanup after global add** below).
3. **If NOT set** → check for Git's default global excludes file before offering to create one:
   ```bash
   XDG="${XDG_CONFIG_HOME:-$HOME/.config}"
   DEFAULT_EXCLUDES="$XDG/git/ignore"
   ```
   - **If `$DEFAULT_EXCLUDES` exists** → Git is already using it as the implicit global excludes file. Check whether it contains `.claude/worktrees`. If not, append the entry there:
     ```bash
     echo "" >> "$DEFAULT_EXCLUDES"
     echo "# N1 worktree directories" >> "$DEFAULT_EXCLUDES"
     echo ".claude/worktrees/" >> "$DEFAULT_EXCLUDES"
     ```
     Tell the user: "Added `.claude/worktrees/` to Git's default global excludes (`$DEFAULT_EXCLUDES`). No `core.excludesFile` change needed."
     Then check project `.gitignore` for a stale `.claude/worktrees` entry (see **Project-level cleanup after global add** below).
   - **If `$DEFAULT_EXCLUDES` does not exist** → sub-prompt:
     ```
     No global gitignore is configured (core.excludesFile is unset and $XDG_CONFIG_HOME/git/ignore does not exist).
     Want me to create ~/.config/git/ignore (Git's default location) for global excludes?
     1 — Yes
     2 — No (fall back to project-level)
     ```
     - **1 (Yes):**
       ```bash
       mkdir -p "$XDG/git"
       echo "# N1 worktree directories" >> "$XDG/git/ignore"
       echo ".claude/worktrees/" >> "$XDG/git/ignore"
       ```
       Tell the user: "Created `$XDG/git/ignore` and added `.claude/worktrees/`. Git uses this location by default — no `core.excludesFile` needed."
       Then check project `.gitignore` for a stale `.claude/worktrees` entry (see **Project-level cleanup after global add** below).
     - **2 (No):** Fall through to project-level append below.

**If 2 (Project-level) from the main prompt**, or fell through from the global sub-prompt:

```bash
# only if .claude/worktrees entry not already present in .gitignore:
if ! grep -q '\.claude/worktrees' .gitignore 2>/dev/null; then
    echo "" >> .gitignore
    echo "# N1 worktree directories" >> .gitignore
    echo ".claude/worktrees/" >> .gitignore
fi
```
Tell the user: "Added `.claude/worktrees/` to this project's `.gitignore`."

**Project-level cleanup after global add:**

After successfully adding `.claude/worktrees/` to the global excludes file, check if the project `.gitignore` also contains a `.claude/worktrees/` or `.claude/worktrees` entry. If found, ask:

```
.claude/worktrees/ is now gitignored globally. The project .gitignore also has this entry.
1 — Remove it from .gitignore (global covers it)
2 — Keep both (redundant, but harmless)
```

**If 1 (Remove):** remove the `.claude/worktrees/` line and its comment line (`# N1 worktree directories`) if present on the preceding line. Tell the user: "Removed redundant `.claude/worktrees/` entry from project `.gitignore`."

**If 2 (Keep):** move on.

**Migration cleanup — old `.n1/` entry:**

During migration only (step 3g), after adding `.claude/worktrees/`, check if the project `.gitignore` contains an `.n1/` or `.n1` entry. If found, check whether the `.n1/` directory still exists and contains files:

```bash
if [ -d ".n1" ] && [ "$(ls -A .n1 2>/dev/null)" ]; then
    # Directory still has files — keep it ignored
    HAS_LEFTOVER=true
else
    HAS_LEFTOVER=false
fi
```

**If `.n1/` has leftover files** (`HAS_LEFTOVER=true`): tell the user: "`.n1/` still contains files — keeping gitignore entry to prevent committing leftover state. Remove `.n1/` manually when ready, then the entry can be cleaned up." Move on.

**If `.n1/` is empty or does not exist**, ask:

```
The old .n1/ entry is still in this project's .gitignore.
Since N1 state is now externalized to ~/.n1/<project>/, this entry is no longer needed.
1 — Remove it
2 — Keep it (harmless, but unnecessary)
```

**If 1 (Remove):** remove the `.n1/` line and its comment line (`# N1 plugin state`) if present on the preceding line. Tell the user: "Removed old `.n1/` entry from `.gitignore`."

**If 2 (Keep):** tell the user: "Kept `.n1/` entry — it does no harm." Move on.

## Confirm

Show summary:
```
N1 is ready.

State directory: ~/.n1/<project-name>/
Worktree mode: worktree
Worktree setup: <command or "none">
Worktree cleanup: after-pr

Tracker: Jira (TRID) / YouTrack / None
Default branch: main
Branch pattern: {prefix}-{id}
Ticket tagging: payments-api / disabled
Error tracking: Sentry (my-backend @ my-org) / disabled
Estimation: enabled (default mapping) / enabled (custom mapping) / disabled
Local testing: enabled / disabled
Codex review: enabled / disabled
Test coverage: maintain / minimal / standard
Telemetry: enabled / disabled
Story workflow: enabled (article/ticket/file) / disabled
PR mode: draft / ready / skip

Created:
  ~/.n1/<project-name>/config.json
  ~/.n1/<project-name>/memory/
  git config n1.home set
  .gitignore configured (.claude/worktrees/ — global or project-level)
  .claude/settings.json updated (if pinning configured)

Next: Use /n1:n1-start <ticket-or-description> to begin working on a task.
```

If `tracker.mcp` is not null, append after the summary:
```
To activate tracker routing, reload the session: type /clear or restart Claude Code.
```

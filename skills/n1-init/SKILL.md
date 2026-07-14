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
   - **If exists:** Tell the user: "N1 is already configured for this project (state at `$N1_HOME`). Current config:" then show the config. Ask: "Reconfigure? **1** — Yes / **2** — No". If no — **STOP.**

2. **Old-format config (migration candidate):** Check if `.n1/n1.config.json` exists on disk.
   - **If exists:** Proceed to **Migration Flow** below.

3. **No config found:** Continue with **Fresh Setup**.

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
   i. Report: "Migrated N1 state to `~/.n1/$PROJECT_NAME/`. Config, memory, and telemetry moved."
   j. Continue to **Analyze Repository** (skip the fresh setup sections that the migration already handled)

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

1. Try calling `mcp__plugin_atlassian_atlassian__fetch` with the Jira REST endpoint `/rest/api/3/project/{projectKey}/statuses` to get all workflow statuses for the project.
2. If that fails or returns empty: find a sample issue via `mcp__plugin_atlassian_atlassian__searchJiraIssuesUsingJql` (JQL: `project = {KEY} ORDER BY created DESC`, maxResults: 1), then call `mcp__plugin_atlassian_atlassian__getTransitionsForJiraIssue` on it to retrieve available transitions.

Auto-map detected statuses to N1 workflow slots by matching common names:
- **todo**: "To Do", "Open", "New", "Backlog", "Created"
- **inProgress**: "In Progress", "In Development", "Active", "In Work"
- **codeReview**: "Code Review" — if no exact match found, fall back to the `inProgress` value (N1 uses this after PR creation; the tracker's "Review"/"QA" columns are reserved for human QA outside the orchestrator)
- **done**: "Done", "Closed", "Resolved", "Fixed", "Complete", "Completed" — if no match found, leave the slot absent (n1-finish will skip ticket closing and say why)

Show the detected mapping for confirmation:
```
Detected workflow statuses:
  todo       → To Do
  inProgress → In Progress
  codeReview → Code Review (or In Progress if no Code Review status)
  done       → Done (or absent if none matched)

Correct? 1 — Yes / 2 — No, let me specify manually
```

- If **1**: use detected values.
- If **2** or auto-detection failed entirely: ask the user for the 4 status names (todo, inProgress, codeReview, done — done may be left empty to skip ticket closing).

Set config:
```json
{
  "tracker": {
    "type": "jira",
    "mcp": "plugin_atlassian_atlassian",
    "prefix": "<from project selection>",
    "projectKey": "<from project selection>",
    "assignToCreator": true,
    "operations": {
      "readTicket": "getJiraIssue",
      "getTransitions": "getTransitionsForJiraIssue",
      "moveStatus": "transitionJiraIssue",
      "addComment": "addCommentToJiraIssue",
      "search": "searchJiraIssuesUsingJql",
      "createIssue": "createJiraIssue",
      "getCurrentUser": "atlassianUserInfo",
      "assign": "editJiraIssue",
      "editTicket": "editJiraIssue",
      "linkIssues": "linkJiraIssues"
    },
    "statuses": {
      "todo": "<detected or manual>",
      "inProgress": "<detected or manual>",
      "codeReview": "<detected or inProgress fallback>",
      "done": "<detected or manual — omit key entirely when absent>"
    }
  }
}
```

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

1. Try `mcp__youtrack__get_issue_fields_schema` — look for the State field and extract its bundle values (possible states).
2. If that doesn't return state values: search for a sample issue via `mcp__youtrack__search_issues` (query: `project: {shortName}`, limit: 1), then examine its State field to see available values.

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
      "done": "<detected or manual — omit key entirely when absent>"
    }
  }
}
```

### If None:

```json
{
  "tracker": {
    "mcp": null
  }
}
```

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

## Error Tracking Configuration

Detect available error-tracking MCP servers by attempting a lightweight discovery call. Currently supported: Sentry.

**Detection:** Attempt `mcp__sentry__list_projects` (no arguments). If it succeeds, the Sentry MCP server is available. If it fails or times out, skip this section silently — no error-tracking setup offered.

**If Sentry MCP detected:**

```
Error tracking integration detected: Sentry MCP server
Enable Sentry integration? 1 — Yes / 2 — No (default)
```

**If 2 (No) or default:**
```json
{
  "errorTracking": null
}
```

**If 1 (Yes):**

1. Use the project list from the detection call result (or re-call `mcp__sentry__list_projects`).
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
4. Operations map is preset (not asked interactively):
   ```json
   {
     "getIssue": "get_sentry_issue",
     "searchIssues": "search_sentry_issues",
     "listProjects": "list_projects",
     "getAiAnalysis": "get_autofix_state"
   }
   ```
   **Implementation note:** verify actual tool names against the live MCP server during development (call `ToolSearch` or list available tools); the names above are based on research and may differ from the actual server's tool identifiers.
5. Confirm:
   ```
   Sentry integration:
     Org: my-org
     Project: my-backend
     URL pattern: sentry\.io/issues/|my-org\.sentry\.io/issues/
   ```

```json
{
  "errorTracking": {
    "mcp": "sentry",
    "operations": {
      "getIssue": "get_sentry_issue",
      "searchIssues": "search_sentry_issues",
      "listProjects": "list_projects",
      "getAiAnalysis": "get_autofix_state"
    },
    "urlPattern": "sentry\\.io/issues/|<orgSlug>\\.sentry\\.io/issues/",
    "projectSlug": "<selected>",
    "orgSlug": "<selected>"
  }
}
```

### On reconfiguration (n1-init re-run):

If `errorTracking` already exists and is not `null`, show current config and offer:
```
Current error tracking:
  Provider: sentry
  Project: <projectSlug> (<orgSlug>)

1 — Keep current
2 — Change project
3 — Disable
```
- **1** → leave unchanged.
- **2** → re-run the project selection flow above (detection call, project list, confirm).
- **3** → set `"errorTracking": null`.

If `errorTracking` is `null` or absent, re-run detection from scratch (same as fresh setup).

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

## Story Workflow Configuration

### Detect Article Support

Check if the tracker supports knowledge base articles:

**YouTrack:** Check if `create_article` MCP tool exists:
```
Use ToolSearch to look for "create_article" in the youtrack MCP tools.
```
If found: article support = true.

**Jira:** Check if Confluence MCP tools exist:
```
Use ToolSearch to look for "confluence" or "create_page" MCP tools.
```
If found: article support = true.

### Configure Story

Ask whether N1 should enable story decomposition. **Default is No.**

```
Enable story decomposition workflow?
This lets you use /n1:n1-story to break features into design docs and subtask tickets.
1 — Yes
2 — No (default)
```

**If 2 (No) or default:**
```json
{
  "story": {
    "enabled": false
  }
}
```

**If 1 (Yes):**

Set `story.enabled: true`.

**If article support detected:**
- Set `story.designStorage: "article"`
- Add article operations to tracker operations map (already included in the tracker operations maps above)

**If no article support:**
Ask:
```
No knowledge base detected. Store design docs in:
1 — Ticket description
2 — Local repo file
```
- **1:** set `story.designStorage: "ticket"`
- **2:** set `story.designStorage: "local"`

```json
{
  "story": {
    "enabled": true,
    "designStorage": "<article|ticket|local>",
    "designPath": "docs/design/",
    "taskSizing": {
      "maxSize": "L",
      "warnOnLargeTask": true
    }
  }
}
```

### On reconfiguration (n1-init re-run):

If `story` already exists in the current config, show current state and offer:
```
Current story workflow:
  enabled        → <true/false>
  designStorage  → <article/ticket/local>

1 — Keep current
2 — Enable / change settings
3 — Disable
```
- **1** → leave unchanged.
- **2** → re-run the detection and questions above, overwrite the block.
- **3** → set `enabled: false`. Keep the other keys.

## Agent Model Configuration

Use default models from agent frontmatter. **Do NOT ask** about model customization unless the user explicitly requested it when invoking n1-init.

If the user did request customization, show the defaults table and accept per-agent overrides (valid values: opus, sonnet, haiku) — only store overrides that differ from the default.

Defaults:
```
product-analyst    sonnet
solution-architect opus
planner            opus
developer          opus
code-reviewer      opus
security-reviewer  opus
qa-engineer        sonnet
tech-writer        sonnet
codex-adapter      sonnet
```

## Write Configuration and Structure

Create all files:

**`$N1_HOME/config.json`** — assembled from sections above (where `$N1_HOME` was set during Fresh Setup or Migration):
```json
{
  "version": "2.0.0",
  "worktree": {
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
  "errorTracking": null,
  "estimation": {
    "enabled": false
  },
  "localTesting": {
    "enabled": false
  },
  "finishWork": {
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
  "escalation": {
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
  "story": {
    "enabled": false,
    "designStorage": "article",
    "designPath": "docs/design/",
    "taskSizing": {
      "maxSize": "L",
      "warnOnLargeTask": true
    }
  },
  "memory": {
    "ticketContext": true,
    "decisions": true
  },
  "models": {
    "product-analyst": "sonnet",
    "solution-architect": "opus",
    "planner": "opus",
    "developer": "opus",
    "code-reviewer": "opus",
    "security-reviewer": "opus",
    "qa-engineer": "sonnet",
    "tech-writer": "sonnet",
    "codex-adapter": "sonnet"
  }
}
```

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

# Step 5a: Telemetry Follow-Up Ticket

**Hard-skip gates** — when either holds, skip immediately without warning and go to Step 6 (Cleanup & Report):
- `tracker.mcp` is null or absent in `$N1_HOME/config.json`
- `N1_HEADLESS=1` is set in the environment

**Trigger judgment:** Read `$N1_HOME/memory/<ID>/ticket.md`. Inline LLM judgment: does the implemented feature warrant telemetry follow-up? Apply when the feature introduces:
- New telemetry signals or signal fields
- Token counting or cost measurement
- Model-selection or routing logic
- Agent-spawn patterns or timing measurements

Skip for: documentation updates, chore/version-bump-only commits, non-behavioral config changes. When uncertain, skip.

**Idempotency:** Read the `## Pending` section of `$N1_HOME/memory/<ID>/overview.md`. If any line starts with `telemetry_followup:`, skip the entire step (ticket was already created on a prior run) and go to Step 6 (Cleanup & Report).

**When trigger applies and no prior follow-up exists:**

1. **Compute check date** (run via Bash):

   ```bash
   CHECK_DATE=$(date -d "+7 days" +%Y-%m-%d 2>/dev/null)
   [ -z "$CHECK_DATE" ] && CHECK_DATE=$(date -v+7d +%Y-%m-%d)
   ```

   Default is 7 days. Use 14 or 30 days for features with low expected usage frequency (e.g., rarely invoked flags, optional integrations). Pick at model judgment — not configurable.

2. **Read plugin version** (run via Bash):

   ```bash
   MAIN_CHECKOUT=$(dirname "$(git rev-parse --git-common-dir)")
   PLUGIN_VERSION=$(grep '"version"' "${MAIN_CHECKOUT}/.claude-plugin/plugin.json" | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
   ```

   If the worktree check is not applicable (standalone checkout), use `.claude-plugin/plugin.json` directly.

3. **Read PR URL** from the `## Pending` section of `$N1_HOME/memory/<ID>/overview.md` — the line recording the PR URL written by n1-pr.

4. **Read tracker config** (run via Bash):

   ```bash
   N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -n "$N1_ROOT" ] && [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
   source "$N1_ROOT/lib/config.sh"
   TRACKER_MCP=$(n1_config_val ".tracker.mcp" "$N1_HOME/config.json")
   PROJECT_KEY=$(n1_config_val ".tracker.projectKey" "$N1_HOME/config.json")
   TRACKER_TYPE=$(n1_config_val ".tracker.type" "$N1_HOME/config.json")
   ```

5. **Compose title:** `[Telemetry] <concise feature description> — check by <CHECK_DATE>`

   Where `<concise feature description>` is the originating ticket title from `ticket.md`, trimmed to ≤60 characters if needed (trim at a word boundary, append `…` if truncated).

6. **Compose body:**

   ```
   Telemetry follow-up for <ID>.
   PR: <PR URL from overview.md ## Pending>
   Plugin version: <PLUGIN_VERSION> (filter telemetry data to sessions at or above this version)

   ## What to validate
   <Infer from the feature: which signals, fields, or behaviors to confirm appear in telemetry.
   Example: "Verify that smoke step telemetry events appear in sessions using plugin >= vX.Y.Z.">

   ## How to check
   Open N1 telemetry. Filter to sessions where plugin version >= <PLUGIN_VERSION>. Confirm the expected signal/field is present. If usage is below ~50 sessions at check date, extend the window by another 7 days.
   ```

7. **Create the follow-up ticket** via `mcp__<tracker.mcp>__` prefix:

   - **YouTrack** (`tracker.type == "youtrack"`):
     Call `mcp__<tracker.mcp>__create_issue` with:
     ```json
     { "project": "<PROJECT_KEY>", "summary": "<title>", "description": "<body>" }
     ```
   - **Jira** (`tracker.type == "jira"`):
     Call `mcp__<tracker.mcp>__createJiraIssue` with:
     ```json
     { "projectKey": "<PROJECT_KEY>", "summary": "<title>", "description": "<body>", "issuetype": { "name": "Task" } }
     ```

   Extract the new ticket ID and URL from the response. If the response does not include a URL, construct it from the tracker base URL and ticket ID.

8. **Link to originating ticket** via tracker MCP (non-blocking — skip silently if the link operation is absent or fails):

   - **YouTrack:** Call `mcp__<tracker.mcp>__add_issue_link` with:
     ```json
     { "issueId": "<new ticket ID>", "targetIssueId": "<ID>", "type": "Relates" }
     ```
   - **Jira:** Call `mcp__<tracker.mcp>__<operations.createIssueLink>` (from `tracker.operations` in config) with:
     ```json
     { "inwardIssue": { "key": "<ID>" }, "outwardIssue": { "key": "<new ticket ID>" }, "type": { "name": "Relates" } }
     ```

9. **Record idempotency marker:** Append to the `## Pending` section of `$N1_HOME/memory/<ID>/overview.md`:
   ```
   telemetry_followup: <new ticket ID>
   ```
   Only append on successful ticket creation. If creation failed, do not write this line.

**Error handling:** All tracker calls in this step are **non-blocking** — same pattern as Step 4 Comment.
- On any failure: emit `> Warning: Telemetry follow-up ticket creation failed: <brief error>` and continue to Step 6 (Cleanup & Report).
- Do NOT set the idempotency marker on failure.
- Never abort n1-finish due to errors in this step.

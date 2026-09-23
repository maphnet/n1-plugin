# Step 5b: Tracker Release Operations

**Runs after Step 5 completes successfully.** First, resolve Sources C and D of the ticket discovery (sub-step 6 in Step 2) — these require the tag/release to exist.

Only runs when ALL hold:
- `tracker.type` is `"jira"`
- `tracker.mcp` is configured (not null)
- `RELEASE_TICKET_IDS` is non-empty

All sub-operations are best-effort: failures warn but never block the release report.

```
Warning format: "Could not <operation> for <target>: <error> -- continuing."
```

**MCP routing for version operations:** Version ops (`createVersion`, `releaseVersion`, `listVersions`) use `tracker.versionMcp` when configured, falling back to `tracker.mcp`. Construct tool names as `mcp__<versionMcp>__<operation>`. All other operations (editTicket, getTransitions, moveStatus) use `tracker.mcp` as usual.

## 5b-0. Inline Configuration

Before running tracker release operations, check for missing configuration and offer to set it up. All values discovered here are persisted to `$N1_HOME/config.json` so subsequent releases skip these prompts.

**Service name resolution:**
```bash
SERVICE=$(n1_config_val '.ticketTagging.service')
[ -z "$SERVICE" ] && SERVICE=$(basename "$(git rev-parse --show-toplevel)")
```

If `ticketTagging.service` was empty (fell back to directory name), present:
```
Service name for Jira version: "<SERVICE>"
1 — Use this
2 — Enter a different name
```

If 2: read user input and use it as `SERVICE`.

Persist to config when `ticketTagging.service` was absent:
```bash
source ~/.n1/root/lib/preamble.sh
jq --arg s "$SERVICE" '.ticketTagging.service = $s' "$N1_HOME/config.json" > "$N1_HOME/config.json.tmp" && mv "$N1_HOME/config.json.tmp" "$N1_HOME/config.json"
```

Report: `"Service name saved: \"<SERVICE>\""`

**Version MCP resolution:**

Read `tracker.versionMcp` from config. If null or absent:

1. Auto-detect jc-mcp from the tool list (load if deferred, per HOST ROUTING): search for `jcm_createVersion`.
2. If found, extract the MCP server name from the tool name prefix (e.g., `mcp__publius-jc-mcp__jcm_createVersion` → `publius-jc-mcp`). Present:
   ```
   Jira version operations require jc-mcp. Detected: "<server-name>"
   1 — Use "<server-name>"
   2 — Enter a different server name
   3 — Skip version operations for this release
   ```
3. If not detected in the tool list, present:
   ```
   Jira version operations require jc-mcp but it was not detected.
   1 — Enter your jc-mcp MCP server name (e.g., publius-jc-mcp)
   2 — Skip version operations for this release
   ```

On accept (option 1 or 2 with input): set `VERSION_MCP` to the server name. Persist to config:
```bash
source ~/.n1/root/lib/preamble.sh
jq --arg m "$VERSION_MCP" '.tracker.versionMcp = $m' "$N1_HOME/config.json" > "$N1_HOME/config.json.tmp" && mv "$N1_HOME/config.json.tmp" "$N1_HOME/config.json"
```

Also add version operations to `tracker.operations` if missing:
```bash
jq '.tracker.operations += {"createVersion":"jcm_createVersion","releaseVersion":"jcm_releaseVersion","listVersions":"jcm_listVersions"}' "$N1_HOME/config.json" > "$N1_HOME/config.json.tmp" && mv "$N1_HOME/config.json.tmp" "$N1_HOME/config.json"
```

Report: `"Version MCP saved: \"<VERSION_MCP>\". Version operations added to config."`

On skip: set `VERSION_MCP` to empty. Skip steps 5b-1 (version creation) and 5b-2 (fixVersion — requires version to exist) entirely. Continue to 5b-3 (ticket transitions).

**Resolve `VERSION_NAME`** (used by 5b-1 and 5b-2):
```bash
TRACKER_RELEASE_VERSION_NAME=$(n1_config_val '.release.trackerRelease.versionName')
[ -z "$TRACKER_RELEASE_VERSION_NAME" ] && TRACKER_RELEASE_VERSION_NAME="{serviceName} {version}"
VERSION_NAME=$(echo "$TRACKER_RELEASE_VERSION_NAME" | sed "s/{serviceName}/$SERVICE/g; s/{version}/$VERSION/g")
```

## 5b-1. Create & release version

Gate: `trackerRelease.createVersion` is `true` AND `VERSION_MCP` is non-empty. If `VERSION_MCP` is empty (user skipped in 5b-0), skip with `"Version creation skipped: jc-mcp not configured."`.

1. `mcp__<versionMcp>__<operations.listVersions>` with `projectKey` -- check if `VERSION_NAME` already exists.
2. If not found: `mcp__<versionMcp>__<operations.createVersion>` with `projectKey`, `name=VERSION_NAME`, `releaseDate=<today's date>`.
3. `mcp__<versionMcp>__<operations.releaseVersion>` with `versionId` from step 1 or 2, `releaseDate=<today's date>` -- mark as released. Idempotent if already released.

Report: `"Version \"<VERSION_NAME>\" -- created and released"` or `"Version \"<VERSION_NAME>\" -- already existed, marked released"`.

## 5b-2. Set fix version on tickets

Gate: `trackerRelease.setFixVersion` is `true` AND `VERSION_MCP` is non-empty (version must have been created or already exist in Jira for fixVersion to work). If `VERSION_MCP` is empty (user skipped in 5b-0), skip with `"Fix version skipped: jc-mcp not configured."`.

For each ticket in `RELEASE_TICKET_IDS`:

`mcp__<tracker.mcp>__<operations.editTicket>` with `issueKey=<ticket>`, `fields: {"fixVersions": [{"add": {"name": VERSION_NAME}}]}`.

Idempotent: adding an already-set fix version is a no-op in Jira.

Report: `"Fix version set on <ID1>, <ID2>, ..."` or `"Fix version: skipped (setFixVersion disabled)"`.

## 5b-3. Move tickets to released status

Gate: `trackerRelease.moveTickets` is `true`.

Resolve target status: `tracker.statuses.released`.

**Released-status recovery** — when `tracker.statuses.released` is absent:

1. Pick **one ticket** from `RELEASE_TICKET_IDS` that is currently in the `done` status (or the first ticket if none are in `done`).
2. Call `mcp__<tracker.mcp>__<operations.getTransitions>` on it to get available transitions.
3. Match transition target names against: "Released", "Deployed", "Live" (case-insensitive).
4. If a match is found — present it for confirmation:
   ```
   No "released" status configured. Detected "<match>" as a post-done status.
   Use "<match>" for this release? 1 — Yes (also save to config) / 2 — No, use "<done>" instead
   ```
   - **1**: use the matched status, persist it to `tracker.statuses.released` in config.
   - **2**: fall back to `tracker.statuses.done`.
5. If no match and no `tracker.statuses.done` — skip with: `"Ticket transition skipped: no released or done status configured."`.
6. If no match but `tracker.statuses.done` exists — warn: `"No released status found — falling back to done status \"<done>\"."` and use `done`.

For each ticket in `RELEASE_TICKET_IDS`:

1. `mcp__<tracker.mcp>__<operations.getTransitions>` on the ticket -- find the transition whose target status matches the resolved target.
2. If a matching transition is found: `mcp__<tracker.mcp>__<operations.moveStatus>` with that transition ID.
3. If the ticket is already in the target status -- skip silently (idempotent).
4. If no matching transition exists -- warn: `"Could not transition <ID>: no transition to '<target>' available -- continuing."`.

Report: `"<N> ticket(s) moved to \"<target>\""` or `"Ticket transition: skipped (moveTickets disabled)"`.

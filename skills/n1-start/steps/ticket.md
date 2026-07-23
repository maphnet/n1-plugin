
**Phase 1: Spawn intake-agent**

Resolve model for `intake-agent` (see Model Resolution above).

The intake-agent accepts four input modes. Choose based on input type:

**Ticket mode** (input matches `<prefix>-<number>`):
0. The `<ID>` is already known (the ticket ID). Workspace isolation is deferred until after investigation detection (see below).
1. Read `$N1_HOME/config.json` -> `tracker.type`, `tracker.mcp`, `tracker.operations`
2. Spawn intake-agent with:
   - `mode`: "ticket"
   - `ticketId`: the parsed ticket ID
   - `trackerMcp`: from config (`tracker.mcp`)
   - `operations`: from config (`tracker.operations`)
   - `trackerType`: from config (`tracker.type`)
   - `ticketMdPath`: `$N1_HOME/memory/<ID>/ticket.md`

**File mode** (input is a file path that exists on disk):
1. Spawn intake-agent with:
   - `mode`: "file"
   - `filePath`: the provided path
   - `ticketMdPath`: `$N1_HOME/scratch/intake-raw.md` (ID not yet final -- write outside memory; moved to final path after ID resolution)

**Brain dump mode** (free text):
1. Spawn intake-agent with:
   - `mode`: "text"
   - `content`: the raw input text
   - `ticketMdPath`: `$N1_HOME/scratch/intake-raw.md` (ID not yet final -- write outside memory; moved to final path after ID resolution)

**Error tracker mode** (input matches `errorTracking.urlPattern`):
1. Read `$N1_HOME/config.json` -> `errorTracking.mcp`, `errorTracking.operations`, `errorTracking.orgSlug`, `errorTracking.projectSlug`
2. Parse the issue ID from the URL (see Error tracker URL parsing above)
3. The provisional `<ID>` is `sentry-<issueId>`. Workspace isolation is deferred until after investigation detection (see below).
4. Spawn intake-agent with:
   - `mode`: "error-tracker"
   - `issueId`: the parsed issue ID
   - `issueUrl`: the original URL
   - `errorTrackingMcp`: from config
   - `operations`: from config (`errorTracking.operations`)
   - `orgSlug`: from config
   - `projectSlug`: from config
   - `ticketMdPath`: `$N1_HOME/memory/<ID>/ticket.md`

**Parse intake-result**

After intake-agent returns, extract the `intake-result:` line from the agent's output text:

```bash
INTAKE_RESULT=$(echo "$AGENT_OUTPUT" | grep -m1 '^intake-result: ' | sed 's/^intake-result: //')
```

If `INTAKE_RESULT` is empty (line absent), default to: `{"title": null, "tags": [], "type": "task"}`.

Parse the JSON fields:
- `TITLE` -- from `title` (may be `null`)
- `TAGS` -- from `tags` (array, join with `, ` for the bash helper)
- `TYPE` -- from `type`
- `CLOUD_ID` -- from `cloudId` (Jira only, may be absent)

**Type resolution (between spawns)**

Resolve the workflow type using the parsed metadata and the type registry in `pipeline.json`:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"

# Parse --type flag if provided by the user
TYPE_OVERRIDE=""
if n1_parse_type_arg "$USER_INPUT" 2>/dev/null; then
    TYPE_OVERRIDE=$(n1_parse_type_arg "$USER_INPUT")
fi

# Extract tags as CSV from intake-result
TAGS_CSV=$(echo "$INTAKE_RESULT" | sed 's/.*"tags":\[//;s/\].*//' | tr -d '"' | tr -d ' ')

# Extract type field from intake-result (bug/task/feature/improvement)
TYPE_FIELD=$(echo "$INTAKE_RESULT" | sed 's/.*"type": *"\([^"]*\)".*/\1/')

# Resolve type via registry cascade
RESOLVED_TYPE=$(n1_resolve_type "$TITLE" "$TAGS_CSV" "$TYPE_FIELD" "$TYPE_OVERRIDE")
INVESTIGATION_DETECTED=false
if [ "$RESOLVED_TYPE" = "investigation" ]; then
    INVESTIGATION_DETECTED=true
fi
```

**Workspace isolation (ticket and error-tracker modes)**

If `INVESTIGATION_DETECTED` is false AND the input mode is "ticket" or "error-tracker" (i.e., the `<ID>` is already known from intake): run the workspace isolation procedure now — **Ensure Worktree(`<ID>`)** when `USE_WORKTREE` is true, or **Ensure Working Branch(`<ID>`)** otherwise. For investigation tasks, no branch or worktree is created — all output goes to `$N1_HOME/memory/<ID>/` only.

Note: overview.md may not exist yet at this point (for ticket mode it does because we already resolved `<ID>`; for brain dump/file/error-tracker the ID may still be provisional). If overview.md does not exist yet, store the investigation flag in context and write it after overview.md is created (see "Write resolved type to overview.md" below).

**Phase 2: Spawn product-analyst**

Resolve model for `product-analyst` (see Model Resolution above).

Read `$N1_HOME/config.json` -> `ticketEnrichment`.

Determine enrichment eligibility: `enrichmentEnabled` = `ticketEnrichment.enabled !== false` (default true when block is absent) AND `tracker.operations.editTicket` exists.

For Jira: use `CLOUD_ID` from the intake-result (no need to re-resolve).

Spawn product-analyst with:
- `mode`: the same mode as intake-agent
- `ticketId`: the parsed ticket ID (ticket mode only)
- `trackerMcp`: from config (`tracker.mcp`) (ticket mode only)
- `operations`: from config (`tracker.operations`) (ticket mode only)
- `enrichmentEnabled`: from above (ticket mode only)
- `cloudId`: from intake-result (Jira ticket mode only)
- `ticketMdPath`: `$N1_HOME/memory/<ID>/ticket.md` for ticket/error-tracker modes (ID known), or `$N1_HOME/scratch/intake-raw.md` for brain dump/file modes (ID not yet final)

**Output-path directive** (include in spawn instructions): "Write your full structured output (your standard Output Format) to `ticketMdPath` yourself, as a full overwrite (never append). Return to the orchestrator ONLY this compact block:
```
tier: <simple|standard|complex>
title: <ticket title>
ambiguities: <count of ambiguity items, 0 if none>
```
Do NOT return the full report."

For error tracker mode, also pass:
- `issueId`, `issueUrl`, `errorTrackingMcp`, `operations` (error tracker ops), `orgSlug`, `projectSlug`

The product-analyst reads the raw `ticket.md` (written by intake-agent) instead of fetching from MCP. It then fetches comments/transitions, runs enrichment, and overwrites `ticket.md` with the structured output.

**ID-Final invariant.** No file may be written under `$N1_HOME/memory/` and no working branch may be created until `<ID>` is **final**: the ticket ID in ticket mode; the *created* ticket ID for brain-dump/file/error-tracker mode answered "Yes"; the slug only for brain-dump/file mode answered "No"; `sentry-<issueId>` for error-tracker mode answered "No" (or when no tracker is configured). Resolving the create-ticket decision (and, on "Yes", actually creating the ticket) therefore happens BEFORE the `ticket.md`/`overview.md` writes and branch creation below.

**Scratch-to-memory move (brain dump and file modes only):** After `<ID>` is resolved (via ticket creation "Yes" or slug adoption "No"), move the scratch file to the final memory path: `mv "$N1_HOME/scratch/intake-raw.md" "$N1_HOME/memory/$ID/ticket.md"`. The product-analyst's structured output will overwrite this file in place. For ticket and error-tracker modes this step is unnecessary -- intake-agent writes directly to `$N1_HOME/memory/<ID>/ticket.md` because the ID is already known.

**Tracker ticket creation (brain dump and file modes):**

After product-analyst returns, if the input was a brain dump or file path, AND a tracker is configured (`tracker.mcp` is not null AND `tracker.operations.createIssue` exists):

Ask the user:
```
The task has been structured. Would you like to create a tracker ticket?
1 -- Yes, create a ticket in <tracker.mcp>
2 -- No, continue without a ticket
```

**If 1 (Yes):**

> **Create the ticket now.** Creating the ticket via MCP is **mandatory and immediate** -- it is the first action after the user answers "Yes". Do NOT proceed as if the run were ticket-less; the slug is adopted as `<ID>` ONLY on the explicit "No" path. (See the ID-Final invariant above.)

1. Read the Title from the compact return (`title:` line). Read structured content (Core Ask, Description, Acceptance Criteria sections) from `$N1_HOME/memory/<ID>/ticket.md` (or `$N1_HOME/scratch/intake-raw.md` for brain-dump/file modes before ID resolution).
2. **Resolve ticket tagging.** Read `ticketTagging` from `$N1_HOME/config.json`.
   - **If `ticketTagging.enabled` is `true` AND `ticketTagging.service` is a non-empty string** -> tagging is ON:
     - `<summary>` = `<service> | <Title>` -- but if `<Title>` already begins with `<service> |`, use `<Title>` unchanged (idempotency guard for resume/retry).
     - `<description>` = `**Service:** <service>` as the first line, a blank line, then the Core Ask + Description + Acceptance Criteria sections.
   - **Otherwise** (block missing, `enabled` false, or `service` empty) -> tagging is OFF:
     - `<summary>` = the Title from product-analyst output.
     - `<description>` = the Core Ask + Description + Acceptance Criteria sections.
3. Create the ticket via MCP. Use exactly `mcp__<tracker.mcp>__` as the tool prefix -- the value from config, not from the tool list.
   - If `tracker.type == "jira"`: First resolve `cloudId` via `mcp__<tracker.mcp>__getAccessibleAtlassianResources` (reuse if already cached), then call `mcp__<tracker.mcp>__<tracker.operations.createIssue>` with:
     - `cloudId`: resolved cloud ID
     - `projectKey`: `tracker.projectKey`
     - `issueTypeName`: "Task"
     - `summary`: `<summary>`
     - `description`: `<description>`
   - Else (`tracker.type == "youtrack"`): Call `mcp__<tracker.mcp>__<tracker.operations.createIssue>` with:
     - `project`: `tracker.projectKey`
     - `summary`: `<summary>`
     - `description`: `<description>`
4. The returned ticket ID is the final `<ID>`. Adopt it deterministically:
   1. Compute the provisional `<slug>` exactly as the "No" path would (description slug for brain dump, filename slug for file mode).
   2. Run **Reconcile Memory ID & Branch(`<slug>`, `<ticketID>`)** (see Workspace Isolation above) -- a no-op in the clean path; it moves any leaked slug memory folder into the ticket-ID folder and renames the slug branch if drift occurred.
   3. Set `<ID>` = `<ticketID>`. If `INVESTIGATION_DETECTED` is false, run the workspace isolation procedure: **Ensure Worktree(`<ticketID>`)** when `USE_WORKTREE` is true, or **Ensure Working Branch(`<ticketID>`)** otherwise.
5. Extract the ticket URL from the MCP response (YouTrack returns it in the response body; for Jira construct it as `https://<cloud>/browse/<key>` from the response)
6. **Assign to creator.** Run this step ONLY if ALL of: `tracker.assignToCreator !== false`, `tracker.operations.getCurrentUser` exists, AND `tracker.operations.assign` exists. If any condition fails, skip this step silently (no message) and go to step 7.
   1. Resolve the current user: call `mcp__<tracker.mcp>__<tracker.operations.getCurrentUser>` (no arguments). Use exactly `mcp__<tracker.mcp>__` as the tool prefix.
      - If `tracker.type == "jira"`: take the account id (`account_id`) from the response; reuse the `cloudId` already resolved during creation.
      - Else (`tracker.type == "youtrack"`): take `login` from the response.
   2. Assign the ticket: call `mcp__<tracker.mcp>__<tracker.operations.assign>`. Use exactly `mcp__<tracker.mcp>__` as the tool prefix.
      - If `tracker.type == "jira"`: with `cloudId`: resolved cloud ID, `issueIdOrKey`: `<ID>`, `assignee_account_id`: `<account id>`.
      - Else (`tracker.type == "youtrack"`): with `issueId`: `<ID>`, `assigneeLogin`: `<login>`.
   3. **On success:** set the report suffix to ` (assigned to you)`.
   4. **On failure** (either call errors -- permission, unresolvable user, MCP error): do NOT roll back creation. Emit "Warning: Ticket created but could not auto-assign (<reason>); assign it manually." and use an empty report suffix.
7. Report: "Created ticket **[<ID>](<ticket URL>)**<report suffix>: <title>"
8. After writing ticket.md and overview.md, update tracker status to In Progress (same as ticket mode -- call `mcp__<tracker.mcp>__<tracker.operations.moveStatus>`)

**If 2 (No):**
- Use description slug as memory ID for brain dump (e.g., `csv-export-users`) or filename slug for file mode (e.g., `requirements` from `requirements.md`)
- Now that the slug `<ID>` is known: if `INVESTIGATION_DETECTED` is false, run the workspace isolation procedure: **Ensure Worktree(`<slug>`)** when `USE_WORKTREE` is true, or **Ensure Working Branch(`<slug>`)** otherwise.
- Skip tracker status updates throughout the pipeline

**Tracker ticket creation (error tracker mode):**

After product-analyst returns, if the input was an error tracker URL:

**If a tracker is configured** (`tracker.mcp` is not null AND `tracker.operations.createIssue` exists):

Ask the user:
```
The Sentry issue has been analyzed. Would you like to create a tracker ticket?
1 -- Yes, create a ticket in <tracker.mcp>
2 -- No, continue with sentry-<issueId> as the working ID
```

**If 1 (Yes):**

> **Create the ticket now.** Same mandatory-immediate semantics as brain-dump "Yes" (see ID-Final invariant above).

1. Read the Title from the compact return (`title:` line). Read structured content (Core Ask, Description, Acceptance Criteria sections) from `$N1_HOME/memory/<ID>/ticket.md` (or `$N1_HOME/scratch/intake-raw.md` for brain-dump/file modes before ID resolution).
2. **Prepend Sentry link to description:** The first line of `<description>` is `**Sentry:** [#<issueId>](<original URL>)`, followed by a blank line, then the Core Ask + Description + Acceptance Criteria sections.
3. **Resolve ticket tagging** -- same logic as brain-dump ticket creation (see above).
   - If tagging is ON: `<summary>` = `<service> | <Title>` (with idempotency guard); `<description>` = `**Service:** <service>` line, blank line, then the Sentry-prefixed description from step 2.
   - If tagging is OFF: `<summary>` = the Title; `<description>` = the Sentry-prefixed description from step 2.
4. Create the ticket via MCP -- same YouTrack/Jira logic as brain-dump ticket creation (see above).
5. The returned ticket ID is the final `<ID>`. Adopt it:
   1. The provisional ID is `sentry-<issueId>`.
   2. Run **Reconcile Memory ID & Branch(`sentry-<issueId>`, `<ticketID>`)**.
   3. Set `<ID>` = `<ticketID>`. If `INVESTIGATION_DETECTED` is false, run the workspace isolation procedure: **Ensure Worktree(`<ticketID>`)** when `USE_WORKTREE` is true, or **Ensure Working Branch(`<ticketID>`)** otherwise.
6. Extract the ticket URL, assign to creator, report -- same as brain-dump ticket creation (steps 5-8 above).

**If 2 (No):**
- `sentry-<issueId>` is the final `<ID>`
- If `INVESTIGATION_DETECTED` is false, run the workspace isolation procedure: **Ensure Worktree(`sentry-<issueId>`)** when `USE_WORKTREE` is true, or **Ensure Working Branch(`sentry-<issueId>`)** otherwise.
- Skip tracker status updates throughout the pipeline

**If no tracker is configured** (`tracker.mcp` is null or `tracker.operations.createIssue` does not exist):
- Skip the prompt entirely -- `sentry-<issueId>` is the final `<ID>`
- Skip tracker status updates throughout the pipeline

**For ticket mode only (after product-analyst returns):**
5. After agent returns, update tracker status to In Progress:
   - Call `mcp__<tracker.mcp>__<tracker.operations.moveStatus>`

**For all modes:**
- The agent wrote `$N1_HOME/memory/<ID>/ticket.md` itself. Verify it:
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
  n1_verify_dependencies "$N1_HOME/memory/$ID" ticket.md
  ```
  If missing/empty (agent failed to write), write the returned compact block to `ticket.md` as a fallback and note the gap in overview's `## Key Decisions`: "product-analyst failed to write ticket.md; stub written from compact return -- downstream context is degraded."
- ID is: ticket ID for ticket mode (or brain dump/file mode with ticket creation), filename slug for file mode without ticket, description slug for brain dump without ticket (e.g., `csv-export-users`)

**Extract and persist signals:**
Parse the product-analyst's compact return for a line starting with `n1:signals `:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
SIGNAL_LINE=$(echo "$AGENT_OUTPUT" | grep -m1 '^n1:signals ')
if [ -n "$SIGNAL_LINE" ]; then
    PAIRS=$(echo "$SIGNAL_LINE" | sed 's/^n1:signals //')
    n1_write_signals "$N1_HOME/memory/$ID/ticket.md" $PAIRS
fi
```

**Parse compact return:**
1. Extract `tier:` from the product-analyst's compact return. Use case-insensitive regex: `^tier:\s*(simple|standard|complex)` against the compact return.
2. If a valid tier is found, set `TIER` to that value. If not found or invalid, default to `standard`.
3. Extract `title:` from the compact return:
   ```bash
   TITLE=$(echo "$AGENT_OUTPUT" | grep -m1 '^title: ' | sed 's/^title: //')
   ```
   This `TITLE` is used for the overview.md heading `# <ID>: <Title>`.
4. After writing the overview.md template below, update the tier in frontmatter:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
   n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier" "$TIER"
   ```

**Create initial overview.md:**
```markdown
---
ticket: <ID>
tier: standard
step: ticket
qa_fix_cycle: 0
review_fix_cycle: 0
clean_passes: 0
local_test_fix_cycle: 0
---

# <ID>: <Title>

## Progress
- [x] Ticket read
- [ ] Analysis
- [ ] Brainstorm
- [ ] Plan
- [ ] Estimation
- [ ] Implementation
- [ ] QA
- [ ] Review
- [ ] Local Testing
- [ ] PR
- [ ] CI

## Key Decisions
(none yet)

## Escalations
(none yet)
```

**Write resolved type to overview.md:**

Write the resolved type to overview.md frontmatter:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "type" "$RESOLVED_TYPE"
```

**If `INVESTIGATION_DETECTED` is true** (i.e., `RESOLVED_TYPE` is `"investigation"`):
1. Replace the overview.md progress checklist with the investigation variant:
   ```markdown
   ## Progress
   - [x] Ticket read
   - [ ] Analysis
   - [ ] Brainstorm
   - [ ] Investigation deliverable
   ```
2. Report: "Detected investigation task -- running shortened pipeline (no implementation/QA/review/PR)."

**Telemetry (if enabled):** Write the run envelope -- this provides the run-level metadata for the merge script:

```bash
echo '{"layer":"envelope","run_id":"'"$N1_RUN_ID"'","n1_version":"'"$N1_VERSION"'","ticket_id":"'"$ID"'","branch":"'"$BRANCH"'","started_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","config_snapshot":{'"$(
  TIER=$(json_val '.testCoverage.tier' "${N1_HOME}/config.json")
  EST=$(json_val '.estimation.enabled' "${N1_HOME}/config.json")
  LT=$(json_val '.localTesting.enabled' "${N1_HOME}/config.json")
  CX=$(json_val '.codex.enabled' "${N1_HOME}/config.json")
  [ -z "$CX" ] && CX=$(json_val '.codexReview.enabled' "${N1_HOME}/config.json")
  PR=$(json_val '.planReview.reviewPlan' "${N1_HOME}/config.json")
  printf '"test_coverage_tier":"%s","estimation_enabled":%s,"local_testing_enabled":%s,"codex_review_enabled":%s,"plan_review_enabled":%s' \
    "${TIER:-maintain}" "${EST:-false}" "${LT:-false}" "${CX:-false}" "${PR:-true}"
)"'}}' >> "${N1_HOME}/memory/$ID/telemetry/raw/steps/$N1_RUN_ID.jsonl"
```

**Step result (step mode):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_emit_step_result "ticket" "pass" "analysis" "null" "" "$N1_HOME/memory/$ID"
```


**Phase 1: Spawn intake-agent**

Resolve model for `intake-agent` (see Model Resolution above).

The intake-agent accepts four input modes. Choose based on input type:

**Ticket mode** (input matches `<prefix>-<number>`):
0. The `<ID>` is already known (the ticket ID). Workspace isolation is deferred until after investigation detection (see below).
1. Read `$N1_HOME/config.json` -> `tracker.type`, `tracker.mcp`, `tracker.operations`
2. Read `$N1_HOME/config.json` -> find the error-tracker provider. Requires jq. Scan all providers in `observability.providers` for one that has a `urlPattern` field. If found, set `ET_CONFIGURED` = true and extract from that provider entry: `errorTrackingMcp` (from `.mcp`), `errorTrackingOps` (from `.operations`), `errorTrackingUrlPattern` (from `.urlPattern`), `orgSlug` (from `.orgSlug`), `projectSlug` (from `.projectSlug`). If no provider has `urlPattern` or jq is unavailable, set `ET_CONFIGURED` = false.

jq extraction:
```bash
ET_PROVIDER=$(jq -r '
    [.observability.providers // {} | to_entries[] | select(.value.urlPattern)] | first | .value // empty
' "$N1_HOME/config.json" 2>/dev/null)
```
3. Spawn intake-agent with:
   - `mode`: "ticket"
   - `ticketId`: the parsed ticket ID
   - `trackerMcp`: from config (`tracker.mcp`)
   - `operations`: from config (`tracker.operations`)
   - `trackerType`: from config (`tracker.type`)
   - `ticketMdPath`: `$N1_HOME/memory/<ID>/ticket.md`
   - (**Only if `ET_CONFIGURED` is true**) `errorTrackingMcp`: from the matched provider's `.mcp`
   - (**Only if `ET_CONFIGURED` is true**) `errorTrackingOps`: from the matched provider's `.operations`
   - (**Only if `ET_CONFIGURED` is true**) `errorTrackingUrlPattern`: from the matched provider's `.urlPattern`
   - (**Only if `ET_CONFIGURED` is true**) `orgSlug`: from the matched provider's `.orgSlug` (if present)
   - (**Only if `ET_CONFIGURED` is true**) `projectSlug`: from the matched provider's `.projectSlug` (if present)

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

**Error tracker mode** (input matches the matched provider's `urlPattern`):
1. Use the already-extracted provider fields from the `ET_CONFIGURED` detection above: `errorTrackingMcp` (`.mcp`), `errorTrackingOps` (`.operations`), `orgSlug`, `projectSlug`.
2. Parse the issue ID from the URL (see Error tracker URL parsing above)
3. The provisional `<ID>` is `sentry-<issueId>`. Workspace isolation is deferred until after investigation detection (see below).
4. Spawn intake-agent with:
   - `mode`: "error-tracker"
   - `issueId`: the parsed issue ID
   - `issueUrl`: the original URL
   - `errorTrackingMcp`: from the matched provider's `.mcp`
   - `operations`: from the matched provider's `.operations`
   - `orgSlug`: from the matched provider's `.orgSlug`
   - `projectSlug`: from the matched provider's `.projectSlug`
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
- `LINKED_ERROR` -- from `linked_error` (object with `provider`, `issueId`, `issueUrl`; may be absent)

If `LINKED_ERROR` is present (not null/absent):
- Override `TYPE` to `"bug"` (linked error tracker issues are defects by definition)
- Store `LINKED_ERROR_URL` = the `issueUrl` value (available for downstream steps: PR body, ticket description enrichment)

**Type resolution (between spawns)**

Resolve the workflow type using the parsed metadata and the type registry in `pipeline.json`:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"

# Parse --type flag if provided by the user
TYPE_OVERRIDE=""
if n1_parse_type_arg "$USER_INPUT" 2>/dev/null; then
    TYPE_OVERRIDE=$(n1_parse_type_arg "$USER_INPUT")
fi

# --investigate flag forces the investigation type (see SKILL.md Investigate flag detection)
if [ "$INVESTIGATE_FLAG" = "true" ]; then
    TYPE_OVERRIDE="investigation"
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

**Capture original ticket status (ticket mode only):**

Read the raw ticket.md written by the intake-agent BEFORE the product-analyst overwrites it:
```bash
ORIGINAL_STATUS=$(grep -m1 '^\*\*Status:\*\*' "$N1_HOME/memory/$ID/ticket.md" | sed 's/^\*\*Status:\*\* //')
```
Store `ORIGINAL_STATUS` in context — it will be written to overview.md frontmatter after overview.md is created (see "Write original ticket status to overview.md" below). Brain-dump and file modes produce `Not specified` or an empty string here — the guard at write-time skips the frontmatter write, which is correct since there is no tracker status to restore.

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
Do NOT return the full report — followed by your n1:signals line per your Signal Emission section."

For error tracker mode, also pass:
- `issueId`, `issueUrl`, `errorTrackingMcp`, `operations` (error tracker ops), `orgSlug`, `projectSlug`

The product-analyst reads the raw `ticket.md` (written by intake-agent) instead of fetching from MCP. It then fetches comments/transitions, runs enrichment, and overwrites `ticket.md` with the structured output.

**ID-Final invariant.** No file may be written under `$N1_HOME/memory/` and no working branch may be created until `<ID>` is **final**: the ticket ID in ticket mode; the *created* ticket ID for brain-dump/file/error-tracker mode answered "Yes"; the slug only for brain-dump/file mode answered "No"; `sentry-<issueId>` for error-tracker mode answered "No" (or when no tracker is configured). Resolving the create-ticket decision (and, on "Yes", actually creating the ticket) therefore happens BEFORE the `ticket.md`/`overview.md` writes and branch creation below.

**Scratch-to-memory move (brain dump and file modes only):** After `<ID>` is resolved (via ticket creation "Yes" or slug adoption "No"), move the scratch file to the final memory path: `mv "$N1_HOME/scratch/intake-raw.md" "$N1_HOME/memory/$ID/ticket.md"`. The product-analyst's structured output will overwrite this file in place. For ticket and error-tracker modes this step is unnecessary -- intake-agent writes directly to `$N1_HOME/memory/<ID>/ticket.md` because the ID is already known.

**Brain dump raw persist (brain dump mode only):** Immediately after `<ID>` is final and the memory directory exists, write the requester's original raw input text to `$N1_HOME/memory/<ID>/ticket.raw.md`. Use the Write tool directly — the content is the verbatim text the user provided (the brain dump). This file is for audit and traceability only; it is never fed into agent spawns by default. Prefix the file with a single header line so its provenance is clear:
```markdown
<!-- n1: raw brain dump input — verbatim; not processed by agents -->
<original user text>
```

**Tracker ticket creation (brain-dump, file, and error-tracker modes):**

> **MCP prefix for all tracker calls in this section:** Use `mcp__<tracker.mcp>__` (value from config, not from tool list).

After product-analyst returns, if the input was a brain dump, file path, or error tracker URL, AND a tracker is configured (`tracker.mcp` is not null AND `tracker.operations.createIssue` exists):

Determine `source_mode`:
- `braindump` if input was brain dump or file path
- `error-tracker` if input was an error tracker URL

**Autonomy gate:** read `MP=$(n1_autonomy_val 'mechanicalPrompts')`. If `MP` is `auto`, skip the prompt — take path **1 (Yes)** below (creating the ticket is the recommended default and the tracker write is editable/deletable). After the ticket is created and `<ID>` is final, append a Decision Ledger row per `skills/n1-start/ledger.md`:

- If `source_mode == braindump`: `| ticket | mechanical | C | [auto] | Create tracker ticket for brain-dump run? | Created <ID> | Continue without ticket | mechanicalPrompts=auto; formalizes work, reversible in tracker |`
- If `source_mode == error-tracker`: `| ticket | mechanical | C | [auto] | Create tracker ticket for Sentry issue? | Created <ID> | Continue without ticket | mechanicalPrompts=auto; formalizes work, reversible in tracker |`

**Deferred ticket creation (`--investigate` brain-dump mode):** If `INVESTIGATE_FLAG` is `true` AND `source_mode == braindump`, skip this ticket-creation question entirely (regardless of `MP`) and take the "No" path below: adopt the description slug as `<ID>` and skip tracker status updates. Report: "Investigation mode: ticket creation deferred until findings are ready." Ticket creation is offered after the investigation deliverable instead (see steps/investigation-deliverable.md, Phase 5 brain-dump variant).

If `MP` is `ask` (default), ask:

- If `source_mode == braindump`:
  ```
  The task has been structured. Would you like to create a tracker ticket?
  1 -- Yes, create a ticket in <tracker.mcp>
  2 -- No, continue without a ticket
  ```
- If `source_mode == error-tracker`:
  ```
  The Sentry issue has been analyzed. Would you like to create a tracker ticket?
  1 -- Yes, create a ticket in <tracker.mcp>
  2 -- No, continue with sentry-<issueId> as the working ID
  ```

**If 1 (Yes):**

> **Create the ticket now.** Creating the ticket via MCP is **mandatory and immediate** -- it is the first action after the user answers "Yes". Do NOT proceed as if the run were ticket-less; the slug is adopted as `<ID>` ONLY on the explicit "No" path. (See the ID-Final invariant above.)

1. Read the Title from the compact return (`title:` line). Read structured content (Core Ask, Description, Acceptance Criteria sections) from the product-analyst output path: `$N1_HOME/scratch/intake-raw.md` (braindump/file) or `$N1_HOME/memory/<ID>/ticket.md` (error-tracker, where `<ID>` = `sentry-<issueId>`).
2. **Build description:**
   - If `source_mode == error-tracker`: prepend `**Sentry:** [#<issueId>](<original URL>)`, a blank line, then Core Ask + Description + Acceptance Criteria.
   - If `source_mode == braindump`: description = Core Ask + Description + Acceptance Criteria sections.
   - **Jira formatting:** If `tracker.type == "jira"`, convert any checkbox syntax in the description: replace `- [ ] ` with `- ` and `- [x] ` with `- ` (Jira does not support GitHub-flavored Markdown checkboxes and silently strips the brackets, leaving empty bullets).
3. **Resolve ticket tagging.** Read `ticketTagging` from `$N1_HOME/config.json`.
   - If `ticketTagging.enabled == true` AND `ticketTagging.service` is non-empty → tagging ON:
     - `<summary>` = `<service> | <Title>` (if Title already begins with `<service> |`, use Title unchanged -- idempotency guard).
     - `<description>` = `**Service:** <service>` line, blank line, then description from step 2.
   - Otherwise → tagging OFF: `<summary>` = Title; `<description>` = description from step 2.
4. Create the ticket via tracker MCP:
   - Jira: resolve `cloudId` via `getAccessibleAtlassianResources` (reuse if already cached), then call `<tracker.operations.createIssue>` with `cloudId`, `projectKey: tracker.projectKey`, `issueTypeName: "Task"`, `summary`, `description`.
   - YouTrack: call `<tracker.operations.createIssue>` with `project: tracker.projectKey`, `summary`, `description`.
5. The returned ticket ID is the final `<ID>`. Adopt it:
   - Provisional ID: description slug (brain dump) or filename slug (file mode) if `source_mode == braindump`; `sentry-<issueId>` if `source_mode == error-tracker`.
   - Run **Reconcile Memory ID & Branch(`<provisional>`, `<ticketID>`)** (a no-op in the clean path; moves any leaked slug memory folder and renames the slug branch if drift occurred).
   - Set `<ID>` = `<ticketID>`. If `INVESTIGATION_DETECTED` is false, run the workspace isolation procedure: **Ensure Worktree(`<ticketID>`)** when `USE_WORKTREE` is true, or **Ensure Working Branch(`<ticketID>`)** otherwise.
6. Extract the ticket URL from the MCP response (YouTrack returns it in the response body; for Jira construct it as `https://<cloud>/browse/<key>` from the response). Store it as `TICKET_URL` in orchestrator context for downstream use (persisted to overview.md frontmatter by the analysis step).
7. **Assign to creator.** Skip if ANY of: `tracker.assignToCreator === false`, `tracker.operations.getCurrentUser` missing, `tracker.operations.assign` missing.
   - Resolve current user: call `<tracker.operations.getCurrentUser>` (no args).
     - Jira: take `account_id`; reuse `cloudId`.
     - YouTrack: take `login`.
   - Assign: call `<tracker.operations.assign>`.
     - Jira: `cloudId`, `issueIdOrKey: <ID>`, `assignee_account_id: <account_id>`.
     - YouTrack: `issueId: <ID>`, `assigneeLogin: <login>`.
   - Success: report suffix = ` (assigned to you)`. Failure: emit warning; use empty suffix; do not roll back creation.
8. Report: "Created ticket **[<ID>](<ticket URL>)**<report suffix>: <title>"
9. After writing ticket.md and overview.md, proceed to the next step.

**If 2 (No):**
- Final `<ID>`: description slug (brain dump) or filename slug (file mode) if `source_mode == braindump`; `sentry-<issueId>` if `source_mode == error-tracker`.
- If `INVESTIGATION_DETECTED` is false, run the workspace isolation procedure: **Ensure Worktree(`<ID>`)** when `USE_WORKTREE` is true, or **Ensure Working Branch(`<ID>`)** otherwise.
- Skip tracker status updates throughout the pipeline.

**If no tracker is configured** (error-tracker mode only — brain-dump/file mode is already gated by the outer `if` above):
- `sentry-<issueId>` is the final `<ID>`. Skip tracker status updates throughout the pipeline.

**Capture ticket URL (ticket mode):**
For ticket mode where the URL was not captured by creation (step 6 above), construct it:
- YouTrack: `TICKET_URL` is the tracker instance URL + `/issue/<ID>` (read `tracker.instanceUrl` from config if available, or derive from `tracker.mcp`)
- Jira: `TICKET_URL = https://<cloud>.atlassian.net/browse/<ID>` (derive `<cloud>` from the `cloudId` or `getAccessibleAtlassianResources` response)
- If URL cannot be constructed, set `TICKET_URL` to empty — the orientation block omits the link line.

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

**Name the session:**
After `ID` and `TITLE` are finalized, output `/rename <ID> <TITLE truncated so total length (ID + space + title) ≤ 50 chars>`. If `TITLE` is empty, output `/rename <ID>`.
```bash
MAX=$(( 50 - ${#ID} - 1 ))
SESSION_NAME="$ID${TITLE:+ ${TITLE:0:$MAX}}"
```
Run: `/rename $SESSION_NAME`

**Create initial overview.md:**
```markdown
---
ticket: <ID>
tier: standard
step: ticket
qa_fix_cycle: 0
tq_fix_cycle: 0
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

If `INVESTIGATE_FLAG` is `true`, also persist the interactive-investigation marker (read by the brainstorm and investigation-deliverable steps, and by resumed sessions):

```bash
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "investigate_interactive" "true"
```

**Write original ticket status to overview.md:**

`ORIGINAL_STATUS` was captured from the raw intake-agent output before the product-analyst ran (see "Capture original ticket status" above). Write it to frontmatter now that overview.md exists:
```bash
if [ -n "$ORIGINAL_STATUS" ] && [ "$ORIGINAL_STATUS" != "Not specified" ]; then
    n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "original_status" "$ORIGINAL_STATUS"
fi
```

Brain-dump and file modes produce `Not specified` or an empty string — the guard skips the frontmatter write, which is correct since there is no tracker status to restore.

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

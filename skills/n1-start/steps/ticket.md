<!-- n1:step-snippet-exception: two sequential agent spawns with interspersed type resolution and tracker MCP calls -->

> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user.**

**Phase 1: Spawn intake-agent**

Resolve model for `intake-agent`. Choose spawn mode:

**Ticket mode** (`<ID>` matches `<prefix>-<number>`):
1. Read `tracker.type`, `tracker.mcp`, `tracker.operations` from config.
2. Detect error-tracker provider (requires jq):
   ```bash
   ET_PROVIDER=$(jq -r '
       [.observability.providers // {} | to_entries[] | select(.value.urlPattern)] | first | .value // empty
   ' "$N1_HOME/config.json" 2>/dev/null)
   ```
   If found: `ET_CONFIGURED=true`; extract `errorTrackingMcp`, `errorTrackingOps`, `errorTrackingUrlPattern`, `orgSlug`, `projectSlug`. Otherwise: `ET_CONFIGURED=false`.
3. Spawn intake-agent: `mode=ticket`, `ticketId`, `trackerMcp`, `operations`, `trackerType`, `ticketMdPath=$N1_HOME/memory/<ID>/ticket.md`. Include error-tracking fields only when `ET_CONFIGURED=true`.

**File mode** (input is a file path on disk): spawn `mode=file`, `filePath`, `ticketMdPath=$N1_HOME/scratch/intake-raw.md`.

**Brain dump mode** (free text): spawn `mode=text`, `content`, `ticketMdPath=$N1_HOME/scratch/intake-raw.md`.

**Error tracker mode** (input matches `urlPattern`): spawn `mode=error-tracker`, `issueId`, `issueUrl`, `errorTrackingMcp`, `operations`, `orgSlug`, `projectSlug`, `ticketMdPath=$N1_HOME/memory/<ID>/ticket.md`. Provisional `<ID>=sentry-<issueId>`.

**Parse intake-result**

```bash
INTAKE_RESULT=$(echo "$AGENT_OUTPUT" | grep -m1 '^intake-result: ' | sed 's/^intake-result: //')
```

If empty, default: `{"title": null, "tags": [], "type": "task"}`. Parse: `TITLE`, `TAGS`, `TYPE`, `CLOUD_ID`, `LINKED_ERROR`. If `LINKED_ERROR` present: override `TYPE="bug"`, store `LINKED_ERROR_URL`.

**Type resolution (between spawns)**

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
source "$N1_ROOT/lib/validation.sh"

TYPE_OVERRIDE=""
if n1_parse_type_arg "$USER_INPUT" 2>/dev/null; then
    TYPE_OVERRIDE=$(n1_parse_type_arg "$USER_INPUT")
fi

if [ "$INVESTIGATE_FLAG" = "true" ]; then
    TYPE_OVERRIDE="investigation"
fi

TAGS_CSV=$(echo "$INTAKE_RESULT" | sed 's/.*"tags":\[//;s/\].*//' | tr -d '"' | tr -d ' ')
TYPE_FIELD=$(echo "$INTAKE_RESULT" | sed 's/.*[,{] *"type": *"\([^"]*\)".*/\1/')

n1_resolve_type "$TITLE" "$TAGS_CSV" "$TYPE_FIELD" "$TYPE_OVERRIDE" > "$N1_HOME/memory/$ID/.resolved-type" 2>/dev/null || true
RESOLVED_TYPE=$(cat "$N1_HOME/memory/$ID/.resolved-type"); rm -f "$N1_HOME/memory/$ID/.resolved-type"
TYPE_MATCHED_BY="$N1_TYPE_MATCHED_BY"
INVESTIGATION_DETECTED=false
if [ "$RESOLVED_TYPE" = "investigation" ]; then
    INVESTIGATION_DETECTED=true
elif n1_title_hints_investigation "$TITLE"; then
    echo "Hint: title reads like an investigation but ticket has no 'investigation' tag. Re-run with --type investigation to skip implementation; continuing as ${RESOLVED_TYPE}."
fi
```

**Story handoff**

```bash
ISSUE_TYPE=$(echo "$INTAKE_RESULT" | sed -n 's/.*"issue_type": *"\([^"]*\)".*/\1/p' | tr '[:upper:]' '[:lower:]')
SUBTASK_COUNT=$(echo "$INTAKE_RESULT" | sed -n 's/.*"subtask_count": *\([0-9]*\).*/\1/p')
IS_STORY=false
case "$ISSUE_TYPE" in story|epic) IS_STORY=true ;; esac
if [ "${SUBTASK_COUNT:-0}" -gt 0 ] && ! grep -q '### Parent Context' "$N1_HOME/memory/$ID/ticket.md"; then IS_STORY=true; fi
```

If `IS_STORY=true` and `N1_HEADLESS!=1`: print "**<ID>** is a story with <SUBTASK_COUNT> subtasks — handing off to n1-story-run." Invoke `n1:n1-story-run <ID>` and **STOP**.
If `IS_STORY=true` and `N1_HEADLESS=1`: apply `procedures/autonomy-headless.md § Headless Guard`.

**Workspace isolation** (ticket and error-tracker modes, when `INVESTIGATION_DETECTED=false`):
Run **Ensure Worktree(`<ID>`)** when `USE_WORKTREE=true`, else **Ensure Working Branch(`<ID>`)**.

**Capture original ticket status** (ticket mode only):
```bash
ORIGINAL_STATUS=$(grep -m1 '^\*\*Status:\*\*' "$N1_HOME/memory/$ID/ticket.md" | sed 's/^\*\*Status:\*\* //')
```

**Phase 2: Spawn product-analyst**

Resolve model for `product-analyst`. Read `ticketEnrichment` from config. `enrichmentEnabled = ticketEnrichment.enabled !== false` AND `tracker.operations.editTicket` exists.

Spawn product-analyst: `mode`, `ticketId` (ticket mode), `trackerMcp`, `operations`, `enrichmentEnabled`, `cloudId` (Jira), `ticketMdPath`. For error-tracker mode also: `issueId`, `issueUrl`, `errorTrackingMcp`, error-tracker ops, `orgSlug`, `projectSlug`.

**Output-path directive:** "Write structured output to `ticketMdPath` as full overwrite. Return ONLY: `tier: <simple|standard|complex>\ntitle: <title>\nambiguities: <count>` followed by your `n1:signals` line."

**ID-Final invariant:** no file written under `$N1_HOME/memory/` and no branch created until `<ID>` is final. For brain-dump/file/error-tracker: resolve create-ticket decision BEFORE any writes.

**Scratch-to-memory move** (brain-dump and file modes, after `<ID>` resolved):
`mv "$N1_HOME/scratch/intake-raw.md" "$N1_HOME/memory/$ID/ticket.md"`

**Brain dump raw persist** (brain-dump mode, after memory dir exists):
Write verbatim input to `$N1_HOME/memory/$ID/ticket.raw.md` with prefix `<!-- n1: raw brain dump input — verbatim; not processed by agents -->`.

**Tracker ticket creation** (brain-dump, file, error-tracker modes when tracker configured and `tracker.operations.createIssue` exists):

> Use `mcp__<tracker.mcp>__` prefix for all tracker calls.

`source_mode = braindump` (brain-dump/file) or `error-tracker`.

**Autonomy gate:** `MP=$(n1_autonomy_val 'mechanicalPrompts')`. If `MP=auto`: take path 1 (create ticket), append Decision Ledger row.

**Deferred creation** (`INVESTIGATE_FLAG=true` AND `source_mode==braindump`): skip regardless of `MP`, take "No" path; offer creation after investigation deliverable instead.

If `MP=ask`: present prompt:
- braindump: "Task structured. Create tracker ticket? 1 — Yes / 2 — No"
- error-tracker: "Sentry issue analyzed. Create tracker ticket? 1 — Yes / 2 — No (continue with sentry-<issueId>)"

**If 1 (Yes):**
1. Read Title from compact return. Read Core Ask + Description + AC from product-analyst output.
2. Build description (Jira: convert `- [ ]` → `-`). If `source_mode==error-tracker`: prepend `**Sentry:** [#<issueId>](<url>)`.
3. Resolve ticketTagging: if `enabled=true` AND `service` non-empty → `summary = "<service> | <Title>"`, `description = "**Service:** <service>\n\n<description>"`. Otherwise: `summary = Title`.
4. Create ticket: Jira: `createIssue` with `cloudId`, `projectKey`, `issueTypeName: "Task"`, `summary`, `description`. YouTrack: `createIssue` with `project`, `summary`, `description`.
5. Final `<ID>` = returned ticket ID. Run **Reconcile Memory ID & Branch(`<provisional>`, `<ticketID>`)`. Set `<ID> = <ticketID>`. If `INVESTIGATION_DETECTED=false`: run workspace isolation.
6. Extract ticket URL. Store as `TICKET_URL`.
7. **Assign to creator** (skip if `assignToCreator===false` or missing `getCurrentUser`/`assign`): call `getCurrentUser`, then `assign`.
8. Record ticket ID, URL, title in overview.md frontmatter.

**If 2 (No):** final `<ID>` = description slug or `sentry-<issueId>`. Run workspace isolation if `INVESTIGATION_DETECTED=false`. Skip tracker status updates throughout pipeline.

**For all modes — verify ticket.md:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
source "$N1_ROOT/lib/validation.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" ticket.md
```
If missing/empty: write returned compact block as fallback, log in overview `## Key Decisions`.

**Capture ticket URL** (ticket mode, not from creation): YouTrack: `tracker.instanceUrl/issue/<ID>`; Jira: `https://<cloud>.atlassian.net/browse/<ID>`. If unresolvable: `TICKET_URL=""`.

**Extract and persist signals:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
SIGNAL_LINE=$(echo "$AGENT_OUTPUT" | grep -m1 '^n1:signals ')
if [ -n "$SIGNAL_LINE" ]; then
    PAIRS=$(echo "$SIGNAL_LINE" | sed 's/^n1:signals //')
    n1_write_signals "$N1_HOME/memory/$ID/ticket.md" $PAIRS
fi
```

**Parse compact return:**
```bash
TITLE=$(echo "$AGENT_OUTPUT" | grep -m1 '^title: ' | sed 's/^title: //')
```
Extract `tier:` regex `^tier:\s*(simple|standard|complex)`; default `standard` if missing. Write tier:
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier" "$TIER"
```

**Name the session:**
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

## Context
(pending — written after analysis)

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

**Write resolved type and context:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
source "$N1_ROOT/lib/context.sh"
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "type" "$RESOLVED_TYPE"
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "type_matched_by" "$TYPE_MATCHED_BY"
if [ "$INVESTIGATE_FLAG" = "true" ]; then
    n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "investigate_interactive" "true"
fi
[ -n "${N1_STORY_ID:-}" ] && n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "story" "$N1_STORY_ID"
if [ -n "$ORIGINAL_STATUS" ] && [ "$ORIGINAL_STATUS" != "Not specified" ]; then
    n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "original_status" "$ORIGINAL_STATUS"
fi
n1_write_context
```

If `INVESTIGATION_DETECTED=true`: replace progress checklist with investigation variant:
```markdown
## Progress
- [x] Ticket read
- [ ] Analysis
- [ ] Brainstorm
- [ ] Investigation deliverable
```

**Telemetry (if enabled):** write run envelope:
```bash
echo '{"layer":"envelope","run_id":"'"$N1_RUN_ID"'","n1_version":"'"$N1_VERSION"'","ticket_id":"'"$ID"'","branch":"'"$BRANCH"'","started_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","config_snapshot":{'"$(
  TIER=$(json_val '.testCoverage.tier' "${N1_HOME}/config.json")
  EST=$(json_val '.estimation.enabled' "${N1_HOME}/config.json")
  LT=$(json_val '.localTesting.enabled' "${N1_HOME}/config.json")
  PR=$(json_val '.planReview.reviewPlan' "${N1_HOME}/config.json")
  printf '"test_coverage_tier":"%s","estimation_enabled":%s,"local_testing_enabled":%s,"plan_review_enabled":%s' \
    "${TIER:-maintain}" "${EST:-false}" "${LT:-false}" "${PR:-true}"
)"'}}' >> "${N1_HOME}/memory/$ID/telemetry/raw/steps/$N1_RUN_ID.jsonl"
```

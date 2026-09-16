<!-- n1:step-snippet-exception: agent spawn with interspersed type resolution and tracker MCP calls -->

> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user.**

**Spawn product-analyst.** Detect mode and params. Ticket: `mode=ticket ticketId trackerMcp operations trackerType ticketMdPath`; add error fields if `ET_CONFIGURED`. File: `mode=file filePath ticketMdPath`. Brain dump: `mode=text content ticketMdPath`. Error tracker: `mode=error-tracker issueId issueUrl`+error fields; provisional `<ID>=sentry-<issueId>`. Always: `enrichmentEnabled cloudId` (Jira only).

```bash
INTAKE_RESULT=$(echo "$AGENT_OUTPUT" | grep -m1 '^intake-result: ' | sed 's/^intake-result: //')
```
Empty: `{"title":null,"tags":[],"type":"task"}`. Parse `TITLE TAGS TYPE CLOUD_ID LINKED_ERROR`. `LINKED_ERROR` → `TYPE=bug`, `LINKED_ERROR_URL`.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/validation.sh"
TYPE_OVERRIDE=""; n1_parse_type_arg "$USER_INPUT" 2>/dev/null && TYPE_OVERRIDE=$(n1_parse_type_arg "$USER_INPUT")
[ "$INVESTIGATE_FLAG" = "true" ] && TYPE_OVERRIDE="investigation"
TAGS_CSV=$(echo "$INTAKE_RESULT" | sed 's/.*"tags":\[//;s/\].*//' | tr -d '"' | tr -d ' ')
TYPE_FIELD=$(echo "$INTAKE_RESULT" | sed 's/.*[,{] *"type": *"\([^"]*\)".*/\1/')
n1_resolve_type "$TITLE" "$TAGS_CSV" "$TYPE_FIELD" "$TYPE_OVERRIDE" > "$N1_HOME/memory/$ID/.resolved-type" 2>/dev/null || true
RESOLVED_TYPE=$(cat "$N1_HOME/memory/$ID/.resolved-type"); rm -f "$N1_HOME/memory/$ID/.resolved-type"; TYPE_MATCHED_BY="$N1_TYPE_MATCHED_BY"
INVESTIGATION_DETECTED=false
[ "$RESOLVED_TYPE" = "investigation" ] && INVESTIGATION_DETECTED=true || { n1_title_hints_investigation "$TITLE" && echo "Hint: title looks like investigation; re-run with --type investigation; continuing as ${RESOLVED_TYPE}."; }
ISSUE_TYPE=$(echo "$INTAKE_RESULT" | sed -n 's/.*"issue_type": *"\([^"]*\)".*/\1/p' | tr '[:upper:]' '[:lower:]')
SUBTASK_COUNT=$(echo "$INTAKE_RESULT" | sed -n 's/.*"subtask_count": *\([0-9]*\).*/\1/p'); IS_STORY=false
case "$ISSUE_TYPE" in story|epic) IS_STORY=true ;; esac
[ "${SUBTASK_COUNT:-0}" -gt 0 ] && ! grep -q '### Parent Context' "$N1_HOME/memory/$ID/ticket.md" && IS_STORY=true
ORIGINAL_STATUS=$(echo "$INTAKE_RESULT" | sed -n 's/.*"original_status": *"\([^"]*\)".*/\1/p')
```
`IS_STORY=true`: non-headless→handoff `n1:n1-story-run <ID>`, STOP; headless→`procedures/autonomy-headless.md § Headless Guard`. **Workspace isolation** (`INVESTIGATION_DETECTED=false`): **Ensure Worktree** or **Ensure Working Branch**.

**ID-Final:** no memory file/branch until `<ID>` final. product-analyst writes ticket.md directly to `ticketMdPath`.

**Tracker ticket creation** (brain-dump/file/error-tracker+`createIssue`): skip if `INVESTIGATE_FLAG=true`+braindump. `MP=auto`→create+ledger. `MP=ask`→"Create ticket? Yes/No". Yes→`createIssue`, final `<ID>`, **Reconcile Memory ID & Branch**, assign, record URL.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/validation.sh"; source "$N1_ROOT/lib/context.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" ticket.md
SIGNAL_LINE=$(echo "$AGENT_OUTPUT" | grep -m1 '^n1:signals ')
[ -n "$SIGNAL_LINE" ] && { PAIRS=$(echo "$SIGNAL_LINE" | sed 's/^n1:signals //'); n1_write_signals "$N1_HOME/memory/$ID/ticket.md" $PAIRS; }
TITLE=$(echo "$AGENT_OUTPUT" | grep -m1 '^title: ' | sed 's/^title: //')
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier" "$TIER"
MAX=$(( 50 - ${#ID} - 1 )); SESSION_NAME="$ID${TITLE:+ ${TITLE:0:$MAX}}"
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "type" "$RESOLVED_TYPE"
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "type_matched_by" "$TYPE_MATCHED_BY"
[ "$INVESTIGATE_FLAG" = "true" ] && n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "investigate_interactive" "true"
[ -n "${N1_STORY_ID:-}" ] && n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "story" "$N1_STORY_ID"
[ -n "$ORIGINAL_STATUS" ] && [ "$ORIGINAL_STATUS" != "Not specified" ] && n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "original_status" "$ORIGINAL_STATUS"
n1_write_context
```
Missing/empty: compact fallback. Extract `tier:` default `standard`. Run `/rename $SESSION_NAME`. **Create overview.md**: frontmatter (ticket, tier, step, fix_cycles), heading, `## Context` (pending), `## Progress`, `## Key Decisions`, `## Escalations`. `INVESTIGATION_DETECTED=true`: investigation variant.

```bash
TIER=$(json_val '.testCoverage.tier' "${N1_HOME}/config.json"); EST=$(json_val '.estimation.enabled' "${N1_HOME}/config.json")
LT=$(json_val '.localTesting.enabled' "${N1_HOME}/config.json"); PR=$(json_val '.planReview.reviewPlan' "${N1_HOME}/config.json")
echo '{"layer":"envelope","run_id":"'"$N1_RUN_ID"'","n1_version":"'"$N1_VERSION"'","ticket_id":"'"$ID"'","branch":"'"$BRANCH"'","started_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","config_snapshot":{"test_coverage_tier":"'"${TIER:-maintain}"'","estimation_enabled":'"${EST:-false}"',"local_testing_enabled":'"${LT:-true}"',"plan_review_enabled":'"${PR:-true}"'}}' >> "${N1_HOME}/memory/$ID/telemetry/raw/steps/$N1_RUN_ID.jsonl"
```

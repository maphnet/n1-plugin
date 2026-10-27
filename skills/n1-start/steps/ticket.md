<!-- n1:step-snippet-exception: agent spawn with interspersed type resolution and tracker MCP calls -->

> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user. (Orchestrator-only: a fork ignores this.)**

**Spawn product-analyst.** Detect mode and params. Ticket: `mode=ticket ticketId trackerMcp operations trackerType ticketMdPath`; add error fields if `ET_CONFIGURED`. File: `mode=file filePath ticketMdPath`. Brain dump: `mode=text content ticketMdPath`. Error tracker: `mode=error-tracker issueId issueUrl`+error fields; provisional `<ID>=sentry-<issueId>`. Always: `enrichmentEnabled` (`ticketEnrichment.enabled != false`), `cloudId` (Jira only).

```bash
INTAKE_RESULT=$(echo "$AGENT_OUTPUT" | grep -m1 '^intake-result: ' | sed 's/^intake-result: //')
```
Empty: `{"title":null,"tags":[],"type":"task"}`. Parse `TITLE TAGS TYPE CLOUD_ID LINKED_ERROR`. `LINKED_ERROR` → `TYPE=bug`, `LINKED_ERROR_URL`.

```bash
source ~/.n1/preamble.sh
TYPE_OVERRIDE=""; n1_parse_type_arg "$USER_INPUT" 2>/dev/null && TYPE_OVERRIDE=$(n1_parse_type_arg "$USER_INPUT")
TAGS_CSV=$(echo "$INTAKE_RESULT" | sed 's/.*"tags":\[//;s/\].*//' | tr -d '"' | tr -d ' ')
TYPE_FIELD=$(echo "$INTAKE_RESULT" | sed 's/.*[,{] *"type": *"\([^"]*\)".*/\1/')
n1_resolve_type "$TITLE" "$TAGS_CSV" "$TYPE_FIELD" "$TYPE_OVERRIDE" > "$N1_HOME/memory/$ID/.resolved-type" 2>/dev/null || true
RESOLVED_TYPE=$(cat "$N1_HOME/memory/$ID/.resolved-type"); rm -f "$N1_HOME/memory/$ID/.resolved-type"; TYPE_MATCHED_BY="$N1_TYPE_MATCHED_BY"
INVESTIGATION_DETECTED=false
[ "$RESOLVED_TYPE" = "investigation" ] && INVESTIGATION_DETECTED=true || { n1_title_hints_investigation "$TITLE" && echo "Hint: title looks like investigation; re-run with --type investigation; continuing as ${RESOLVED_TYPE}."; }
ISSUE_TYPE=$(echo "$INTAKE_RESULT" | sed -n 's/.*"issue_type": *"\([^"]*\)".*/\1/p' | tr '[:upper:]' '[:lower:]'); IS_STORY=false
SUBTASK_COUNT=$(echo "$INTAKE_RESULT" | sed -n 's/.*"subtask_count": *\([0-9]*\).*/\1/p')
case "$ISSUE_TYPE" in epic) IS_STORY=true ;; story) ;; *) [ "${SUBTASK_COUNT:-0}" -gt 0 ] && ! grep -q '### Parent Context' "$N1_HOME/memory/$ID/ticket.md" && IS_STORY=true ;; esac
ORIGINAL_STATUS=$(echo "$INTAKE_RESULT" | sed -n 's/.*"original_status": *"\([^"]*\)".*/\1/p')
```
**Story children** (`ISSUE_TYPE=story` only): Jira: `mcp__<trackerMcp>__<operations.search>` JQL `parent = <ID>`, maxResults 1, `cloudId` when set. YouTrack: `operations.getIssueLinks`, any `subtask` link with `<ID>` as parent. Jira: non-empty `issues` list→`has`, parsed empty `issues` list→`none`. YouTrack: a parent `subtask` link→`has`, parsed links without one→`none`. Error, absent search/links op, missing `issues`, or unparseable→`unknown`. Never infer from `total` (jc-mcp's `/search/jql` omits it).
```bash
source ~/.n1/preamble.sh; source "$N1_ROOT/lib/queue.sh"
n1_story_convert_decision "$(n1_config_val '.tracker.type')" "<has|none|unknown>" "$(n1_config_val '.tracker.versionMcp')"
```
`story`→`IS_STORY=true`. `single:<r>`→token `unconverted: <r>`. `convert`→`mcp__<versionMcp>__jcm_convertIssueType` `issueKeys:[<ID>]`, `issueTypeName:"Task"`. `ok:true`→token `converted`, then `operations.addComment` "N1: converted Story to Task, it has no sub-tasks. Running it as a single ticket." (ignore failure). Anything else (error, `RUNNING`, declined)→token `convert-failed: <message, one line, ≤80 chars>`. Write the token to `$N1_HOME/memory/<ID>/.story-convert` via the file-write mechanism, never a shell string. Never prompt or retry. Single/convert outcomes continue as a single ticket; `ISSUE_TYPE` not story: skip this block.

`INVESTIGATION_DETECTED=true` with `N1_QUEUE_RUN_ID` unset and `N1_HEADLESS=1` not set: say "Interactive investigation moved: run `/n1:n1-refine <ID> --investigate`." (no tracker ID: `/n1:n1-ticket` first) and STOP before overview.md.

`IS_STORY=true`: non-headless→handoff `n1:n1-queue --story <ID>`, STOP; headless→`procedures/autonomy-headless.md § Headless Guard`. **Workspace isolation** (`INVESTIGATION_DETECTED=false`): **Ensure Worktree**.

**ID-Final:** no memory file/branch until `<ID>` final. product-analyst writes ticket.md directly to `ticketMdPath`.

**Tracker ticket creation** (brain-dump/file/error-tracker+`createIssue`): `MP=auto`→create+ledger. `MP=ask`→"Create ticket? Yes/No". Yes→`createIssue`, final `<ID>`, **Reconcile Memory ID & Branch**, assign, record URL. Type: `<N1_ROOT>/references/ticket-scope.md` § Free-form creation.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/context.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" ticket.md
SIGNAL_LINE=$(echo "$AGENT_OUTPUT" | grep -m1 '^n1:signals ')
[ -n "$SIGNAL_LINE" ] && { PAIRS=$(echo "$SIGNAL_LINE" | sed 's/^n1:signals //'); n1_write_signals "$N1_HOME/memory/$ID/ticket.md" $PAIRS; }
TITLE=$(echo "$AGENT_OUTPUT" | grep -m1 '^title: ' | sed 's/^title: //')
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier" "$TIER"
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "pid" "$$"
MAX=$(( 50 - ${#ID} - 1 )); SESSION_NAME="$ID${TITLE:+ ${TITLE:0:$MAX}}"
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "type" "$RESOLVED_TYPE"
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "type_matched_by" "$TYPE_MATCHED_BY"
[ -n "${N1_STORY_ID:-}" ] && n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "story" "$N1_STORY_ID"
[ -n "$ORIGINAL_STATUS" ] && [ "$ORIGINAL_STATUS" != "Not specified" ] && n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "original_status" "$ORIGINAL_STATUS"
SC=$(tr -d '\\\r\n' 2>/dev/null < "$N1_HOME/memory/$ID/.story-convert"); rm -f "$N1_HOME/memory/$ID/.story-convert"; [ -n "$SC" ] && n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "story_convert" "$SC"
n1_write_context
```
Missing/empty: compact fallback. Extract `tier:` default `standard`. Run `/rename $SESSION_NAME`. **Create overview.md**: frontmatter (ticket, tier, step, fix_cycles), heading, `## Context` (pending), `## Progress`, `## Key Decisions`, `## Escalations`. `INVESTIGATION_DETECTED=true`: investigation variant.

**Ticket URL** (mode=ticket): call `mcp__<trackerMcp>__get_instance_url` (format=json) → extract `base_url`. YouTrack: `TICKET_URL=<base_url>/issue/<ID>`. Jira: `TICKET_URL=<base_url>/browse/<ID>`. On failure: skip silently. `n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "ticket_url" "$TICKET_URL"`.

**Duplicate check:** follow `<N1_ROOT>/references/duplicate-check.md` § Check with `CONTEXT=start`, `TEXT` = title + description from ticket.md, `SELF_ID=<ID>`, `OVERVIEW=$N1_HOME/memory/<ID>/overview.md` (cached; skipped on resume and in queue children — resolved at plan time). **Stop** → end the run as the procedure says.

```bash
source ~/.n1/preamble.sh
LT=$(n1_config_val '.localTesting.enabled' "${N1_HOME}/config.json")
echo '{"layer":"envelope","run_id":"'"$N1_RUN_ID"'","n1_version":"'"$N1_VERSION"'","ticket_id":"'"$ID"'","branch":"'"$BRANCH"'","started_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","config_snapshot":{"test_coverage_tier":"maintain","local_testing_enabled":'"${LT:-true}"',"plan_review_enabled":true}}' >> "${N1_HOME}/memory/$ID/telemetry/raw/steps/$N1_RUN_ID.jsonl"
```

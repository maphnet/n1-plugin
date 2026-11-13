#!/usr/bin/env bash
# lib/ticket-step.sh (N1-476): deterministic bodies of skills/n1-start/steps/ticket.md blocks.
# Requires lib/preamble.sh first. Needs $N1_HOME and $ID. Never calls n1_step_begin/n1_step_end (ticket.md keeps them).
# Input: the product-analyst return, written by the model to $N1_HOME/memory/$ID/ticket-return.md with the file-write
# mechanism; tracker text never appears in a shell string.
_n1_ticket_step_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_n1_ticket_step_dir/context.sh"

_n1_ticket_parse() {
    # Usage: _n1_ticket_parse <type override> — sets the caller's locals (dynamic scope) from ticket-return.md:
    # RET INTAKE_RESULT TITLE TYPE_OVERRIDE RESOLVED_TYPE TYPE_MATCHED_BY CLOUD_ID LINKED_ERROR_URL ISSUE_TYPE SUBTASK_COUNT ORIGINAL_STATUS.
    local rt="$N1_HOME/memory/$ID/.resolved-type" TAGS_CSV TYPE_FIELD
    case "$1" in *[!a-z-]*) TYPE_OVERRIDE="" ;; *) TYPE_OVERRIDE="$1" ;; esac  # type names only; a placeholder is ignored
    RET=""; [ -f "$N1_HOME/memory/$ID/ticket-return.md" ] && RET=$(cat "$N1_HOME/memory/$ID/ticket-return.md")
    INTAKE_RESULT=$(grep -m1 '^intake-result: ' <<<"$RET" | sed 's/^intake-result: //')
    [ -n "$INTAKE_RESULT" ] || INTAKE_RESULT='{"title":null,"tags":[],"type":"task"}'
    TITLE=$(jq -r '.title // empty' <<<"$INTAKE_RESULT" 2>/dev/null)
    CLOUD_ID=$(jq -r '.cloudId // empty' <<<"$INTAKE_RESULT" 2>/dev/null)
    LINKED_ERROR_URL=$(jq -r '.linked_error.issueUrl // empty' <<<"$INTAKE_RESULT" 2>/dev/null)
    TAGS_CSV=$(echo "$INTAKE_RESULT" | sed 's/.*"tags" *: *\[//;s/\].*//' | tr -d '"' | tr -d ' ')
    TYPE_FIELD=$(echo "$INTAKE_RESULT" | sed 's/.*[,{] *"type": *"\([^"]*\)".*/\1/')
    [ -n "$LINKED_ERROR_URL" ] && TYPE_FIELD=bug
    n1_resolve_type "$TITLE" "$TAGS_CSV" "$TYPE_FIELD" "$TYPE_OVERRIDE" > "$rt" 2>/dev/null || true
    RESOLVED_TYPE=$(cat "$rt" 2>/dev/null); rm -f "$rt"; TYPE_MATCHED_BY="${N1_TYPE_MATCHED_BY:-}"
    ISSUE_TYPE=$(echo "$INTAKE_RESULT" | sed -n 's/.*"issue_type": *"\([^"]*\)".*/\1/p' | tr '[:upper:]' '[:lower:]')
    SUBTASK_COUNT=$(echo "$INTAKE_RESULT" | sed -n 's/.*"subtask_count": *\([0-9]*\).*/\1/p')
    ORIGINAL_STATUS=$(echo "$INTAKE_RESULT" | sed -n 's/.*"original_status": *"\([^"]*\)".*/\1/p')
}

n1_ticket_intake() {
    # Usage: n1_ticket_intake '<type override or empty>' — prints TITLE=, CLOUD_ID=, LINKED_ERROR_URL=, RESOLVED_TYPE=,
    # TYPE_MATCHED_BY=, INVESTIGATION_DETECTED=, ISSUE_TYPE=, IS_STORY=, ORIGINAL_STATUS=, QUEUE_RUN_ID=, HEADLESS=.
    local RET INTAKE_RESULT TITLE TYPE_OVERRIDE RESOLVED_TYPE TYPE_MATCHED_BY CLOUD_ID LINKED_ERROR_URL ISSUE_TYPE SUBTASK_COUNT ORIGINAL_STATUS
    local INVESTIGATION_DETECTED=false IS_STORY=false
    _n1_ticket_parse "${1:-}"
    [ "$RESOLVED_TYPE" = "investigation" ] && INVESTIGATION_DETECTED=true || { [ -z "$TYPE_OVERRIDE" ] && n1_title_hints_investigation "$TITLE" && echo "Hint: title looks like investigation; re-run with --type investigation; continuing as ${RESOLVED_TYPE}."; }
    case "$ISSUE_TYPE" in epic) IS_STORY=true ;; story) ;; *) [ "${SUBTASK_COUNT:-0}" -gt 0 ] && ! grep -q '### Parent Context' "$N1_HOME/memory/$ID/ticket.md" 2>/dev/null && IS_STORY=true ;; esac
    printf 'TITLE=%s\nCLOUD_ID=%s\nLINKED_ERROR_URL=%s\n' "$TITLE" "$CLOUD_ID" "$LINKED_ERROR_URL"
    printf 'RESOLVED_TYPE=%s\nTYPE_MATCHED_BY=%s\nINVESTIGATION_DETECTED=%s\n' "$RESOLVED_TYPE" "$TYPE_MATCHED_BY" "$INVESTIGATION_DETECTED"
    printf 'ISSUE_TYPE=%s\nIS_STORY=%s\nORIGINAL_STATUS=%s\n' "$ISSUE_TYPE" "$IS_STORY" "$ORIGINAL_STATUS"
    printf 'QUEUE_RUN_ID=%s\nHEADLESS=%s\n' "${N1_QUEUE_RUN_ID:-}" "${N1_HEADLESS:-}"
    return 0
}

_n1_ticket_write_url() {
    # Writes overview.md ticket_url from $N1_HOME/memory/$ID/instance-url.txt (the tracker's base_url, written by the model with the
    # file-write mechanism) and tracker.type. Absent file, unknown type or a URL with shell/space characters: write nothing.
    local f="$N1_HOME/memory/$ID/instance-url.txt" base ttype path
    [ -f "$f" ] || return 0
    base=$(head -n1 "$f" | tr -d '\r'); base="${base%/}"; rm -f "$f"
    case "$base" in http://*|https://*) ;; *) return 0 ;; esac
    case "$base" in *[[:space:]\'\"\$\`\\]*) return 0 ;; esac
    ttype=$(n1_config_val ".tracker.type")
    case "$ttype" in youtrack) path=issue ;; jira) path=browse ;; *) return 0 ;; esac
    n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "ticket_url" "$base/$path/$ID"
}

n1_ticket_persist() {
    # Usage: n1_ticket_persist '<type override or empty>' — after the final <ID>: ticket.md dependency check, return signals,
    # overview.md frontmatter (tier, type, type_matched_by, story, original_status, story_convert), ticket context.
    # Prints TIER= (return's tier:, default standard), SESSION_NAME=, the four assign config values and any n1_assign_gap_warn line.
    local RET INTAKE_RESULT TITLE TYPE_OVERRIDE RESOLVED_TYPE TYPE_MATCHED_BY CLOUD_ID LINKED_ERROR_URL ISSUE_TYPE SUBTASK_COUNT ORIGINAL_STATUS
    local SIGNAL_LINE PAIRS MAX SESSION_NAME SC TIER TYPE ASSIGN_TO_CREATOR GET_USER_OP ASSIGN_OP READ_OP
    _n1_ticket_parse "${1:-}"
    n1_verify_dependencies "$N1_HOME/memory/$ID" ticket.md
    SIGNAL_LINE=$(grep -m1 '^n1:signals ' <<<"$RET")
    # shellcheck disable=SC2086 # PAIRS splits into key=value words on purpose
    [ -n "$SIGNAL_LINE" ] && { PAIRS=$(sed 's/^n1:signals //' <<<"$SIGNAL_LINE"); n1_write_signals "$N1_HOME/memory/$ID/ticket.md" $PAIRS; }
    TITLE=$(grep -m1 '^title: ' <<<"$RET" | sed 's/^title: //')
    TIER=$(grep -m1 '^tier: ' <<<"$RET" | sed 's/^tier: *//'); TYPE="$RESOLVED_TYPE"
    case "$TIER" in simple|standard|complex) ;; *) TIER=standard ;; esac # ticket-context.sh is sourced later: enum only
    n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier" "$TIER"
    MAX=$(( 50 - ${#ID} - 1 )); SESSION_NAME="$ID${TITLE:+ ${TITLE:0:$MAX}}"
    n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "type" "$RESOLVED_TYPE"
    n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "type_matched_by" "$TYPE_MATCHED_BY"
    [ -n "${N1_STORY_ID:-}" ] && n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "story" "$N1_STORY_ID"
    [ -n "$ORIGINAL_STATUS" ] && [ "$ORIGINAL_STATUS" != "Not specified" ] && n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "original_status" "$ORIGINAL_STATUS"
    SC=$(tr -d '\\\r\n' 2>/dev/null < "$N1_HOME/memory/$ID/.story-convert"); rm -f "$N1_HOME/memory/$ID/.story-convert"; [ -n "$SC" ] && n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "story_convert" "$SC"
    _n1_ticket_write_url
    n1_write_context
    echo "TIER=$TIER"; echo "SESSION_NAME=$SESSION_NAME"
    ASSIGN_TO_CREATOR=$(n1_config_val ".tracker.assignToCreator"); GET_USER_OP=$(n1_config_val ".tracker.operations.getCurrentUser"); ASSIGN_OP=$(n1_config_val ".tracker.operations.assign"); READ_OP=$(n1_config_val ".tracker.operations.readTicket")
    printf 'ASSIGN_TO_CREATOR=%s\nGET_USER_OP=%s\nASSIGN_OP=%s\nREAD_OP=%s\n' "$ASSIGN_TO_CREATOR" "$GET_USER_OP" "$ASSIGN_OP" "$READ_OP"
    n1_assign_gap_warn
    return 0
}

n1_ticket_envelope() {
    # Usage: n1_ticket_envelope — appends the run envelope (config_snapshot) to the step telemetry when N1_RUN_ID is set.
    local LT
    LT=$(n1_config_val '.localTesting.enabled' "${N1_HOME}/config.json")
    [ -n "${N1_RUN_ID:-}" ] && echo '{"layer":"envelope","run_id":"'"$N1_RUN_ID"'","n1_version":"'"${N1_VERSION:-}"'","ticket_id":"'"$ID"'","branch":"'"${BRANCH:-}"'","started_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","config_snapshot":{"test_coverage_tier":"maintain","local_testing_enabled":'"${LT:-true}"',"plan_review_enabled":true}}' >> "${N1_HOME}/memory/$ID/telemetry/raw/steps/$N1_RUN_ID.jsonl"
    return 0
}

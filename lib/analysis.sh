#!/usr/bin/env bash
# lib/analysis.sh (N1-436): deterministic bodies of skills/n1-start/steps/analysis.md entry and post-SA blocks.
# Requires lib/preamble.sh first (config.sh, step.sh, validation.sh). Needs $N1_HOME and $ID.
# The step text keeps n1_step_begin/n1_step_end literal (tests/test_step_telemetry.sh) and keys on the printed lines.
_n1_analysis_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_n1_analysis_dir/cache.sh"; source "$_n1_analysis_dir/related.sh"; source "$_n1_analysis_dir/context.sh"

n1_analysis_entry() {
    # Usage: n1_analysis_entry — sets and persists TIER/TYPE/DESC_QUALITY/LITE_MODE (n1_write_context), records
    # lite-analysis-gate, prints RELATED_ENABLED=, LITE_MODE= CACHE_STATE=, SA_MODEL= SA_EFFORT=, SNAPSHOT_PATH=, PROJECT_MAP_PATH=.
    local CACHE_ENABLED SNAPSHOT_PATH CACHE_STATE SA_MODEL SA_EFFORT RELATED_ENABLED PROJECT_MAP_PATH
    CACHE_ENABLED=$(n1_config_val ".analysisCache.enabled" "$N1_HOME/config.json"); CACHE_ENABLED="${CACHE_ENABLED:-true}"
    SNAPSHOT_PATH=$(n1_snapshot_path "$N1_HOME"); CACHE_STATE="cold"
    [ "$CACHE_ENABLED" = "true" ] && CACHE_STATE=$(n1_snapshot_check_freshness "$SNAPSHOT_PATH" "$N1_HOME/config.json")
    TIER=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier"); TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
    DESC_QUALITY=$(n1_read_signal "$N1_HOME/memory/$ID/ticket.md" "description_quality"); LITE_MODE=false
    [ "$TIER" = "simple" ] && { [ "$DESC_QUALITY" = "adequate" ] || [ "$DESC_QUALITY" = "weak" ]; } && { [ "$TYPE" = "task" ] || [ "$TYPE" = "chore" ]; } && LITE_MODE=true
    n1_record_decision lite-analysis-gate "$LITE_MODE" '{"all":[{"frontmatter":"tier","eq":"simple"},{"signal":"ticket.description_quality","neq":"empty"},{"signal":"ticket.description_quality","neq":"skeletal"},{"any":[{"frontmatter":"type","eq":"task"},{"frontmatter":"type","eq":"chore"}]}]}' "tier=$TIER" "type=$TYPE" "quality=$DESC_QUALITY"
    IFS=$'\t' read -r SA_MODEL SA_EFFORT < <(n1_resolve_agent solution-architect analysis)
    n1_write_context
    RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json"); PROJECT_MAP_PATH=$(n1_project_map_path "$N1_HOME"); echo "RELATED_ENABLED=$RELATED_ENABLED"
    echo "LITE_MODE=$LITE_MODE CACHE_STATE=$CACHE_STATE"
    echo "SA_MODEL=$SA_MODEL SA_EFFORT=$SA_EFFORT"
    echo "SNAPSHOT_PATH=$SNAPSHOT_PATH"
    echo "PROJECT_MAP_PATH=$PROJECT_MAP_PATH"
}

n1_analysis_finalize() {
    # Usage: n1_analysis_finalize < <SA return text> — persistence checks, drift, signal writes,
    # simple-path gate (n1_write_context); prints the status lines analysis.md keys on and the context block.
    # ticket_url frontmatter is owned by the ticket step (N1-476 SEC-1: no tracker text in a shell argument).
    local AGENT_OUTPUT CACHE_ENABLED SNAPSHOT_PATH PROJECT_MAP_PATH CACHE_STATE DRIFT CONTEXT_BLOCK
    local SIGNAL_LINE PAIRS ESCALATED SELF_RESOLVED BLAST FILES_CHANGED_A SECURITY HAS_ROOT_CAUSE CONTRADICTIONS XREPO_PENDING_FILE
    AGENT_OUTPUT=$(cat)
    n1_verify_dependencies "$N1_HOME/memory/$ID" analysis.md; n1_read_context
    CACHE_ENABLED=$(n1_config_val ".analysisCache.enabled" "$N1_HOME/config.json"); CACHE_ENABLED="${CACHE_ENABLED:-true}"
    SNAPSHOT_PATH=$(n1_snapshot_path "$N1_HOME"); PROJECT_MAP_PATH=$(n1_project_map_path "$N1_HOME"); CACHE_STATE="cold"
    [ "$CACHE_ENABLED" = "true" ] && CACHE_STATE=$(n1_snapshot_check_freshness "$SNAPSHOT_PATH" "$N1_HOME/config.json") || true
    { [ ! -f "$SNAPSHOT_PATH" ] || [ ! -s "$SNAPSHOT_PATH" ]; } && echo "Snapshot persistence failed."
    [ "$CACHE_STATE" != "fresh" ] && [ "$CACHE_ENABLED" = "true" ] && [ "$LITE_MODE" != "true" ] && { [ ! -f "$PROJECT_MAP_PATH" ] || [ ! -s "$PROJECT_MAP_PATH" ]; } && echo "Project map persistence failed."
    DRIFT=$(echo "$AGENT_OUTPUT" | grep -m1 '^SNAPSHOT_DRIFT:'); [ -n "$DRIFT" ] && rm -f "$SNAPSHOT_PATH"
    CONTEXT_BLOCK=$(echo "$AGENT_OUTPUT" | sed -n '/^context: |$/,/^[^ ]/{/^context: |$/d;/^[^ ]/d;s/^  //;p}')
    SIGNAL_LINE=$(echo "$AGENT_OUTPUT" | grep -m1 '^n1:signals ')
    # shellcheck disable=SC2086 # PAIRS splits into key=value words on purpose
    [ -n "$SIGNAL_LINE" ] && { PAIRS=$(echo "$SIGNAL_LINE" | sed 's/^n1:signals //'); n1_write_signals "$N1_HOME/memory/$ID/analysis.md" $PAIRS; }
    ESCALATED=$(echo "$AGENT_OUTPUT" | grep -m1 '^LITE_ESCALATED:'); [ -n "$ESCALATED" ] && echo "$ESCALATED"
    SELF_RESOLVED=$(grep -c '<!-- n1:resolved:' "$N1_HOME/memory/$ID/analysis.md" 2>/dev/null | head -1); SELF_RESOLVED="${SELF_RESOLVED:-0}"
    [ "$SELF_RESOLVED" -gt 0 ] && n1_write_signals "$N1_HOME/memory/$ID/analysis.md" "self_resolved=$SELF_RESOLVED"
    TYPE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type")
    BLAST=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "blast_radius"); FILES_CHANGED_A=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "files_changed")
    SECURITY=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "security_relevant"); HAS_ROOT_CAUSE=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "has_bug_root_cause")
    CONTRADICTIONS=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "ticket_contradictions"); CONTRADICTIONS="${CONTRADICTIONS:-0}"
    [ "$CONTRADICTIONS" -gt 0 ] && echo "Ticket contradictions found: $CONTRADICTIONS"
    SIMPLE_PATH=false; [ "$TIER" = "simple" ] && [ "$BLAST" = "low" ] && [ "${FILES_CHANGED_A:-999}" -lt 3 ] && [ "$SECURITY" != "true" ] && { [ "$TYPE" = "task" ] || [ "$TYPE" = "chore" ] || { [ "$TYPE" = "bug" ] && [ "$HAS_ROOT_CAUSE" = "true" ]; }; } && SIMPLE_PATH=true
    n1_record_decision simple-path "$SIMPLE_PATH" '{"all":[{"frontmatter":"tier","eq":"simple"},{"signal":"analysis.blast_radius","eq":"low"},{"signal":"analysis.files_changed","lt":3},{"signal":"analysis.security_relevant","neq":"true"},{"any":[{"frontmatter":"type","eq":"task"},{"frontmatter":"type","eq":"chore"},{"all":[{"frontmatter":"type","eq":"bug"},{"signal":"analysis.has_bug_root_cause","eq":"true"}]}]}]}' "tier=$TIER" "type=$TYPE" "blast=$BLAST" "files_changed=${FILES_CHANGED_A:-}" "security_relevant=${SECURITY:-}" "has_bug_root_cause=${HAS_ROOT_CAUSE:-}"
    n1_write_context
    [ "$SIMPLE_PATH" = "true" ] && echo "Simple-path: skipping brainstorm and plan"
    XREPO_PENDING_FILE="$N1_HOME/memory/$ID/xrepo-pending.tsv"; rm -f "$XREPO_PENDING_FILE"
    [ -n "$DRIFT" ] && echo "$DRIFT"
    echo "SELF_RESOLVED=$SELF_RESOLVED SIMPLE_PATH=$SIMPLE_PATH"
    [ -n "$CONTEXT_BLOCK" ] && printf 'CONTEXT_BLOCK<<\n%s\nCONTEXT_BLOCK>>\n' "$CONTEXT_BLOCK"
    return 0
}

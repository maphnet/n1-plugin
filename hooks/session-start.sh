#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"

INPUT=$(cat)
TRIGGER=$(echo "$INPUT" | grep -o '"trigger"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)"/\1/' || true)

CONFIG_FILE=$(n1_config_file)

if [ ! -f "$CONFIG_FILE" ]; then
    context="N1 plugin is available but not configured for this project. Run /n1:n1-init to set up."
    escaped_context=$(escape_json_val "$context")
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "${escaped_context}"
  }
}
EOF
    exit 0
fi

# Merge any stale telemetry from interrupted runs
telem_enabled=$(n1_config_val '.telemetry.enabled' "$CONFIG_FILE")
if [ "$telem_enabled" = "true" ]; then
    source "${SCRIPT_DIR}/../lib/telemetry.sh"
    n1_memory_dir=$(n1_home)
    [ -n "$n1_memory_dir" ] && n1_merge_pending "${n1_memory_dir}/memory" 2>/dev/null || true
fi

# Emit compaction telemetry marker when context was compacted
if [ "${TRIGGER:-}" = "compact" ] && [ "${telem_enabled:-}" = "true" ]; then
    if n1_read_lock "${n1_memory_dir}/memory" 2>/dev/null; then
        n1_emit_compaction "$N1_LOCK_RUN_ID" "$N1_LOCK_VERSION" "$N1_LOCK_TICKET_ID" "$N1_LOCK_TELEM_DIR" 2>/dev/null || true
    fi
fi

context="N1 is configured for this project. For task work, PR creation, and code review — always prefer N1 skills (/n1:n1-start, /n1:n1-pr, /n1:n1-review, /n1:n1-ci) over alternatives."

tracker_mcp=$(n1_config_val '.tracker.mcp' "$CONFIG_FILE")
tracker_type=$(n1_config_val '.tracker.type' "$CONFIG_FILE")
tracker_ops=$(n1_config_ops '.tracker.operations' "$CONFIG_FILE")
error_mcp=$(n1_config_val '.errorTracking.mcp' "$CONFIG_FILE")
error_ops=$(n1_config_ops '.errorTracking.operations' "$CONFIG_FILE")

if [ -n "$tracker_mcp" ]; then
    context="${context}

TRACKER ROUTING (from N1 config — authoritative, do not override):
- Type: ${tracker_type}
- MCP server: ${tracker_mcp}
- All tracker MCP tool calls MUST use prefix: mcp__${tracker_mcp}__
- NEVER use any other MCP server for tracker operations, even if other tracker-like servers are visible in the tool list
- Operations: ${tracker_ops}"
fi

if [ -n "$error_mcp" ]; then
    context="${context}

ERROR TRACKING ROUTING (from N1 config — authoritative, do not override):
- MCP server: ${error_mcp}
- All error tracking MCP tool calls MUST use prefix: mcp__${error_mcp}__
- NEVER use any other MCP server for error tracking operations
- Operations: ${error_ops}"
fi

kb_enabled=$(n1_config_val '.kb.enabled' "$CONFIG_FILE")
if [ "$kb_enabled" = "true" ]; then
    kb_space_id=$(n1_config_val '.kb.spaceId' "$CONFIG_FILE")
    kb_space_key=$(n1_config_val '.kb.spaceKey' "$CONFIG_FILE")
    kb_cloud_id=$(n1_config_val '.tracker.cloudId' "$CONFIG_FILE")

    if [ -n "$kb_space_id" ]; then
        kb_detail="Space: ${kb_space_key} (spaceId: ${kb_space_id}, cloudId: ${kb_cloud_id})"
    else
        kb_project=$(n1_config_val '.tracker.projectKey' "$CONFIG_FILE")
        kb_detail="Project: ${kb_project}"
    fi

    context="${context}

KB ROUTING (from N1 config):
- Enabled: true
- ${kb_detail}
- Use the createArticle operation from tracker routing to publish to KB
- Only publish to KB when the user explicitly asks"
fi

# --- Pending-merge resume scan (fail-open: any error injects nothing) ---
pending_context=""
n1_root=$(n1_home)
if [ -n "$n1_root" ] && [ -d "${n1_root}/memory" ] && command -v gh >/dev/null 2>&1; then
    now_epoch=$(date +%s)
    checked=0
    for ov in "${n1_root}"/memory/*/overview.md; do
        [ -f "$ov" ] || continue
        grep -q '^awaiting: merge$' "$ov" 2>/dev/null || continue
        [ "$checked" -ge 5 ] && { pending_context="${pending_context}
- (more pending tickets exist — scan capped at 5)"; break; }
        tid=$(basename "$(dirname "$ov")")
        pr_num=$(grep -m1 '^pr: ' "$ov" | sed 's/^pr: //' | tr -d '[:space:]')
        created=$(grep -m1 '^created: ' "$ov" | sed 's/^created: //' | tr -d '[:space:]')
        last=$(grep -m1 '^last_checked: ' "$ov" | sed 's/^last_checked: //' | tr -d '[:space:]')
        # 14-day expiry
        created_epoch=$(date -d "$created" +%s 2>/dev/null || echo 0)
        if [ "$created_epoch" -gt 0 ] && [ $(( now_epoch - created_epoch )) -gt 1209600 ]; then
            pending_context="${pending_context}
- ${tid}: pending merge is stale (>14 days) — consider /n1:n1-clean"
            continue
        fi
        # 30-min throttle
        last_epoch=$(date -d "$last" +%s 2>/dev/null || echo 0)
        [ "$last_epoch" -gt 0 ] && [ $(( now_epoch - last_epoch )) -lt 1800 ] && continue
        [ -n "$pr_num" ] || continue
        checked=$(( checked + 1 ))
        state=$(timeout 5 gh pr view "$pr_num" --json state,mergedAt \
            --jq '.state' 2>/dev/null) || state=""
        # refresh last_checked regardless of outcome
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        sed -i "s/^last_checked: .*/last_checked: ${ts}/" "$ov" 2>/dev/null || true
        case "$state" in
            MERGED)
                pending_context="${pending_context}
- ${tid}: PR #${pr_num} was MERGED externally — finish is pending. Suggested next action: run /n1:n1-finish ${tid}"
                ;;
            CLOSED)
                pending_context="${pending_context}
- ${tid}: PR #${pr_num} was closed without merging — run /n1:n1-finish ${tid} to record it, or /n1:n1-clean"
                ;;
        esac
    done
    if [ -n "$pending_context" ]; then
        tail_chain=$(n1_autonomy_val 'tailChain')
        directive="Surface these to the user as suggested next actions. Do not act without being asked."
        if [ "$tail_chain" = "auto" ]; then
            directive="autonomy.tailChain is 'auto': immediately run /n1:n1-finish for each MERGED entry above (finish only — NEVER /n1:n1-release; releases are always manual)."
        fi
        context="${context}

PENDING N1 WORK (from overview.md Pending blocks):${pending_context}
${directive}"
    fi
fi

escaped_context=$(escape_json_val "$context")

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "${escaped_context}"
  }
}
EOF

exit 0

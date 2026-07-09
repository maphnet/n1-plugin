#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"

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

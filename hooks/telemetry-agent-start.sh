#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"
source "${SCRIPT_DIR}/../lib/telemetry.sh"

N1_HOME=$(n1_home)
INPUT=$(cat)
# N1-315: an Orca queue child beacons its phase to the coordinator. Runs before the no-lock exit below.
if source "${SCRIPT_DIR}/../lib/orca-queue.sh" 2>/dev/null && n1_orca_child_env "${CLAUDE_PROJECT_DIR:-$PWD}" "$(printf '%s' "$INPUT" | n1_hook_field session_id)"; then
    source "${SCRIPT_DIR}/../lib/frontmatter.sh"
    n1_orca_beacon start "$(printf '%s' "$INPUT" | n1_hook_field agent_type)" || true
fi
N1_SESSION_ID=$(printf '%s' "$INPUT" | n1_hook_field session_id)
export N1_SESSION_ID="${N1_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
n1_read_lock "$N1_HOME/memory" || exit 0

AGENT_ID=$(printf '%s' "$INPUT" | n1_hook_field agent_id)
AGENT_TYPE=$(printf '%s' "$INPUT" | n1_hook_field agent_type)

[ -n "$(n1_persona_name "$AGENT_TYPE")" ] || exit 0
[ -n "$AGENT_ID" ] || exit 0

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUTFILE="${N1_LOCK_TELEM_DIR}/raw/agents/${N1_LOCK_RUN_ID}.jsonl"
mkdir -p "$(dirname "$OUTFILE")"

echo "{\"run_id\":\"$(escape_json_val "$N1_LOCK_RUN_ID")\",\"n1_version\":\"$(escape_json_val "$N1_LOCK_VERSION")\",\"ticket_id\":\"$(escape_json_val "$N1_LOCK_TICKET_ID")\",\"layer\":\"agent\",\"event\":\"start\",\"agent_id\":\"$(escape_json_val "$AGENT_ID")\",\"agent_type\":\"$(escape_json_val "$AGENT_TYPE")\",\"started_at\":\"${TIMESTAMP}\"}" >> "$OUTFILE"

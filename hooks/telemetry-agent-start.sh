#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"
source "${SCRIPT_DIR}/../lib/telemetry.sh"

N1_HOME=$(n1_home)
n1_read_lock "$N1_HOME/memory" || exit 0

INPUT=$(cat)

AGENT_ID=$(printf '%s' "$INPUT" | n1_hook_field agent_id)
AGENT_TYPE=$(printf '%s' "$INPUT" | n1_hook_field agent_type)

[ -n "$(n1_persona_name "$AGENT_TYPE")" ] || exit 0
[ -n "$AGENT_ID" ] || exit 0

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUTFILE="${N1_LOCK_TELEM_DIR}/raw/agents/${N1_LOCK_RUN_ID}.jsonl"
mkdir -p "$(dirname "$OUTFILE")"

echo "{\"run_id\":\"$(escape_json_val "$N1_LOCK_RUN_ID")\",\"n1_version\":\"$(escape_json_val "$N1_LOCK_VERSION")\",\"ticket_id\":\"$(escape_json_val "$N1_LOCK_TICKET_ID")\",\"layer\":\"agent\",\"event\":\"start\",\"agent_id\":\"$(escape_json_val "$AGENT_ID")\",\"agent_type\":\"$(escape_json_val "$AGENT_TYPE")\",\"started_at\":\"${TIMESTAMP}\"}" >> "$OUTFILE"

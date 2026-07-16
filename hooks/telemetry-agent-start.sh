#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"
source "${SCRIPT_DIR}/../lib/telemetry.sh"

N1_HOME=$(n1_home)
n1_read_lock "$N1_HOME/memory" || exit 0

INPUT=$(cat)

if command -v jq >/dev/null 2>&1; then
    AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
    AGENT_TYPE=$(echo "$INPUT" | jq -r '.subagent_type // .agent_type // empty' 2>/dev/null || true)
else
    AGENT_ID=$(echo "$INPUT" | grep -o '"agent_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' || true)
    AGENT_TYPE=$(echo "$INPUT" | grep -o '"subagent_type"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' || true)
    if [ -z "$AGENT_TYPE" ]; then
        AGENT_TYPE=$(echo "$INPUT" | grep -o '"agent_type"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' || true)
    fi
fi

[[ "$AGENT_TYPE" == n1:* ]] || exit 0
[ -n "$AGENT_ID" ] || exit 0

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUTFILE="${N1_LOCK_TELEM_DIR}/raw/agents/${N1_LOCK_RUN_ID}.jsonl"
mkdir -p "$(dirname "$OUTFILE")"

echo "{\"run_id\":\"$(escape_json_val "$N1_LOCK_RUN_ID")\",\"n1_version\":\"$(escape_json_val "$N1_LOCK_VERSION")\",\"ticket_id\":\"$(escape_json_val "$N1_LOCK_TICKET_ID")\",\"layer\":\"agent\",\"event\":\"start\",\"agent_id\":\"$(escape_json_val "$AGENT_ID")\",\"agent_type\":\"$(escape_json_val "$AGENT_TYPE")\",\"started_at\":\"${TIMESTAMP}\"}" >> "$OUTFILE"

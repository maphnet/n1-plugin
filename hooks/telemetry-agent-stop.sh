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
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | n1_hook_field transcript_path)

SESSION_TRANSCRIPT_PATH="$TRANSCRIPT_PATH"

[ -n "$(n1_persona_name "$AGENT_TYPE")" ] || exit 0
[ -n "$AGENT_ID" ] || exit 0

# The payload's transcript_path is the PARENT session transcript; the subagent's own
# transcript lives at <parent-minus-.jsonl>/subagents/agent-<agent_id>.jsonl. Prefer it —
# otherwise every agent gets attributed the whole session's token totals.
if [ -n "$TRANSCRIPT_PATH" ]; then
    AGENT_TRANSCRIPT="${TRANSCRIPT_PATH%.jsonl}/subagents/agent-${AGENT_ID}.jsonl"
    [ -f "$AGENT_TRANSCRIPT" ] && TRANSCRIPT_PATH="$AGENT_TRANSCRIPT"
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUTFILE="${N1_LOCK_TELEM_DIR}/raw/agents/${N1_LOCK_RUN_ID}.jsonl"
mkdir -p "$(dirname "$OUTFILE")"

echo "{\"run_id\":\"$(escape_json_val "$N1_LOCK_RUN_ID")\",\"n1_version\":\"$(escape_json_val "$N1_LOCK_VERSION")\",\"ticket_id\":\"$(escape_json_val "$N1_LOCK_TICKET_ID")\",\"layer\":\"agent\",\"event\":\"stop\",\"agent_id\":\"$(escape_json_val "$AGENT_ID")\",\"agent_type\":\"$(escape_json_val "$AGENT_TYPE")\",\"completed_at\":\"${TIMESTAMP}\",\"transcript_path\":\"$(escape_json_val "$TRANSCRIPT_PATH")\",\"session_transcript_path\":\"$(escape_json_val "$SESSION_TRANSCRIPT_PATH")\"}" >> "$OUTFILE"

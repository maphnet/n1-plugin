#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"
source "${SCRIPT_DIR}/../lib/telemetry.sh"

N1_HOME=$(n1_home)
INPUT=$(cat)
# Run before telemetry's early exit: standalone PRs and disabled telemetry also
# need receipts. A continuation block must preserve the current run lock.
REVIEW_STOP=$(printf '%s' "$INPUT" | bash "${SCRIPT_DIR}/pr-review-stop.sh")
if [ -n "$REVIEW_STOP" ]; then
    printf '%s\n' "$REVIEW_STOP"
    exit 0
fi
N1_SESSION_ID=$(printf '%s' "$INPUT" | n1_hook_field session_id)
export N1_SESSION_ID="${N1_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
n1_read_lock "$N1_HOME/memory" || exit 0

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUTFILE="${N1_LOCK_TELEM_DIR}/raw/steps/${N1_LOCK_RUN_ID}.jsonl"
mkdir -p "$(dirname "$OUTFILE")"

# Parent usage is available even when no subagent hook was delivered.
TRANSCRIPT=$(printf '%s' "$INPUT" | n1_hook_field transcript_path)
if [ -n "$TRANSCRIPT" ]; then
    printf '{"layer":"session","session_id":"%s","session_transcript_path":"%s"}\n' \
        "$(escape_json_val "$N1_SESSION_ID")" "$(escape_json_val "$TRANSCRIPT")" >> "$OUTFILE"
fi

AGENTS_FILE="${N1_LOCK_TELEM_DIR}/raw/agents/${N1_LOCK_RUN_ID}.jsonl"
HAS_TERMINAL_ENVELOPE=false
grep -q '"layer"[[:space:]]*:[[:space:]]*"envelope_close"' "$OUTFILE" 2>/dev/null && HAS_TERMINAL_ENVELOPE=true

ACTIVE_RUN_FILE=$(n1_active_run_file)
ACTIVE_RUN_ID=""
if [ -f "$ACTIVE_RUN_FILE" ]; then
    ACTIVE_RUN_ID=$(n1_hook_field runId < "$ACTIVE_RUN_FILE")
fi
ACTIVE_SELECTED_RUN=false
[ "$ACTIVE_RUN_ID" = "$N1_LOCK_RUN_ID" ] && [ "$HAS_TERMINAL_ENVELOPE" = false ] && ACTIVE_SELECTED_RUN=true

# A matching session-local pointer owns this run until explicit finalization
# records a terminal envelope. Pending agents retain the existing wait guard.
if [ "$ACTIVE_SELECTED_RUN" = true ] || n1_run_has_pending_agent "$AGENTS_FILE"; then
    exit 0
fi

# Explicit pipeline finalization may already have recorded its outcome.
if [ "$HAS_TERMINAL_ENVELOPE" = false ]; then

# Read tier and type from overview.md if it exists
MEM_DIR="${N1_HOME}/memory/${N1_LOCK_TICKET_ID}"
RESOLVED_TYPE=""
ESTIMATED_TIER=""
OVERVIEW="${MEM_DIR}/overview.md"
if [ -f "$OVERVIEW" ]; then
    source "${SCRIPT_DIR}/../lib/frontmatter.sh"
    RESOLVED_TYPE=$(n1_read_frontmatter "$OVERVIEW" "type" 2>/dev/null || true)
    ESTIMATED_TIER=$(n1_read_frontmatter "$OVERVIEW" "tier" 2>/dev/null || true)
fi

printf '{"layer":"envelope_close","run_id":"%s","n1_version":"%s","ticket_id":"%s","completed_at":"%s","final_outcome":"abandoned","type":"%s","estimated_tier":"%s"}\n' \
    "$(escape_json_val "$N1_LOCK_RUN_ID")" \
    "$(escape_json_val "$N1_LOCK_VERSION")" \
    "$(escape_json_val "$N1_LOCK_TICKET_ID")" \
    "$TIMESTAMP" \
    "$(escape_json_val "${RESOLVED_TYPE:-}")" \
    "$(escape_json_val "${ESTIMATED_TIER:-}")" \
    >> "$OUTFILE"
fi

# Trigger merge
bash "${SCRIPT_DIR}/telemetry-merge.sh" "$N1_LOCK_RUN_ID" "$N1_LOCK_TELEM_DIR" 2>/dev/null || true

# Remove lock if merge succeeded (mirrors finalize.md pattern)
MERGED="${N1_LOCK_TELEM_DIR}/runs/${N1_LOCK_RUN_ID}.jsonl"
[ -s "$MERGED" ] && n1_remove_run_lock "$N1_LOCK_TELEM_DIR" "$N1_LOCK_RUN_ID"

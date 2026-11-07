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
# N1-225: an Orca queue child reports its stop point (worker_done) to the queue coordinator once.
if source "${SCRIPT_DIR}/../lib/orca-queue.sh" 2>/dev/null && n1_orca_child_env "${CLAUDE_PROJECT_DIR:-$PWD}" "$(printf '%s' "$INPUT" | n1_hook_field session_id)"; then
    source "${SCRIPT_DIR}/../lib/frontmatter.sh"
    source "${SCRIPT_DIR}/../lib/queue.sh"
    n1_orca_beacon tick || true   # N1-315: before worker_done, so a terminal worker_done follows the last beacon
    n1_orca_worker_done || true
fi
N1_SESSION_ID=$(printf '%s' "$INPUT" | n1_hook_field session_id)
export N1_SESSION_ID="${N1_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
n1_read_lock "$N1_HOME/memory" || exit 0

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

# No terminal envelope yet: record abandoned. Either way re-merge (orchestrator.tail, N1-229)
# and drop the lock once the merged file exists.
n1_abandon_run "$N1_LOCK_TELEM_DIR" "$N1_LOCK_RUN_ID" "$N1_LOCK_TICKET_ID" "$N1_LOCK_VERSION"

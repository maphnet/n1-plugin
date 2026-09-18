#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"
source "${SCRIPT_DIR}/../lib/telemetry.sh"
[ "$(n1_host)" != codex ] || trap 'printf "{}\n"' EXIT

N1_HOME=$(n1_home)
INPUT=$(cat)
N1_SESSION_ID=$(printf '%s' "$INPUT" | n1_hook_field session_id)
export N1_SESSION_ID="${N1_SESSION_ID:-${CODEX_THREAD_ID:-}}"
n1_read_lock "$N1_HOME/memory" || exit 0

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUTFILE="${N1_LOCK_TELEM_DIR}/raw/steps/${N1_LOCK_RUN_ID}.jsonl"
mkdir -p "$(dirname "$OUTFILE")"
# Explicit pipeline finalization may already have recorded its outcome.
if ! grep -q '"layer"[[:space:]]*:[[:space:]]*"envelope_close"' "$OUTFILE" 2>/dev/null; then

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

# Parent usage is available even when no subagent hook was delivered.
TRANSCRIPT=$(printf '%s' "$INPUT" | n1_hook_field transcript_path)
if [ -n "$TRANSCRIPT" ]; then
    printf '{"layer":"session","session_id":"%s","session_transcript_path":"%s"}\n' \
        "$(escape_json_val "$N1_SESSION_ID")" "$(escape_json_val "$TRANSCRIPT")" >> "$OUTFILE"
fi

# Trigger merge
bash "${SCRIPT_DIR}/telemetry-merge.sh" "$N1_LOCK_RUN_ID" "$N1_LOCK_TELEM_DIR" 2>/dev/null || true

# Remove lock if merge succeeded (mirrors finalize.md pattern)
MERGED="${N1_LOCK_TELEM_DIR}/runs/${N1_LOCK_RUN_ID}.jsonl"
[ -s "$MERGED" ] && n1_remove_run_lock "$N1_LOCK_TELEM_DIR" "$N1_LOCK_RUN_ID"

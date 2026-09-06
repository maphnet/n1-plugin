#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)

# Safety: prevent infinite loops — if Claude is already in forced-continuation
# state from a prior block, allow the stop.
HOOK_ACTIVE=$(echo "$INPUT" | grep -o '"stop_hook_active"[[:space:]]*:[[:space:]]*[a-z]*' | grep -o '[a-z]*$' || echo "false")
if [ "$HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"

# No N1 configured — not our concern
N1_ROOT=$(n1_home 2>/dev/null) || exit 0
AR_FILE="${N1_ROOT}/active-run.json"
[ -f "$AR_FILE" ] || exit 0

# Extract ticket ID from active-run.json
if command -v jq >/dev/null 2>&1; then
    TICKET=$(jq -r '.ticketId // empty' "$AR_FILE" 2>/dev/null)
else
    TICKET=$(grep -o '"ticketId"[[:space:]]*:[[:space:]]*"[^"]*"' "$AR_FILE" | sed 's/.*:.*"\([^"]*\)"/\1/' || true)
fi
[ -n "$TICKET" ] || exit 0

OV_FILE="${N1_ROOT}/memory/${TICKET}/overview.md"
[ -f "$OV_FILE" ] || exit 0

# Read current pipeline step from overview.md frontmatter
source "${SCRIPT_DIR}/../lib/frontmatter.sh"
STEP=$(n1_read_frontmatter "$OV_FILE" "step")

# Terminal states — pipeline is done, allow stop
case "$STEP" in
    done|"") exit 0 ;;
esac

# Legitimate user gates — the pipeline is paused for user input, allow stop
# Interactive brainstorm: user is being asked clarifying questions (analysis done,
# brainstorm mode is interactive, brainstorm.md not yet written)
BRAINSTORM_MODE=$(n1_autonomy_val 'brainstorm' 2>/dev/null || echo "interactive")
BRAINSTORM_FILE="${N1_ROOT}/memory/${TICKET}/brainstorm.md"
if [ "$STEP" = "analysis" ] && [ "$BRAINSTORM_MODE" = "interactive" ] && [ ! -f "$BRAINSTORM_FILE" ]; then
    exit 0
fi

# Acceptance gate: user is being asked to confirm design
ACCEPTANCE_GATE=$(n1_autonomy_val 'acceptanceGate' 2>/dev/null || echo "auto")
if [ "$STEP" = "brainstorm" ] && [ "$ACCEPTANCE_GATE" != "auto" ]; then
    exit 0
fi

# Plan approval gate: plan written, user has not approved yet
REQUIRE_PLAN_APPROVAL=$(n1_config_val '.planReview.requirePlanApproval' 2>/dev/null || echo "false")
PLAN_APPROVED=$(n1_read_frontmatter "$OV_FILE" "plan_approved")
if [ "$STEP" = "plan" ] && [ "$REQUIRE_PLAN_APPROVAL" = "true" ] && [ "$PLAN_APPROVED" != "true" ]; then
    exit 0
fi

# Mechanical prompt in flight: the orchestrator wrote pending_prompt before asking the user
PENDING_PROMPT=$(n1_read_frontmatter "$OV_FILE" "pending_prompt")
if [ -n "$PENDING_PROMPT" ]; then
    exit 0
fi

# Pipeline is active at a non-terminal, non-gated step — block the stop
echo "N1 pipeline is active (ticket: ${TICKET}, step: ${STEP}). Continue to the next pipeline step — do not stop here." >&2
exit 2

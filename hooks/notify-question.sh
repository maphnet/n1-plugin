#!/usr/bin/env bash
# PreToolUse hook (AskUserQuestion): desktop-notify that an interactive N1 run waits for an answer.
# Advisory and fail-open: every path exits 0 with no stdout, so the question is never delayed.
set -u
[ "${N1_HEADLESS:-}" = "1" ] && exit 0
[ -n "${N1_QUEUE_RUN_ID:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh" 2>/dev/null || exit 0
source "${SCRIPT_DIR}/../lib/host.sh" 2>/dev/null || exit 0
source "${SCRIPT_DIR}/../lib/frontmatter.sh" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ "$(n1_config_val '.notify.onQuestion')" = "false" ] && exit 0
export N1_SESSION_ID
N1_SESSION_ID=$(cat | jq -r '.session_id // empty' 2>/dev/null)
run=$(n1_active_run_file) && [ -f "$run" ] || exit 0
# Only this session's keyed pointer; the unkeyed fallback may belong to a crashed run.
case "$run" in */active-run.json) exit 0 ;; esac
id=$(jq -r '.ticketId // empty' "$run" 2>/dev/null)
[ -n "$id" ] || exit 0
step=$(n1_read_frontmatter "$(n1_home)/memory/$id/overview.md" step)
n1_desktop_notify "N1 $id" "Waiting for your answer${step:+ after $step}" >/dev/null 2>&1 &
exit 0

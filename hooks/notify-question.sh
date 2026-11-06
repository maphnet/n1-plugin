#!/usr/bin/env bash
# PreToolUse hook (AskUserQuestion): set the unread dot on the run's Orca workspace card while an
# interactive N1 run waits for an answer (N1-224). No desktop toast.
# Advisory and fail-open: every path exits 0 with no stdout, so the question is never delayed.
set -u
INPUT=$(cat)
[ "${N1_HEADLESS:-}" = "1" ] && exit 0
[ -n "${N1_QUEUE_RUN_ID:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh" 2>/dev/null || exit 0
source "${SCRIPT_DIR}/../lib/host.sh" 2>/dev/null || exit 0
source "${SCRIPT_DIR}/../lib/frontmatter.sh" 2>/dev/null || exit 0
# N1-225: an Orca queue child is unattended; its questions reach the queue through Orca ask.
command -v jq >/dev/null 2>&1 || exit 0
sid=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null) || true
source "${SCRIPT_DIR}/../lib/orca-queue.sh" 2>/dev/null && n1_orca_child_env "${CLAUDE_PROJECT_DIR:-$PWD}" "$sid" && exit 0
[ -n "$sid" ] && export N1_SESSION_ID="$sid"
run=$(n1_active_run_file) && [ -f "$run" ] || exit 0
# Only this session's keyed pointer; the unkeyed fallback may belong to a crashed run.
case "$run" in */active-run.json) exit 0 ;; esac
id=$(jq -r '.ticketId // empty' "$run" 2>/dev/null)
case "$id" in ""|*[!A-Za-z0-9_-]*) exit 0 ;; esac
step=$(n1_read_frontmatter "$(n1_home)/memory/$id/overview.md" step)
if [ -n "${ORCA_CLI_COMMAND:-}" ]; then
    cwd=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null) || cwd=""
    ( cd "${cwd:-.}" 2>/dev/null && n1_orca_sync "waiting: ${step:-answer}" --unread ) >/dev/null 2>&1 &
fi
exit 0

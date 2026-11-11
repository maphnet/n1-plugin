#!/usr/bin/env bash
# PreCompact hook (N1-404): print N1 compaction instructions so the summary keeps N1 run state without a user CLAUDE.md.
# CC 2.1.309 appends a PreCompact hook's exit-0 stdout to the compaction prompt (verified by reading the binary; not in the
# hooks docs) and shows it to the user on manual /compact, so the output stays short. Exit 2 would block compaction:
# every path exits 0. Silent outside N1-configured projects and in subagents (CC 2.1.309 discards subagent output there).
set -u
INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' <<<"$INPUT" >/dev/null 2>&1 || exit 0
sid=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null) || sid=""
cwd=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null) || cwd=""
aid=$(jq -r '.agent_id // empty' <<<"$INPUT" 2>/dev/null) || aid=""
[ -n "$aid" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "$cwd" ]; then cd "$cwd" 2>/dev/null || exit 0; fi
source "${SCRIPT_DIR}/../lib/config.sh" 2>/dev/null || exit 0
source "${SCRIPT_DIR}/../lib/frontmatter.sh" 2>/dev/null || exit 0
cfg=$(n1_config_file 2>/dev/null) || exit 0
[ -n "$cfg" ] && [ -f "$cfg" ] || exit 0
home=$(n1_home 2>/dev/null) || exit 0
[ -n "$home" ] || exit 0

printf '%s\n' \
    "N1 run state: preserve verbatim the N1 ticket ID, branch, worktree path and current N1 pipeline step." \
    "N1 run state: preserve verbatim every artifact path under ${home}/memory/<ticket ID>/ named in this session." \
    "N1 run state: preserve the names of Docker containers and background processes the N1 run started that are still running."

# Concrete values only from this session's keyed n1-start pointer; the unkeyed fallback may belong to a crashed run.
[ -n "$sid" ] && export N1_SESSION_ID="$sid"
# N1-440: an n1-queue plan in progress (no active-run pointer while planning).
qp=$( source "${SCRIPT_DIR}/../lib/queue.sh" && n1_queue_plan_state read ) 2>/dev/null || qp=""
if [ -n "$qp" ]; then
    IFS=$'\t' read -r qp_id qp_step _ <<<"$qp"
    printf 'N1 queue planning: preserve verbatim queue id %s and step %s.\n' "$qp_id" "$qp_step"
fi
run=$(n1_active_run_file 2>/dev/null) && [ -f "$run" ] || exit 0
case "$run" in */active-run.json) exit 0 ;; esac
id=$(jq -r '.ticketId // empty' "$run" 2>/dev/null) || exit 0
case "$id" in ""|*[!A-Za-z0-9_-]*) exit 0 ;; esac
[ "$(jq -r '.runId // empty' "$run" 2>/dev/null)" = n1-finish ] && exit 0
branch=$(jq -r '.branch // empty' "$run" 2>/dev/null | LC_ALL=C tr -d '[:cntrl:]')
wt=$(jq -r '.worktreePath // empty' "$run" 2>/dev/null | LC_ALL=C tr -d '[:cntrl:]')
step=$(n1_read_frontmatter "${home}/memory/${id}/overview.md" step 2>/dev/null | LC_ALL=C tr -d '[:cntrl:]')
printf 'Active N1 run: ticket=%s branch=%s worktree=%s step=%s memory=%s\n' \
    "$id" "${branch:-unknown}" "${wt:-none}" "${step:-unknown}" "${home}/memory/${id}"
exit 0

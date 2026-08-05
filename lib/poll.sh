#!/usr/bin/env bash
# Bounded internal polling for gh state — one tool call instead of one call per poll.
# Each invocation runs at most POLL_CHUNK_SECONDS; callers re-invoke until terminal.

POLL_CHUNK_SECONDS=480   # 8 min — safely under the 10-min Bash tool ceiling

n1_wait_pr_merged() {
    # Usage: n1_wait_pr_merged <pr-number> <max-minutes>
    # Prints: "merged <sha>" | "open" | "closed"
    local pr="$1" max_minutes="${2:-10}"
    local deadline=$(( $(date +%s) + max_minutes * 60 ))
    local chunk_end=$(( $(date +%s) + POLL_CHUNK_SECONDS ))
    [ "$deadline" -lt "$chunk_end" ] && chunk_end=$deadline
    while :; do
        local state sha
        state=$(gh pr view "$pr" --json state,mergeCommit \
            --jq '.state + " " + (.mergeCommit.oid // "")' 2>/dev/null) || state=""
        case "$state" in
            MERGED*) sha="${state#MERGED }"; printf 'merged %s\n' "$sha"; return 0 ;;
            CLOSED*) printf 'closed\n'; return 0 ;;
        esac
        [ "$(date +%s)" -ge "$chunk_end" ] && { printf 'open\n'; return 0; }
        sleep 30
    done
}

n1_wait_ci_checks() {
    # Usage: n1_wait_ci_checks <pr-number> <max-minutes>
    # Prints: "green" | "red" | "pending"
    local pr="$1" max_minutes="${2:-30}"
    local deadline=$(( $(date +%s) + max_minutes * 60 ))
    local chunk_end=$(( $(date +%s) + POLL_CHUNK_SECONDS ))
    [ "$deadline" -lt "$chunk_end" ] && chunk_end=$deadline
    while :; do
        local counts
        counts=$(gh pr checks "$pr" --json state,conclusion --jq \
            '[([.[] | select(.conclusion == "FAILURE")] | length),
              ([.[] | select(.state != "COMPLETED")] | length)] | @tsv' 2>/dev/null) || counts=""
        if [ -n "$counts" ]; then
            local failed pending
            failed=$(printf '%s' "$counts" | cut -f1)
            pending=$(printf '%s' "$counts" | cut -f2)
            [ "$failed" -gt 0 ] 2>/dev/null && { printf 'red\n'; return 0; }
            [ "$pending" -eq 0 ] 2>/dev/null && { printf 'green\n'; return 0; }
        fi
        [ "$(date +%s)" -ge "$chunk_end" ] && { printf 'pending\n'; return 0; }
        sleep 30
    done
}

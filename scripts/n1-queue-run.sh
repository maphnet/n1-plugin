#!/usr/bin/env bash
# N1 queue runner — sequential batch executor for n1-queue.
# Usage: n1-queue-run.sh <queue.md>
set -uo pipefail

N1_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export N1_ROOT
: "${CLAUDE_PLUGIN_ROOT:=$N1_ROOT}"; export CLAUDE_PLUGIN_ROOT
source "$N1_ROOT/lib/config.sh"
source "$N1_ROOT/lib/frontmatter.sh"
source "$N1_ROOT/lib/queue.sh"

QUEUE="$1"
[ -f "$QUEUE" ] || { echo "queue file not found: $QUEUE" >&2; exit 1; }

# --- Run ID ------------------------------------------------------------------
RUN_ID=$(n1_read_frontmatter "$QUEUE" run_id)
if [ -z "$RUN_ID" ]; then
    RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
    n1_write_frontmatter "$QUEUE" run_id "$RUN_ID"
fi

# --- Busy guard --------------------------------------------------------------
EXISTING_PID=$(n1_read_frontmatter "$QUEUE" pid)
if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
    echo "queue already running (pid $EXISTING_PID)"
    exit 3
fi
n1_write_frontmatter "$QUEUE" pid "$$"
n1_write_frontmatter "$QUEUE" step run

TIMEOUT_SECS=$(( $(n1_queue_val subtaskTimeoutMinutes) * 60 ))
CONSECUTIVE_FAIL=0

# --- Main loop ---------------------------------------------------------------
while true; do
    # Re-read pending rows each iteration (defer-once may have appended rows)
    ROW=$(n1_queue_pending_rows "$QUEUE" | head -1)
    [ -n "$ROW" ] || break

    IFS=$'\t' read -r NUM TICKET REPO N1H MODEL <<< "$ROW"

    # Write-ahead: mark in-progress
    n1_queue_row_status "$QUEUE" "$NUM" "in-progress"

    STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # Append a Runs row at end of file (Runs section is always last)
    echo "| $TICKET | $STARTED | | | |" >> "$QUEUE"

    OVERVIEW="$N1H/memory/$TICKET/overview.md"
    QUEUE_ID=$(n1_read_frontmatter "$QUEUE" queue_id)
    QUEUE_ID="${QUEUE_ID:-queue}"
    LOG_DIR="$N1H/queue/$QUEUE_ID/logs"
    mkdir -p "$LOG_DIR"
    LOG="$LOG_DIR/${TICKET}.${RUN_ID}.log"

    CMD=$(n1_queue_child_cmd "$REPO" "$TICKET" "$MODEL" "$RUN_ID" "$LOG")
    # Child command already redirects its own output into $LOG; append so wrapper errors (cd failure) land there too.
    timeout -k 30 "$TIMEOUT_SECS" bash -c "$CMD" >>"$LOG" 2>&1
    EXIT=$?

    OUTCOME=$(n1_queue_child_status "$OVERVIEW" "$EXIT")
    # If still "running" after exit, treat as failed
    [ "$OUTCOME" = "running" ] && OUTCOME="failed"
    # Timeout
    [ "$EXIT" = "124" ] && OUTCOME="failed"
    REASON=""
    case "$EXIT" in 124|137) REASON="timeout" ;; esac
    # Read the row's current Reason BEFORE rewriting it (defer-once guard).
    EXISTING_REASON=$(awk -F'|' -v num="$NUM" '{
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        if ($2 == num) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $9); print $9 }
    }' "$QUEUE")

    PR_URL=""
    [ "$OUTCOME" = "pr" ] && PR_URL=$(n1_queue_child_pr_url "$OVERVIEW")

    # Update Runs row (best-effort: last row matching ticket in ## Runs section)
    awk -v tk="$TICKET" -v ex="$EXIT" -v oc="$OUTCOME" -v pr="$PR_URL" '
    { lines[NR] = $0; n = NR }
    /^## Runs/ { runs_start = NR }
    /^## / && !/^## Runs/ { if (runs_start && !runs_end) runs_end = NR }
    END {
        if (!runs_end) runs_end = n + 1
        done = 0
        for (i = runs_end - 1; i >= runs_start; i--) {
            if (!done && index(lines[i], "| " tk " |") > 0) {
                split(lines[i], c, "|")
                c[4] = " " ex " "; c[5] = " " oc " "; c[6] = " " pr " "
                out = ""
                for (j = 1; j <= 6; j++) out = out c[j] "|"
                lines[i] = out; done = 1
            }
        }
        for (i = 1; i <= n; i++) print lines[i]
    }' "$QUEUE" > "${QUEUE}.tmp" && mv "${QUEUE}.tmp" "$QUEUE"

    # Update Plan row
    if [ -n "$REASON" ]; then
        [ "$EXISTING_REASON" = "deferred-retry" ] && REASON="deferred-retry ($REASON)"
        n1_queue_row_status "$QUEUE" "$NUM" "$OUTCOME" "$REASON"
    else
        n1_queue_row_status "$QUEUE" "$NUM" "$OUTCOME"
    fi

    # Defer-once: first failure -> deferred + new pending row; second stays failed
    if [ "$OUTCOME" = "failed" ]; then
        if [ "$EXISTING_REASON" != "deferred-retry" ]; then
            n1_queue_row_status "$QUEUE" "$NUM" "deferred"
            # Find next row number
            NEXT_NUM=$(awk -F'|' '
                { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2) }
                $2 ~ /^[0-9]+$/ { max = $2 }
                END { print max + 1 }
            ' "$QUEUE")
            # Get the Title from the original row
            TITLE=$(awk -F'|' -v num="$NUM" '{
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                if ($2 == num) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4 }
            }' "$QUEUE")
            # Append new pending row before the blank line or end of Plan table
            awk -v row="| $NEXT_NUM | $TICKET | $TITLE | $REPO | $N1H | $MODEL | pending | deferred-retry |" '
                /^## Plan/ { in_plan=1 }
                in_plan && /^$/ && !added { print row; added=1 }
                { print }
                END { if (in_plan && !added) print row }
            ' "$QUEUE" > "${QUEUE}.tmp" && mv "${QUEUE}.tmp" "$QUEUE"
        fi
    fi

    # Three-strikes counter
    case "$OUTCOME" in
        failed|escalated) CONSECUTIVE_FAIL=$((CONSECUTIVE_FAIL + 1)) ;;
        pr) CONSECUTIVE_FAIL=0 ;;
    esac
    if [ "$CONSECUTIVE_FAIL" -ge 3 ]; then
        n1_write_frontmatter "$QUEUE" step halted
        # Remove pid
        awk 'NR==1 && /^---$/ { in_fm=1; print; next }
             in_fm && /^---$/ { in_fm=0; print; next }
             in_fm && /^pid:/ { next }
             { print }' "$QUEUE" > "${QUEUE}.tmp" && mv "${QUEUE}.tmp" "$QUEUE"
        echo "HALTED after 3 consecutive non-success"
        exit 2
    fi

    echo "[$NUM] $TICKET -> $OUTCOME $PR_URL"
done

# --- Done --------------------------------------------------------------------
n1_write_frontmatter "$QUEUE" step done
# Remove pid
awk 'NR==1 && /^---$/ { in_fm=1; print; next }
     in_fm && /^---$/ { in_fm=0; print; next }
     in_fm && /^pid:/ { next }
     { print }' "$QUEUE" > "${QUEUE}.tmp" && mv "${QUEUE}.tmp" "$QUEUE"
exit 0

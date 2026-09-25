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

# --- Host --------------------------------------------------------------------
# Fixed at queue creation (run.md). CLAUDE_PLUGIN_ROOT is forced above for path
# resolution, so auto-detection here would report claude-code on both hosts.
QUEUE_HOST=$(n1_read_frontmatter "$QUEUE" host)
[ -z "$QUEUE_HOST" ] || export N1_HOST="$QUEUE_HOST"

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
# Shared grace limit: consecutive unreadable-agents-list polls (halts the run) and
# consecutive missing-from-list polls for one session (fails that row).
BG_POLL_GRACE=10
CONSECUTIVE_FAIL=0
QUEUE_ID=$(n1_read_frontmatter "$QUEUE" queue_id)
QUEUE_ID="${QUEUE_ID:-queue}"

strip_pid() {
    local tmp; tmp=$(mktemp "${QUEUE}.XXXXXX")
    awk 'NR==1 && /^---$/ { in_fm=1; print; next }
         in_fm && /^---$/ { in_fm=0; print; next }
         in_fm && /^pid:/ { next }
         { print }' "$QUEUE" > "$tmp" && mv "$tmp" "$QUEUE" || { rm -f "$tmp"; false; }
}

EVENTS="$(dirname "$QUEUE")/events.jsonl"
# ponytail: STARTED_AT/PARKED are in-memory; after a runner crash-restart duration_s is null and
# a re-parked ticket may notify twice. Persist them in queue.md if that ever matters.
declare -a STARTED_AT=() PARKED=()

ev() { n1_queue_event "$EVENTS" "$QUEUE_ID" "$RUN_ID" "$@"; }

# escalate <ticket> <n1-home> — escalated event + needs-you notification (with resume hint).
escalate() {
    local sid q
    sid=$(n1_queue_session_id "$QUEUE" "$1")
    q=$(n1_queue_escalation_text "$2/memory/$1/overview.md")
    ev escalated ticket="$1" session="$sid" reason="$q"
    n1_notify needs-you "$1 needs you: ${q:-waiting for an answer}${sid:+ (resume: $(n1_bg_cmd attach "$sid"))}"
}

# halt <message> — record, notify, and stop the runner (exit 2).
halt() {
    n1_write_frontmatter "$QUEUE" step halted
    strip_pid
    ev halted reason="$1"
    n1_notify needs-you "Queue $QUEUE_ID halted: ${1:0:200}"
    echo "$1"
    exit 2
}

ev queue_started

# finalize <num> <ticket> <repo> <n1-home> <model> <outcome> <exit> [reason]
# Records a terminal outcome: Runs + Plan rows, defer-once, three-strikes (may exit 2).
finalize() {
    local NUM="$1" TICKET="$2" REPO="$3" N1H="$4" MODEL="$5" OUTCOME="$6" EXIT="$7" REASON="${8:-}"
    local OVERVIEW="$N1H/memory/$TICKET/overview.md" EXISTING_REASON PR_URL="" NEXT_NUM TITLE EV_OUTCOME="$OUTCOME" DUR=""
    # Read the row's current Reason BEFORE rewriting it (defer-once guard).
    EXISTING_REASON=$(awk -F'|' -v num="$NUM" '{
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        if ($2 == num) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $9); print $9 }
    }' "$QUEUE")

    [ "$OUTCOME" = "pr" ] && PR_URL=$(n1_queue_child_pr_url "$OVERVIEW")

    # Update Runs row (last row matching ticket in ## Runs); the Session cell is kept.
    local tmp; tmp=$(mktemp "${QUEUE}.XXXXXX")
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
                for (j = 1; j <= 7; j++) out = out c[j] "|"
                lines[i] = out; done = 1
            }
        }
        for (i = 1; i <= n; i++) print lines[i]
    }' "$QUEUE" > "$tmp" && mv "$tmp" "$QUEUE" || { rm -f "$tmp"; false; }

    # Update Plan row
    if [ -n "$REASON" ]; then
        [ "$EXISTING_REASON" = "deferred-retry" ] && REASON="deferred-retry ($REASON)"
        n1_queue_row_status "$QUEUE" "$NUM" "$OUTCOME" "$REASON"
    else
        n1_queue_row_status "$QUEUE" "$NUM" "$OUTCOME"
    fi

    # Defer-once: first failure -> deferred + new pending row; second stays failed
    if [ "$OUTCOME" = "failed" ] && [ "$EXISTING_REASON" != "deferred-retry" ]; then
        EV_OUTCOME="deferred"
        n1_queue_row_status "$QUEUE" "$NUM" "deferred"
        NEXT_NUM=$(awk -F'|' '
            { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2) }
            $2 ~ /^[0-9]+$/ { max = $2 }
            END { print max + 1 }
        ' "$QUEUE")
        TITLE=$(awk -F'|' -v num="$NUM" '{
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            if ($2 == num) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4 }
        }' "$QUEUE")
        # Append new pending row before the blank line or end of Plan table
        tmp=$(mktemp "${QUEUE}.XXXXXX")
        awk -v row="| $NEXT_NUM | $TICKET | $TITLE | $REPO | $N1H | $MODEL | pending | deferred-retry |" '
            /^## Plan/ { in_plan=1 }
            in_plan && /^$/ && !added { print row; added=1 }
            { print }
            END { if (in_plan && !added) print row }
        ' "$QUEUE" > "$tmp" && mv "$tmp" "$QUEUE" || { rm -f "$tmp"; false; }
    fi

    # Events + notifications before three-strikes (which may exit). PR successes notify only
    # through the end-of-queue digest.
    [ "$OUTCOME" = "escalated" ] && [ -z "${PARKED[NUM]:-}" ] && escalate "$TICKET" "$N1H"
    [ -n "${STARTED_AT[NUM]:-}" ] && DUR=$(( $(date +%s) - STARTED_AT[NUM] ))
    ev ticket_finished ticket="$TICKET" outcome="$EV_OUTCOME" pr="$PR_URL" \
        session="$(n1_queue_session_id "$QUEUE" "$TICKET")" duration_s="$DUR" reason="$REASON"
    [ "$EV_OUTCOME" = "failed" ] && n1_notify info "$TICKET failed${REASON:+ ($REASON)}"

    # Three-strikes counter
    case "$OUTCOME" in
        failed|escalated) CONSECUTIVE_FAIL=$((CONSECUTIVE_FAIL + 1)) ;;
        pr) CONSECUTIVE_FAIL=0 ;;
    esac
    if [ "$CONSECUTIVE_FAIL" -ge 3 ]; then
        halt "HALTED after 3 consecutive non-success"
    fi

    echo "[$NUM] $TICKET -> $OUTCOME $PR_URL"
}

# run_sync — one synchronous headless child at a time (Codex; stub-driven tests).
run_sync() {
    local ROW NUM TICKET REPO N1H MODEL STARTED LOG_DIR LOG CMD EXIT OUTCOME REASON
    while true; do
        # Re-read pending rows each iteration (defer-once may have appended rows)
        ROW=$(n1_queue_pending_rows "$QUEUE" | head -1)
        [ -n "$ROW" ] || break
        IFS=$'\t' read -r NUM TICKET REPO N1H MODEL _ <<< "$ROW"

        # Write-ahead: mark in-progress; Runs section is always last
        n1_queue_row_status "$QUEUE" "$NUM" "in-progress"
        STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        echo "| $TICKET | $STARTED | | | | |" >> "$QUEUE"
        STARTED_AT[NUM]=$(date +%s)
        ev ticket_started ticket="$TICKET"

        LOG_DIR="$N1H/queue/$QUEUE_ID/logs"
        mkdir -p "$LOG_DIR"
        LOG="$LOG_DIR/${TICKET}.${RUN_ID}.log"

        CMD=$(n1_queue_child_cmd "$REPO" "$TICKET" "$MODEL" "$RUN_ID" "$LOG")
        # Child command already redirects its own output into $LOG; append so wrapper errors (cd failure) land there too.
        timeout -k 30 "$TIMEOUT_SECS" bash -c "$CMD" >>"$LOG" 2>&1
        EXIT=$?

        OUTCOME=$(n1_queue_child_status "$N1H/memory/$TICKET/overview.md" "$EXIT")
        # Still "running" after exit, or timeout -> failed
        [ "$OUTCOME" = "running" ] && OUTCOME="failed"
        [ "$EXIT" = "124" ] && OUTCOME="failed"
        REASON=""
        case "$EXIT" in 124|137) REASON="timeout" ;; esac

        finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "$OUTCOME" "$EXIT" "$REASON"
    done
}

# launch_bg <pending-row> — start the row's background session. A launch refused for the
# bypass-permissions disclaimer halts the queue (every later launch would fail the same way).
launch_bg() {
    local NUM TICKET REPO N1H MODEL CMD OUT SID STARTED
    IFS=$'\t' read -r NUM TICKET REPO N1H MODEL _ <<< "$1"
    n1_queue_row_status "$QUEUE" "$NUM" "in-progress"
    STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    STARTED_AT[NUM]=$(date +%s)
    CMD=$(n1_queue_child_cmd "$REPO" "$TICKET" "$MODEL" "$RUN_ID" "" "n1-${QUEUE_ID}-${TICKET}-${NUM}")
    OUT=$(bash -c "$CMD" 2>&1)
    if SID=$(n1_queue_parse_launch "$OUT"); then
        echo "| $TICKET | $STARTED | | | | $SID |" >> "$QUEUE"
        ev ticket_started ticket="$TICKET" session="$SID"
        echo "[$NUM] $TICKET launched ($SID)"
        return
    fi
    echo "| $TICKET | $STARTED | | | | |" >> "$QUEUE"
    if [ "$SID" = "bypass-permissions-disclaimer" ]; then
        n1_queue_row_status "$QUEUE" "$NUM" "failed" "$SID"
        halt "HALTED: background sessions refuse bypassPermissions until its disclaimer is accepted once interactively (run: claude --dangerously-skip-permissions). Launch output: $OUT"
    fi
    echo "[$NUM] $TICKET launch failed: $OUT"
    finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" "$SID"
}

# run_bg — background sessions, still sequential: launch the next pending ticket only when
# no launched child is working. blocked -> awaiting-human (no strike) and the queue moves on.
# Working time is capped by subtaskTimeoutMinutes; at end of queue, parked rows are polled
# for up to subtaskTimeoutMinutes after the last park, then left awaiting-human (never relaunched).
run_bg() {
    local POLL AGENTS WORKING ROW NUM TICKET REPO N1H MODEL STATUS STATE OUTCOME SID
    # ponytail: WORKED/SINCE_PARK live only in this process's memory. If the runner
    # crashes and restarts (busy guard lets a new run start once the old pid is dead),
    # both budgets reset to 0 even though the background sessions survived the crash —
    # a ticket already 170 of 180 minutes in gets a fresh 180. Add persisted elapsed-time
    # tracking (e.g. derive from the Runs row's Started timestamp) if crash-resume timing
    # accuracy matters; no test or AC currently requires it.
    local SINCE_PARK=0 AGENT_FAILS=0
    local -a WORKED=()
    local -a MISSING=()
    POLL=$(n1_queue_val pollSeconds)
    while true; do
        # An unreadable session list skips the tick: never treat a CLI hiccup as dead children.
        if ! AGENTS=$(bash -c "$(n1_bg_cmd agents)" 2>/dev/null) || ! printf '%s' "$AGENTS" | jq -e . >/dev/null 2>&1; then
            AGENT_FAILS=$((AGENT_FAILS + 1))
            if [ "$AGENT_FAILS" -ge "$BG_POLL_GRACE" ]; then
                halt "HALTED: background session list unreadable for $BG_POLL_GRACE polls in a row"
            fi
            sleep "$POLL"
            continue
        fi
        AGENT_FAILS=0
        WORKING=0
        while IFS=$'\t' read -r NUM TICKET REPO N1H MODEL STATUS; do
            SID=$(n1_queue_session_id "$QUEUE" "$TICKET")
            STATE=$(n1_queue_bg_state "$AGENTS" "$SID")
            case "$STATE" in
                missing)
                    MISSING[NUM]=$(( ${MISSING[NUM]:-0} + 1 ))
                    if [ "${MISSING[NUM]}" -ge "$BG_POLL_GRACE" ]; then
                        finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" "bg-session-not-listed"
                        continue
                    fi
                    WORKED[NUM]=$(( ${WORKED[NUM]:-0} + POLL ))
                    if [ "${WORKED[NUM]}" -le "$TIMEOUT_SECS" ]; then WORKING=1; continue; fi
                    [ -n "$SID" ] && bash -c "$(n1_bg_cmd stop "$SID")" >/dev/null 2>&1
                    finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" "timeout"
                    ;;
                working)
                    MISSING[NUM]=0
                    if [ "$STATUS" = "awaiting-human" ]; then
                        n1_queue_row_status "$QUEUE" "$NUM" "in-progress"
                        ev unblocked ticket="$TICKET" session="$SID"
                    fi
                    WORKED[NUM]=$(( ${WORKED[NUM]:-0} + POLL ))
                    if [ "${WORKED[NUM]}" -le "$TIMEOUT_SECS" ]; then WORKING=1; continue; fi
                    [ -n "$SID" ] && bash -c "$(n1_bg_cmd stop "$SID")" >/dev/null 2>&1
                    finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" "timeout"
                    ;;
                blocked)
                    if [ "$STATUS" != "awaiting-human" ]; then
                        n1_queue_row_status "$QUEUE" "$NUM" "awaiting-human"
                        SINCE_PARK=0
                        echo "[$NUM] $TICKET -> awaiting-human"
                        PARKED[NUM]=1
                        escalate "$TICKET" "$N1H"
                    fi
                    ;;
                done)
                    OUTCOME=$(n1_queue_child_status "$N1H/memory/$TICKET/overview.md" 0)
                    [ "$OUTCOME" = "running" ] && OUTCOME="failed"
                    finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "$OUTCOME" ""
                    ;;
                failed|*) finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" ;;
            esac
        done < <(n1_queue_pending_rows "$QUEUE" 'in-progress|awaiting-human')

        if [ "$WORKING" = 0 ]; then
            ROW=$(n1_queue_pending_rows "$QUEUE" | head -1)
            if [ -n "$ROW" ]; then
                launch_bg "$ROW"
            else
                # Nothing pending: finish when nothing is parked, or the awaiting wait expired.
                [ -n "$(n1_queue_pending_rows "$QUEUE" 'awaiting-human')" ] || break
                if [ "$SINCE_PARK" -ge "$TIMEOUT_SECS" ]; then
                    echo "awaiting-human rows left for the user; queue done"
                    break
                fi
            fi
        fi
        SINCE_PARK=$((SINCE_PARK + POLL))
        sleep "$POLL"
    done
}

# Claude Code children run as background sessions; Codex (and stub-driven tests) stay synchronous.
if [ "$(n1_host)" = "claude-code" ] && [ -z "${N1_QUEUE_CHILD_STUB:-}" ]; then
    run_bg
else
    run_sync
fi

# --- Done --------------------------------------------------------------------
count_rows() { n1_queue_pending_rows "$QUEUE" "$1" | wc -l | tr -d ' '; }
DIGEST="$(count_rows pr) PR / $(count_rows 'awaiting-human|escalated') awaiting / $(count_rows failed) failed"
ev queue_done reason="$DIGEST"
n1_notify done "Queue $QUEUE_ID: $DIGEST"
n1_write_frontmatter "$QUEUE" step done
strip_pid
exit 0

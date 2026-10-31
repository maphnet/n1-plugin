#!/usr/bin/env bash
# N1 queue runner — sequential batch executor for n1-queue (Claude Code background sessions).
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
# Frontmatter pid (older runners, and what --status reads) plus an atomic lock (N1-82): a noclobber
# create fails when the file exists, so two runners started together cannot both pass (the old
# check-then-write could). Portable to Git Bash/MSYS, where ln -s is unreliable. The pid is written to a
# private mktemp file and published with a hard link, which fails when the lock exists: the lock is never
# visible empty. A dead holder's lock is reclaimed by renaming it away and verifying the renamed file is the
# stale one we judged (a different pid means another runner reclaimed first: put it back and exit).
EXISTING_PID=$(n1_read_frontmatter "$QUEUE" pid)
if n1_queue_runner_alive "$EXISTING_PID" "$QUEUE"; then
    echo "queue already running (pid $EXISTING_PID)"
    exit 3
fi
LOCK="$QUEUE.lock"
take_lock() {
    local t rc; t=$(mktemp "$LOCK.XXXXXX") || return 1
    printf '%s\n' "$$" > "$t" && ln "$t" "$LOCK" 2>/dev/null; rc=$?
    rm -f "$t"; return $rc
}
if ! take_lock; then
    EXISTING_PID=$(cat "$LOCK" 2>/dev/null)
    if n1_queue_runner_alive "$EXISTING_PID" "$QUEUE"; then
        echo "queue already running (pid $EXISTING_PID)"
        exit 3
    fi
    gone=$(mktemp "$LOCK.XXXXXX") || exit 3
    if mv -f "$LOCK" "$gone" 2>/dev/null; then
        if [ "$(cat "$gone" 2>/dev/null)" != "$EXISTING_PID" ]; then
            ln "$gone" "$LOCK" 2>/dev/null
            rm -f "$gone"
            echo "queue already running (lock reclaimed by another runner)"
            exit 3
        fi
    fi
    rm -f "$gone"
    take_lock || { echo "queue already running (lock taken)"; exit 3; }
fi
trap '[ "$(cat "$LOCK" 2>/dev/null)" = "$$" ] && rm -f "$LOCK"' EXIT
n1_write_frontmatter "$QUEUE" pid "$$"
n1_write_frontmatter "$QUEUE" step run

TIMEOUT_SECS=$(( $(n1_queue_val subtaskTimeoutMinutes) * 60 ))
# Shared grace limit: consecutive unreadable-agents-list polls (halts the run) and
# consecutive missing-from-list polls for one session (fails that row).
BG_POLL_GRACE=10
CONSECUTIVE_FAIL=0
QUEUE_ID=$(n1_read_frontmatter "$QUEUE" queue_id)
QUEUE_ID="${QUEUE_ID:-queue}"
# Tag mode: QUEUE_ID is the tag; children release it on handoff (NP-199).
N1_QUEUE_TAG=""
[ "$(n1_read_frontmatter "$QUEUE" mode)" = tag ] && N1_QUEUE_TAG="$QUEUE_ID"
export N1_QUEUE_TAG

# Absolute queue dir: children read their plan-time ## Decisions row from here (NP-203).
# Unconditional (tag and story mode); story-mode children may run under a different N1_HOME.
N1_QUEUE_DIR=$(cd "$(dirname "$QUEUE")" && pwd)
export N1_QUEUE_DIR

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
declare -a STARTED_AT=() PARKED=() DRAIN=() DRAIN_ESCALATED=()

ev() { n1_queue_event "$EVENTS" "$QUEUE_ID" "$RUN_ID" "$@"; }

# escalate <ticket> <n1-home> [session-state] — escalated event + needs-you notification
# (with resume hint). session-state "stopped" means the bg session is draining (success-path
# finalize; stopped once idle): hint n1-start, since attach only reaches a running session.
# N1-60: when the child has mirrored a question to .question-<ticket>.json, that file's full
# content (question/options/recommended/rationale) is packed into the event's reason field so
# it survives the file's later removal by n1_queue_answer/the child on resume. events.jsonl's
# reason field is already free text; this just widens what it can hold, as JSON, via jq -c.
escalate() {
    local sid q qfile qfull reason mark
    sid=$(n1_queue_session_id "$QUEUE" "$1")
    q=$(n1_queue_escalation_text "$2/memory/$1/overview.md")
    reason="$q"
    case "$1" in
        ''|*[!A-Za-z0-9_-]*) qfile="" mark="" ;;
        *) qfile="$N1_QUEUE_DIR/.question-$1.json" mark="$N1_QUEUE_DIR/.esc-reason-$1" ;;
    esac
    if [ -n "$qfile" ] && [ -f "$qfile" ]; then
        # SEC-1/CR-2/N1-60-follow-up: cap each field so the packed reason stays far
        # under execve's per-arg limit (128 KiB) however large the mirrored question
        # file is. Control/format chars are stripped before capping (same class the
        # watch reader already strips at render time, lib/queue.sh) so a field full of
        # single-byte control chars can't 6x-expand via \uXXXX JSON escaping. A second
        # hard check rebuilds with a much smaller per-field cap if the first pass (at
        # the normal 2000-char cap) still exceeds a 32 KiB budget — covers 4-byte UTF-8
        # (emoji) content, which isn't a control char and isn't escaped by jq.
        qfull=$(jq -cn '
            def strip: tostring | gsub("[\u0000-\u001f\u007f-\u009f\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069\u061c]"; " ");
            def build($src; $n): $src | objects | {
                question: (.question // "" | strip | .[:$n]),
                options: ((.options // []) | arrays | .[:10] | map(strip | .[:$n])),
                recommended: (.recommended // "" | strip | .[:$n]),
                rationale: (.rationale // "" | strip | .[:$n])
            };
            (input) as $src
            | (build($src; 2000)) as $full
            | if ($full | tojson | utf8bytelength) > 32768 then build($src; 200) else $full end
        ' "$qfile" 2>/dev/null)
        [ -n "$qfull" ] && reason="$qfull"
    fi
    # N1-241: one escalation per ticket+reason. Park, finalize, drain and a crash-restart can all
    # reach here for the same pending stop; the marker is cleared on launch, unblock, new question,
    # drain re-arm and --answer, so a genuinely new or re-asked escalation still fires. A failed
    # marker write only risks a duplicate, never a lost escalation. The marker keys on the stable
    # overview text $q, not the packed reason (the mirrored question file is gone by drain time).
    # A crash between the marker write and the emit would lose that escalation (accepted).
    if [ -n "$mark" ] && [ -f "$mark" ] && [ "$(cat "$mark" 2>/dev/null)" = "$q" ]; then
        return 0
    fi
    [ -n "$mark" ] && { printf '%s' "$q" > "$mark"; } 2>/dev/null || true
    if [ "${3:-}" = "stopped" ]; then
        ev escalated ticket="$1" session="$sid" reason="$reason" outcome=terminal
    else
        ev escalated ticket="$1" session="$sid" reason="$reason"
    fi
    if [ "${3:-}" = "stopped" ]; then
        n1_notify needs-you "$1 needs you: ${q:-waiting for an answer} (resume: n1-start $1)"
    else
        n1_notify needs-you "$1 needs you: ${q:-waiting for an answer}${sid:+ (resume: $(n1_bg_cmd attach "$sid"))}"
    fi
}

# release_backstop — NP-199: fires the automatic tag-release backstop (tag mode only,
# only when a row still needs releasing) so a failed/escalated/halted-strike ticket's
# tag is released even when nobody runs --status. Best-effort, blocking: nothing waits
# on this runner process once it reaches here (run.md already ended the interactive
# turn right after launching it).
release_backstop() {
    [ "$(n1_read_frontmatter "$QUEUE" mode)" = tag ] || return 0
    [ -n "$(n1_queue_release_rows "$QUEUE")" ] || return 0
    local rel_repo rel_log
    rel_repo=$(awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$5)} $2 ~ /^[0-9]+$/ {print $5; exit}' "$QUEUE")
    rel_log="$(dirname "$QUEUE")/release.$RUN_ID.log"
    timeout -k 30 300 bash -c "$(n1_queue_release_cmd "$QUEUE_ID" "$rel_repo" "$rel_log")" >>"$rel_log" 2>&1 || true
}

# halt <message> — record, notify, and stop the runner (exit 2).
halt() {
    n1_write_frontmatter "$QUEUE" step halted
    ev halted reason="$1"
    release_backstop
    n1_notify needs-you "Queue $QUEUE_ID halted: ${1:0:200}"
    echo "$1"
    drain_wait
    strip_pid
    exit 2
}

ev queue_started

# finalize <num> <ticket> <repo> <n1-home> <model> <outcome> <exit> [reason] [pr-url]
# Records a terminal outcome: Runs + Plan rows, defer-once, three-strikes (may exit 2).
finalize() {
    local NUM="$1" TICKET="$2" REPO="$3" N1H="$4" MODEL="$5" OUTCOME="$6" EXIT="$7" REASON="${8:-}" PR_FOUND="${9:-}"
    local OVERVIEW="$N1H/memory/$TICKET/overview.md" EXISTING_REASON PR_URL="" NEXT_NUM TITLE EV_OUTCOME="$OUTCOME" DUR=""
    # NP-216 AC3 safety net: every failed/deferred Runs row must carry a non-empty
    # reason. Call sites should already pass one; this is the last line of defense.
    [ "$OUTCOME" = "failed" ] && [ -z "$REASON" ] && REASON="unspecified-failure"
    # N1-240: snapshot the escalation state chain_finish needs before the files below are removed.
    CHAIN_ESC=""
    chain_child_escalated "$TICKET" "$N1H" && CHAIN_ESC="$TICKET"
    # Persist it too: a runner restart loses CHAIN_ESC and the question files are removed below.
    if [ -n "$CHAIN_ESC" ]; then : > "$N1_QUEUE_DIR/.escalated-$TICKET"; else rm -f "$N1_QUEUE_DIR/.escalated-$TICKET"; fi
    rm -f "$N1_QUEUE_DIR/.question-$TICKET.json" "$N1_QUEUE_DIR/.relay-$TICKET" "$N1_QUEUE_DIR/.launch-$NUM"
    # Marks the ticket as queue-handled; intake excludes it until the tag release is confirmed.
    n1_write_frontmatter "$OVERVIEW" queue_run_id "$RUN_ID" || true
    # Read the row's current Reason BEFORE rewriting it (defer-once guard).
    EXISTING_REASON=$(awk -F'|' -v num="$NUM" '{
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        if ($2 == num) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $9); print $9 }
    }' "$QUEUE")

    [ "$OUTCOME" = "pr" ] && { PR_URL=$(n1_queue_child_pr_url "$OVERVIEW"); PR_URL="${PR_URL:-$PR_FOUND}"; }

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
    [ "$OUTCOME" = "escalated" ] && [ -z "${PARKED[NUM]:-}" ] && escalate "$TICKET" "$N1H" stopped
    [ -n "${STARTED_AT[NUM]:-}" ] && DUR=$(( $(date +%s) - STARTED_AT[NUM] ))
    ev ticket_finished ticket="$TICKET" outcome="$EV_OUTCOME" pr="$PR_URL" \
        session="$(n1_queue_session_id "$QUEUE" "$TICKET")" duration_s="$DUR" reason="$REASON"
    [ "$EV_OUTCOME" = "failed" ] && n1_notify info "$TICKET failed${REASON:+ ($REASON)}"

    # Three-strikes counter
    case "$OUTCOME" in
        failed|escalated) CONSECUTIVE_FAIL=$((CONSECUTIVE_FAIL + 1)) ;;
        pr|awaiting-human) CONSECUTIVE_FAIL=0 ;;
    esac
    if [ "$CONSECUTIVE_FAIL" -ge 3 ]; then
        halt "HALTED after 3 consecutive non-success"
    fi

    echo "[$NUM] $TICKET -> $OUTCOME $PR_URL"
    # N1-185: one funnel for the three pr sites (reconcile, timeout_stop, open-PR rescue). stdin is the
    # row loop's process substitution, so the chain's commands never read from it.
    [ "$OUTCOME" = pr ] && chain_finish "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "$PR_URL" </dev/null
    return 0
}

# live_row_sid <num> <ticket> <agents-json> — N1-82: id of a live (working/blocked) session this run
# already launched for the row (its .launch-<num> lock holds this run id), else nothing. A lock from
# another run id never matches, so a relaunch under a new run id is never blocked.
live_row_sid() {
    [ "$(cat "$N1_QUEUE_DIR/.launch-$1" 2>/dev/null)" = "$RUN_ID" ] || return 0
    n1_queue_live_by_name "$3" "n1-${QUEUE_ID}-$2-$1"
}

# launch_bg <pending-row> <agents-json> — start the row's background session. A launch refused for the
# bypass-permissions disclaimer halts the queue (every later launch would fail the same way).
# N1-82: the row's launch lock is written before launching; a row this run already launched whose
# session is still live is adopted instead of launched a second time.
launch_bg() {
    local NUM TICKET REPO N1H MODEL CMD OUT SID STARTED
    IFS=$'\t' read -r NUM TICKET REPO N1H MODEL _ <<< "$1"
    STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    STARTED_AT[NUM]=$(date +%s)
    SID=$(live_row_sid "$NUM" "$TICKET" "${2:-}")
    if [ -n "$SID" ]; then
        n1_queue_row_status "$QUEUE" "$NUM" "in-progress"
        echo "| $TICKET | $STARTED | | | | $SID |" >> "$QUEUE"
        ev ticket_started ticket="$TICKET" session="$SID" reason="adopted live session"
        echo "[$NUM] $TICKET already live ($SID); adopted, not relaunched"
        return
    fi
    if ! printf '%s\n' "$RUN_ID" > "$N1_QUEUE_DIR/.launch-$NUM"; then
        echo "| $TICKET | $STARTED | | | | |" >> "$QUEUE"
        finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" "launch-lock-unwritable"
        return
    fi
    n1_queue_row_status "$QUEUE" "$NUM" "in-progress"
    # Re-queued ticket: forget the previous run's tag release (NP-199).
    n1_write_frontmatter "$N1H/memory/$TICKET/overview.md" queue_tag_removed false || true
    CMD=$(n1_queue_child_cmd "$REPO" "$TICKET" "$MODEL" "$RUN_ID" "" "n1-${QUEUE_ID}-${TICKET}-${NUM}")
    OUT=$(bash -c "$CMD" 2>&1)
    if SID=$(n1_queue_parse_launch "$OUT"); then
        echo "| $TICKET | $STARTED | | | | $SID |" >> "$QUEUE"
        rm -f "$N1_QUEUE_DIR/.esc-reason-$TICKET"
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

# drain_stop <agents-json> — stop and drop DRAIN sids once their bg session goes idle
# (done); missing/failed sessions are dropped without stopping (already gone). working/blocked
# sessions are kept: right after a terminal overview step a child may still be in CI watch,
# finish/merge, or memory finalize, and killing it mid-way would lose that work. A blocked
# session is escalated once (DRAIN_ESCALATED dedupe) so a question raised post-finalize still
# reaches the user instead of silently idling until drain_wait's timeout.
drain_stop() {
    local agents="$1" entry sid ticket n1h st
    local -a keep=()
    # ${a[@]+...}: an empty array is "unbound" under set -u before bash 4.4.
    for entry in ${DRAIN[@]+"${DRAIN[@]}"}; do
        IFS=$'\t' read -r sid ticket n1h <<<"$entry"
        st=$(n1_queue_bg_state "$agents" "$sid")
        case "$st" in
            done) bash -c "$(n1_bg_cmd stop "$sid")" >/dev/null 2>&1 || keep+=("$entry") ;;
            missing|failed) ;;  # failed also covers stopped/unknown states: nothing safe to stop
            blocked)
                if ! printf '%s\n' "${DRAIN_ESCALATED[@]+"${DRAIN_ESCALATED[@]}"}" | grep -qxF -- "$sid"; then
                    DRAIN_ESCALATED+=("$sid")
                    escalate "$ticket" "$n1h"
                fi
                keep+=("$entry")
                ;;
            *)  # back to working (question answered): re-arm so a later question escalates too
                DRAIN_ESCALATED=($(printf '%s\n' "${DRAIN_ESCALATED[@]+"${DRAIN_ESCALATED[@]}"}" | grep -vxF -- "$sid"))
                rm -f "$N1_QUEUE_DIR/.esc-reason-$ticket"
                keep+=("$entry") ;;
        esac
    done
    DRAIN=(${keep[@]+"${keep[@]}"})
}

# drain_leftover <log-reason> <notify-label> — drain_wait gave up: log the left-running sids and
# send one needs-you notification naming their tickets.
drain_leftover() {
    local entry sid ticket
    local -a sids=() tickets=()
    for entry in ${DRAIN[@]+"${DRAIN[@]}"}; do
        IFS=$'\t' read -r sid ticket _ <<<"$entry"
        sids+=("$sid"); tickets+=("$ticket")
    done
    echo "$1, left running: ${sids[*]}"
    n1_notify needs-you "$2: ${tickets[*]}"
}

# drain_wait — end of run: give DRAIN sessions up to subtaskTimeoutMinutes to go idle, then
# leave the rest running. Runs after the digest (never delays the queue-done notice) but
# before strip_pid, so the busy guard still holds while sessions drain.
drain_wait() {
    local agents waited=0 poll fails=0
    poll=$(n1_queue_val pollSeconds)
    while [ "${#DRAIN[@]}" -gt 0 ]; do
        if agents=$(bash -c "$(n1_bg_cmd agents)" 2>/dev/null) && printf '%s' "$agents" | jq -e . >/dev/null 2>&1; then
            fails=0; drain_stop "$agents"
        else
            fails=$((fails + 1))
            [ "$fails" -ge "$BG_POLL_GRACE" ] && { drain_leftover "session list unreadable" "still running after unreadable session list"; break; }
        fi
        [ "${#DRAIN[@]}" -eq 0 ] && break
        [ "$waited" -ge "$TIMEOUT_SECS" ] && { drain_leftover "still finishing up" "still finishing up"; break; }
        sleep "$poll"
        waited=$((waited + poll))
    done
}

# timeout_stop <num> <ticket> <repo> <n1h> <model> <sid> — re-reads status first: the tick's OUTCOME is stale if the child reached step: pr since (N1-77).
timeout_stop() {
    local NUM="$1" TICKET="$2" REPO="$3" N1H="$4" MODEL="$5" SID="$6" OUTCOME
    OUTCOME=$(n1_queue_child_status "$N1H/memory/$TICKET/overview.md" 0 1)
    if [ "$OUTCOME" = "pr" ] || [ "$OUTCOME" = "escalated" ]; then
        [ -n "$SID" ] && DRAIN+=("$SID"$'\t'"$TICKET"$'\t'"$N1H")
        finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "$OUTCOME" ""
        return
    fi
    [ -n "$SID" ] && bash -c "$(n1_bg_cmd stop "$SID")" >/dev/null 2>&1
    finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" "timeout"
}

# --- fullAuto chain (N1-185) ---------------------------------------------------
# chain_authorized <n1-home> — this row's config authorizes an unattended merge (mergeOnFinish AND
# fullAuto). N1_QUEUE_RUN_ID makes n1_merge_authorized take its unattended branch: the runner exports
# neither it nor N1_HEADLESS, and story-mode rows carry their own N1 Home.
chain_authorized() {
    [ "$(N1_HOME="$1" N1_QUEUE_RUN_ID="$RUN_ID" n1_merge_authorized)" = true ]
}

# chain_note <num> <ticket> <why> — the chain ended without a merge: row stays pr, reason recorded.
chain_note() {
    n1_queue_row_status "$QUEUE" "$1" pr "finish:$3"
    echo "[$1] $2 chain: not merged ($3)"
}

# chain_merged <num> <ticket> <repo> <n1-home> <pr-url> — Runs Outcome merged + event, then fast-forward
# the local default branch so the next child branches from the merge (Plan Status stays pr).
chain_merged() {
    local tmp; tmp=$(mktemp "${QUEUE}.XXXXXX")
    awk -v tk="$2" '
    { lines[NR] = $0; n = NR }
    /^## Runs/ { rs = NR }
    END {
        for (i = n; rs && i > rs; i--) if (index(lines[i], "| " tk " |") > 0) {
            split(lines[i], c, "|"); c[5] = " merged "; out = ""
            for (j = 1; j <= 7; j++) out = out c[j] "|"
            lines[i] = out; break
        }
        for (i = 1; i <= n; i++) print lines[i]
    }' "$QUEUE" > "$tmp" && mv "$tmp" "$QUEUE" || rm -f "$tmp"
    ev ticket_finished ticket="$2" outcome=merged pr="$5" session="$(n1_queue_session_id "$QUEUE" "$2")"
    echo "[$1] $2 -> merged $5"
    chain_sync "$1" "$2" "$3" "$4"
}

# chain_sync <num> <ticket> <repo> <n1-home> — fast-forward the local default branch (one retry). A sync
# still failing is recorded on the row (Status stays pr): the next child may branch from a stale local
# default. chain_reconcile reruns it for an already-merged row, so a runner that died between recording
# merged and syncing does not skip the sync for good (fast-forward is idempotent).
chain_sync() {
    N1_HOME="$4" n1_queue_sync_default "$3" </dev/null || N1_HOME="$4" n1_queue_sync_default "$3" </dev/null || {
        n1_queue_row_status "$QUEUE" "$1" pr "finish:sync-failed"
        echo "[$1] $2 merged; local default-branch sync failed in $3 (next child may branch from a stale base)"
    }
}

# chain_reconcile <num> <ticket> <repo> <n1-home> <pr-url> <fin-name> <poll> <marker-state> — marker-hit path:
# wait (bounded) for a live fin session. A session that cannot be confirmed gone (still live at the timeout
# and not stopped, or the agents list unreadable for BG_POLL_GRACE polls) halts the run rather than letting
# the next ticket start while it may still merge. A merged PR gets Runs Outcome merged (once) and the sync
# retried. Returns 10 when the marker says the launch was only intended (crash before launch was confirmed),
# the PR is still OPEN and no fin session is live: the caller launches the owed finish.
chain_reconcile() {
    local agents waited=0 absent=0 fails=0 fid="" out st
    while true; do
        if agents=$(bash -c "$(n1_bg_cmd agents)" 2>/dev/null) && printf '%s' "$agents" | jq -e . >/dev/null 2>&1; then
            fails=0
            fid=$(n1_queue_live_by_name "$agents" "$6")
            if [ -z "$fid" ]; then
                absent=$((absent + 1)); [ "$absent" -ge "$BG_POLL_GRACE" ] && break
            else
                absent=0
            fi
        else
            fails=$((fails + 1))
            [ "$fails" -ge "$BG_POLL_GRACE" ] && halt "chained n1-finish session $6 state unknown for $2 (agents list unreadable)"
        fi
        if [ "$waited" -ge "$TIMEOUT_SECS" ]; then
            if [ -n "$fid" ]; then
                bash -c "$(n1_bg_cmd stop "$fid")" >/dev/null 2>&1
                if agents=$(bash -c "$(n1_bg_cmd agents)" 2>/dev/null) && printf '%s' "$agents" | jq -e . >/dev/null 2>&1 \
                    && [ -z "$(n1_queue_live_by_name "$agents" "$6")" ]; then
                    break
                fi
                halt "chained n1-finish session $6 for $2 still live after the timeout; stop it and re-run"
            fi
            break
        fi
        sleep "$7"; waited=$((waited + $7))
    done
    out=$(awk -F'|' -v tk="$2" '/^## Runs/{f=1;next} f { t=$2; gsub(/ /,"",t); if (t == tk) { o=$5; gsub(/ /,"",o) } } END { print o }' "$QUEUE")
    if [ "$out" = merged ]; then
        chain_sync "$1" "$2" "$3" "$4"
        return 0
    fi
    st=$(n1_queue_pr_state "$5")
    if [ "$st" = MERGED ]; then chain_merged "$1" "$2" "$3" "$4" "$5"; return 0; fi
    [ "$8" = pending ] && [ "$st" = OPEN ] && return 10
    return 0
}

CHAIN_ESC=""   # set by finalize (ticket id) before it removes the question file

# chain_child_escalated <ticket> <n1-home> — exit 0 when the child has a pending escalation: an unanswered
# mirrored question (no relay marker, or the question newer than it), or more "- [headless]" escalation
# entries in its overview than answered ask-mode ledger rows. Stopping such a child would pre-empt the
# human's answer and let the chain merge past a stop-list gate (N1-240 SEC-1). Fails closed.
chain_child_escalated() {
    local qf="$N1_QUEUE_DIR/.question-$1.json" rf="$N1_QUEUE_DIR/.relay-$1" ov="$2/memory/$1/overview.md"
    [ -e "$N1_QUEUE_DIR/.escalated-$1" ] && return 0   # persisted by finalize, reset by its next run
    if [ -e "$qf" ] && { [ ! -e "$rf" ] || [ "$qf" -nt "$rf" ]; }; then return 0; fi
    [ -f "$ov" ] || return 1
    # Per step: an escalation line "- [headless] <step>: ..." needs its own ask-mode answer row
    # "| <step> | headless | ... | headless: ask-mode answer |"; a step with more entries than rows is pending,
    # so extra rows of one step cannot hide another step's escalation.
    awk '/^- \[headless\] /{s=$3; sub(/:$/,"",s); e[s]++}
        /^\|[^|]*\| *headless *\|.*\| *headless: ask-mode answer *\|/{split($0,f,"|"); s=f[2]; gsub(/^ +| +$/,"",s); a[s]++}
        END{for(s in e) if(e[s]>a[s]) exit 0; exit 1}' "$ov" 2>/dev/null
}

# chain_finish <num> <ticket> <repo> <n1-home> <model> <pr-url> — the deterministic fullAuto chain.
# No-op unless chain_authorized. Waits for the child session to go idle (a child blocked for BG_POLL_GRACE polls is stopped; it may still run CI watch or
# its own prose chain), skips when the PR is already MERGED or not OPEN, else launches a bg
# `n1-finish <ticket> chained` session and waits for it. Blocking on purpose: the next child must
# branch from the merged default branch. .chained-<ticket> (line 1 run id, line 2 pending|launched|done) is
# written before the gh check, so the chain is evaluated once per run, also across a runner restart; a
# restart finding it pending (launch intended, not confirmed) relaunches for a still-OPEN PR. The runner never
# merges: n1-finish merges only at the reviewed pin, and the merge-deny hook still applies.
# Every exit writes a "[NUM] TICKET chain: ..." line to runner.log (N1-240).
chain_finish() {
    local NUM="$1" TICKET="$2" REPO="$3" N1H="$4" MODEL="$5" URL="$6"
    local marker mstate rc=0 csid fsid st agents out poll waited=0 fails=0 miss=0 idle=0 blk=0 chk stopped=0 asked="" why=finish-timeout
    # N1-240: every exit writes a runner.log line. The raw id is not echoed (it failed validation).
    case "$TICKET" in ''|*[!A-Za-z0-9_-]*) echo "[$NUM] chain: skipped (invalid-ticket-id)"; return 0 ;; esac
    chain_authorized "$N1H" || { echo "[$NUM] $TICKET chain: skipped (chain_authorized=false)"; return 0; }
    marker="$N1_QUEUE_DIR/.chained-$TICKET"
    poll=$(n1_queue_val pollSeconds)
    mark() { printf '%s\n%s\n' "$RUN_ID" "$1" > "$marker"; }
    if [ "$(head -n1 "$marker" 2>/dev/null)" = "$RUN_ID" ]; then
        # Chain already evaluated this run (restart): never launch a second finish for a confirmed launch;
        # reconcile an orphaned -fin session. Only a marker still "pending" (crash between the marker and
        # the confirmed launch) with an OPEN PR and no live session falls through to launch the owed finish.
        mstate=$(sed -n 2p "$marker" 2>/dev/null)
        chain_reconcile "$NUM" "$TICKET" "$REPO" "$N1H" "$URL" "n1-${QUEUE_ID}-${TICKET}-${NUM}-fin" "$poll" "$mstate" || rc=$?
        [ "$rc" -eq 10 ] || { echo "[$NUM] $TICKET chain: already evaluated (marker=${mstate:-unknown})"; return 0; }
    else
    csid=$(n1_queue_session_id "$QUEUE" "$TICKET")
    while true; do
        if agents=$(bash -c "$(n1_bg_cmd agents)" 2>/dev/null) && printf '%s' "$agents" | jq -e . >/dev/null 2>&1; then
            drain_stop "$agents"
            [ -n "$csid" ] || break
            case "$(n1_queue_bg_state "$agents" "$csid")" in
                working) idle=0; blk=0 ;;
                blocked)
                    # N1-240: a child parked on a question after its PR never goes idle on its own; waiting
                    # would end in finish-child-busy. Stop it and chain only when the block is benign: a
                    # pending escalation keeps the row awaiting-human, and the stop must be confirmed
                    # (re-read up to BG_POLL_GRACE times, the stop is not instantaneous) before n1-finish launches.
                    idle=0
                    if [ "$CHAIN_ESC" = "$TICKET" ] || chain_child_escalated "$TICKET" "$N1H"; then
                        chain_note "$NUM" "$TICKET" child-escalated; return 0
                    fi
                    blk=$((blk + 1))
                    if [ "$blk" -ge "$BG_POLL_GRACE" ]; then
                        bash -c "$(n1_bg_cmd stop "$csid")" >/dev/null 2>&1
                        for ((chk = 0; chk < BG_POLL_GRACE; chk++)); do
                            if agents=$(bash -c "$(n1_bg_cmd agents)" 2>/dev/null) && printf '%s' "$agents" | jq -e . >/dev/null 2>&1 \
                                && case "$(n1_queue_bg_state "$agents" "$csid")" in working|blocked) false ;; esac; then
                                stopped=1; break
                            fi
                            sleep "$poll"
                        done
                        [ "$stopped" = 1 ] || { chain_note "$NUM" "$TICKET" child-stop-failed; return 0; }
                        echo "[$NUM] $TICKET chain: stopped blocked child ($csid)"
                        break
                    fi ;;
                missing) blk=0; idle=$((idle + 1)); [ "$idle" -ge "$BG_POLL_GRACE" ] && break ;;
                *) break ;;
            esac
        fi
        [ "$waited" -ge "$TIMEOUT_SECS" ] && { chain_note "$NUM" "$TICKET" finish-child-busy; return 0; }
        sleep "$poll"; waited=$((waited + poll))
    done
    # N1-240 SEC-1: every exit of the wait loop (no session id, missing, done, failed, stopped) and the restart
    # sweep pass here; a child with a pending escalation is never chained, whatever state it reports.
    if [ "$CHAIN_ESC" = "$TICKET" ] || chain_child_escalated "$TICKET" "$N1H"; then
        chain_note "$NUM" "$TICKET" child-escalated; return 0
    fi
    mark pending || { chain_note "$NUM" "$TICKET" marker-write-failed; return 0; }
    fi
    st=$(n1_queue_pr_state "$URL")
    case "$st" in
        MERGED) mark done; chain_merged "$NUM" "$TICKET" "$REPO" "$N1H" "$URL"; return 0 ;;
        OPEN) ;;
        '') mark done; chain_note "$NUM" "$TICKET" pr-state-unreadable; return 0 ;;
        *) mark done; chain_note "$NUM" "$TICKET" pr-not-open; return 0 ;;
    esac
    out=$(bash -c "$(n1_queue_finish_cmd "$REPO" "$TICKET" "$MODEL" "$RUN_ID" "n1-${QUEUE_ID}-${TICKET}-${NUM}-fin")" 2>&1)
    if ! fsid=$(n1_queue_parse_launch "$out"); then
        mark done; chain_note "$NUM" "$TICKET" finish-launch-failed
        return 0
    fi
    mark launched
    echo "[$NUM] $TICKET n1-finish chained ($fsid)"
    waited=0
    while [ "$waited" -le "$TIMEOUT_SECS" ]; do
        if agents=$(bash -c "$(n1_bg_cmd agents)" 2>/dev/null) && printf '%s' "$agents" | jq -e . >/dev/null 2>&1; then
            fails=0
            st=$(n1_queue_bg_state "$agents" "$fsid")
            case "$st" in
                done|failed) why=finish-stopped; break ;;
                missing) miss=$((miss + 1)); [ "$miss" -ge "$BG_POLL_GRACE" ] && { why=finish-not-listed; break; } ;;
                blocked)
                    if [ -z "$asked" ]; then
                        asked=1
                        ev escalated ticket="$TICKET" session="$fsid" reason="chained n1-finish needs you"
                        n1_notify needs-you "$TICKET n1-finish needs you (resume: $(n1_bg_cmd attach "$fsid"))"
                    fi ;;
                *) asked=""; miss=0 ;;
            esac
        else
            fails=$((fails + 1))
            [ "$fails" -ge "$BG_POLL_GRACE" ] && { why=finish-agents-unreadable; break; }
        fi
        sleep "$poll"; waited=$((waited + poll))
    done
    if [ "$why" = finish-timeout ]; then
        bash -c "$(n1_bg_cmd stop "$fsid")" >/dev/null 2>&1
    else
        DRAIN+=("$fsid"$'\t'"$TICKET"$'\t'"$N1H")
    fi
    st=$(n1_queue_pr_state "$URL")
    case "$st" in
        MERGED) chain_merged "$NUM" "$TICKET" "$REPO" "$N1H" "$URL" ;;
        '') chain_note "$NUM" "$TICKET" pr-state-unreadable ;;
        *) chain_note "$NUM" "$TICKET" "$why" ;;
    esac
}

# run_bg — background sessions, still sequential: launch the next pending ticket only when
# no launched child is working. blocked -> awaiting-human (no strike) and the queue moves on.
# Working time is capped by subtaskTimeoutMinutes; at end of queue, parked rows are polled
# for up to subtaskTimeoutMinutes after the last park, then left awaiting-human (never relaunched).
# A finished child (pr/escalated) queues into DRAIN and is stopped only once
# drain_stop sees it idle (done/failed) — not immediately on the terminal step.
run_bg() {
    local POLL AGENTS WORKING ROW NUM TICKET REPO N1H MODEL STATUS STATE OUTCOME SID
    # ponytail: WORKED/SINCE_PARK live only in this process's memory. If the runner
    # crashes and restarts (busy guard lets a new run start once the old pid is dead),
    # both budgets reset to 0 even though the background sessions survived the crash —
    # a ticket already 170 of 180 minutes in gets a fresh 180. Add persisted elapsed-time
    # tracking (e.g. derive from the Runs row's Started timestamp) if crash-resume timing
    # accuracy matters; no test or AC currently requires it.
    local SINCE_PARK=0 AGENT_FAILS=0 HELD_WAIT=0 HELD
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
        drain_stop "$AGENTS"
        WORKING=0
        while IFS=$'\t' read -r NUM TICKET REPO N1H MODEL STATUS; do
            SID=$(n1_queue_session_id "$QUEUE" "$TICKET")
            # N1-82: in-progress with no Session cell = the runner died between launch and the Runs
            # write. Adopt the live session this run launched instead of failing and relaunching the row.
            if [ -z "$SID" ]; then
                SID=$(live_row_sid "$NUM" "$TICKET" "$AGENTS")
                if [ -n "$SID" ]; then
                    echo "| $TICKET | $(date -u +%Y-%m-%dT%H:%M:%SZ) | | | | $SID |" >> "$QUEUE"
                    echo "[$NUM] $TICKET adopted live session ($SID)"
                fi
            fi
            STATE=$(n1_queue_bg_state "$AGENTS" "$SID")
            # NP-216: overview.md is ground truth, bg state is only a liveness hint — a
            # finished child can report working/blocked/missing on a stale or vanished
            # session. Reconcile before trusting STATE, so a done ticket is never timed
            # out, retried, or parked awaiting-human.
            OUTCOME=$(n1_queue_child_status "$N1H/memory/$TICKET/overview.md" 0 1)
            if [ "$OUTCOME" = "pr" ] || [ "$OUTCOME" = "escalated" ]; then
                [ -n "$SID" ] && DRAIN+=("$SID"$'\t'"$TICKET"$'\t'"$N1H")
                finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "$OUTCOME" ""
                continue
            fi
            # N1-55: n1_queue_answer stops then bg-resumes a parked child. While its fresh relay
            # marker exists, a non-working/blocked reading is that gap, not a dead child: hold it
            # as working (no finalize, no grace burn, no end-of-queue exit). The hold accrues
            # WORKED, so a refreshed marker can't hold a dead child past the subtask timeout.
            case "$STATE" in
                working|blocked) ;;
                *) if n1_queue_relay_active "$N1_QUEUE_DIR" "$TICKET"; then
                       WORKED[NUM]=$(( ${WORKED[NUM]:-0} + POLL ))
                       if [ "${WORKED[NUM]}" -le "$TIMEOUT_SECS" ]; then WORKING=1; continue; fi
                       timeout_stop "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "$SID"
                       continue
                   fi ;;
            esac
            case "$STATE" in
                missing)
                    MISSING[NUM]=$(( ${MISSING[NUM]:-0} + 1 ))
                    if [ "${MISSING[NUM]}" -ge "$BG_POLL_GRACE" ]; then
                        finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" "bg-session-not-listed"
                        continue
                    fi
                    WORKED[NUM]=$(( ${WORKED[NUM]:-0} + POLL ))
                    if [ "${WORKED[NUM]}" -le "$TIMEOUT_SECS" ]; then WORKING=1; continue; fi
                    timeout_stop "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "$SID"
                    ;;
                working)
                    MISSING[NUM]=0
                    if [ "$STATUS" = "awaiting-human" ]; then
                        n1_queue_row_status "$QUEUE" "$NUM" "in-progress"
                        rm -f "$N1_QUEUE_DIR/.esc-reason-$TICKET"
                        ev unblocked ticket="$TICKET" session="$SID"
                    fi
                    WORKED[NUM]=$(( ${WORKED[NUM]:-0} + POLL ))
                    if [ "${WORKED[NUM]}" -le "$TIMEOUT_SECS" ]; then WORKING=1; continue; fi
                    timeout_stop "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "$SID"
                    ;;
                blocked)
                    if [ "$STATUS" != "awaiting-human" ]; then
                        n1_queue_row_status "$QUEUE" "$NUM" "awaiting-human"
                        SINCE_PARK=0
                        rm -f "$N1_QUEUE_DIR/.relay-$TICKET"
                        echo "[$NUM] $TICKET -> awaiting-human"
                        PARKED[NUM]=1
                        escalate "$TICKET" "$N1H"
                    elif [ -e "$N1_QUEUE_DIR/.relay-$TICKET" ] && [ "$N1_QUEUE_DIR/.question-$TICKET.json" -nt "$N1_QUEUE_DIR/.relay-$TICKET" ]; then
                        # N1-55: an answered child re-blocked on a new question before any poll saw
                        # it working; dropping the marker escalates this question exactly once.
                        rm -f "$N1_QUEUE_DIR/.relay-$TICKET" "$N1_QUEUE_DIR/.esc-reason-$TICKET"
                        SINCE_PARK=0
                        echo "[$NUM] $TICKET -> awaiting-human (new question)"
                        escalate "$TICKET" "$N1H"
                    fi
                    ;;
                done)
                    # OUTCOME is "running" here (pr/escalated already
                    # finalized above): the bg session ended without the overview ever
                    # reaching a terminal step. N1-182: an off-script child may still have
                    # opened a PR without recording pr_url; that is a pr, not a retry.
                    OPEN_PR=$(n1_queue_child_open_pr "$TICKET" "$N1H" "$REPO" "${STARTED_AT[NUM]:-}")
                    if [ -n "$OPEN_PR" ]; then
                        finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "pr" "" "" "$OPEN_PR"
                    else
                        finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" "child-exited-incomplete"
                    fi
                    ;;
                failed|*) finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" "bg-state:$STATE" ;;
            esac
        done < <(n1_queue_pending_rows "$QUEUE" 'in-progress|awaiting-human')

        if [ "$WORKING" = 0 ]; then
            ROW=$(n1_queue_pending_rows "$QUEUE" | head -1)
            if [ -n "$ROW" ]; then
                launch_bg "$ROW" "$AGENTS"
                HELD_WAIT=0
            else
                # N1-64/N1-114: held rows (same-plan blocker) are never launched directly; the
                # sweep releases one to pending once the user merges its blocker's PR.
                HELD=$(n1_queue_held_sweep "$QUEUE")
                if [ -n "$(n1_queue_pending_rows "$QUEUE")" ]; then
                    # N1-114: the sweep just released a row; the next tick launches it, whatever the held timeout says.
                    HELD_WAIT=0
                elif [ -n "$(n1_queue_parked_rows "$QUEUE")" ]; then
                    # Parked rows wait on the human; the parked wait below bounds held rows too.
                    HELD_WAIT=0
                    if [ "$SINCE_PARK" -ge "$TIMEOUT_SECS" ]; then
                        [ "$HELD" -gt 0 ] && n1_queue_held_expire "$QUEUE"
                        echo "awaiting-human rows left for the user; queue done"
                        break
                    fi
                elif [ "$HELD" -gt 0 ] && [ "$HELD_WAIT" -lt "$TIMEOUT_SECS" ]; then
                    HELD_WAIT=$((HELD_WAIT + POLL))
                else
                    [ "$HELD" -gt 0 ] && { n1_queue_held_expire "$QUEUE"; echo "held rows expired (blocker not merged)"; }
                    break
                fi
            fi
        fi
        SINCE_PARK=$((SINCE_PARK + POLL))
        sleep "$POLL"
    done
}

# N1-185: a chain owed from before a runner restart (row already pr, no .chained marker for this run).
# Only rows this run finalized (finalize stamps queue_run_id on the overview): a pr row left over from an
# earlier run, or from a run with the flags off, is never merged by a later run's sweep.
while IFS=$'\t' read -r NUM TICKET REPO N1H MODEL _; do
    OV="$N1H/memory/$TICKET/overview.md"
    [ "$(n1_read_frontmatter "$OV" queue_run_id 2>/dev/null)" = "$RUN_ID" ] || continue
    chain_finish "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "$(n1_queue_child_pr_url "$OV")" </dev/null
done < <(n1_queue_pending_rows "$QUEUE" pr)

run_bg

# --- Done --------------------------------------------------------------------
count_rows() { n1_queue_pending_rows "$QUEUE" "$1" | wc -l | tr -d ' '; }
DIGEST="$(count_rows pr) PR / $(count_rows 'awaiting-human|escalated') awaiting / $(count_rows failed) failed"
release_backstop
ev queue_done reason="$DIGEST"
n1_notify done "Queue $QUEUE_ID: $DIGEST"
n1_write_frontmatter "$QUEUE" step done
drain_wait
strip_pid
exit 0

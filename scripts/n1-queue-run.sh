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
source "$N1_ROOT/lib/orca-queue.sh"

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
# N1-267: last counted strike (reason, epoch). Orca only: a subtask-timeout within STRIKE_WINDOW seconds of the last counted one
# shares one cause (a usage-limit wait, an outage) and adds no strike.
STRIKE_REASON="" STRIKE_AT=0 STRIKE_WINDOW=300
# N1-268: set (to the halt reason) when a halt arrives while run_orca still owns unsettled workers: launches stop,
# supervision goes on, and the final halt runs once the loop ends. ORCA_LOOP is 1 inside run_orca.
HALT_DRAIN="" ORCA_LOOP=""
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
    local sid q qfile qfull reason mark key
    sid=$(n1_queue_session_id "$QUEUE" "$1")
    # N1-241: newest entry, so an appended entry changes the reason and the watch dedupe relays it.
    q=$(n1_queue_escalation_text "$2/memory/$1/overview.md" last)
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
    # SEC-1: the key also holds the state argument and a checksum of the whole ## Escalations
    # section, so a terminal stop or any appended entry re-arms the alert.
    key="${3:-}"$'\t'"$q"$'\t'$(awk '/^## Escalations/{f=1;next} /^## /{f=0} f' "$2/memory/$1/overview.md" 2>/dev/null | cksum)
    if [ -n "$mark" ] && [ -f "$mark" ] && [ "$(cat "$mark" 2>/dev/null)" = "$key" ]; then
        return 0
    fi
    [ -n "$mark" ] && { printf '%s' "$key" > "$mark"; } 2>/dev/null || true
    if [ "${3:-}" = "stopped" ]; then
        ev escalated ticket="$1" session="$sid" reason="$reason" outcome=terminal
    else
        ev escalated ticket="$1" session="$sid" reason="$reason"
    fi
    if [ "${3:-}" = "stopped" ]; then
        n1_notify needs-you "$1 needs you: ${q:-waiting for an answer} (resume: n1-start $1)"
    elif [ "${sid#orca:}" != "$sid" ]; then
        n1_notify needs-you "$1 needs you: ${q:-waiting for an answer} (answer: /n1:n1-queue --answer $1 <text>)"
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

# halt_now <message> — record, notify, and stop the runner (exit 2).
halt_now() {
    n1_write_frontmatter "$QUEUE" step halted
    ev halted reason="$1"
    release_backstop
    n1_notify needs-you "Queue $QUEUE_ID halted: ${1:0:200}"
    echo "$1"
    drain_wait
    strip_pid
    exit 2
}

# halt <message> — N1-268: inside run_orca with workers in flight (rows in-progress/awaiting-human, or OWED from
# run_orca's dynamic scope), stop launching but keep supervising (questions, settle, merged recording); step stays
# run and the halted event (which ends the session watch) waits for halt_now after the loop. Idempotent.
halt() {
    if [ -n "$ORCA_LOOP" ] && { [ -n "$(n1_queue_pending_rows "$QUEUE" 'in-progress|awaiting-human')" ] || [ -n "${OWED// /}" ]; }; then
        [ -n "$HALT_DRAIN" ] && return 0
        HALT_DRAIN="$1"
        ev halt_draining reason="$1"
        n1_notify needs-you "Queue $QUEUE_ID halted: ${1:0:160}; still supervising live workers. Stop them: /n1:n1-queue --stop $QUEUE_ID"
        echo "$1 (supervising live workers until they finish or are stopped)"
        return 0
    fi
    halt_now "$1"
}

ev queue_started

# finalize <num> <ticket> <repo> <n1-home> <model> <outcome> <exit> [reason] [pr-url] [nodefer]
# Records a terminal outcome: Runs + Plan rows, defer-once, three-strikes (may exit 2).
finalize() {
    local NUM="$1" TICKET="$2" REPO="$3" N1H="$4" MODEL="$5" OUTCOME="$6" EXIT="$7" REASON="${8:-}" PR_FOUND="${9:-}"
    local NODEFER="${10:-}"
    local OVERVIEW="$N1H/memory/$TICKET/overview.md" EXISTING_REASON PR_URL="" NEXT_NUM TITLE EV_OUTCOME="$OUTCOME" DUR=""
    # NP-216 AC3 safety net: every failed/deferred Runs row must carry a non-empty
    # reason. Call sites should already pass one; this is the last line of defense.
    [ "$OUTCOME" = "failed" ] && [ -z "$REASON" ] && REASON="unspecified-failure"
    # N1-240: snapshot the escalation state chain_finish needs before the files below are removed.
    CHAIN_ESC=""
    chain_child_escalated "$TICKET" "$N1H" && CHAIN_ESC="$TICKET"
    # Persist it too: a runner restart loses CHAIN_ESC and the question files are removed below.
    if [ -n "$CHAIN_ESC" ]; then : > "$N1_QUEUE_DIR/.escalated-$TICKET"; else rm -f "$N1_QUEUE_DIR/.escalated-$TICKET"; fi
    rm -f "$N1_QUEUE_DIR/.question-$TICKET.json" "$N1_QUEUE_DIR/.relay-$TICKET" "$N1_QUEUE_DIR/.launch-$NUM" "$N1_QUEUE_DIR/.ask-$TICKET"
    # N1-225: an Orca row's identity is never removed here: a timed-out worker may still be running. orca_settle
    # removes it once the worker reported done, is durably finished, or is proven exited.
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
    if [ "$OUTCOME" = "failed" ] && [ "$EXISTING_REASON" != "deferred-retry" ] && [ "$NODEFER" != nodefer ]; then
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

    # Three-strikes counter. N1-267: under Orca concurrency, a subtask-timeout right after a counted subtask-timeout
    # within STRIKE_WINDOW adds no strike (launch/exit failures stay systemic), so one cause timing out several rows neither halts nor stops the tick's other rows.
    case "$OUTCOME" in
        failed|escalated)
            if [ -n "${ORCA_RUN:-}" ] && [ "$OUTCOME" = failed ] && [ "$REASON" = subtask-timeout ] && [ "$REASON" = "$STRIKE_REASON" ] \
                && [ $(( $(date +%s) - STRIKE_AT )) -lt "$STRIKE_WINDOW" ]; then
                echo "[$NUM] $TICKET: same reason as the last strike ($REASON), not counted"
            else
                CONSECUTIVE_FAIL=$((CONSECUTIVE_FAIL + 1)); STRIKE_REASON="$REASON"; STRIKE_AT=$(date +%s)
            fi ;;
        pr|awaiting-human) CONSECUTIVE_FAIL=0; STRIKE_REASON="" ;;
    esac
    if [ "$CONSECUTIVE_FAIL" -ge 3 ]; then
        halt "HALTED after 3 consecutive non-success"
    fi

    echo "[$NUM] $TICKET -> $OUTCOME $PR_URL"
    # N1-185: one funnel for the three pr sites (reconcile, timeout_stop, open-PR rescue). The chain gets
    # /dev/null on stdin; the row loops read fd 3 (N1-265), so nothing here can consume their rows.
    # N1-225: in Orca mode the chain runs from run_orca's settle step, once the worker reported done or exited.
    [ "$OUTCOME" = pr ] && [ -z "${ORCA_RUN:-}" ] && chain_finish "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "$PR_URL" </dev/null
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
                ev unblocked ticket="$ticket" session="$sid"
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
    n1_queue_runs_outcome "$QUEUE" "$2" merged
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
            [ "$fails" -ge "$BG_POLL_GRACE" ] && halt_now "chained n1-finish session $6 state unknown for $2 (agents list unreadable)"
        fi
        if [ "$waited" -ge "$TIMEOUT_SECS" ]; then
            if [ -n "$fid" ]; then
                bash -c "$(n1_bg_cmd stop "$fid")" >/dev/null 2>&1
                if agents=$(bash -c "$(n1_bg_cmd agents)" 2>/dev/null) && printf '%s' "$agents" | jq -e . >/dev/null 2>&1 \
                    && [ -z "$(n1_queue_live_by_name "$agents" "$6")" ]; then
                    break
                fi
                halt_now "chained n1-finish session $6 for $2 still live after the timeout; stop it and re-run"
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
    case "$csid" in orca:*) csid="" ;; esac  # N1-225: an Orca worker has already settled (worker_done/exited) here
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
        while IFS=$'\t' read -r -u 3 NUM TICKET REPO N1H MODEL STATUS; do
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
        done 3< <(n1_queue_pending_rows "$QUEUE" 'in-progress|awaiting-human')

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

# --- Orca orchestration backend (N1-225) --------------------------------------
ORCA_RUN=""

# orca_row_of_task <task> — "<ticket>\t<dispatch>" of the Runs row whose Session cell is orca:<task>/<dispatch>.
orca_row_of_task() { n1_orca_row_of_task "$QUEUE" "$1"; }

# orca_n1h_of <ticket> — the ticket's N1 Home cell (last Plan row for it).
orca_n1h_of() {
    awk -F'|' -v tk="$1" '{ n = $2; t = $3; h = $6
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", n); gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); gsub(/^[[:space:]]+|[[:space:]]+$/, "", h) }
        n ~ /^[0-9]+$/ && t == tk { r = h } END { print r }' "$QUEUE"
}

# launch_orca <pending-row> — task, identity sentinel, then worker. The Runs row is written once the dispatch
# exists; .launch-<num> holds "<run-id> <task>" so a runner that dies in between adopts the worker, never relaunches.
launch_orca() {
    local NUM TICKET REPO N1H MODEL STARTED TASK DISP
    IFS=$'\t' read -r NUM TICKET REPO N1H MODEL _ <<< "$1"
    STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    STARTED_AT[NUM]=$(date +%s)
    n1_queue_row_status "$QUEUE" "$NUM" "in-progress"
    # Re-queued ticket: forget the previous run's tag release (NP-199).
    n1_write_frontmatter "$N1H/memory/$TICKET/overview.md" queue_tag_removed false || true
    if n1_orca_worktree_taken "$TICKET"; then
        # A leftover worktree named like the ticket: Orca may rename the new one, and the child would then miss its
        # sentinel. Fail the row (no retry) instead; the user removes the old worktree and re-queues.
        echo "| $TICKET | $STARTED | | | | |" >> "$QUEUE"
        finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" "orca-worktree-name-taken" "" nodefer
        return
    fi
    if ! TASK=$(n1_orca_task_create "$ORCA_RUN" "$TICKET"); then
        echo "| $TICKET | $STARTED | | | | |" >> "$QUEUE"
        finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" "orca-task-create"
        return
    fi
    if ! printf '%s %s\n' "$RUN_ID" "$TASK" > "$N1_QUEUE_DIR/.launch-$NUM" \
        || ! n1_orca_sentinel_write "$N1H" "$TICKET" "$REPO" "$RUN_ID" "$ORCA_RUN" "$TASK"; then
        # No child is ever started without its unattended identity.
        echo "| $TICKET | $STARTED | | | | |" >> "$QUEUE"
        finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" "sentinel-unwritable"
        return
    fi
    if ! DISP=$(n1_orca_worker_start "$ORCA_RUN" "$TASK" "$TICKET" "$REPO" "$MODEL"); then
        # A timeout or lost response does not prove the worker never started: drop the identity only when a readable
        # worker list shows no worker for this task (else it stays; the user stops the worker in Orca).
        if L=$(n1_orca_liveness "$ORCA_RUN") && ! awk -F'\t' -v k="$TASK" '$2 == k { f = 1 } END { exit !f }' <<< "$L"; then
            n1_orca_sentinel_rm "$N1H" "$TICKET" "$TASK"
        fi
        echo "| $TICKET | $STARTED | | | | |" >> "$QUEUE"
        echo "[$NUM] $TICKET launch failed: $DISP"
        # Orca forbids a blind relaunch after a failed worker-start (residual resources): no deferred retry.
        finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" "$DISP" "" nodefer
        return
    fi
    n1_orca_sentinel_set "$N1H" "$TICKET" N1_ORCA_DISPATCH "$DISP"
    echo "| $TICKET | $STARTED | | | | orca:$TASK/$DISP |" >> "$QUEUE"
    rm -f "$N1_QUEUE_DIR/.esc-reason-$TICKET"
    ev ticket_started ticket="$TICKET" session="orca:$TASK/$DISP"
    echo "[$NUM] $TICKET launched as Orca worker ($DISP)"
}

# orca_settle <task> — release the worker, drop its sentinel, run the owed fullAuto chain (once). Uses run_orca's
# SETTLED/OWED (dynamic scope). A task whose row is still in flight waits.
orca_settle() {
    local TASK="$1" T DISP ROW NUM TICKET REPO N1H MODEL URL
    [[ "$SETTLED" == *" $TASK "* ]] && return
    IFS=$'\t' read -r T DISP <<< "$(orca_row_of_task "$TASK")"
    [ -n "$T" ] || return
    [ -z "$(n1_queue_pending_rows "$QUEUE" 'in-progress|awaiting-human' | awk -F'\t' -v t="$T" '$2 == t')" ] || return
    SETTLED="$SETTLED$TASK "; OWED="${OWED// $TASK / }"
    n1_orca_release "$DISP"
    ROW=$(n1_queue_pending_rows "$QUEUE" pr | awk -F'\t' -v t="$T" '$2 == t' | tail -1)
    if [ -n "$ROW" ]; then
        IFS=$'\t' read -r NUM TICKET REPO N1H MODEL _ <<< "$ROW"
        URL=$(n1_queue_child_pr_url "$N1H/memory/$TICKET/overview.md")
        chain_finish "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "$URL" </dev/null
        URL=$(n1_queue_attested_pr "$QUEUE" "$TICKET" "$N1H")   # N1-268: only a PR attributed to this run is recorded merged
        # N1-268: a worker that merged its own PR (its own fullAuto finish) is recorded merged even when the
        # runner's chain did not run or did not merge.
        if [ "$(_n1_queue_run_outcome "$QUEUE" "$TICKET")" != merged ] && [ "$(n1_queue_pr_state "$URL")" = MERGED ]; then
            n1_queue_runs_outcome "$QUEUE" "$TICKET" merged "$URL"
            ev ticket_finished ticket="$TICKET" outcome=merged pr="$URL" session="$(n1_queue_session_id "$QUEUE" "$TICKET")"
            echo "[$NUM] $TICKET -> merged $URL"
        fi
    fi
    # Last: a restart re-owes a pr row only while its sentinel still names the task, so a crash mid-chain re-runs it.
    n1_orca_sentinel_rm "$(orca_n1h_of "$T")" "$T" "$TASK"
}

# run_orca — Orca workers, up to queue.maxConcurrent at once (run_bg stays sequential). Each tick waits on the Run
# inbox (check --wait: worker_done, escalation, question), re-reads the worker list (worker-list), then reconciles
# every live row from overview.md, the ground truth, so a lost or lying worker_done is corrected. worker_done (the
# fast path), a durable terminal worker state (n1_orca_liveness field 4) or positive proof of exit settles a worker
# (release + sentinel removal + owed fullAuto chain); running or unverifiable workers are never relaunched, stopped
# or released. Held/parked/end-of-queue handling mirrors run_bg.
run_orca() {
    local STOP_OK POLL MAXC MERGE ELIG BATCH EVS TYPE TASK MSG T DISP L ROW NUM TICKET REPO N1H MODEL STATUS SID OUTCOME OPEN_PR HELD INFLIGHT TICK0 CHARGE OWEDN
    ORCA_LOOP=1
    # N1-268: a marker from another run (a dead runner's era) never stops this one; the current run's own marker stays
    [ "$(cat "$N1_QUEUE_DIR/.stop" 2>/dev/null)" = "$RUN_ID" ] || rm -f "$N1_QUEUE_DIR/.stop"
    local LIVE="" LIVE_OK=0 DONE=" " SETTLED=" " OWED=" " SEEN=" " OWED_NOTED="" FAILS=0 HELD_WAIT=0 SINCE_PARK=0 OWED_WAIT=0
    local -a WORKED=() STALLED=()
    POLL=$(n1_queue_val pollSeconds)
    # N1-303: the plan pins max_concurrent; live config is read only for a plan made before it (legacy).
    MAXC=$(n1_read_frontmatter "$QUEUE" max_concurrent 2>/dev/null)
    if [[ ! "$MAXC" =~ ^[1-9][0-9]*$ ]]; then
        MAXC=$(n1_queue_val maxConcurrent); [[ "$MAXC" =~ ^[1-9][0-9]*$ ]] || MAXC=3
        echo "queue.md has no max_concurrent (planned before N1-303); using live queue.maxConcurrent=$MAXC"
    fi
    # N1-303: an overlap successor waits for its predecessor's merge only when the queue merges its own PRs.
    # ponytail: one queue-level answer from the queue's home; story-mode rows with their own homes share it in practice.
    MERGE=false; chain_authorized "$(n1_home)" && MERGE=true
    LIVE_OK=1; LIVE=$(n1_orca_liveness "$ORCA_RUN") || { LIVE=""; LIVE_OK=0; }
    # A runner restart loses OWED: re-owe this run's finished rows that are not settled yet (settle removes the
    # sentinel, so a row whose sentinel still names its task is the unsettled one).
    while IFS=$'\t' read -r NUM TICKET REPO N1H MODEL _; do
        [ "$(n1_read_frontmatter "$N1H/memory/$TICKET/overview.md" queue_run_id 2>/dev/null)" = "$RUN_ID" ] || continue
        SID=$(n1_queue_session_id "$QUEUE" "$TICKET"); case "$SID" in orca:*/*) TASK="${SID#orca:}"; TASK="${TASK%%/*}" ;; *) continue ;; esac
        [ "$(_n1_orca_sget "$(n1_orca_sentinel_path "$N1H" "$TICKET")" N1_ORCA_TASK)" = "$TASK" ] && OWED="$OWED$TASK "
    done < <(n1_queue_pending_rows "$QUEUE" pr)
    while true; do
        TICK0=$(date +%s)
        # An unreadable inbox skips the tick: never treat a CLI hiccup as dead children.
        if ! BATCH=$(n1_orca_check "$ORCA_RUN" "$POLL") || ! jq -e '.ok == true' >/dev/null 2>&1 <<< "$BATCH"; then
            FAILS=$((FAILS + 1))
            [ "$FAILS" -ge "$BG_POLL_GRACE" ] && halt_now "HALTED: Orca run inbox unreadable for $BG_POLL_GRACE polls in a row"
            sleep "$POLL"
            continue
        fi
        FAILS=0
        EVS=$(n1_orca_events "$BATCH")
        # Time charged to this tick: a full wait only for a truly empty batch, else the real time spent (an early
        # return, a heartbeat, or a replayed batch must not count as a whole poll interval).
        if [ -n "$EVS" ]; then CHARGE=$(( $(date +%s) - TICK0 )); else CHARGE=$POLL; fi
        # N1-265: loops that can reach n1_notify read fd 3; a notifier backend that reads fd 0
        # (WSL powershell.exe drains it) must never consume the remaining rows or events.
        while IFS=$'\t' read -r -u 3 TYPE TASK MSG MDISP; do
            _n1_orca_id "$TASK" || continue
            [ "$MSG" != "-" ] || MSG=""; [ "$MDISP" != "-" ] || MDISP=""   # "-" = empty field (see n1_orca_events)
            IFS=$'\t' read -r T DISP <<< "$(orca_row_of_task "$TASK")"
            [ -n "$T" ] || continue
            # The message must name the dispatch the Runs row holds: a task id alone must not act on another's row.
            [ -n "$MDISP" ] && [ "$MDISP" = "$DISP" ] || continue
            # A replayed message (a missed ack) must not redo its effect, e.g. re-park an answered row.
            [ -z "$MSG" ] || [[ "$SEEN" != *" $MSG "* ]] || continue
            SEEN="$SEEN${MSG:+$MSG }"
            case "$TYPE" in
                worker_done) DONE="$DONE$TASK " ;;
                question) _n1_orca_id "$MSG" && printf '%s\n' "$MSG" > "$N1_QUEUE_DIR/.ask-$T" ;;
                escalation) escalate "$T" "$(orca_n1h_of "$T")" ;;
            esac
        done 3<<< "$EVS"
        n1_orca_ack "$ORCA_RUN" "$BATCH"
        # N1-281: durable worker state every tick (the inbox is only the fast path). A failed read keeps the last
        # list and disables the absence rule below (LIVE_OK=0).
        if L=$(n1_orca_liveness "$ORCA_RUN"); then LIVE="$L"; LIVE_OK=1; else LIVE_OK=0; fi
        # N1-268: n1-queue --stop (user-confirmed) left a marker: close each unsettled worker's own terminal and record
        # it stopped (a merged PR is only recorded), then stop launching; the loop ends through the end-of-queue
        # branch and the final halt. A worker whose close failed keeps its row and identity and is supervised on.
        # The marker is the user's confirmation: stop.md writes this queue's run_id into it (queue children are denied
        # the file by the policy hook); any other content is discarded unread.
        if [ -f "$N1_QUEUE_DIR/.stop" ]; then
            STOP_OK=0; [ "$(cat "$N1_QUEUE_DIR/.stop" 2>/dev/null)" = "$RUN_ID" ] && STOP_OK=1
            rm -f "$N1_QUEUE_DIR/.stop"
        else
            STOP_OK=0
        fi
        if [ "$STOP_OK" = 1 ]; then
            [ -n "$HALT_DRAIN" ] || { HALT_DRAIN="stopped by user"; ev halt_draining reason="$HALT_DRAIN"; }
            while IFS=$'\t' read -r -u 3 NUM TICKET N1H TASK DISP; do
                if n1_orca_stop_worker "$QUEUE" "$NUM" "$TICKET" "$N1H" "$TASK" "$DISP" "$ORCA_RUN" </dev/null; then
                    SETTLED="$SETTLED$TASK "; OWED="${OWED// $TASK / }"
                else
                    n1_notify needs-you "Stop failed: $TICKET (worker terminal not closed; row and identity kept). Close it in the workspace manager, then run /n1:n1-queue --status $QUEUE_ID" </dev/null
                fi
            done 3< <(n1_orca_unsettled "$QUEUE")
        fi

        INFLIGHT=0
        while IFS=$'\t' read -r -u 3 NUM TICKET REPO N1H MODEL STATUS; do
            SID=$(n1_queue_session_id "$QUEUE" "$TICKET")
            TASK=""; case "$SID" in orca:*/*) TASK="${SID#orca:}"; TASK="${TASK%%/*}" ;; esac
            if [ -z "$TASK" ]; then
                # Runner died between worker-start and the Runs write: adopt the dispatch Orca lists for this run's
                # task; with none listed (yet), wait. Never relaunch.
                L=""; read -r L TASK 2>/dev/null < "$N1_QUEUE_DIR/.launch-$NUM" || true
                [ "$L" = "$RUN_ID" ] || TASK=""
                DISP=$(awk -F'\t' -v k="$TASK" 'k != "" && $2 == k { print $1; exit }' <<< "$LIVE")
                if [ -n "$DISP" ]; then
                    SID="orca:$TASK/$DISP"
                    echo "| $TICKET | $(date -u +%Y-%m-%dT%H:%M:%SZ) | | | | $SID |" >> "$QUEUE"
                    echo "[$NUM] $TICKET adopted Orca worker ($DISP)"
                else
                    TASK=""
                fi
            fi
            DISP=""; [ -n "$TASK" ] && DISP="${SID#*/}"
            OUTCOME=$(n1_queue_child_status "$N1H/memory/$TICKET/overview.md" 0 1)
            if [ "$OUTCOME" = pr ] || [ "$OUTCOME" = escalated ]; then
                [ -n "$TASK" ] && OWED="$OWED$TASK "
                finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "$OUTCOME" ""
                continue
            fi
            if [ -n "$TASK" ] && { [[ "$DONE" == *" $TASK "* ]] \
                || awk -F'\t' -v d="$DISP" '$1 == d && ($3 == "exited" || $4 == "done") { f = 1 } END { exit !f }' <<< "$LIVE"; }; then
                # The worker stopped without a terminal overview step (N1-182: it may still have opened a PR).
                OPEN_PR=$(n1_queue_child_open_pr "$TICKET" "$N1H" "$REPO" "${STARTED_AT[NUM]:-}")
                if [ -n "$OPEN_PR" ]; then
                    finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "pr" "" "" "$OPEN_PR"
                else
                    finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" "child-exited-incomplete" "" nodefer
                fi
                continue
            fi
            if [ -f "$N1_QUEUE_DIR/.ask-$TICKET" ]; then
                if [ "$STATUS" != awaiting-human ]; then
                    n1_queue_row_status "$QUEUE" "$NUM" "awaiting-human"
                    PARKED[NUM]=1; SINCE_PARK=0
                    echo "[$NUM] $TICKET -> awaiting-human"
                    escalate "$TICKET" "$N1H"
                fi
                continue
            fi
            if [ "$STATUS" = awaiting-human ]; then
                # n1-queue --answer replied and removed the .ask marker: the child continues.
                n1_queue_row_status "$QUEUE" "$NUM" "in-progress"
                rm -f "$N1_QUEUE_DIR/.esc-reason-$TICKET"
                ev unblocked ticket="$TICKET" session="$SID"
            fi
            # N1-267: a worker waiting on the Claude usage limit is idle, not working: its tick goes to STALLED instead.
            # Rows are checked one by one, so workers that all stall at once all pause. ponytail: the pause is capped at
            # 2x subtaskTimeoutMinutes so a worker hung behind a stale notice still times out.
            if [ "${STALLED[NUM]:-0}" -lt $((2 * TIMEOUT_SECS)) ] && n1_orca_usage_stalled "$TICKET"; then
                STALLED[NUM]=$(( ${STALLED[NUM]:-0} + CHARGE ))
                INFLIGHT=$((INFLIGHT + 1))
                continue
            fi
            WORKED[NUM]=$(( ${WORKED[NUM]:-0} + CHARGE ))
            if [ "${WORKED[NUM]}" -gt "$TIMEOUT_SECS" ]; then
                # ponytail: an Orca worker is never stopped without proof of exit, so a timed-out row fails without a
                # deferred retry (a relaunch could duplicate a live worker); the user stops the worker in Orca.
                [ -n "$TASK" ] && OWED="$OWED$TASK "
                # N1-267: a worker that already opened its PR (pr step still waiting on CI/review) is a pr, not a
                # timeout. It stays owed: settle releases it and runs the chain once it reports done or exits.
                OPEN_PR=$(n1_queue_child_open_pr "$TICKET" "$N1H" "$REPO" "${STARTED_AT[NUM]:-}")
                if [ -n "$OPEN_PR" ]; then
                    finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "pr" "" "" "$OPEN_PR"
                else
                    finalize "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "failed" "" "subtask-timeout" "" nodefer
                fi
                continue
            fi
            INFLIGHT=$((INFLIGHT + 1))
        done 3< <(n1_queue_pending_rows "$QUEUE" 'in-progress|awaiting-human')

        # Settle: a final row's worker that reported done, is durably finished (worker-list) or is proven exited is
        # released and loses its sentinel; a pr row then runs the fullAuto chain (n1-finish stays a bg session, it is
        # not a ticket worker). Re-settling after a restart is guarded by SETTLED, idempotent release and .chained-<ticket>.
        # A worker-list row settles only the dispatch the Runs row holds for its task.
        for TASK in $DONE; do orca_settle "$TASK"; done
        while IFS=$'\t' read -r -u 3 L TASK; do
            _n1_orca_id "$TASK" || continue
            IFS=$'\t' read -r T DISP <<< "$(orca_row_of_task "$TASK")"
            [ -n "$T" ] && [ "$L" = "$DISP" ] && orca_settle "$TASK"
        done 3< <(awk -F'\t' '$3 == "exited" || $4 == "done" { print $1 "\t" $2 }' <<< "$LIVE")

        # Unsettled workers (finished or timed-out rows whose worker is not proven exited or durably finished) still hold a slot.
        OWEDN=$(wc -w <<< "$OWED")
        while [ -z "$HALT_DRAIN" ] && [ $((INFLIGHT + OWEDN)) -lt "$MAXC" ]; do
            # N1-303 (N1-269 rule): the first ELIGIBLE pending row (every ## Schedule predecessor released).
            ROW=$(n1_queue_eligible_rows "$QUEUE" "$MERGE"); ROW="${ROW%%$'\n'*}"
            [ -n "$ROW" ] || break
            launch_orca "$ROW"
            INFLIGHT=$((INFLIGHT + 1)); HELD_WAIT=0
        done

        # N1-268: while draining a halt, pending rows are never launched, so they read as none here.
        # N1-303: "pending" means ELIGIBLE pending; rows gated on a ## Schedule predecessor are counted into HELD below.
        ELIG=""; [ -n "$HALT_DRAIN" ] || ELIG=$(n1_queue_eligible_rows "$QUEUE" "$MERGE")
        # Also entered when unsettled workers alone fill every slot, so their expiry/notice is not starved by pending rows.
        if [ "$INFLIGHT" = 0 ] && { [ -z "$ELIG" ] || [ "$OWEDN" -ge "$MAXC" ]; }; then
            # Done reports that never came: the overview is terminal, so settle (release + chain) anyway.
            if [ "$OWED" != " " ] && [ "$OWED_WAIT" -ge "$TIMEOUT_SECS" ]; then
                # Only a worker proven exited (or gone from a readable worker list) is settled; a live one (a long PR
                # review-fix loop) keeps its identity.
                for TASK in $OWED; do
                    IFS=$'\t' read -r T DISP <<< "$(orca_row_of_task "$TASK")"
                    L=$(awk -F'\t' -v d="$DISP" '$1 == d { print $3; exit }' <<< "$LIVE")
                    if [ "$L" = exited ] || { [ -z "$L" ] && [ "$LIVE_OK" = 1 ]; }; then orca_settle "$TASK"; fi
                done
                if [ "$OWED" != " " ] && [ -z "$OWED_NOTED" ]; then
                    OWED_NOTED=1
                    n1_notify info "Queue $QUEUE_ID: worker(s)${OWED% } still running after their PR; not released. Resume: /n1:n1-queue --run $QUEUE_ID"
                fi
            fi
            # N1-64/N1-114: held rows start only once their blocker's PR is merged (no Orca --deps).
            # N1-268: no sweep while draining (held and gated rows stay untouched, HELD=0 so nothing expires).
            HELD=0; ELIG=""
            if [ -z "$HALT_DRAIN" ]; then
                HELD=$(n1_queue_held_sweep "$QUEUE")
                ELIG=$(n1_queue_eligible_rows "$QUEUE" "$MERGE")
                # N1-303: pending rows gated on a ## Schedule predecessor wait like held rows, under the same bounded timeout.
                [ -n "$ELIG" ] || HELD=$((HELD + $(n1_queue_pending_rows "$QUEUE" | wc -l)))
            fi
            if [ -n "$ELIG" ]; then
                HELD_WAIT=0
                [ "$OWEDN" -ge "$MAXC" ] && [ "$OWED_WAIT" -lt "$TIMEOUT_SECS" ] && OWED_WAIT=$((OWED_WAIT + CHARGE))
            elif [ "$OWED" != " " ] && [ "$OWED_WAIT" -lt "$TIMEOUT_SECS" ]; then
                # Finished rows whose worker has not reported done yet: wait so it is released (and chained).
                OWED_WAIT=$((OWED_WAIT + CHARGE))
            elif [ -n "$(n1_queue_parked_rows "$QUEUE")" ]; then
                HELD_WAIT=0
                if [ "$SINCE_PARK" -ge "$TIMEOUT_SECS" ]; then
                    [ "$HELD" -gt 0 ] && { n1_queue_held_expire "$QUEUE"; n1_queue_gated_expire "$QUEUE"; }
                    echo "awaiting-human rows left for the user; queue done"
                    break
                fi
            elif [ "$HELD" -gt 0 ] && [ "$HELD_WAIT" -lt "$TIMEOUT_SECS" ]; then
                HELD_WAIT=$((HELD_WAIT + CHARGE))
            else
                [ "$HELD" -gt 0 ] && { n1_queue_held_expire "$QUEUE"; n1_queue_gated_expire "$QUEUE"; echo "held rows expired (blocker not merged)"; }
                break
            fi
        fi
        SINCE_PARK=$((SINCE_PARK + CHARGE))
    done
}

# N1-185: a chain owed from before a runner restart (row already pr, no .chained marker for this run).
# Only rows this run finalized (finalize stamps queue_run_id on the overview): a pr row left over from an
# earlier run, or from a run with the flags off, is never merged by a later run's sweep.
if [ -z "$(n1_read_frontmatter "$QUEUE" orca_run_id)" ]; then
while IFS=$'\t' read -r NUM TICKET REPO N1H MODEL _; do
    OV="$N1H/memory/$TICKET/overview.md"
    [ "$(n1_read_frontmatter "$OV" queue_run_id 2>/dev/null)" = "$RUN_ID" ] || continue
    chain_finish "$NUM" "$TICKET" "$REPO" "$N1H" "$MODEL" "$(n1_queue_child_pr_url "$OV")" </dev/null
done < <(n1_queue_pending_rows "$QUEUE" pr)
fi

# N1-225: a queue that already owns an Orca Run resumes it (run-use; rows are adopted, never relaunched). A fresh
# run uses Orca when queue.backend allows and orchestration answers, else claude --bg, saying so once (AC5).
ORCA_RUN=$(n1_read_frontmatter "$QUEUE" orca_run_id)
# The Orca Run belongs to the queue run that created it: a fresh --run picks its backend anew.
[ -z "$ORCA_RUN" ] || [ "$(n1_read_frontmatter "$QUEUE" orca_queue_run)" = "$RUN_ID" ] || ORCA_RUN=""
# N1-270: Orca nudges the Run's coordinator terminal whenever a worker sends (heartbeats included), and a coordinator
# must be a terminal. The runner opens its own (n1_orca_coord_open) and exports its handle, so every coordinator call
# (run-create/run-use, task-create, worker-start, check, worker-list) names it, never the launching session. No
# terminal, or Orca refusing it as coordinator: the launching terminal coordinates (legacy), said once.
LAUNCH_HANDLE="${ORCA_TERMINAL_HANDLE:-}" COORD=""
orca_coord_open() {
    if COORD=$(n1_orca_coord_open "$QUEUE_ID"); then
        export ORCA_TERMINAL_HANDLE="$COORD"
    else
        COORD=""
        echo "Orca coordinator terminal unavailable; the launching session coordinates this run"
    fi
    return 0
}
# orca_coord_drop — back to the launching terminal and close the runner's own; non-zero when none was in use.
orca_coord_drop() {
    [ -n "$COORD" ] || return 1
    if [ -n "$LAUNCH_HANDLE" ]; then export ORCA_TERMINAL_HANDLE="$LAUNCH_HANDLE"; else unset ORCA_TERMINAL_HANDLE; fi
    n1_orca_coord_close "$COORD"; COORD=""
    echo "Orca refused the coordinator terminal; the launching session coordinates this run"
}
if [ -n "$ORCA_RUN" ]; then
    PREV_COORD=$(n1_read_frontmatter "$QUEUE" orca_coord_terminal)
    orca_coord_open
    n1_orca_run_use "$ORCA_RUN" || { orca_coord_drop && n1_orca_run_use "$ORCA_RUN"; } \
        || halt "HALTED: Orca run $ORCA_RUN unreachable; start Orca, then /n1:n1-queue --run $QUEUE_ID"
    n1_write_frontmatter "$QUEUE" orca_coord_terminal "$COORD"
    # run-use rebound the Run to this runner's terminal: the previous runner's one is no longer the coordinator.
    [ -z "$PREV_COORD" ] || [ "$PREV_COORD" = "$COORD" ] || n1_orca_coord_close "$PREV_COORD"
    run_orca
elif [ "$(n1_queue_backend)" = orca ] && orca_coord_open \
        && { ORCA_RUN=$(n1_orca_run_create "$QUEUE_ID") || { orca_coord_drop && ORCA_RUN=$(n1_orca_run_create "$QUEUE_ID"); }; }; then
    n1_write_frontmatter "$QUEUE" orca_run_id "$ORCA_RUN"
    n1_write_frontmatter "$QUEUE" orca_queue_run "$RUN_ID"
    n1_write_frontmatter "$QUEUE" orca_coord_terminal "$COORD"
    echo "Orca run $ORCA_RUN: children launch as Orca workers"
    run_orca
else
    ORCA_RUN=""
    BACKEND=$(n1_queue_val backend)
    if [ "$BACKEND" = orca ] || { [ "$BACKEND" != bg ] && [ -n "${ORCA_CLI_COMMAND:-}" ]; }; then
        echo "Orca orchestration unavailable, using claude --bg"
        n1_notify info "Queue $QUEUE_ID: Orca orchestration unavailable, using claude --bg"
    fi
    run_bg
fi

# --- Done --------------------------------------------------------------------
# N1-268: a halt deferred while Orca workers were in flight ends here, after they finished or were stopped.
[ -z "$HALT_DRAIN" ] || halt_now "$HALT_DRAIN"
count_rows() { n1_queue_pending_rows "$QUEUE" "$1" | wc -l | tr -d ' '; }
DIGEST="$(count_rows pr) PR / $(count_rows 'awaiting-human|escalated') awaiting / $(count_rows failed) failed"
# N1-270: close the runner's coordinator terminal unless a row still waits on an answer (--answer replies from it,
# and the waiting worker's next message must still land in a terminal that discards the nudge). A crash or halt
# leaves it open on purpose.
if [ -n "$COORD" ] && [ "$(count_rows awaiting-human)" = 0 ]; then n1_orca_coord_close "$COORD"; fi
release_backstop
ev queue_done reason="$DIGEST"
n1_notify done "Queue $QUEUE_ID: $DIGEST"
n1_write_frontmatter "$QUEUE" step done
drain_wait
strip_pid
exit 0

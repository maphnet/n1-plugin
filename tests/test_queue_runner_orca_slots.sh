#!/usr/bin/env bash
# Tests for lib/queue.sh and scripts/n1-queue-run.sh: Orca slot counting and notifier/stdin drains.
# Shared setup and fixtures: tests/queue_runner_lib.sh (N1-304 split).
set -euo pipefail
source "$(dirname "$0")/queue_runner_lib.sh"

test_orca_owed_holds_slot() {   # an unsettled finished worker still counts toward maxConcurrent
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done"; mk_orca "$tmp"; cfg_set "$tmp" '.queue.maxConcurrent = 1'
    wl_set "$tmp" "$(wl_row T-A running)"
    touch "$tmp/fake/nodone.T-A"
    # T-A's worker is still running after its PR (AC3: never settled); the runner waits on it by design; the tick cap ends the run.
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=10 > /dev/null
    assert_eq "orca-owed-slot: T-B does not start while T-A's worker is unsettled" "0" "$(grep -c -- "--task task-T-B" "$tmp/fake/orca-calls" || true)"
    rm -rf "$tmp"
}

# N1-478 AC4. Bug caught: an owed worker (pr row, no worker_done, no stop notice; N1-440) held the only slot and the
# session was never told why pending rows did not start.
test_orca_slot_held_told() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.queue.maxConcurrent = 1 | .queue.stallMinutes = 1 | .queue.subtaskTimeoutMinutes = 600'
    wl_set "$tmp" "$(wl_row T-A running)"
    touch "$tmp/fake/nodone.T-A"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=10 > /dev/null
    assert_eq "slot-held: one event naming T-A and the waiting row" "T-A|1 pending row(s) waiting" \
        "$(jq -r 'select(.event == "slot_held") | "\(.ticket)|\(.reason)"' "$tmp/events.jsonl")"
    assert_eq "slot-held: T-B still waits" "0" "$(grep -c -- "--task task-T-B" "$tmp/fake/orca-calls" || true)"
    rm -rf "$tmp"
    # stallMinutes 0 disables the notice.
    tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.queue.maxConcurrent = 1 | .queue.stallMinutes = 0 | .queue.subtaskTimeoutMinutes = 600'
    wl_set "$tmp" "$(wl_row T-A running)"; touch "$tmp/fake/nodone.T-A"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=10 > /dev/null
    assert_eq "slot-held: stallMinutes 0 disables" "0" "$(grep -c '"slot_held"' "$tmp/events.jsonl" || true)"
    rm -rf "$tmp"
}

test_orca_notifier_drain_keeps_rows() {   # N1-265: a stdin-draining notifier must not hide in-flight rows from the slot count
    local tmp t; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done" "T-C:done" "T-D:done" "T-E:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.queue.maxConcurrent = 3 | .queue.subtaskTimeoutMinutes = 600'; drain_notifier "$tmp"   # N1-267: no timeouts, so rows stay in flight; the tick cap ends the run
    for t in T-A T-B T-C T-D; do echo implement > "$tmp/fake/step.$t"; done
    : > "$tmp/fake/nodone.T-B"; : > "$tmp/fake/nodone.T-C"; : > "$tmp/fake/nodone.T-D"
    # Tick 2: T-A's worker reports done without a terminal step -> failed (notifies) while T-B and T-C are in flight.
    # T-B/T-C/T-D never finish; the run ends on the tick cap.
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=10 > /dev/null
    assert_eq "orca-drain: notifier fired" "yes" "$([ -s "$tmp/fake/drained" ] && echo yes || echo no)"
    assert_eq "orca-drain: T-A failed" "failed|child-exited-incomplete" "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "orca-drain: freed slot refilled once" "1" "$(grep -c -- "--task task-T-D" "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-drain: never past maxConcurrent (T-E not started)" "0" "$(grep -c -- "--task task-T-E" "$tmp/fake/orca-calls" || true)"
    rm -rf "$tmp"
}

test_orca_event_drain_keeps_events() {   # N1-265: an escalation's notifier must not swallow the rest of the event batch
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done"; mk_orca "$tmp"; cfg_set "$tmp" '.queue.maxConcurrent = 3'; drain_notifier "$tmp"
    echo implement > "$tmp/fake/step.T-A"; echo implement > "$tmp/fake/step.T-B"
    : > "$tmp/fake/nodone.T-A"; : > "$tmp/fake/nodone.T-B"
    # One batch (emitted once both workers started): T-A escalates (notifies), then T-B's worker reports done.
    printf '%s,%s' "$(orca_msg escalation task-T-A m-e1)" "$(orca_msg worker_done task-T-B m-d1)" > "$tmp/fake/question"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=10 > /dev/null
    assert_eq "orca-event-drain: notifier fired" "yes" "$([ -s "$tmp/fake/drained" ] && echo yes || echo no)"
    # A lost worker_done leaves T-B to time out instead (subtask-timeout).
    assert_eq "orca-event-drain: worker_done after the escalation still processed" "failed|child-exited-incomplete" \
        "$(plan_cell "$tmp/queue.md" 2 8)|$(plan_cell "$tmp/queue.md" 2 9)"
    rm -rf "$tmp"
}

test_bg_notifier_drain_keeps_rows() {   # N1-265: a failed row's stdin-draining notifier must not hide a working row
    local tmp b_done c_launch; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:failed" "T-B:working done" "T-C:done"; drain_notifier "$tmp"
    # Resume state: T-A (already a deferred retry, so its failure notifies instead of deferring) and T-B in flight.
    n1_queue_row_status "$tmp/queue.md" 1 in-progress deferred-retry
    n1_queue_row_status "$tmp/queue.md" 2 in-progress
    printf '/n1:n1-start T-A\n' > "$tmp/fake/prompt.n1-bgq-T-A-1"; echo 00000001 > "$tmp/fake/id.n1-bgq-T-A-1"
    printf '/n1:n1-start T-B\n' > "$tmp/fake/prompt.n1-bgq-T-B-2"; echo 00000002 > "$tmp/fake/id.n1-bgq-T-B-2"
    echo 2 > "$tmp/fake/seq"   # new launches get ids after the seeded ones
    printf '| T-A | 2026-01-01T00:00:00Z | | | | 00000001 |\n| T-B | 2026-01-01T00:00:00Z | | | | 00000002 |\n' >> "$tmp/queue.md"
    run_bg_queue "$tmp" > /dev/null
    assert_eq "bg-drain: notifier fired" "yes" "$([ -s "$tmp/fake/drained" ] && echo yes || echo no)"
    assert_eq "bg-drain: T-A failed" "failed" "$(plan_cell "$tmp/queue.md" 1 8)"
    b_done=$(line_of "$tmp/fake/events" "state n1-bgq-T-B-2 done"); c_launch=$(line_of "$tmp/fake/events" "launch n1-bgq-T-C-3")
    assert_eq "bg-drain: T-C launched only after T-B finished" "yes" \
        "$([ -n "$b_done" ] && [ -n "$c_launch" ] && [ "$c_launch" -gt "$b_done" ] && echo yes || echo no)"
    rm -rf "$tmp"
}

test_runner_loops_fd3() {   # N1-265: notifying loops read a dedicated fd, so no child reading fd 0 can drain them
    local s="$REPO_ROOT/scripts/n1-queue-run.sh"
    assert_eq "loops-fd3: both row loops read fd 3" "2" \
        "$(grep -cF "done 3< <(n1_queue_pending_rows \"\$QUEUE\" 'in-progress|awaiting-human')" "$s" || true)"
    assert_eq "loops-fd3: both row loop reads use -u 3" "2" \
        "$(grep -cF "while IFS=\$'\\t' read -r -u 3 NUM TICKET REPO N1H MODEL STATUS; do" "$s" || true)"
    assert_eq "loops-fd3: event loop reads fd 3" "2" \
        "$(grep -cF -e 'done 3<<< "$EVS"' -e "while IFS=\$'\\t' read -r -u 3 TYPE TASK MSG MDISP EXTRA; do" "$s" || true)"
    assert_eq "loops-fd3: no row loop left on fd 0" "0" \
        "$(grep -cF "done < <(n1_queue_pending_rows \"\$QUEUE\" 'in-progress|awaiting-human')" "$s" || true)"
}

# N1-394. Bug caught: a "finished" stop notice for a worker whose row is already final (pr) left its owed slot held for
# the 180-minute expiry, so the next pending row never launched. The same notice for an in-progress row must change nothing.
stop_notice_slot_run() {   # <tmp> <step>: T-A (maxConcurrent 1, nodone, unverifiable worker) gets a finished stop notice on tick 3
    local tmp="$1"
    mk_bg "$tmp" oq "T-A:done" "T-B:done"; mk_orca "$tmp"; cfg_set "$tmp" '.queue.maxConcurrent = 1 | .queue.subtaskTimeoutMinutes = 600'
    wl_set "$tmp" "$(wl_row T-A running unverifiable)"
    # $2 = step; with "samepoll" T-A starts at implement and reaches pr on the same poll (tick 3) the notice arrives
    if [ "${2:-}" = samepoll ]; then echo implement > "$tmp/fake/step.T-A"; elif [ -n "${2:-}" ]; then echo "$2" > "$tmp/fake/step.T-A"; fi
    touch "$tmp/fake/nodone.T-A"
    orca_msg escalation task-T-A m-stop1 finished "Worker stopped without reporting" "Worker ended its turn" > "$tmp/fake/q.stop"
    printf 'cp "%s" "%s"\n' "$tmp/fake/q.stop" "$tmp/fake/question" > "$tmp/fake/at.3"
    if [ "${2:-}" = samepoll ]; then
        printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://x/pr/1\n' > "$tmp/fake/ov.pr"
        printf 'cp "%s" "%s/n1home/memory/T-A/overview.md"\n' "$tmp/fake/ov.pr" "$tmp" >> "$tmp/fake/at.3"
    fi
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=8 > /dev/null
}

test_orca_stop_finished_releases_pr_slot() {
    local tmp; tmp=$(mktemp -d)
    stop_notice_slot_run "$tmp"
    assert_eq "orca-stop-slot: T-A is pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "orca-stop-slot: worker released" "1" "$(grep -c 'worker-release --dispatch d-T-A' "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-stop-slot: T-B launched" "1" "$(grep -c -- "--task task-T-B" "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-stop-slot: one worker_owed event for T-A (N1-478 AC3)" "T-A" \
        "$(jq -r 'select(.event == "worker_owed") | .ticket' "$tmp/events.jsonl")"
    rm -rf "$tmp"
}

# Same-tick race: the notice and the first pr observation land on one poll, so the row is still in-progress in the event loop.
test_orca_stop_finished_same_tick_releases() {
    local tmp; tmp=$(mktemp -d)
    stop_notice_slot_run "$tmp" samepoll
    assert_eq "orca-stop-same-tick: T-A is pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "orca-stop-same-tick: worker released" "1" "$(grep -c 'worker-release --dispatch d-T-A' "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-stop-same-tick: T-B launched" "1" "$(grep -c -- "--task task-T-B" "$tmp/fake/orca-calls" || true)"
    rm -rf "$tmp"
}

test_orca_stop_finished_keeps_in_progress() {
    local tmp; tmp=$(mktemp -d)
    stop_notice_slot_run "$tmp" implement
    assert_eq "orca-stop-slot: in-progress row unchanged" "in-progress" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "orca-stop-slot: no release" "0" "$(grep -c worker-release "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-stop-slot: T-B not launched" "0" "$(grep -c -- "--task task-T-B" "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-stop-slot: no worker_owed for an in-progress row" "0" "$(grep -c '"worker_owed"' "$tmp/events.jsonl" || true)"
    rm -rf "$tmp"
}

# N1-422 AC1/AC5. Bug caught: a "finished" stop notice (the worker only ended a turn) chained n1-finish against the
# live worker; the finish hit the moved head and raised a false "needs you". The notice now only frees the slot; the
# worker's later worker_done (after it merged its own PR) settles the row, with no chained finish, even when the
# released dispatch reads exited/done in the worker list on the next tick.
test_orca_stop_notice_then_resume_no_chain() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.autonomy.fullAuto = true | .finishWork.mergeOnFinish = true | .queue.maxConcurrent = 1 | .queue.subtaskTimeoutMinutes = 600'
    wl_set "$tmp" "$(wl_row T-A running unverifiable)"
    echo OPEN > "$tmp/fake/gh-state"; touch "$tmp/fake/nodone.T-A"
    printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://github.com/o/r/pull/7\n' > "$tmp/fake/overview.T-A"
    orca_msg escalation task-T-A m-stop1 finished "Worker stopped without reporting" "Worker ended its turn" > "$tmp/fake/q.stop"
    printf 'cp "%s" "%s"\n' "$tmp/fake/q.stop" "$tmp/fake/question" > "$tmp/fake/at.3"
    # Tick 4: the released dispatch now reads exited/done in the worker list (as real Orca rows do); a resuming worker must not be chained.
    wl_set "$tmp" "$(wl_row T-A released)"; cp "$tmp/fake/workers.json" "$tmp/fake/workers.released"
    wl_set "$tmp" "$(wl_row T-A running unverifiable)"
    printf 'cp "%s" "%s"\n' "$tmp/fake/workers.released" "$tmp/fake/workers.json" > "$tmp/fake/at.4"
    # Tick 5: the worker resumed, merged its own PR and now reports done.
    printf 'echo MERGED > "%s"; rm -f "%s"\n' "$tmp/fake/gh-state" "$tmp/fake/nodone.T-A" > "$tmp/fake/at.5"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=10 > /dev/null
    assert_eq "orca-stop-resume: no chained n1-finish" "0" "$(count_x "$tmp/fake/events" 'launch n1-oq-T-A-1-fin')"
    assert_eq "orca-stop-resume: released by the notice and by worker_done" "2" \
        "$(grep -c 'worker-release --dispatch d-T-A' "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-stop-resume: Runs outcome merged" "merged" "$(runs_outcome "$tmp/queue.md" T-A)"
    assert_eq "orca-stop-resume: merged recorded once" "1" \
        "$(jq -r 'select(.event == "ticket_finished" and .outcome == "merged" and .ticket == "T-A") | .ticket' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    rm -rf "$tmp"
}

# N1-422 review. Bug caught: DEFERRED lived only in memory, so after a runner restart a released dispatch reading
# exited/done passed the settlement guard and chained n1-finish while the worker could still resume.
test_orca_stop_notice_deferral_survives_restart() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.autonomy.fullAuto = true | .finishWork.mergeOnFinish = true | .queue.maxConcurrent = 1 | .queue.subtaskTimeoutMinutes = 600'
    wl_set "$tmp" "$(wl_row T-A running unverifiable)"
    echo OPEN > "$tmp/fake/gh-state"; touch "$tmp/fake/nodone.T-A"
    printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://github.com/o/r/pull/7\n' > "$tmp/fake/overview.T-A"
    orca_msg escalation task-T-A m-stop1 finished "Worker stopped without reporting" "Worker ended its turn" > "$tmp/fake/q.stop"
    printf 'cp "%s" "%s"\n' "$tmp/fake/q.stop" "$tmp/fake/question" > "$tmp/fake/at.3"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=4 > /dev/null
    assert_eq "orca-defer-restart: marker persisted" "1" "$(ls "$tmp"/.deferred-* 2>/dev/null | wc -l | tr -d ' ')"
    rm -f "$tmp/fake/at.3"
    wl_set "$tmp" "$(wl_row T-A released)"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=4 > /dev/null
    assert_eq "orca-defer-restart: no chained n1-finish" "0" "$(count_x "$tmp/fake/events" 'launch n1-oq-T-A-1-fin')"
    rm -rf "$tmp"
}

test_orca_owed_holds_slot
test_orca_notifier_drain_keeps_rows
test_orca_event_drain_keeps_events
test_bg_notifier_drain_keeps_rows
test_runner_loops_fd3
test_orca_stop_finished_releases_pr_slot
test_orca_stop_finished_same_tick_releases
test_orca_stop_finished_keeps_in_progress
test_orca_stop_notice_then_resume_no_chain
test_orca_stop_notice_deferral_survives_restart
test_orca_slot_held_told

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

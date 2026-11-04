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

test_orca_owed_holds_slot
test_orca_notifier_drain_keeps_rows
test_orca_event_drain_keeps_events
test_bg_notifier_drain_keeps_rows
test_runner_loops_fd3

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

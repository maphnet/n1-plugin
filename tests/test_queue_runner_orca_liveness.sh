#!/usr/bin/env bash
# Tests for lib/queue.sh and scripts/n1-queue-run.sh: Orca heartbeat and worker-list dispatch binding.
# Shared setup and fixtures: tests/queue_runner_lib.sh (N1-304 split).
set -euo pipefail
source "$(dirname "$0")/queue_runner_lib.sh"

test_orca_heartbeat() {   # AC3/N1-315: a heartbeat is acked and stored as the row's beacon; heartbeat-only ticks charge real elapsed time
    local tmp; tmp=$(mktemp -d)
    # (a) A batch carrying a heartbeat is acked (row parked, so not finalized).
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"
    printf '%s,%s' "$(jq -cn --arg y question --arg i m-q1 '{id: $i, type: $y, payload: ({taskId: "task-T-A", dispatchId: "d-T-A"} | tojson)}')" "$(jq -cn --arg y heartbeat --arg i m-hb1 '{id: $i, type: $y, payload: ({taskId: "task-T-A", dispatchId: "d-T-A"} | tojson)}')" > "$tmp/fake/question"   # real payload shape, bound to d-T-A
    printf '{"ticket":"T-A","question":"Pick a DB?","options":["A","B"],"recommended":"A","rationale":"x"}' > "$tmp/.question-T-A.json"
    assert_eq "orca-hb: exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-hb: check requests heartbeat" "yes" "$(grep -q 'check --run run-1.*--types worker_done,escalation,question,heartbeat' "$tmp/fake/orca-calls" && echo yes || echo no)"
    assert_eq "orca-hb: heartbeat batch acked" "yes" "$(grep -q 'check --run run-1 --ack del-1' "$tmp/fake/orca-calls" && echo yes || echo no)"
    rm -rf "$tmp"; tmp=$(mktemp -d)
    # (b) Heartbeat-only ticks return early: they must charge real elapsed time, not a full poll
    # (subtaskTimeoutMinutes=1, pollSeconds=30 must not time the worker out within seconds).
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"
    jq -cn '{id: "m-hb1", type: "heartbeat", payload: ({taskId: "task-T-A", dispatchId: "d-T-A", phase: "implement/developer"} | tojson)}' > "$tmp/fake/heartbeat"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=10 > /dev/null
    assert_eq "orca-hb-only: early heartbeat returns do not charge a full poll (no early timeout)" "no" \
        "$([ "$(plan_cell "$tmp/queue.md" 1 9)" = subtask-timeout ] && echo yes || echo no)"
    assert_eq "orca-hb-only: beacon stored as <epoch>\\t<phase>" "yes|implement/developer" \
        "$(IFS=$'\t' read -r a p 2>/dev/null < "$tmp/.hb-T-A"; [[ "${a:-}" =~ ^[0-9]+$ ]] && echo "yes|${p:-}" || echo "no|${p:-}")"
    rm -rf "$tmp"; tmp=$(mktemp -d)
    # (c) finalize removes the beacon and stall markers (a retry must not inherit them). No heartbeat message is
    # injected, so only finalize can remove the pre-made files (the heartbeat arm would also clear .stall).
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    printf '1\tpr\n' > "$tmp/.hb-T-A"; : > "$tmp/.stall-T-A"
    assert_eq "orca-hb-final: exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-hb-final: finalize removes .hb and .stall" "no|no" \
        "$([ -e "$tmp/.hb-T-A" ] && echo yes || echo no)|$([ -e "$tmp/.stall-T-A" ] && echo yes || echo no)"

    rm -rf "$tmp"
}

test_orca_worker_list_dispatch_bound() {   # N1-281: a worker-list row for the task with another dispatch id must not settle the Runs-row worker
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.queue.subtaskTimeoutMinutes = 600'
    : > "$tmp/fake/nodone.T-A"   # final row (pr): only a settle can release its worker
    printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://github.com/o/r/pull/7\n' > "$tmp/fake/overview.T-A"
    wl_set "$tmp" "$(wl_row T-A succeeded | jq -c '.dispatchId = "d-forged"')"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=10 > /dev/null
    assert_eq "orca-wl-bound: mismatched dispatch does not release the worker" "0" "$(grep -c worker-release "$tmp/fake/orca-calls" || true)"
    rm -rf "$tmp"
}

# N1-315 AC4: a live worker whose last beacon (else launch) is older than queue.stallMinutes is flagged once (event +
# info notice) and never touched. Bugs caught: no flag; a flag every tick; a flag that changes or releases the row;
# a flag for a fresh beacon, a non-live verdict, a parked row, or a row with no baseline at all.
stall_fixture() {   # <tmp> — orca_resumed_row on a live worker, stallMinutes 1, notices appended to $tmp/notes
    orca_resumed_row "$1"
    wl_set "$1" "$(wl_row T-A running)"
    cfg_set "$1" '.queue.subtaskTimeoutMinutes = 600 | .queue.stallMinutes = 1 | .queue.notify = "command" | .queue.notifyCommand = "cat >> '"$1"'/notes"'
}
stalls() { grep -c '"stalled"' "$1/events.jsonl" 2>/dev/null || true; }
stall_notes() { grep -c 'may be stalled' "$1/notes" 2>/dev/null || true; }
test_orca_stall_flag() {
    local tmp
    # (a) live, beacon from 1970: one event + one notice over 3 ticks; row stays in-progress, worker not released.
    tmp=$(mktemp -d); stall_fixture "$tmp"; printf '1\timplement/developer\n' > "$tmp/.hb-T-A"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
    assert_eq "stall: flagged exactly once" "1|1" "$(stalls "$tmp")|$(stall_notes "$tmp")"
    assert_eq "stall: notice names the last phase" "yes" "$(grep -q 'last phase implement/developer' "$tmp/notes" && echo yes || echo no)"
    assert_eq "stall: row unchanged, worker not released" "in-progress|0" \
        "$(plan_cell "$tmp/queue.md" 1 8)|$(grep -c worker-release "$tmp/fake/orca-calls" || true)"
    assert_eq "stall: marker written" "yes" "$([ -e "$tmp/.stall-T-A" ] && echo yes || echo no)"
    rm -rf "$tmp"
    # (b) a fresh beacon every tick: not flagged (the inbox step runs before the row loop).
    tmp=$(mktemp -d); stall_fixture "$tmp"; printf '1\timplement\n' > "$tmp/.hb-T-A"
    echo task-T-A > "$tmp/fake/started"; : > "$tmp/fake/nodone.T-A"
    jq -cn '{id: "m-hb1", type: "heartbeat", payload: ({taskId: "task-T-A", dispatchId: "d-T-A", phase: "implement"} | tojson)}' > "$tmp/fake/heartbeat"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
    assert_eq "stall: fresh beacon not flagged" "0" "$(stalls "$tmp")"
    rm -rf "$tmp"
    # (c) liveness unverifiable: never flagged.
    tmp=$(mktemp -d); stall_fixture "$tmp"; wl_set "$tmp" "$(wl_row T-A running unverifiable)"; printf '1\timplement\n' > "$tmp/.hb-T-A"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
    assert_eq "stall: unverifiable worker not flagged" "0" "$(stalls "$tmp")"
    rm -rf "$tmp"
    # (d) awaiting-human (worker question parked the row): exempt.
    tmp=$(mktemp -d); stall_fixture "$tmp"; printf '1\timplement\n' > "$tmp/.hb-T-A"
    echo task-T-A > "$tmp/fake/started"; : > "$tmp/fake/nodone.T-A"
    orca_msg question task-T-A m-q1 > "$tmp/fake/question"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
    assert_eq "stall: awaiting-human row not flagged" "awaiting-human|0" "$(plan_cell "$tmp/queue.md" 1 8)|$(stalls "$tmp")"
    rm -rf "$tmp"
    # (e) never beaconed, launched 2 hours ago: flagged from the launch marker, phase "-".
    tmp=$(mktemp -d); stall_fixture "$tmp"; echo "R1 task-T-A" > "$tmp/.launch-1"; touch -d '2 hours ago' "$tmp/.launch-1"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
    assert_eq "stall: never-beaconed row flagged from launch" "1|yes" \
        "$(stalls "$tmp")|$(grep -q 'last phase -' "$tmp/notes" && echo yes || echo no)"
    rm -rf "$tmp"
    # (f) no beacon and no launch marker: no baseline, not flagged.
    tmp=$(mktemp -d); stall_fixture "$tmp"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
    assert_eq "stall: no baseline not flagged" "0" "$(stalls "$tmp")"
    rm -rf "$tmp"
    # (g) a parked row answered after a long wait (no .ask marker left): the baseline restarts, so the resumed worker is
    # not flagged before its first hook fires. Phase is kept.
    tmp=$(mktemp -d); stall_fixture "$tmp"; printf '1\timplement\n' > "$tmp/.hb-T-A"
    n1_queue_row_status "$tmp/queue.md" 1 awaiting-human
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
    assert_eq "stall: unparked row not flagged, baseline restarted, phase kept" "0|yes|implement" \
        "$(stalls "$tmp")|$([ "$(cut -f1 "$tmp/.hb-T-A")" -gt 1000 ] && echo yes || echo no)|$(cut -f2 "$tmp/.hb-T-A")"
    rm -rf "$tmp"
    # (h) stallMinutes 0 disables the flag.
    tmp=$(mktemp -d); stall_fixture "$tmp"; cfg_set "$tmp" '.queue.stallMinutes = 0'; printf '1\timplement\n' > "$tmp/.hb-T-A"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
    assert_eq "stall: stallMinutes 0 disables" "0" "$(stalls "$tmp")"
    rm -rf "$tmp"
}

test_orca_heartbeat
test_orca_worker_list_dispatch_bound
test_orca_stall_flag

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

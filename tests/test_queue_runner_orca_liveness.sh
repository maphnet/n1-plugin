#!/usr/bin/env bash
# Tests for lib/queue.sh and scripts/n1-queue-run.sh: Orca heartbeat and worker-list dispatch binding.
# Shared setup and fixtures: tests/queue_runner_lib.sh (N1-304 split).
set -euo pipefail
source "$(dirname "$0")/queue_runner_lib.sh"

test_orca_heartbeat() {   # AC3: a stray heartbeat is acked and ignored; heartbeat-only ticks charge real elapsed time
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
    jq -cn '{id: "m-hb1", type: "heartbeat", payload: ({taskId: "task-T-A", dispatchId: "d-T-A"} | tojson)}' > "$tmp/fake/heartbeat"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=40 > /dev/null
    assert_eq "orca-hb-only: early heartbeat returns do not charge a full poll (no early timeout)" "no" \
        "$([ "$(plan_cell "$tmp/queue.md" 1 9)" = subtask-timeout ] && echo yes || echo no)"

    rm -rf "$tmp"
}

test_orca_worker_list_dispatch_bound() {   # N1-281: a worker-list row for the task with another dispatch id must not settle the Runs-row worker
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.queue.subtaskTimeoutMinutes = 600'
    : > "$tmp/fake/nodone.T-A"   # final row (pr): only a settle can release its worker
    printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://github.com/o/r/pull/7\n' > "$tmp/fake/overview.T-A"
    wl_set "$tmp" "$(wl_row T-A succeeded | jq -c '.dispatchId = "d-forged"')"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=40 > /dev/null
    assert_eq "orca-wl-bound: mismatched dispatch does not release the worker" "0" "$(grep -c worker-release "$tmp/fake/orca-calls" || true)"
    rm -rf "$tmp"
}

test_orca_heartbeat
test_orca_worker_list_dispatch_bound

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

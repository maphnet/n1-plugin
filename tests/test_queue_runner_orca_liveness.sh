#!/usr/bin/env bash
# Tests for lib/queue.sh and scripts/n1-queue-run.sh: Orca heartbeat and worker-list dispatch binding.
# Shared setup and fixtures: tests/queue_runner_lib.sh (N1-304 split).
set -euo pipefail
source "$(dirname "$0")/queue_runner_lib.sh"

test_orca_heartbeat() {   # AC3: a bound heartbeat is recorded per worker; heartbeat-only ticks charge real elapsed time
    local tmp t0 hb; tmp=$(mktemp -d)
    # (a) A batch carrying a heartbeat records the runner's receive time in .hb-<TICKET> (row parked, so not finalized).
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"
    printf '%s,%s' "$(jq -cn --arg y question --arg i m-q1 '{id: $i, type: $y, payload: ({taskId: "task-T-A", dispatchId: "d-T-A"} | tojson)}')" "$(jq -cn --arg y heartbeat --arg i m-hb1 '{id: $i, type: $y, payload: ({taskId: "task-T-A", dispatchId: "d-T-A"} | tojson)}')" > "$tmp/fake/question"   # real payload shape, bound to d-T-A
    printf '{"ticket":"T-A","question":"Pick a DB?","options":["A","B"],"recommended":"A","rationale":"x"}' > "$tmp/.question-T-A.json"
    t0=$(date +%s)
    assert_eq "orca-hb: exit 0" "0" "$(run_orca_queue "$tmp")"
    hb=$(cat "$tmp/.hb-T-A" 2>/dev/null)
    assert_eq "orca-hb: last heartbeat epoch recorded" "yes" \
        "$([[ "$hb" =~ ^[0-9]+$ ]] && [ "$hb" -ge "$t0" ] && [ "$hb" -le "$(date +%s)" ] && echo yes || echo no)"
    assert_eq "orca-hb: check requests heartbeat" "yes" "$(grep -q 'check --run run-1.*--types worker_done,escalation,question,heartbeat' "$tmp/fake/orca-calls" && echo yes || echo no)"
    assert_eq "orca-hb: heartbeat batch acked" "yes" "$(grep -q 'check --run run-1 --ack del-1' "$tmp/fake/orca-calls" && echo yes || echo no)"
    rm -rf "$tmp"; tmp=$(mktemp -d)
    # (b) Heartbeat-only ticks return early: they must still record .hb-<TICKET> and must charge real elapsed time, not a full poll
    # (subtaskTimeoutMinutes=1, pollSeconds=30 must not time the worker out within seconds). A heartbeat whose dispatchId does not
    # match the Runs row (real shape, forged dispatch) must not be recorded.
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"
    jq -cn '{id: "m-hb1", type: "heartbeat", payload: ({taskId: "task-T-A", dispatchId: "d-T-A"} | tojson)}' > "$tmp/fake/heartbeat"
    timeout 8 bash -c "REPO_ROOT='$REPO_ROOT'; $(declare -f run_orca_queue); run_orca_queue '$tmp'" > /dev/null 2>&1 || true
    assert_eq "orca-hb-only: bound heartbeat recorded" "yes" "$([[ "$(cat "$tmp/.hb-T-A" 2>/dev/null)" =~ ^[0-9]+$ ]] && echo yes || echo no)"
    assert_eq "orca-hb-only: early heartbeat returns do not charge a full poll (no early timeout)" "no" \
        "$([ "$(plan_cell "$tmp/queue.md" 1 9)" = subtask-timeout ] && echo yes || echo no)"
    rm -rf "$tmp"; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"
    jq -cn '{id: "m-hb2", type: "heartbeat", payload: ({taskId: "task-T-A", dispatchId: "d-forged"} | tojson)}' > "$tmp/fake/heartbeat"
    timeout 8 bash -c "REPO_ROOT='$REPO_ROOT'; $(declare -f run_orca_queue); run_orca_queue '$tmp'" > /dev/null 2>&1 || true
    assert_eq "orca-hb-only: heartbeat for another dispatch not recorded" "no" "$([ -e "$tmp/.hb-T-A" ] && echo yes || echo no)"

    # (c) A bound message with no message id is still processed (the empty id must not shift the dispatch column).
    rm -rf "$tmp"; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"
    jq -cn '{type: "heartbeat", payload: ({taskId: "task-T-A", dispatchId: "d-T-A"} | tojson)}' > "$tmp/fake/heartbeat"
    timeout 8 bash -c "REPO_ROOT='$REPO_ROOT'; $(declare -f run_orca_queue); run_orca_queue '$tmp'" > /dev/null 2>&1 || true
    assert_eq "orca-hb-noid: bound heartbeat without message id recorded" "yes" "$([[ "$(cat "$tmp/.hb-T-A" 2>/dev/null)" =~ ^[0-9]+$ ]] && echo yes || echo no)"
    rm -rf "$tmp"
}

test_orca_worker_list_dispatch_bound() {   # N1-281: a worker-list row for the task with another dispatch id must not settle the Runs-row worker
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.queue.subtaskTimeoutMinutes = 600'
    : > "$tmp/fake/nodone.T-A"   # final row (pr): only a settle can release its worker
    printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://github.com/o/r/pull/7\n' > "$tmp/fake/overview.T-A"
    wl_set "$tmp" "$(wl_row T-A succeeded | jq -c '.dispatchId = "d-forged"')"
    timeout 20 bash -c "REPO_ROOT='$REPO_ROOT'; $(declare -f run_orca_queue); run_orca_queue '$tmp'" > /dev/null 2>&1 || true
    assert_eq "orca-wl-bound: mismatched dispatch does not release the worker" "0" "$(grep -c worker-release "$tmp/fake/orca-calls" || true)"
    rm -rf "$tmp"
}

test_orca_heartbeat
test_orca_worker_list_dispatch_bound

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

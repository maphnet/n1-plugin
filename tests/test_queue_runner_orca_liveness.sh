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
    age_memory "$1"
}
# age_memory <tmp> — N1-478: T-A's memory files read as 2 hours old, so only the signal a case adds counts as activity.
age_memory() { find "$1/n1home/memory/T-A" -type f -exec touch -d '2 hours ago' {} +; }
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
    # (i) a fresh launch with an old beacon left behind (late beacon after an earlier finalize): the launch clears it,
    # so the new worker's baseline is its launch marker and it is not flagged.
    tmp=$(mktemp -d); mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"; wl_set "$tmp" "$(wl_row T-A running)"
    cfg_set "$tmp" '.queue.subtaskTimeoutMinutes = 600 | .queue.stallMinutes = 1'
    : > "$tmp/fake/nodone.T-A"; printf -- '---\nstep: implement\n---\n' > "$tmp/fake/overview.T-A"
    printf '1\timplement\n' > "$tmp/.hb-T-A"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
    assert_eq "stall: launch clears an old beacon" "in-progress|0" "$(plan_cell "$tmp/queue.md" 1 8)|$(stalls "$tmp")"
    rm -rf "$tmp"
    # N1-478 AC2. Bug caught: workers with recent commits, fresh ticket memory or a running subagent were flagged
    # "may be stalled (phase=- ...)" because the runner received no beacons. Activity inside the window suppresses the flag.
    # (j) a commit in the overview's workspace_path inside the window: not flagged, no marker.
    tmp=$(mktemp -d); stall_fixture "$tmp"; printf '1\timplement\n' > "$tmp/.hb-T-A"
    git init -q "$tmp/ws" && git -C "$tmp/ws" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
    n1_write_frontmatter "$tmp/n1home/memory/T-A/overview.md" workspace_path "$tmp/ws"; age_memory "$tmp"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
    assert_eq "stall: recent commit not flagged" "0|no" "$(stalls "$tmp")|$([ -e "$tmp/.stall-T-A" ] && echo yes || echo no)"
    rm -rf "$tmp"
    # (k) a ticket memory file written inside the window: not flagged.
    tmp=$(mktemp -d); stall_fixture "$tmp"; printf '1\timplement\n' > "$tmp/.hb-T-A"
    : > "$tmp/n1home/memory/T-A/implementation.md"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
    assert_eq "stall: fresh memory file not flagged" "0" "$(stalls "$tmp")"
    rm -rf "$tmp"
    # (l) a subagent started long ago and not stopped (newest agents file): not flagged.
    tmp=$(mktemp -d); stall_fixture "$tmp"; printf '1\timplement\n' > "$tmp/.hb-T-A"
    mkdir -p "$tmp/n1home/memory/T-A/telemetry/raw/agents"
    printf '{"event":"start","agent_id":"a1","ticket_id":"T-A"}\n' > "$tmp/n1home/memory/T-A/telemetry/raw/agents/R1.jsonl"
    age_memory "$tmp"; touch -d '30 minutes ago' "$tmp/n1home/memory/T-A/telemetry/raw/agents/R1.jsonl"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
    assert_eq "stall: running subagent not flagged" "0" "$(stalls "$tmp")"
    rm -rf "$tmp"
    # (l2) an orphaned start (no stop) in an agents file older than an hour is no activity: flagged.
    tmp=$(mktemp -d); stall_fixture "$tmp"; printf '1\timplement\n' > "$tmp/.hb-T-A"
    mkdir -p "$tmp/n1home/memory/T-A/telemetry/raw/agents"
    printf '{"event":"start","agent_id":"a1"}\n' > "$tmp/n1home/memory/T-A/telemetry/raw/agents/R1.jsonl"
    age_memory "$tmp"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
    assert_eq "stall: orphaned subagent start flagged" "1" "$(stalls "$tmp")"
    rm -rf "$tmp"
    # (m) all three signals stale (old commit, aged memory, subagent stopped): flagged once as before.
    tmp=$(mktemp -d); stall_fixture "$tmp"; printf '1\timplement\n' > "$tmp/.hb-T-A"
    git init -q "$tmp/ws" && GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' git -C "$tmp/ws" -c user.name=t -c user.email=t@t \
        commit -q --allow-empty --date='2020-01-01T00:00:00Z' -m x
    n1_write_frontmatter "$tmp/n1home/memory/T-A/overview.md" workspace_path "$tmp/ws"
    mkdir -p "$tmp/n1home/memory/T-A/telemetry/raw/agents"
    printf '{"event":"start","agent_id":"a1"}\n{"event":"stop","agent_id":"a1"}\n' > "$tmp/n1home/memory/T-A/telemetry/raw/agents/R1.jsonl"
    age_memory "$tmp"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
    assert_eq "stall: all signals stale still flagged once" "1" "$(stalls "$tmp")"
    rm -rf "$tmp"
}

test_beacon_lines() {   # N1-315 AC3: --status shows the last phase and its age for in-progress rows with a beacon
    local tmp out; tmp=$(mktemp -d); orca_resumed_row "$tmp"
    assert_eq "beacon-lines: no beacon prints nothing" "" "$(n1_queue_beacon_lines "$tmp/queue.md")"
    printf '%s\timplement/developer\n' "$(( $(date +%s) - 600 ))" > "$tmp/.hb-T-A"
    out=$(n1_queue_beacon_lines "$tmp/queue.md")
    assert_eq "beacon-lines: ticket, phase, flag" "T-A|implement/developer|" "$(cut -f1,2,4 <<<"$out" | tr '\t' '|')"
    assert_eq "beacon-lines: age present" "yes" "$([ -n "$(cut -f3 <<<"$out")" ] && echo yes || echo no)"
    : > "$tmp/.stall-T-A"
    assert_eq "beacon-lines: stalled flag" "stalled?" "$(n1_queue_beacon_lines "$tmp/queue.md" | cut -f4)"
    n1_queue_row_status "$tmp/queue.md" 1 pr
    assert_eq "beacon-lines: final rows skipped" "" "$(n1_queue_beacon_lines "$tmp/queue.md")"
    rm -rf "$tmp"
    # Stall-flagged row that never beaconed: aged from the launch lock, phase unknown.
    tmp=$(mktemp -d); orca_resumed_row "$tmp"
    : > "$tmp/.stall-T-A"
    assert_eq "beacon-lines: stall without .hb or launch lock hidden" "" "$(n1_queue_beacon_lines "$tmp/queue.md")"
    printf 'R1 task-T-A\n' > "$tmp/.launch-1"; touch -d '2 hours ago' "$tmp/.launch-1"
    out=$(n1_queue_beacon_lines "$tmp/queue.md")
    assert_eq "beacon-lines: stall without .hb shown" "T-A|unknown|stalled?" "$(cut -f1,2,4 <<<"$out" | tr '\t' '|')"
    assert_eq "beacon-lines: launch-based age" "yes" "$(grep -q $'\t2h' <<<"$out" && echo yes || echo no)"
    rm -f "$tmp/.stall-T-A"
    assert_eq "beacon-lines: no stall, no .hb stays hidden" "" "$(n1_queue_beacon_lines "$tmp/queue.md")"
    rm -rf "$tmp"
}

# N1-333 AC2/AC3: a ghost worker (Orca stage.detail terminal_missing, verdict not live) more than 5 minutes after its
# .launch-<n> marker ends failed worker-terminal-missing (nodefer): released, identity removed, slot freed. Every case
# runs a fresh runner on a pre-seeded in-progress row (orca_resumed_row), so it also covers a runner restart.
# Bugs caught: a live worker or one without the marker released; a release inside the grace, without a launch marker
# or on an unreadable list; the old child-exited-incomplete reason on an exited ghost; a deferred relaunch.
ghost_fixture() {   # <tmp> <verdict> <stage detail|""> [launch age for touch -d]
    orca_resumed_row "$1"
    cfg_set "$1" '.queue.subtaskTimeoutMinutes = 600'
    wl_set "$1" "$(wl_row T-A running "$2" "$3")"
    if [ -n "${4:-}" ]; then echo "R1 task-T-A" > "$1/.launch-1"; touch -d "$4" "$1/.launch-1"; fi
    return 0
}
ghost_rel() { grep -c 'worker-release --dispatch d-T-A' "$1/fake/orca-calls" || true; }
test_orca_ghost_worker() {
    local tmp sent v
    for v in unverifiable exited; do
        tmp=$(mktemp -d); ghost_fixture "$tmp" "$v" terminal_missing '10 minutes ago'; sent="$tmp/n1home/queue/sentinels/T-A.env"
        run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=2 > /dev/null
        assert_eq "ghost $v: failed with its own reason" "failed|worker-terminal-missing" \
            "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
        assert_eq "ghost $v: no deferred retry row" "" "$(plan_cell "$tmp/queue.md" 2 3)"
        assert_eq "ghost $v: dispatch released, identity removed" "yes|no" \
            "$([ "$(ghost_rel "$tmp")" -ge 1 ] && echo yes || echo no)|$([ -e "$sent" ] && echo yes || echo no)"
        rm -rf "$tmp"
    done
    # Slot freed: maxConcurrent 1, the ghost's slot goes to the next pending row.
    tmp=$(mktemp -d); mk_bg "$tmp" oq "T-A:done" "T-B:done"; mk_orca "$tmp"
    n1_write_frontmatter "$tmp/queue.md" orca_run_id run-1; n1_write_frontmatter "$tmp/queue.md" run_id R1; n1_write_frontmatter "$tmp/queue.md" orca_queue_run R1
    n1_write_frontmatter "$tmp/queue.md" max_concurrent 1
    mkdir -p "$tmp/n1home/queue/sentinels"; printf 'N1_ORCA_TASK=task-T-A\n' > "$tmp/n1home/queue/sentinels/T-A.env"
    n1_queue_row_status "$tmp/queue.md" 1 in-progress
    echo "| T-A | 2026-10-31T00:00:00Z | | | | orca:task-T-A/d-T-A |" >> "$tmp/queue.md"
    mkdir -p "$tmp/n1home/memory/T-A"; printf -- '---\nstep: implement\n---\n' > "$tmp/n1home/memory/T-A/overview.md"
    cfg_set "$tmp" '.queue.subtaskTimeoutMinutes = 600'
    wl_set "$tmp" "$(wl_row T-A running unverifiable terminal_missing)"
    echo "R1 task-T-A" > "$tmp/.launch-1"; touch -d '10 minutes ago' "$tmp/.launch-1"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
    assert_eq "ghost: slot freed, next row launched" "failed|yes" \
        "$(plan_cell "$tmp/queue.md" 1 8)|$(grep 'worker-start' "$tmp/fake/orca-calls" | grep -q 'T-B' && echo yes || echo no)"
    rm -rf "$tmp"
}
test_orca_ghost_open_pr() {
    local tmp; tmp=$(mktemp -d); ghost_fixture "$tmp" unverifiable terminal_missing '10 minutes ago'
    mkdir -p "$tmp/n1home/memory/T-A/telemetry/raw/steps"
    printf '{"layer":"envelope","run_id":"r1","ticket_id":"T-A","branch":"me/T-A","started_at":"x","config_snapshot":{}}\n' \
        > "$tmp/n1home/memory/T-A/telemetry/raw/steps/r1.jsonl"
    touch -d "+1 hour" "$tmp/n1home/memory/T-A/telemetry/raw/steps/r1.jsonl"
    git -C "$tmp" init -q; git -C "$tmp" -c user.name=t -c user.email=t@t -c commit.gpgSign=false commit -q --allow-empty -m i; git -C "$tmp" branch me/T-A
    printf 'https://github.com/o/r/pull/239\t%s\n' "$(git -C "$tmp" rev-parse refs/heads/me/T-A)" > "$tmp/fake/gh-pr"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=2 > /dev/null
    assert_eq "ghost-pr: row is pr, dispatch released" "pr|yes" \
        "$(plan_cell "$tmp/queue.md" 1 8)|$([ "$(ghost_rel "$tmp")" -ge 1 ] && echo yes || echo no)"
    rm -rf "$tmp"
}
test_orca_ghost_never_released() {
    local tmp label v d age wlfail
    while IFS='|' read -r label v d age wlfail; do
        tmp=$(mktemp -d); ghost_fixture "$tmp" "$v" "$d" "$age"
        if [ -n "$wlfail" ]; then run_orca_queue "$tmp" FAKE_ORCA_WL_FAIL_AFTER=1 N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null
        else run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=3 > /dev/null; fi
        assert_eq "ghost-guard: $label -> row kept, not released" "in-progress|0" "$(plan_cell "$tmp/queue.md" 1 8)|$(ghost_rel "$tmp")"
        rm -rf "$tmp"
    done <<'EOF'
live verdict with terminal_missing|live|terminal_missing|10 minutes ago|
unverifiable without the marker|unverifiable||10 minutes ago|
marker inside the 5-minute grace|unverifiable|terminal_missing|1 minute ago|
no launch marker|unverifiable|terminal_missing||
unreadable worker list after the startup read|unverifiable|terminal_missing|10 minutes ago|1
EOF
}

test_orca_heartbeat
test_orca_worker_list_dispatch_bound
test_orca_stall_flag
test_beacon_lines
test_orca_ghost_worker
test_orca_ghost_never_released
test_orca_ghost_open_pr

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

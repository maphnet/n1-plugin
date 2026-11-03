#!/usr/bin/env bash
# Tests for lib/queue.sh and scripts/n1-queue-run.sh: Orca orchestration backend.
# Shared setup and fixtures: tests/queue_runner_lib.sh (N1-304 split).
set -euo pipefail
source "$(dirname "$0")/queue_runner_lib.sh"

# N1-268 AC2 (lib side). Bugs caught: a failed close still recording "stopped" and dropping the identity (merge guard
# off for a live worker); a worktree-wide close; closing a worker whose PR already merged.
test_orca_stop_worker() {
    local tmp out rc sent
    tmp=$(mktemp -d); orca_live_fixture "$tmp" https://github.com/o/r/pull/1; sent="$tmp/n1home/queue/sentinels/T-A.env"
    assert_eq "stop-lib: listed as unsettled" "1	T-A	$tmp/n1home	task-T-A	d-T-A" "$(orca_lib "$tmp" n1_orca_unsettled "$tmp/queue.md")"
    rc=0; out=$(FAKE_ORCA_CLOSE_FAIL=1 orca_lib "$tmp" n1_orca_stop_worker "$tmp/queue.md" 1 T-A "$tmp/n1home" task-T-A d-T-A run-1) || rc=$?
    assert_eq "stop-lib: close failure is non-zero" "1" "$rc"
    assert_eq "stop-lib: close failure reported" "yes" "$(grep -qF 'stop failed: T-A' <<< "$out" && echo yes || echo no)"
    assert_eq "stop-lib: close failure keeps row" "in-progress" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "stop-lib: close failure keeps identity" "yes" "$([ -e "$sent" ] && echo yes || echo no)"
    assert_eq "stop-lib: close failure releases nothing" "0" "$(grep -c worker-release "$tmp/fake/orca-calls" || true)"
    out=$(orca_lib "$tmp" n1_orca_stop_worker "$tmp/queue.md" 1 T-A "$tmp/n1home" task-T-A d-T-A run-1)
    assert_eq "stop-lib: stopped" "stopped: T-A" "$out"
    assert_eq "stop-lib: own handle closed (failed try + retry)" "2" "$(grep -c '^terminal close --terminal term-A' "$tmp/fake/orca-calls" || true)"
    assert_eq "stop-lib: never worktree-wide" "0" "$(grep -c -- '--all' "$tmp/fake/orca-calls" || true)"
    assert_eq "stop-lib: Plan + Runs stopped" "stopped stopped" "$(plan_cell "$tmp/queue.md" 1 8) $(_n1_queue_run_outcome "$tmp/queue.md" T-A)"
    assert_eq "stop-lib: identity removed" "no" "$([ -e "$sent" ] && echo yes || echo no)"
    assert_eq "stop-lib: event stopped" "stopped" "$(jq -r 'select(.event=="ticket_finished") | .outcome' "$tmp/events.jsonl")"
    assert_eq "stop-lib: nothing left to stop" "" "$(orca_lib "$tmp" n1_orca_unsettled "$tmp/queue.md")"
    rm -rf "$tmp"
    # N1-268 SEC-1. Bugs caught: a stale or child-forged overview.md pr_url (no queue_run_id of this run) recorded as
    # merged and the live worker's identity dropped without closing it; a merged PR whose worker is not yet settled.
    stop_merged_fixture() {   # <tmp> <stamp 0|1> <worker row state>
        orca_live_fixture "$1" https://github.com/o/r/pull/1
        printf '#!/bin/sh\ncase "$*" in *"pr view"*) echo MERGED ;; esac\n' > "$1/bin/gh"; chmod +x "$1/bin/gh"
        n1_write_frontmatter "$1/queue.md" run_id RID
        [ "$2" = 1 ] && n1_write_frontmatter "$1/n1home/memory/T-A/overview.md" queue_run_id RID
        wl_set "$1" "$(wl_row T-A "$3" | jq -c '.resource.terminalHandle = "term-A"')"
    }
    tmp=$(mktemp -d); stop_merged_fixture "$tmp" 1 succeeded; sent="$tmp/n1home/queue/sentinels/T-A.env"
    assert_eq "stop-lib: merged PR recorded" "merged: T-A" \
        "$(orca_lib "$tmp" n1_orca_stop_worker "$tmp/queue.md" 1 T-A "$tmp/n1home" task-T-A d-T-A run-1)"
    assert_eq "stop-lib: settled merged worker not closed" "0" "$(grep -c '^terminal close' "$tmp/fake/orca-calls" || true)"
    assert_eq "stop-lib: merged row pr / Runs merged" "pr merged" "$(plan_cell "$tmp/queue.md" 1 8) $(_n1_queue_run_outcome "$tmp/queue.md" T-A)"
    assert_eq "stop-lib: merged identity removed" "no" "$([ -e "$sent" ] && echo yes || echo no)"
    rm -rf "$tmp"
    tmp=$(mktemp -d); stop_merged_fixture "$tmp" 0 running; sent="$tmp/n1home/queue/sentinels/T-A.env"
    assert_eq "stop-lib: unattributed pr_url is not a merge" "stopped: T-A" \
        "$(orca_lib "$tmp" n1_orca_stop_worker "$tmp/queue.md" 1 T-A "$tmp/n1home" task-T-A d-T-A run-1)"
    assert_eq "stop-lib: unattributed pr_url -> live worker closed" "1" "$(grep -c '^terminal close --terminal term-A' "$tmp/fake/orca-calls" || true)"
    assert_eq "stop-lib: unattributed pr_url -> stopped, not merged" "stopped stopped" "$(plan_cell "$tmp/queue.md" 1 8) $(_n1_queue_run_outcome "$tmp/queue.md" T-A)"
    rm -rf "$tmp"
    tmp=$(mktemp -d); stop_merged_fixture "$tmp" 1 running; sent="$tmp/n1home/queue/sentinels/T-A.env"
    assert_eq "stop-lib: merged but live worker -> merged" "merged: T-A" \
        "$(orca_lib "$tmp" n1_orca_stop_worker "$tmp/queue.md" 1 T-A "$tmp/n1home" task-T-A d-T-A run-1)"
    assert_eq "stop-lib: merged but live worker is closed" "1" "$(grep -c '^terminal close --terminal term-A' "$tmp/fake/orca-calls" || true)"
    rm -rf "$tmp"
    tmp=$(mktemp -d); stop_merged_fixture "$tmp" 1 running; sent="$tmp/n1home/queue/sentinels/T-A.env"
    out=$(FAKE_ORCA_CLOSE_FAIL=1 orca_lib "$tmp" n1_orca_stop_worker "$tmp/queue.md" 1 T-A "$tmp/n1home" task-T-A d-T-A run-1) || true
    assert_eq "stop-lib: merged live worker, close failed -> identity kept" "yes" "$([ -e "$sent" ] && echo yes || echo no)"
    rm -rf "$tmp"
}

test_orca_parallel_workers() {   # AC1
    local tmp rid last_start first_rel; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done" "T-C:done"; mk_orca "$tmp"
    assert_eq "orca: exit 0" "0" "$(run_orca_queue "$tmp")"
    rid=$(n1_read_frontmatter "$tmp/queue.md" run_id)
    assert_eq "orca: Run id stored" "run-1" "$(n1_read_frontmatter "$tmp/queue.md" orca_run_id)"
    assert_eq "orca: rows reach pr" "pr,pr,pr" "$(plan_cell "$tmp/queue.md" 1 8),$(plan_cell "$tmp/queue.md" 2 8),$(plan_cell "$tmp/queue.md" 3 8)"
    assert_eq "orca: no claude --bg child" "0" "$(grep -c '^launch ' <<< "$(cat "$tmp/fake/events" 2>/dev/null)" || true)"
    last_start=$(grep -n worker-start "$tmp/fake/orca-calls" | tail -1 | cut -d: -f1)
    first_rel=$(line_of "$tmp/fake/orca-calls" worker-release)
    assert_eq "orca: 3 workers running at once" "3,yes" \
        "$(grep -c worker-start "$tmp/fake/orca-calls"),$([ -n "$first_rel" ] && [ "$last_start" -lt "$first_rel" ] && echo yes || echo no)"
    assert_eq "orca: worker flags" "yes" \
        "$(grep -qF -- "--task task-T-A --worktree new-top-level --name T-A --repo path:$tmp --agent claude --model sonnet" "$tmp/fake/orca-calls" && echo yes || echo no)"
    assert_eq "orca: Session cell" "orca:task-T-A/d-T-A" "$(n1_queue_session_id "$tmp/queue.md" T-A)"
    assert_eq "orca: sentinel written before worker-start" "4" \
        "$(grep -c -e '^N1_HEADLESS=1$' -e "^N1_QUEUE_RUN_ID=$rid$" -e '^N1_ORCA_TASK=task-T-A$' -e "^N1_ORCA_REPO=$tmp$" "$tmp/fake/sentinel.T-A")"
    assert_eq "orca: every worker released" "3" "$(grep -c worker-release "$tmp/fake/orca-calls")"
    assert_eq "orca: sentinels removed" "0" "$(ls "$tmp/n1home/queue/sentinels" 2>/dev/null | grep -c '\.env$' || true)"
    rm -rf "$tmp"
}

test_orca_max_concurrent() {
    local tmp b_start a_rel; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done"; mk_orca "$tmp"; cfg_set "$tmp" '.queue.maxConcurrent = 1'
    assert_eq "orca-max1: exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-max1: legacy plan (no max_concurrent) logs the live-config fallback" "1" \
        "$(grep -c 'planned before N1-303' "$tmp/output.txt" || true)"
    b_start=$(line_of "$tmp/fake/orca-calls" "--task task-T-B"); a_rel=$(line_of "$tmp/fake/orca-calls" "worker-release --dispatch d-T-A")
    assert_eq "orca-max1: T-B starts only after T-A is released" "yes" \
        "$([ -n "$b_start" ] && [ -n "$a_rel" ] && [ "$b_start" -gt "$a_rel" ] && echo yes || echo no)"
    rm -rf "$tmp"
}

test_orca_held_blocker() {   # AC3: merge-gated, no --deps
    local tmp b_start a_rel; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done"; mk_orca "$tmp"
    n1_queue_row_status "$tmp/queue.md" 2 held "blocked_on T-A"
    # N1-114 release fixture (as test_bg_held_user_merge): a github pr_url, MERGED into main, a syncable repo.
    printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://github.com/o/r/pull/7\n' > "$tmp/fake/overview.T-A"
    git init -q -b main "$tmp/origin"
    git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m init
    git init -q -b work "$tmp"
    git -C "$tmp" remote add origin "$tmp/origin"
    echo "MERGED main" > "$tmp/fake/gh-state"
    assert_eq "orca-held: exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-held: both pr" "pr,pr" "$(plan_cell "$tmp/queue.md" 1 8),$(plan_cell "$tmp/queue.md" 2 8)"
    b_start=$(line_of "$tmp/fake/orca-calls" "--task task-T-B"); a_rel=$(line_of "$tmp/fake/orca-calls" "worker-release --dispatch d-T-A")
    assert_eq "orca-held: dependent starts after its blocker completed" "yes" \
        "$([ -n "$b_start" ] && [ "$b_start" -gt "$a_rel" ] && echo yes || echo no)"
    assert_eq "orca-held: no --deps on tasks" "0" "$(grep task-create "$tmp/fake/orca-calls" | grep -vc -- "--deps \[\]" || true)"
    rm -rf "$tmp"; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done"; mk_orca "$tmp"
    n1_queue_row_status "$tmp/queue.md" 2 held "blocked_on T-A"
    echo OPEN > "$tmp/fake/gh-state"
    assert_eq "orca-held-open: exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-held-open: dependent never starts" "0" "$(grep -c -- "--task task-T-B" "$tmp/fake/orca-calls" || true)"
    rm -rf "$tmp"
}

test_orca_question_parks() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"
    orca_msg question task-T-A m-q1 > "$tmp/fake/question"
    printf '{"ticket":"T-A","question":"Pick a DB?","options":["A","B"],"recommended":"A","rationale":"x"}' > "$tmp/.question-T-A.json"
    assert_eq "orca-ask: exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-ask: row parked" "awaiting-human" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "orca-ask: message id kept for --answer" "m-q1" "$(cat "$tmp/.ask-T-A" 2>/dev/null)"
    assert_eq "orca-ask: needs-you points at --answer" "1" "$(grep -c 'T-A needs you.*--answer T-A' "$tmp/notes" || true)"
    assert_eq "orca-ask: never relaunched" "1" "$(grep -c worker-start "$tmp/fake/orca-calls")"
    rm -rf "$tmp"
}

# N1-309 AC1-AC3. Bug caught: a worker whose row already failed subtask-timeout asks a question; the .ask marker is
# written but the row loop only visits in-progress/awaiting-human rows, so no event, no needs-you, the worker waits
# forever and its later PR is never recorded (run 20261102T172042Z, N1-268). Timeline (timeout 60 s, poll 30 s):
# tick 3 times out, tick 4 asks, tick 5 answers (.ask removed as --answer does), tick 6 the worker reaches pr.
test_orca_question_after_timeout() {
    local tmp; tmp=$(mktemp -d)
    orca_resumed_row "$tmp"
    : > "$tmp/fake/nodone.T-A"
    orca_msg question task-T-A m-q1 > "$tmp/fake/q.late"
    printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://x/pr/A\n' > "$tmp/fake/overview.pr"
    printf 'cp "%s" "%s"\necho task-T-A >> "%s"\n' "$tmp/fake/q.late" "$tmp/fake/question" "$tmp/fake/started" > "$tmp/fake/at.4"
    printf 'rm -f "%s"\n' "$tmp/.ask-T-A" > "$tmp/fake/at.5"
    printf 'cp "%s" "%s"\n' "$tmp/fake/overview.pr" "$tmp/n1home/memory/T-A/overview.md" > "$tmp/fake/at.6"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=12 > /dev/null
    evc() { jq -R --arg e "$1" --arg o "${2:-}" 'fromjson? | select(.event == $e and .ticket == "T-A" and ($o == "" or .outcome == $o)) | .event' "$tmp/events.jsonl" | wc -l | tr -d ' '; }
    assert_eq "orca-ask-after-timeout: row re-adopted" "1" "$(grep -c 'T-A -> awaiting-human (worker asked after the row failed)' "$tmp/output.txt" || true)"
    assert_eq "orca-ask-after-timeout: one escalated event" "1" "$(evc escalated)"
    assert_eq "orca-ask-after-timeout: needs-you points at --answer" "1" "$(grep -c 'T-A needs you.*--answer T-A' "$tmp/notes" || true)"
    assert_eq "orca-ask-after-timeout: unblocked after the answer" "1" "$(evc unblocked)"
    # no WORKED reset: the stale clock (>60 s) would time the re-adopted row out again on the next tick
    assert_eq "orca-ask-after-timeout: exactly one timeout (clock reset)" "1" "$(evc ticket_finished failed)"
    assert_eq "orca-ask-after-timeout: one pr finish" "1" "$(evc ticket_finished pr)"
    assert_eq "orca-ask-after-timeout: later outcome recorded" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "orca-ask-after-timeout: never relaunched" "0" "$(grep -c worker-start "$tmp/fake/orca-calls" || true)"
    rm -rf "$tmp"
}

# N1-309. Bug caught: a question from a worker whose row is already pr (PR open, worker still in its review/CI loop)
# is dropped silently; re-adopting it instead would re-finalize the row and delete .ask before the user answers.
test_orca_question_on_pr_row() {
    local tmp; tmp=$(mktemp -d)
    orca_resumed_row "$tmp"
    : > "$tmp/fake/nodone.T-A"
    printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://x/pr/A\n' > "$tmp/n1home/memory/T-A/overview.md"
    orca_msg question task-T-A m-q2 > "$tmp/fake/q.late"
    printf 'cp "%s" "%s"\necho task-T-A >> "%s"\n' "$tmp/fake/q.late" "$tmp/fake/question" "$tmp/fake/started" > "$tmp/fake/at.2"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=8 > /dev/null
    assert_eq "orca-ask-pr: row keeps pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "orca-ask-pr: .ask kept for --answer" "m-q2" "$(cat "$tmp/.ask-T-A" 2>/dev/null)"
    assert_eq "orca-ask-pr: one escalated event" "1" \
        "$(jq -R 'fromjson? | select(.event == "escalated" and .ticket == "T-A") | .event' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    assert_eq "orca-ask-pr: one needs-you" "1" "$(grep -c 'T-A needs you.*--answer T-A' "$tmp/notes" || true)"
    rm -rf "$tmp"
}

# N1-309 CR-2. Bug caught: the .ask marker written for a question on a pr row outlived the row (orca_settle removed only
# the sentinel), so a re-queued ticket was parked on a message that no longer exists.
test_orca_question_on_pr_row_cleanup() {
    local tmp; tmp=$(mktemp -d)
    orca_resumed_row "$tmp"
    : > "$tmp/fake/nodone.T-A"
    printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://x/pr/A\n' > "$tmp/n1home/memory/T-A/overview.md"
    orca_msg question task-T-A m-q2 > "$tmp/fake/q.late"
    orca_msg worker_done task-T-A m-d2 > "$tmp/fake/q.done"
    printf 'cp "%s" "%s"\necho task-T-A >> "%s"\n' "$tmp/fake/q.late" "$tmp/fake/question" "$tmp/fake/started" > "$tmp/fake/at.2"
    printf 'cp "%s" "%s"\necho task-T-A >> "%s"\n' "$tmp/fake/q.done" "$tmp/fake/question" "$tmp/fake/started" > "$tmp/fake/at.4"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=8 > /dev/null
    assert_eq "orca-ask-pr-cleanup: row keeps pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "orca-ask-pr-cleanup: .ask removed once the worker is done" "no" "$([ -e "$tmp/.ask-T-A" ] && echo yes || echo no)"
    rm -rf "$tmp"
}

# N1-309. Bug caught: a question delivered after the row settled (worker done, released) recreated .ask and alerted.
test_orca_question_after_settle() {
    local tmp; tmp=$(mktemp -d)
    orca_resumed_row "$tmp"
    : > "$tmp/fake/nodone.T-A"
    printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://x/pr/A\n' > "$tmp/n1home/memory/T-A/overview.md"
    orca_msg worker_done task-T-A m-d2 > "$tmp/fake/q.done"
    orca_msg question task-T-A m-q3 > "$tmp/fake/q.late"
    printf 'cp "%s" "%s"\necho task-T-A >> "%s"\n' "$tmp/fake/q.done" "$tmp/fake/question" "$tmp/fake/started" > "$tmp/fake/at.2"
    printf 'cp "%s" "%s"\necho task-T-A >> "%s"\n' "$tmp/fake/q.late" "$tmp/fake/question" "$tmp/fake/started" > "$tmp/fake/at.5"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=8 > /dev/null
    assert_eq "orca-ask-settled: no .ask marker" "no" "$([ -e "$tmp/.ask-T-A" ] && echo yes || echo no)"
    assert_eq "orca-ask-settled: no alert" "0" "$(grep -c 'T-A needs you' "$tmp/notes" || true)"
    rm -rf "$tmp"
}

# N1-309 CR-1. Bug caught: heartbeats with a mismatched dispatch id were logged and recorded as dispatch_mismatch
# events every tick; the same skipped message replayed was recorded again.
test_orca_dispatch_skip_not_flooded() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"
    local f='.payload |= (fromjson | .dispatchId = "d-forged" | tojson)'
    printf '%s,%s,%s' "$(orca_msg heartbeat task-T-A m-h1 | jq -c "$f")" "$(orca_msg worker_done task-T-A m-x1 | jq -c "$f")" \
        "$(orca_msg worker_done task-T-A m-x1 | jq -c "$f")" > "$tmp/fake/question.multi"
    printf 'cp "%s" "%s"\necho task-T-A >> "%s"\n' "$tmp/fake/question.multi" "$tmp/fake/question" "$tmp/fake/started" > "$tmp/fake/at.2"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=6 > /dev/null
    assert_eq "orca-skip-flood: only the non-heartbeat skip, once" "1" \
        "$(jq -R 'fromjson? | select(.event == "dispatch_mismatch") | .event' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    rm -rf "$tmp"
}

test_orca_coordinator_sink() {   # N1-270 AC1
    # Bugs caught: an orchestration call (run-create, task-create, worker-start, check, worker-list) made as the
    # launching terminal, which Orca then nudges; the sink handle not stored for --answer; the sink left open at queue end.
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"; echo term-sink > "$tmp/fake/sink"
    assert_eq "sink: exit 0" "0" "$(run_orca_queue "$tmp" ORCA_TERMINAL_HANDLE=term-launch)"
    assert_eq "sink: handle stored" "term-sink" "$(n1_read_frontmatter "$tmp/queue.md" orca_coord_terminal)"
    assert_eq "sink: run-create from the sink" "1" "$(grep -c -- '--from term-sink' <<< "$(grep run-create "$tmp/fake/orca-calls")")"
    assert_eq "sink: checks ran as the sink" "yes" "$(grep -q '^orchestration check term-sink$' "$tmp/fake/orca-handles" && echo yes || echo no)"
    assert_eq "sink: no orchestration call as the launching terminal" "0" \
        "$(grep '^orchestration ' "$tmp/fake/orca-handles" | grep -vc ' term-sink$' || true)"
    assert_eq "sink: closed at queue end" "1" "$(grep -c 'terminal close --terminal term-sink' "$tmp/fake/orca-calls")"
    rm -rf "$tmp"
}

test_orca_coordinator_fallback() {
    # Bugs caught: a failed terminal create or a refused sink stopping the Orca run instead of falling back to the
    # launching terminal; a refused sink left open or recorded as the coordinator.
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    assert_eq "no-sink: exit 0" "0" "$(run_orca_queue "$tmp" ORCA_TERMINAL_HANDLE=term-launch)"
    assert_eq "no-sink: one notice" "1" "$(grep -c 'Orca coordinator terminal unavailable' "$tmp/output.txt")"
    assert_eq "no-sink: launching terminal coordinates" "1" "$(grep -c '^orchestration run-create term-launch$' "$tmp/fake/orca-handles")"
    assert_eq "no-sink: no coordinator recorded" "" "$(n1_read_frontmatter "$tmp/queue.md" orca_coord_terminal)"
    rm -rf "$tmp"; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"; echo term-sink > "$tmp/fake/sink"
    assert_eq "refused: exit 0" "0" "$(run_orca_queue "$tmp" ORCA_TERMINAL_HANDLE=term-launch FAKE_ORCA_SINK_REFUSE=1)"
    assert_eq "refused: notice" "1" "$(grep -c 'Orca refused the coordinator terminal' "$tmp/output.txt")"
    assert_eq "refused: retried as the launching terminal" "1" "$(grep -c '^orchestration run-create term-launch$' "$tmp/fake/orca-handles")"
    assert_eq "refused: Run still created" "run-1" "$(n1_read_frontmatter "$tmp/queue.md" orca_run_id)"
    assert_eq "refused: sink closed once" "1" "$(grep -c 'terminal close --terminal term-sink' "$tmp/fake/orca-calls")"
    assert_eq "refused: no coordinator recorded" "" "$(n1_read_frontmatter "$tmp/queue.md" orca_coord_terminal)"
    rm -rf "$tmp"
}

test_orca_resume_no_duplicate() {   # AC4
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    n1_write_frontmatter "$tmp/queue.md" orca_run_id run-1; n1_write_frontmatter "$tmp/queue.md" run_id R1; n1_write_frontmatter "$tmp/queue.md" orca_queue_run R1
    mkdir -p "$tmp/n1home/queue/sentinels"; printf 'N1_ORCA_TASK=task-T-A\n' > "$tmp/n1home/queue/sentinels/T-A.env"
    n1_queue_row_status "$tmp/queue.md" 1 in-progress
    echo "| T-A | 2026-10-31T00:00:00Z | | | | orca:task-T-A/d-T-A |" >> "$tmp/queue.md"
    mkdir -p "$tmp/n1home/memory/T-A"; printf -- '---\nstep: implement\n---\n' > "$tmp/n1home/memory/T-A/overview.md"
    wl_set "$tmp" "$(wl_row T-A running unverifiable)"
    echo term-sink > "$tmp/fake/sink"; n1_write_frontmatter "$tmp/queue.md" orca_coord_terminal term-old
    assert_eq "orca-resume: exit 0" "0" "$(run_orca_queue "$tmp" ORCA_TERMINAL_HANDLE=term-launch)"
    # N1-270: a resume rebinds the Run to a fresh sink and closes the previous one.
    assert_eq "orca-resume: run-use as the new sink" "1" "$(grep -c '^orchestration run-use term-sink$' "$tmp/fake/orca-handles")"
    assert_eq "orca-resume: new sink stored" "term-sink" "$(n1_read_frontmatter "$tmp/queue.md" orca_coord_terminal)"
    assert_eq "orca-resume: previous sink closed" "1" "$(grep -c 'terminal close --terminal term-old' "$tmp/fake/orca-calls")"
    assert_eq "orca-resume: Run rebound" "1" "$(grep -c 'run-use --id run-1' "$tmp/fake/orca-calls")"
    assert_eq "orca-resume: no new Run" "0" "$(grep -c run-create "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-resume: unverifiable worker never relaunched" "0" "$(grep -c worker-start "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-resume: unverifiable worker never released" "0" "$(grep -c worker-release "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-resume: timeout fails without a retry row" "failed|subtask-timeout|1" \
        "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)|$(awk -F'|' '$2 ~ /^ *[0-9]+ *$/' "$tmp/queue.md" | wc -l | tr -d ' ')"
    # SEC-4: the timed-out worker is not proven exited, so it keeps its identity (pin and sentinel).
    assert_eq "orca-resume: timed-out live worker keeps its sentinel" "yes" "$([ -e "$tmp/n1home/queue/sentinels/T-A.env" ] && echo yes || echo no)"
    # A worker proven exited: the failed row loses its sentinel (asserted on the dir the runner used, TQ-2).
    rm -rf "$tmp"; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    n1_write_frontmatter "$tmp/queue.md" orca_run_id run-1; n1_write_frontmatter "$tmp/queue.md" run_id R1; n1_write_frontmatter "$tmp/queue.md" orca_queue_run R1
    mkdir -p "$tmp/n1home/queue/sentinels"; printf 'N1_ORCA_TASK=task-T-A\n' > "$tmp/n1home/queue/sentinels/T-A.env"
    n1_queue_row_status "$tmp/queue.md" 1 in-progress
    echo "| T-A | 2026-10-31T00:00:00Z | | | | orca:task-T-A/d-T-A |" >> "$tmp/queue.md"
    mkdir -p "$tmp/n1home/memory/T-A"; printf -- '---\nstep: implement\n---\n' > "$tmp/n1home/memory/T-A/overview.md"
    wl_set "$tmp" "$(wl_row T-A released)"
    assert_eq "orca-resume: exited: exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-resume: exited: row failed" "failed|child-exited-incomplete" "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "orca-resume: failed row of an exited worker loses its sentinel" "no" "$([ -e "$tmp/n1home/queue/sentinels/T-A.env" ] && echo yes || echo no)"
    rm -rf "$tmp"; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    n1_write_frontmatter "$tmp/queue.md" orca_run_id run-1; n1_write_frontmatter "$tmp/queue.md" run_id R1; n1_write_frontmatter "$tmp/queue.md" orca_queue_run R1
    assert_eq "orca-resume-down: halts" "2" "$(run_orca_queue "$tmp" FAKE_ORCA_RUNUSE_FAIL=1)"
    assert_eq "orca-resume-down: nothing launched" "0" "$(grep -c worker-start "$tmp/fake/orca-calls" || true)"
    rm -rf "$tmp"
}

# N1-267 AC1. Bug caught: a worker whose PR is open (pr step still waiting on CI/review) hits subtaskTimeoutMinutes and
# the row is recorded failed|subtask-timeout although the PR later merges (N1-259 / PR #239 in run 20261101T131600Z).
test_orca_timeout_open_pr() {
    local tmp; tmp=$(mktemp -d)
    orca_resumed_row "$tmp"
    mkdir -p "$tmp/n1home/memory/T-A/telemetry/raw/steps"
    printf '{"layer":"envelope","run_id":"r1","ticket_id":"T-A","branch":"me/T-A","started_at":"x","config_snapshot":{}}\n' \
        > "$tmp/n1home/memory/T-A/telemetry/raw/steps/r1.jsonl"
    touch -d "+1 hour" "$tmp/n1home/memory/T-A/telemetry/raw/steps/r1.jsonl"  # as if written after launch: the runner ignores an envelope older than the child start, and the start can land in the next second
    git -C "$tmp" init -q; git -C "$tmp" -c user.name=t -c user.email=t@t -c commit.gpgSign=false commit -q --allow-empty -m i; git -C "$tmp" branch me/T-A
    printf 'https://github.com/o/r/pull/239\t%s\n' "$(git -C "$tmp" rev-parse refs/heads/me/T-A)" > "$tmp/fake/gh-pr"
    assert_eq "orca-timeout-pr: exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-timeout-pr: row is pr, not subtask-timeout, no retry row" "pr||1" \
        "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)|$(awk -F'|' '$2 ~ /^ *[0-9]+ *$/' "$tmp/queue.md" | wc -l | tr -d ' ')"
    assert_eq "orca-timeout-pr: Runs records the PR" "https://github.com/o/r/pull/239" \
        "$(awk -F'|' '/^## Runs/{f=1;next} f && $2 ~ /T-A/ { gsub(/ /,"",$6); print $6 }' "$tmp/queue.md")"
    assert_eq "orca-timeout-pr: asked gh for the envelope branch" "1" "$(grep -c -- '--head me/T-A' "$tmp/fake/gh-calls")"
    # The worker is still running (unverifiable): it stays owed, never released, keeps its identity.
    assert_eq "orca-timeout-pr: live worker not released" "0" "$(grep -c worker-release "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-timeout-pr: live worker keeps its sentinel" "yes" "$([ -e "$tmp/n1home/queue/sentinels/T-A.env" ] && echo yes || echo no)"
    rm -rf "$tmp"
}

# N1-267 AC2 (timeout 1 min = 60 s, every empty tick charges 30 s, so an unpaused row times out on tick 3).
# Bugs caught: (a) a worker idle on the usage limit is charged and fails subtask-timeout before it can finish;
# (b) after the reset (new assistant entry) the clock never resumes, so a hung worker never times out;
# (c) with no ceiling a stale notice keeps a dead worker in-progress forever; (d) control: a working transcript is charged.
test_orca_usage_stall() {
    local tmp MARK ASST
    MARK='{"type":"system","subtype":"informational","level":"notice","content":"Usage limit reached · continuing automatically at 7:30pm · esc to cancel"}'
    ASST='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}'
    # (a) stalled ticks 1-3, the worker finishes on tick 4 -> pr (unpaused: failed on tick 3).
    tmp=$(mktemp -d); orca_stall_fixture "$tmp" "$ASST" "$MARK"
    printf 'cp "%s" "%s"\n' "$tmp/fake/late" "$tmp/n1home/memory/T-A/overview.md" > "$tmp/fake/at.4"
    assert_eq "orca-stall: exit 0" "0" "$(run_orca_queue "$tmp" CLAUDE_CONFIG_DIR="$tmp/cc")"
    assert_eq "orca-stall: stalled worker not charged, finishes as pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    rm -rf "$tmp"
    # (b) stalled tick 1, reset on tick 2, charged 30/60/90 on ticks 2-4 -> subtask-timeout before the tick-6 finish.
    tmp=$(mktemp -d); orca_stall_fixture "$tmp" "$ASST" "$MARK"
    printf 'cat "%s" >> "%s"\n' "$tmp/fake/asst" "$tmp/cc/projects/-orca-wt-T-A/s1.jsonl" > "$tmp/fake/at.2"
    printf 'cp "%s" "%s"\n' "$tmp/fake/late" "$tmp/n1home/memory/T-A/overview.md" > "$tmp/fake/at.6"
    assert_eq "orca-stall-reset: exit 0" "0" "$(run_orca_queue "$tmp" CLAUDE_CONFIG_DIR="$tmp/cc")"
    assert_eq "orca-stall-reset: charging resumes after the reset" "failed|subtask-timeout" \
        "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
    # (c) notice never clears: stall budget (2x timeout) runs out, the row still times out and the runner exits.
    tmp=$(mktemp -d); orca_stall_fixture "$tmp" "$ASST" "$MARK"
    assert_eq "orca-stall-ceiling: exit 0" "0" "$(run_orca_queue "$tmp" CLAUDE_CONFIG_DIR="$tmp/cc" N1_QUEUE_TEST_MAX_TICKS=10)"
    assert_eq "orca-stall-ceiling: times out despite a stale notice" "failed|subtask-timeout" \
        "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
    # (d) control: no notice -> charged, times out on tick 3 before the tick-4 finish.
    tmp=$(mktemp -d); orca_stall_fixture "$tmp" "$ASST"
    printf 'cp "%s" "%s"\n' "$tmp/fake/late" "$tmp/n1home/memory/T-A/overview.md" > "$tmp/fake/at.4"
    assert_eq "orca-stall-control: exit 0" "0" "$(run_orca_queue "$tmp" CLAUDE_CONFIG_DIR="$tmp/cc")"
    assert_eq "orca-stall-control: working worker is charged" "failed|subtask-timeout" \
        "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
}

# N1-267 AC3. Bug caught: three Orca rows timing out together on one cause (a shared usage-limit wait) count as three
# strikes and halt the queue mid-tick (run 20261101T131600Z), so the pending row T-D never runs.
test_orca_same_reason_one_strike() {
    local tmp t; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done" "T-C:done" "T-D:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.queue.maxConcurrent = 3'
    for t in T-A T-B T-C; do echo implement > "$tmp/fake/step.$t"; : > "$tmp/fake/nodone.$t"; done
    assert_eq "orca-strike-dedupe: not halted (exit 0)" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-strike-dedupe: all three timed out" "failed|subtask-timeout failed|subtask-timeout failed|subtask-timeout" \
        "$(for n in 1 2 3; do printf '%s|%s ' "$(plan_cell "$tmp/queue.md" "$n" 8)" "$(plan_cell "$tmp/queue.md" "$n" 9)"; done | sed 's/ $//')"
    assert_eq "orca-strike-dedupe: remaining row still processed" "pr" "$(plan_cell "$tmp/queue.md" 4 8)"
    assert_eq "orca-strike-dedupe: no halted step" "no" "$([ "$(n1_read_frontmatter "$tmp/queue.md" step)" = halted ] && echo yes || echo no)"
    rm -rf "$tmp"
}

# N1-267 regression guard. Bug caught: the dedupe swallowing distinct reasons, so three unrelated consecutive Orca
# failures (launch clash, incomplete exit, timeout) no longer halt the queue.
test_orca_mixed_reasons_halt() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done" "T-C:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.queue.maxConcurrent = 3'
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"   # -> subtask-timeout
    echo implement > "$tmp/fake/step.T-B"                               # done without PR -> child-exited-incomplete
    printf '{"path":"/orca/wt/T-C"}' > "$tmp/fake/worktrees"            # -> orca-worktree-name-taken at launch
    assert_eq "orca-strike-mixed: halts (exit 2)" "2" "$(run_orca_queue "$tmp")"
    assert_eq "orca-strike-mixed: step halted" "halted" "$(n1_read_frontmatter "$tmp/queue.md" step)"
    rm -rf "$tmp"
}

# N1-267 CR-1. Bug caught: the dedupe swallowing non-timeout reasons, so a systemic launch failure (three launches
# failing orca-task-create) drains every pending row instead of halting the queue.
test_orca_same_launch_reason_halts() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done" "T-C:done" "T-D:done"; mk_orca "$tmp"
    assert_eq "orca-strike-launch: halts (exit 2)" "2" "$(run_orca_queue "$tmp" FAKE_ORCA_TASK_FAIL=1)"
    assert_eq "orca-strike-launch: step halted" "halted" "$(n1_read_frontmatter "$tmp/queue.md" step)"
    assert_eq "orca-strike-launch: no worker, no drain" "0" "$(grep -c '"halt_draining"' "$tmp/events.jsonl" || true)"
    rm -rf "$tmp"
}

# N1-268 AC1. Bug caught (run 20261101T131600Z): halt() exited with a worker in flight; the worker merged its PR
# unsupervised, its Runs row stayed blank and its identity sentinel stayed.
test_orca_halt_keeps_supervising() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done" "T-C:done" "T-D:done" "T-E:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.queue.maxConcurrent = 3 | .queue.subtaskTimeoutMinutes = 5'
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"   # T-A: live worker at the halt
    printf '{"path":"/orca/wt/T-B"},{"path":"/orca/wt/T-C"},{"path":"/orca/wt/T-D"}' > "$tmp/fake/worktrees"   # three launch strikes
    printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://github.com/o/r/pull/7\n' > "$tmp/fake/late"
    printf 'cp "%s" "%s"; rm -f "%s"\n' "$tmp/fake/late" "$tmp/n1home/memory/T-A/overview.md" "$tmp/fake/nodone.T-A" > "$tmp/fake/at.4"
    printf '#!/bin/sh\ncase "$*" in *"pr view"*) echo MERGED ;; esac\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
    assert_eq "orca-halt-supervise: final halt (exit 2)" "2" "$(run_orca_queue "$tmp")"
    assert_eq "orca-halt-supervise: step halted at the end" "halted" "$(n1_read_frontmatter "$tmp/queue.md" step)"
    assert_eq "orca-halt-supervise: drain announced once" "1" "$(grep -c '"halt_draining"' "$tmp/events.jsonl" || true)"
    assert_eq "orca-halt-supervise: worker merge recorded" "merged" "$(_n1_queue_run_outcome "$tmp/queue.md" T-A)"
    assert_eq "orca-halt-supervise: merged before the final halted event" "ticket_finished halted" \
        "$(jq -r 'select((.event=="ticket_finished" and .outcome=="merged") or .event=="halted") | .event' "$tmp/events.jsonl" | tr '\n' ' ' | sed 's/ $//')"
    assert_eq "orca-halt-supervise: identity removed" "no" "$([ -e "$tmp/n1home/queue/sentinels/T-A.env" ] && echo yes || echo no)"
    assert_eq "orca-halt-supervise: no launch after the halt" "0" "$(grep -c 'task-T-E' "$tmp/fake/started" || true)"
    rm -rf "$tmp"
}

# N1-268 Q4. Bug caught: the drain deferring the inbox-unreadable halt, so a runner that cannot supervise hangs.
test_orca_inbox_down_hard_halt() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.queue.subtaskTimeoutMinutes = 5'
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"
    assert_eq "orca-inbox-down: halts (exit 2)" "2" "$(run_orca_queue "$tmp" FAKE_ORCA_CHECK_FAIL=1)"
    assert_eq "orca-inbox-down: step halted" "halted" "$(n1_read_frontmatter "$tmp/queue.md" step)"
    assert_eq "orca-inbox-down: no drain" "0" "$(grep -c '"halt_draining"' "$tmp/events.jsonl" || true)"
    rm -rf "$tmp"
}

# N1-268 AC2 (runner side). Bug caught: no way to stop a halted queue's workers; Escape does not stop an Orca worker.
test_orca_stop_marker() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.queue.maxConcurrent = 1 | .queue.subtaskTimeoutMinutes = 5'
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"
    wl_set "$tmp" "$(wl_row T-A running | jq -c '.resource.terminalHandle = "term-A"')"
    n1_write_frontmatter "$tmp/queue.md" run_id RID-S
    printf 'printf %%s RID-S > "%s/.stop"\n' "$tmp" > "$tmp/fake/at.3"   # the user confirmed --stop during tick 3 (marker = run_id)
    assert_eq "orca-stop: halts after the stop (exit 2)" "2" "$(run_orca_queue "$tmp")"
    assert_eq "orca-stop: own terminal closed" "1" "$(grep -c '^terminal close --terminal term-A' "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-stop: row stopped" "stopped" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "orca-stop: Runs outcome stopped" "stopped" "$(_n1_queue_run_outcome "$tmp/queue.md" T-A)"
    assert_eq "orca-stop: identity removed" "no" "$([ -e "$tmp/n1home/queue/sentinels/T-A.env" ] && echo yes || echo no)"
    assert_eq "orca-stop: marker consumed" "no" "$([ -e "$tmp/.stop" ] && echo yes || echo no)"
    assert_eq "orca-stop: no launch after the stop" "0" "$(grep -c 'task-T-B' "$tmp/fake/started" || true)"
    assert_eq "orca-stop: halted reason" "stopped by user" "$(jq -r 'select(.event=="halted") | .reason' "$tmp/events.jsonl")"
    assert_eq "orca-stop: drain announced (CR-3)" "stopped by user" "$(jq -r 'select(.event=="halt_draining") | .reason' "$tmp/events.jsonl")"
    rm -rf "$tmp"
}

test_orca_stop_gated_untouched() {   # N1-303 x N1-268: draining a stop leaves a schedule-gated pending row pending (no launch, no gated expiry)
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-1:done" "T-2:done"; mk_orca "$tmp"; sched_set "$tmp" 3 T-2 T-1
    cfg_set "$tmp" '.autonomy.fullAuto = true | .finishWork.mergeOnFinish = true | .queue.maxConcurrent = 3 | .queue.subtaskTimeoutMinutes = 1 | .queue.pollSeconds = 30'
    echo implement > "$tmp/fake/step.T-1"; : > "$tmp/fake/nodone.T-1"
    wl_set "$tmp" "$(wl_row T-1 running | jq -c '.resource.terminalHandle = "term-1"')"
    n1_write_frontmatter "$tmp/queue.md" run_id RID-S
    printf 'printf %%s RID-S > "%s/.stop"\n' "$tmp" > "$tmp/fake/at.3"
    assert_eq "orca-stop-gated: halts (exit 2)" "2" "$(run_orca_queue "$tmp")"
    assert_eq "orca-stop-gated: T-2 never started" "0" "$(grep -c -- "--task task-T-2" "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-stop-gated: T-2 still pending, not skipped" "pending" "$(plan_cell "$tmp/queue.md" 2 8)"
    rm -rf "$tmp"
}

test_orca_stop_marker_forged() {   # N1-268 SEC-2: a marker not carrying this queue's run_id is not a user confirmation
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.queue.maxConcurrent = 1 | .queue.subtaskTimeoutMinutes = 5'
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"
    wl_set "$tmp" "$(wl_row T-A running | jq -c '.resource.terminalHandle = "term-A"')"
    printf ': > "%s/.stop"\n' "$tmp" > "$tmp/fake/at.3"
    run_orca_queue "$tmp" >/dev/null
    assert_eq "orca-stop-forged: no terminal closed" "0" "$(grep -c '^terminal close' "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-stop-forged: not recorded stopped" "0" "$(grep -c stopped "$tmp/queue.md" || true)"
    assert_eq "orca-stop-forged: marker discarded" "no" "$([ -e "$tmp/.stop" ] && echo yes || echo no)"
    rm -rf "$tmp"
}

test_orca_stop_close_failure_notifies() {   # N1-268 CR-5: a failed close on the queued path reaches the user
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.queue.maxConcurrent = 1 | .queue.subtaskTimeoutMinutes = 5 | .queue.notify = "command" | .queue.notifyCommand = "cat >> '"$tmp"'/notes"'
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"
    wl_set "$tmp" "$(wl_row T-A running | jq -c '.resource.terminalHandle = "term-A"')"
    n1_write_frontmatter "$tmp/queue.md" run_id RID-S
    printf 'printf %%s RID-S > "%s/.stop"\n' "$tmp" > "$tmp/fake/at.3"
    run_orca_queue "$tmp" FAKE_ORCA_CLOSE_FAIL=1 >/dev/null
    assert_eq "orca-stop-fail: user notified" "yes" "$(jq -r 'select(.kind=="needs-you") | .text' "$tmp/notes" 2>/dev/null | grep -qF 'Stop failed: T-A' && echo yes || echo no)"
    rm -rf "$tmp"
}

test_orca_stale_stop_marker_ignored() {   # N1-268: a marker left by a dead runner must not stop a fresh run
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"; : > "$tmp/.stop"
    assert_eq "orca-stale-stop: run completes (exit 0)" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-stale-stop: row pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    rm -rf "$tmp"
}

test_orca_launch_failure_identity() {   # an ambiguous launch failure never strips a possibly live worker's identity
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    wl_set "$tmp" "$(wl_row T-A running)"
    run_orca_queue "$tmp" FAKE_ORCA_START_FAIL=1 > /dev/null
    assert_eq "orca-launch-fail: listed worker keeps its sentinel" "yes" "$([ -e "$tmp/n1home/queue/sentinels/T-A.env" ] && echo yes || echo no)"
    rm -rf "$tmp"; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    run_orca_queue "$tmp" FAKE_ORCA_START_FAIL=1 > /dev/null
    assert_eq "orca-launch-fail: no worker in a readable list: sentinel removed" "no" "$([ -e "$tmp/n1home/queue/sentinels/T-A.env" ] && echo yes || echo no)"
    rm -rf "$tmp"
}

test_orca_settle_chain_before_sentinel() {   # the sentinel outlives the fullAuto chain, so a restart re-owes it
    grep -n 'chain_finish' "$REPO_ROOT/scripts/n1-queue-run.sh" > /dev/null
    local s r; s=$(grep -n 'chain_finish "\$NUM" "\$TICKET" "\$REPO" "\$N1H" "\$MODEL" "\$URL"' "$REPO_ROOT/scripts/n1-queue-run.sh" | head -1 | cut -d: -f1)
    r=$(grep -n 'n1_orca_sentinel_rm "$(orca_n1h_of' "$REPO_ROOT/scripts/n1-queue-run.sh" | head -1 | cut -d: -f1)
    assert_eq "orca-settle: chain_finish runs before the sentinel is removed" "yes" "$([ -n "$s" ] && [ -n "$r" ] && [ "$s" -lt "$r" ] && echo yes || echo no)"
}

test_orca_resume_owed() {   # CR-1: a settled row is not re-owed on resume; CR-2: a live worker is never settled at expiry
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    n1_write_frontmatter "$tmp/queue.md" orca_run_id run-1; n1_write_frontmatter "$tmp/queue.md" run_id R1; n1_write_frontmatter "$tmp/queue.md" orca_queue_run R1
    n1_queue_row_status "$tmp/queue.md" 1 pr
    echo "| T-A | 2026-10-31T00:00:00Z | | | | orca:task-T-A/d-T-A |" >> "$tmp/queue.md"
    mkdir -p "$tmp/n1home/memory/T-A"; printf -- '---\nstep: pr\nqueue_run_id: R1\n---\n## Pending\npr_url: https://x/pr/A\n' > "$tmp/n1home/memory/T-A/overview.md"
    wl_set "$tmp" "$(wl_row T-A running)"
    assert_eq "orca-owed: settled row (no sentinel): exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-owed: settled row is not waited for or released again" "0" "$(grep -c worker-release "$tmp/fake/orca-calls" || true)"
    # CR-2: the row is still owed (sentinel names the task) but its worker is live: expiry must not release it.
    mkdir -p "$tmp/n1home/queue/sentinels"; printf 'N1_ORCA_TASK=task-T-A\n' > "$tmp/n1home/queue/sentinels/T-A.env"
    assert_eq "orca-owed: live worker: exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-owed: live worker is not released at expiry" "0" "$(grep -c worker-release "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-owed: live worker keeps its sentinel" "yes" "$([ -e "$tmp/n1home/queue/sentinels/T-A.env" ] && echo yes || echo no)"
    assert_eq "orca-owed: user told to resume" "1" "$(grep -c 'still running after their PR' "$tmp/notes" || true)"
    # SEC-7: an empty list that was readable once, then failed refreshes, must not prove the worker gone.
    rm -f "$tmp/fake/workers.json"; : > "$tmp/fake/orca-calls"; : > "$tmp/notes"
    assert_eq "orca-owed: stale list: exit 0" "0" "$(run_orca_queue "$tmp" FAKE_ORCA_WL_FAIL_AFTER=1)"
    assert_eq "orca-owed: failed refresh after an empty list does not release" "0" "$(grep -c worker-release "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-owed: stale list keeps the sentinel" "yes" "$([ -e "$tmp/n1home/queue/sentinels/T-A.env" ] && echo yes || echo no)"
    rm -rf "$tmp"
}

test_orca_adopt_launch() {   # AC4: runner died between worker-start and the Runs write
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    n1_write_frontmatter "$tmp/queue.md" orca_run_id run-1; n1_write_frontmatter "$tmp/queue.md" run_id R1; n1_write_frontmatter "$tmp/queue.md" orca_queue_run R1
    n1_queue_row_status "$tmp/queue.md" 1 in-progress
    echo "R1 task-T-A" > "$tmp/.launch-1"
    mkdir -p "$tmp/n1home/memory/T-A"; printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://x/pr/A\n' > "$tmp/n1home/memory/T-A/overview.md"
    wl_set "$tmp" "$(wl_row T-A running unverifiable)"
    assert_eq "orca-adopt: exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-adopt: no relaunch" "0" "$(grep -cE 'task-create|worker-start' "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-adopt: Runs row adopted" "1" "$(grep -c '| orca:task-T-A/d-T-A |' "$tmp/queue.md")"
    assert_eq "orca-adopt: row reaches pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    rm -rf "$tmp"
}

test_orca_stale_run_not_reused() {   # a fresh --run (new run_id) never rebinds the previous run's Orca Run
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working done"; mk_orca "$tmp"; cfg_set "$tmp" '.queue.backend = "bg"'
    n1_write_frontmatter "$tmp/queue.md" orca_run_id run-old; n1_write_frontmatter "$tmp/queue.md" run_id R2; n1_write_frontmatter "$tmp/queue.md" orca_queue_run R1
    assert_eq "orca-stale: exit 0" "0" "$(run_orca_queue "$tmp" FAKE_ORCA_RUNUSE_FAIL=1)"
    assert_eq "orca-stale: old Run not rebound" "0" "$(grep -c run-use "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-stale: bg launch" "1" "$(grep -c '^launch n1-bgq-T-A-1$' "$tmp/fake/events")"
    rm -rf "$tmp"
}

test_orca_lost_done_still_chains() {   # worker_done lost: the overview is terminal, the fullAuto chain must still run
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.autonomy.fullAuto = true | .finishWork.mergeOnFinish = true'
    echo OPEN > "$tmp/fake/gh-state"; : > "$tmp/fake/nodone.T-A"
    printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://github.com/o/r/pull/7\n' > "$tmp/fake/overview.T-A"
    assert_eq "orca-lost-done: exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-lost-done: one chained n1-finish" "1" "$(grep -c '^launch n1-oq-T-A-1-fin$' <<< "$(cat "$tmp/fake/events" 2>/dev/null)" || true)"
    assert_eq "orca-lost-done: worker released" "1" "$(grep -c worker-release "$tmp/fake/orca-calls")"
    rm -rf "$tmp"
}

test_orca_settled_from_worker_list() {   # N1-281 AC2: worker_done lost, worker-list shows succeeded -> settled, next row launches
    local tmp r s; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done"; mk_orca "$tmp"
    # A large timeout: T-B can only start through the per-tick durable settle, never through the OWED_WAIT expiry.
    cfg_set "$tmp" '.queue.maxConcurrent = 1 | .queue.subtaskTimeoutMinutes = 600'
    : > "$tmp/fake/nodone.T-A"
    wl_set "$tmp" "$(wl_row T-A succeeded)"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=10 > /dev/null
    assert_eq "orca-settled: T-A reached pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "orca-settled: T-A worker released once" "1" "$(grep -c -- 'worker-release --dispatch d-T-A' "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-settled: T-A sentinel removed" "no" "$([ -e "$tmp/n1home/queue/sentinels/T-A.env" ] && echo yes || echo no)"
    r=$(line_of "$tmp/fake/orca-calls" 'worker-release --dispatch d-T-A'); s=$(line_of "$tmp/fake/orca-calls" '--task task-T-B')
    assert_eq "orca-settled: T-B launched after T-A's release" "yes" "$([ -n "$r" ] && [ -n "$s" ] && [ "$s" -gt "$r" ] && echo yes || echo no)"
    rm -rf "$tmp"
}

test_orca_forged_dispatch_ignored() {   # N1-281 SEC-1: a message naming a task with another dispatch id must not act on its row
    # N1-309 (N1-287): the skip is logged to runner.log and recorded as a dispatch_mismatch event (not dropped silently);
    # the untrusted message id reaches both only as [A-Za-z0-9_-].
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done"; mk_orca "$tmp"
    echo implement > "$tmp/fake/step.T-A"; echo implement > "$tmp/fake/step.T-B"
    : > "$tmp/fake/nodone.T-A"; : > "$tmp/fake/nodone.T-B"
    printf '%s' "$(orca_msg worker_done task-T-B 'm-d1"<x>$(y)' | jq -c '.payload |= (fromjson | .dispatchId = "d-forged" | tojson)')" > "$tmp/fake/question"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=10 > /dev/null
    assert_eq "orca-forged: T-B not finalized by a mismatched dispatch" "no" \
        "$([ "$(plan_cell "$tmp/queue.md" 2 9)" = child-exited-incomplete ] && echo yes || echo no)"
    assert_eq "orca-forged: skip logged to runner.log" "1" \
        "$(grep -c -F '[orca] skipped message (dispatch-mismatch task=task-T-B msg=m-d1xy)' "$tmp/output.txt" || true)"
    assert_eq "orca-forged: dispatch_mismatch event, sanitized" "T-B|dispatch-mismatch task=task-T-B msg=m-d1xy" \
        "$(jq -rR 'fromjson? | select(.event == "dispatch_mismatch") | "\(.ticket)|\(.reason)"' "$tmp/events.jsonl")"
    rm -rf "$tmp"
}

test_orca_done_without_dispatch_ignored() {   # N1-281: a worker_done whose payload lacks dispatchId must not act on the row
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done"; mk_orca "$tmp"
    echo implement > "$tmp/fake/step.T-A"; echo implement > "$tmp/fake/step.T-B"
    : > "$tmp/fake/nodone.T-A"; : > "$tmp/fake/nodone.T-B"
    printf '%s' "$(orca_msg worker_done task-T-B m-d1 | jq -c '.payload |= (fromjson | del(.dispatchId) | tojson)')" > "$tmp/fake/question"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=10 > /dev/null
    assert_eq "orca-nodisp: T-B not finalized by a dispatch-less done" "no" \
        "$([ "$(plan_cell "$tmp/queue.md" 2 9)" = child-exited-incomplete ] && echo yes || echo no)"
    rm -rf "$tmp"
}

test_orca_replay_not_timeout() {   # replayed batches must not charge a poll interval each (no false subtask-timeout)
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"; : > "$tmp/fake/replay"
    printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://x/pr/A\n' > "$tmp/fake/overview.late"
    assert_eq "orca-replay: exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-replay: row finished, not timed out" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    rm -rf "$tmp"
}

test_orca_worktree_list_unreadable() {   # SEC-3: an unreadable worktree list fails the row, no worker starts blind
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    assert_eq "orca-wt-unreadable: exit 0" "0" "$(run_orca_queue "$tmp" FAKE_ORCA_WT_FAIL=1)"
    assert_eq "orca-wt-unreadable: nothing started" "0" "$(grep -cE 'task-create|worker-start' "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-wt-unreadable: row failed" "failed|orca-worktree-name-taken" "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
}

test_orca_worktree_name_taken() {   # identity needs the folder name == ticket: a clash fails the row, no launch
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    printf '{"path":"/orca/wt/T-A"}' > "$tmp/fake/worktrees"
    assert_eq "orca-wt-taken: exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-wt-taken: nothing started" "0" "$(grep -cE 'task-create|worker-start' "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-wt-taken: row failed, no deferred retry" "failed|orca-worktree-name-taken|1" \
        "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)|$(awk -F'|' '$2 ~ /^ *[0-9]+ *$/' "$tmp/queue.md" | wc -l | tr -d ' ')"
    rm -rf "$tmp"
}

test_orca_chain_after_settle() {   # fullAuto chain stays a bg n1-finish, launched once the worker settled
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.autonomy.fullAuto = true | .finishWork.mergeOnFinish = true'
    echo OPEN > "$tmp/fake/gh-state"
    printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://github.com/o/r/pull/7\n' > "$tmp/fake/overview.T-A"
    assert_eq "orca-chain: exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-chain: one chained n1-finish" "1" "$(grep -c '^launch n1-oq-T-A-1-fin$' <<< "$(cat "$tmp/fake/events" 2>/dev/null)" || true)"
    rm -rf "$tmp"
}

test_orca_fallback_bg() {   # AC5: Orca available but not used, or unusable -> claude --bg exactly as before
    local tmp c rc want
    for c in backend-bg run-create-fails runtime-down; do
        tmp=$(mktemp -d); mk_bg "$tmp" bgq "T-A:working done"; mk_orca "$tmp"
        case "$c" in
            backend-bg) cfg_set "$tmp" '.queue.backend = "bg"'; rc=$(run_orca_queue "$tmp"); want=0 ;;
            run-create-fails) rc=$(run_orca_queue "$tmp" FAKE_ORCA_RUN_FAIL=1); want=1 ;;
            runtime-down) rc=$(run_orca_queue "$tmp" FAKE_ORCA_DOWN=1); want=1 ;;
        esac
        assert_eq "fallback $c: exit 0" "0" "$rc"
        assert_eq "fallback $c: one bg launch" "1" "$(grep -c '^launch n1-bgq-T-A-1$' "$tmp/fake/events")"
        assert_eq "fallback $c: bg prompt unchanged" "/n1:n1-start T-A" "$(cat "$tmp/fake/prompt.n1-bgq-T-A-1")"
        assert_eq "fallback $c: row pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
        assert_eq "fallback $c: bg session id stored" "00000001" "$(n1_queue_session_id "$tmp/queue.md" T-A)"
        assert_eq "fallback $c: no Orca Run" "" "$(n1_read_frontmatter "$tmp/queue.md" orca_run_id)"
        assert_eq "fallback $c: no task or worker" "0" "$(grep -cE 'task-create|worker-start' "$tmp/fake/orca-calls" || true)"
        assert_eq "fallback $c: notice said once" "$want" "$(grep -c 'using claude --bg' "$tmp/output.txt" || true)"
        rm -rf "$tmp"
    done
}

test_orca_stored_max_concurrent() {   # N1-303 AC: the planned max_concurrent wins over a later config change
    local tmp b_start a_rel c_start b_rel; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done" "T-C:done"; mk_orca "$tmp"
    sched_set "$tmp" 1; cfg_set "$tmp" '.queue.maxConcurrent = 3'
    assert_eq "orca-pinned: exit 0" "0" "$(run_orca_queue "$tmp")"
    b_start=$(line_of "$tmp/fake/orca-calls" "--task task-T-B"); a_rel=$(line_of "$tmp/fake/orca-calls" "worker-release --dispatch d-T-A")
    c_start=$(line_of "$tmp/fake/orca-calls" "--task task-T-C"); b_rel=$(line_of "$tmp/fake/orca-calls" "worker-release --dispatch d-T-B")
    assert_eq "orca-pinned: one worker at a time despite maxConcurrent=3" "yes,yes" \
        "$([ "$b_start" -gt "$a_rel" ] && echo yes || echo no),$([ "$c_start" -gt "$b_rel" ] && echo yes || echo no)"
    assert_eq "orca-pinned: no legacy fallback note" "0" "$(grep -c 'planned before N1-303' "$tmp/output.txt" || true)"
    rm -rf "$tmp"
}

test_orca_overlap_pair_sequential() {   # N1-303 AC: T-2 overlaps T-1 (after T-1); T-3 is independent
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-1:done" "T-2:done" "T-3:done"; mk_orca "$tmp"
    sched_set "$tmp" 3 T-2 T-1
    cfg_set "$tmp" '.queue.subtaskTimeoutMinutes = 600'   # no timeouts: T-1 stays in flight; the tick cap ends the run
    echo implement > "$tmp/fake/step.T-1"; : > "$tmp/fake/nodone.T-1"
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=10 > /dev/null
    assert_eq "orca-overlap: independent T-3 runs alongside T-1" "1" "$(grep -c -- "--task task-T-3" "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-overlap: T-2 never starts while T-1 is in flight" "0" "$(grep -c -- "--task task-T-2" "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-overlap: T-2 still pending" "pending" "$(plan_cell "$tmp/queue.md" 2 8)"
    rm -rf "$tmp"
}

test_orca_overlap_releases_at_pr() {   # N1-303: default (no-merge) mode releases T-2 once T-1 reached PR
    local tmp b_start c_start; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-1:done" "T-2:done" "T-3:done"; mk_orca "$tmp"
    sched_set "$tmp" 3 T-2 T-1
    assert_eq "orca-overlap-pr: exit 0" "0" "$(run_orca_queue "$tmp")"
    b_start=$(line_of "$tmp/fake/orca-calls" "--task task-T-2"); c_start=$(line_of "$tmp/fake/orca-calls" "--task task-T-3")
    assert_eq "orca-overlap-pr: later independent T-3 starts before gated T-2" "yes" "$([ "$c_start" -lt "$b_start" ] && echo yes || echo no)"
    assert_eq "orca-overlap-pr: all rows reach pr" "pr,pr,pr" \
        "$(plan_cell "$tmp/queue.md" 1 8),$(plan_cell "$tmp/queue.md" 2 8),$(plan_cell "$tmp/queue.md" 3 8)"
    rm -rf "$tmp"
}

test_orca_overlap_hard_edge() {   # N1-303: a failed predecessor skips its overlap successor
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-1:done" "T-2:done" "T-3:done"; mk_orca "$tmp"
    sched_set "$tmp" 3 T-2 T-1
    echo implement > "$tmp/fake/step.T-1"   # T-1's worker reports done without a PR -> failed
    run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=10 > /dev/null
    assert_eq "orca-overlap-fail: T-2 skipped" "skip" "$(plan_cell "$tmp/queue.md" 2 8)"
    assert_eq "orca-overlap-fail: reason names the predecessor" "yes" \
        "$(case "$(plan_cell "$tmp/queue.md" 2 9)" in *"predecessor T-1"*) echo yes ;; *) echo no ;; esac)"
    assert_eq "orca-overlap-fail: T-2 never started" "0" "$(grep -c -- "--task task-T-2" "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-overlap-fail: T-3 unaffected" "pr" "$(plan_cell "$tmp/queue.md" 3 8)"
    rm -rf "$tmp"
}

test_orca_gated_wait_expires() {   # N1-303 TQ-1: merge mode, T-1 at pr but unmerged: T-2 waits (bounded), then ends skip, not pending
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-1:done" "T-2:done"; mk_orca "$tmp"
    sched_set "$tmp" 3 T-2 T-1
    cfg_set "$tmp" '.autonomy.fullAuto = true | .finishWork.mergeOnFinish = true | .queue.subtaskTimeoutMinutes = 1 | .queue.pollSeconds = 30'
    n1_queue_row_status "$tmp/queue.md" 1 pr "waiting"
    assert_eq "orca-gated: exit 0" "0" "$(run_orca_queue "$tmp")"
    assert_eq "orca-gated: T-2 never started" "0" "$(grep -c -- "--task task-T-2" "$tmp/fake/orca-calls" || true)"
    assert_eq "orca-gated: T-2 ends skip, not pending" "skip" "$(plan_cell "$tmp/queue.md" 2 8)"
    assert_eq "orca-gated: reason names the predecessor" "yes" \
        "$(case "$(plan_cell "$tmp/queue.md" 2 9)" in *"predecessor T-1"*) echo yes ;; *) echo no ;; esac)"
    rm -rf "$tmp"
}

# N1-321: the test-only tick cap ends a run whose worker never finishes without a wall-clock wait, the way the old
# `timeout` wrappers did (SIGTERM, no halt bookkeeping); a non-numeric value is ignored (inert in production).
test_orca_tick_cap() {
    local tmp rc start; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    cfg_set "$tmp" '.queue.subtaskTimeoutMinutes = 600'
    echo implement > "$tmp/fake/step.T-A"; : > "$tmp/fake/nodone.T-A"
    start=$SECONDS
    rc=$(run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=5)
    assert_eq "orca-tick-cap: runner stopped by its own SIGTERM, not the 60 s timeout" "143" "$rc"
    assert_eq "orca-tick-cap: cap reason logged" "1" "$(grep -c 'N1_QUEUE_TEST_MAX_TICKS=5 reached' "$tmp/output.txt" || true)"
    assert_eq "orca-tick-cap: exactly 5 inbox checks" "1" "$(( $(cat "$tmp/fake/ncheck") == 5 ))"
    assert_eq "orca-tick-cap: ends well before the safety net" "1" "$(( SECONDS - start < 20 ))"
    assert_eq "orca-tick-cap: no halt bookkeeping" "no" "$([ "$(n1_read_frontmatter "$tmp/queue.md" step)" = halted ] && echo yes || echo no)"
    assert_eq "orca-tick-cap: worker row still in flight" "in-progress" "$(plan_cell "$tmp/queue.md" 1 8)"
    rm -rf "$tmp"
    tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done"; mk_orca "$tmp"
    assert_eq "orca-tick-cap: non-numeric cap ignored (natural exit 0)" "0" "$(run_orca_queue "$tmp" N1_QUEUE_TEST_MAX_TICKS=abc)"
    assert_eq "orca-tick-cap: non-numeric cap never logs" "0" "$(grep -c 'N1_QUEUE_TEST_MAX_TICKS' "$tmp/output.txt" || true)"
    rm -rf "$tmp"
}

test_orca_parallel_workers
test_orca_max_concurrent
test_orca_stored_max_concurrent
test_orca_gated_wait_expires
test_orca_overlap_pair_sequential
test_orca_overlap_releases_at_pr
test_orca_overlap_hard_edge
test_orca_held_blocker
test_orca_question_parks
test_orca_question_after_timeout
test_orca_question_on_pr_row
test_orca_question_on_pr_row_cleanup
test_orca_question_after_settle
test_orca_dispatch_skip_not_flooded
test_orca_coordinator_sink
test_orca_coordinator_fallback
test_orca_resume_no_duplicate
test_orca_timeout_open_pr
test_orca_usage_stall
test_orca_same_reason_one_strike
test_orca_mixed_reasons_halt
test_orca_same_launch_reason_halts
test_orca_halt_keeps_supervising
test_orca_inbox_down_hard_halt
test_orca_stop_marker
test_orca_stop_marker_forged
test_orca_stop_gated_untouched
test_orca_stop_close_failure_notifies
test_orca_stale_stop_marker_ignored
test_orca_resume_owed
test_orca_launch_failure_identity
test_orca_forged_dispatch_ignored
test_orca_settle_chain_before_sentinel
test_orca_worktree_name_taken
test_orca_adopt_launch
test_orca_stale_run_not_reused
test_orca_lost_done_still_chains
test_orca_settled_from_worker_list
test_orca_stop_worker
test_orca_done_without_dispatch_ignored
test_orca_replay_not_timeout
test_orca_worktree_list_unreadable
test_orca_chain_after_settle
test_orca_fallback_bg
test_orca_tick_cap

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

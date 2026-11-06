#!/usr/bin/env bash
# Tests for lib/queue.sh and scripts/n1-queue-run.sh: fullAuto finish chain and held rows on the bg backend.
# Shared setup and fixtures: tests/queue_runner_lib.sh (N1-304 split).
set -euo pipefail
source "$(dirname "$0")/queue_runner_lib.sh"

# AC1: fullAuto + mergeOnFinish -> runner chains n1-finish, records merged, next row waits for it.
test_bg_chain_merges() {
    local tmp fin_done b_launch; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working done" "T-B:done"
    chain_setup "$tmp" true true
    gh_overview "$tmp/fake/overview.T-A" 1; gh_overview "$tmp/fake/overview.T-B" 2
    echo "working done" > "$tmp/fake/states.T-A.fin"; touch "$tmp/fake/fin-merge.T-A"
    assert_eq "chain: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "chain: one finish launch for T-A" 1 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
    assert_eq "chain: finish prompt" "/n1:n1-finish T-A chained" "$(cat "$tmp/fake/prompt.n1-bgq-T-A-1-fin")"
    assert_eq "chain: finish session is an unattended queue run" "1,$(n1_read_frontmatter "$tmp/queue.md" run_id)" \
        "$(jq -r '[.env.N1_HEADLESS,.env.N1_QUEUE_RUN_ID]|join(",")' "$tmp/fake/settings.n1-bgq-T-A-1-fin")"
    assert_eq "chain: T-A Runs outcome merged" merged "$(runs_outcome "$tmp/queue.md" T-A)"
    assert_eq "chain: T-A Plan status stays pr" pr "$(plan_cell "$tmp/queue.md" 1 8)"
    fin_done=$(line_of "$tmp/fake/events" "state n1-bgq-T-A-1-fin done")
    b_launch=$(line_of "$tmp/fake/events" "launch n1-bgq-T-B-2")
    assert_eq "chain: next row launches only after the finish ended" yes \
        "$([ -n "$fin_done" ] && [ -n "$b_launch" ] && [ "$b_launch" -gt "$fin_done" ] && echo yes || echo no)"
    # T-B's PR is already MERGED when its chain runs (the child chained itself): no second finish.
    assert_eq "chain: no finish launch for an already-merged PR" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-B-2-fin')"
    assert_eq "chain: T-B Runs outcome merged" merged "$(runs_outcome "$tmp/queue.md" T-B)"
    assert_eq "chain: merged events" "T-A,T-B" \
        "$(jq -r 'select(.event == "ticket_finished" and .outcome == "merged") | .ticket' "$tmp/events.jsonl" | paste -sd,)"
    assert_eq "chain: marker holds the run id and launch state" "$(n1_read_frontmatter "$tmp/queue.md" run_id),launched" "$(head -n2 "$tmp/.chained-T-A" | paste -sd,)"
    # $tmp is not a git repo, so the default-branch sync fails (also on its retry) and is recorded.
    assert_eq "chain: failed sync recorded on the row" "finish:sync-failed" "$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "chain: runner never merges" 0 "$(grep -c '^pr merge' "$tmp/fake/gh-all" || true)"
    assert_eq "N1-339: one n1-clean launch for merged T-B" 1 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-B-2-clean')"
    assert_eq "N1-339: one n1-clean launch for T-A (merged by the chained finish)" 1 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-clean')"
    assert_eq "N1-339: clean prompt" "/n1:n1-clean --ticket T-B" "$(cat "$tmp/fake/prompt.n1-bgq-T-B-2-clean")"
    assert_eq "N1-339: clean session is an unattended queue run" "1,$(n1_read_frontmatter "$tmp/queue.md" run_id)" \
        "$(jq -r '[.env.N1_HEADLESS,.env.N1_QUEUE_RUN_ID]|join(",")' "$tmp/fake/settings.n1-bgq-T-B-2-clean")"
    assert_eq "N1-339: marker run id and state" "$(n1_read_frontmatter "$tmp/queue.md" run_id),launched" "$(head -n2 "$tmp/.cleaned-T-B" | paste -sd,)"
    assert_eq "N1-339: runner.log line" yes "$(grep -q 'T-B n1-clean launched' "$tmp/output.txt" && echo yes || echo no)"
    rm -rf "$tmp"
}

# N1-422 AC6: the bg chain keeps its session-only wait. A PR that turns MERGED during the wait is read only after the
# finish ends (pre-launch + post-loop reads), and a blocked finish still raises one "needs you" with no retraction.
test_bg_chain_fin_wait_unchanged() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:done"
    chain_setup "$tmp" true true
    gh_overview "$tmp/fake/overview.T-A" 1
    echo "blocked blocked done" > "$tmp/fake/states.T-A.fin"
    printf 'OPEN\nOPEN\nOPEN\nMERGED\n' > "$tmp/fake/gh-state-seq"
    run_bg_queue "$tmp" > /dev/null
    assert_eq "bg-fin-wait: one finish launch" 1 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
    assert_eq "bg-fin-wait: needs you raised once" "1" \
        "$(jq -r 'select(.event == "escalated" and .reason == "chained n1-finish needs you") | .ticket' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    assert_eq "bg-fin-wait: no retraction" "0" \
        "$(jq -r 'select(.event == "escalation_retracted") | .ticket' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    assert_eq "bg-fin-wait: PR not polled during the wait" "finish:finish-stopped" "$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
}

# N1-339: a restart (marker for this run) or a finish that already cleaned does not relaunch n1-clean.
test_bg_chain_clean_marker() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working done"
    chain_setup "$tmp" true true
    gh_overview "$tmp/fake/overview.T-A" 1
    echo done > "$tmp/fake/states.T-A.fin"; touch "$tmp/fake/fin-merge.T-A"
    n1_write_frontmatter "$tmp/queue.md" run_id R1
    printf '%s\nlaunched\n' R1 > "$tmp/.cleaned-T-A"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "N1-339: marker for this run -> no relaunch" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-clean')"
    rm -rf "$tmp"
}

# N1-339: a failed n1-clean launch records a failure event and leaves no marker, so a retry is possible.
test_bg_chain_clean_launch_failed() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working done"
    chain_setup "$tmp" true true
    gh_overview "$tmp/fake/overview.T-A" 1
    echo done > "$tmp/fake/states.T-A.fin"; touch "$tmp/fake/fin-merge.T-A"
    touch "$tmp/fake/refuse-clean"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "N1-339: failed launch -> no marker" no "$([ -e "$tmp/.cleaned-T-A" ] && echo yes || echo no)"
    assert_eq "N1-339: failed launch -> failure event" 1 \
        "$(jq -r 'select(.event == "ticket_cleanup" and .outcome == "failed") | .ticket' "$tmp/events.jsonl" | grep -c T-A)"
    rm -rf "$tmp"
}

test_bg_chain_clean_done() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working done"
    chain_setup "$tmp" true true
    gh_overview "$tmp/fake/overview.T-A" 1
    printf '## Finish\n- **Cleanup:** worktree:removed, branch:deleted (/w)\n' >> "$tmp/fake/overview.T-A"
    echo done > "$tmp/fake/states.T-A.fin"; touch "$tmp/fake/fin-merge.T-A"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "N1-339: branch already deleted -> no n1-clean" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-clean')"
    rm -rf "$tmp"
}

# A successful default-branch sync after the merge leaves no reason on the row.
test_bg_chain_sync_ok() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working done"
    chain_setup "$tmp" true true
    gh_overview "$tmp/fake/overview.T-A" 1
    echo done > "$tmp/fake/states.T-A.fin"; touch "$tmp/fake/fin-merge.T-A"
    git init -q --bare -b main "$tmp/origin.git"
    git -C "$tmp" init -q -b main; git -C "$tmp" -c user.name=t -c user.email=t@t -c commit.gpgSign=false commit -q --allow-empty -m i
    git -C "$tmp" remote add origin "$tmp/origin.git"; git -C "$tmp" push -q origin main
    assert_eq "chain-sync: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "chain-sync: outcome merged" merged "$(runs_outcome "$tmp/queue.md" T-A)"
    assert_eq "chain-sync: no reason" "" "$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
}

# A PR that is no longer open when the child ends (closed) is skipped with a reason, no finish session.
test_bg_chain_pr_closed() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working done"
    chain_setup "$tmp" true true
    echo CLOSED > "$tmp/fake/gh-state"
    gh_overview "$tmp/fake/overview.T-A" 1
    assert_eq "chain-closed: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "chain-closed: no finish launch" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
    assert_eq "chain-closed: reason recorded" "finish:pr-not-open" "$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
}

# N1-214: one failed PR-state read is retried, so the chain still reaches n1-finish.
test_bg_chain_pr_state_retry() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working done"
    chain_setup "$tmp" true true
    gh_overview "$tmp/fake/overview.T-A" 1
    echo done > "$tmp/fake/states.T-A.fin"; touch "$tmp/fake/fin-merge.T-A"
    echo 1 > "$tmp/fake/gh-fail"
    assert_eq "chain-retry: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "chain-retry: finish launched after one failed read" 1 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
    assert_eq "chain-retry: outcome merged" merged "$(runs_outcome "$tmp/queue.md" T-A)"
    rm -rf "$tmp"
}

# N1-214: a persistently failing PR-state read still records pr-state-unreadable (no finish).
test_bg_chain_pr_state_unreadable() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working done"
    chain_setup "$tmp" true true
    gh_overview "$tmp/fake/overview.T-A" 1
    echo 99 > "$tmp/fake/gh-fail"
    assert_eq "chain-unreadable: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "chain-unreadable: no finish launch" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
    assert_eq "chain-unreadable: reason recorded" "finish:pr-state-unreadable" "$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
}

# SEC-1: a child listed as missing (lagging agents list) is still busy for BG_POLL_GRACE polls; the
# chained finish must start only once the child is really idle.
test_bg_chain_missing_is_busy() {
    local tmp last; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working done missing missing missing working working done"
    chain_setup "$tmp" true true
    gh_overview "$tmp/fake/overview.T-A" 1
    echo done > "$tmp/fake/states.T-A.fin"; touch "$tmp/fake/fin-merge.T-A"
    assert_eq "chain-missing: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "chain-missing: one finish launch" 1 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
    last=$(awk '/^launch n1-bgq-T-A-1-fin$/{exit} /^state n1-bgq-T-A-1 /{l=$0} END{print l}' "$tmp/fake/events")
    assert_eq "chain-missing: finish waits until the child is idle" "state n1-bgq-T-A-1 done" "$last"
    rm -rf "$tmp"
}

# N1-240: a child parked blocked after its PR (it asked instead of ending) is stopped after
# BG_POLL_GRACE blocked polls and its PR chained; a child still working at the timeout keeps
# finish-child-busy and no marker (retry-safe, unchanged). overview.T-A.2 lands step pr on poll 2.
test_bg_chain_blocked_child() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working blocked"
    chain_setup "$tmp" true true
    gh_overview "$tmp/fake/overview.T-A.2" 1
    echo done > "$tmp/fake/states.T-A.fin"; touch "$tmp/fake/fin-merge.T-A" "$tmp/fake/stopeffective"
    assert_eq "chain-blocked: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "chain-blocked: blocked child stopped" yes \
        "$(grep -qxF 00000001 "$tmp/fake/stopped" 2>/dev/null && echo yes || echo no)"
    assert_eq "chain-blocked: stop logged" 1 \
        "$(grep -cF '[1] T-A chain: stopped blocked child (00000001)' "$tmp/output.txt" || true)"
    assert_eq "chain-blocked: one finish launch" 1 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
    assert_eq "chain-blocked: outcome merged" merged "$(runs_outcome "$tmp/queue.md" T-A)"
    assert_eq "chain-blocked: never finish-child-busy" 0 "$(grep -cF 'finish-child-busy' "$tmp/output.txt" || true)"
    rm -rf "$tmp"
    tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working working"
    chain_setup "$tmp" true true
    gh_overview "$tmp/fake/overview.T-A.2" 1
    assert_eq "chain-working: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "chain-working: no finish launch" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
    assert_eq "chain-working: reason finish-child-busy" "finish:finish-child-busy" "$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "chain-working: no marker" no "$([ -e "$tmp/.chained-T-A" ] && echo yes || echo no)"
    assert_eq "chain-working: chain never stops a working child" no \
        "$(grep -qxF 00000001 "$tmp/fake/stopped" 2>/dev/null && echo yes || echo no)"
    rm -rf "$tmp"
}

# N1-240 SEC-1/SEC-2/SEC-3 CR-1: a child with a pending escalation (question file or overview entry) is never
# stopped or chained, whatever state it reports; a stop that does not take effect launches no finish; a lagging
# stop is re-read; balanced and multi-row-per-step escalation ledgers are counted per step.
test_bg_chain_blocked_guards() {
    local tmp case_ states esc ans row
    esc='- [headless] pr: stop?, options: a, b (blocked-move: moved)'
    row='| pr | headless | S | [asked] | q | a | b | headless: ask-mode answer | --- |'
    for case_ in escalated stopfail ov-blocked ov-done ov-multirow balanced lag marker; do
        tmp=$(mktemp -d)
        states="T-A:working blocked"
        [ "$case_" = ov-done ] && states="T-A:working done"
        
        mk_bg "$tmp" bgq "$states"
        chain_setup "$tmp" true true
        gh_overview "$tmp/fake/overview.T-A.2" 1
        gh_overview "$tmp/fake/overview.T-A" 1
        echo done > "$tmp/fake/states.T-A.fin"; touch "$tmp/fake/fin-merge.T-A"
        case "$case_" in
            escalated) echo '{"question":"stop?"}' > "$tmp/.question-T-A.json" ;;
            marker) : > "$tmp/.escalated-T-A" ;; # restart lost CHAIN_ESC and the question files are gone
            ov-blocked|ov-done) for f in overview.T-A.2 overview.T-A; do printf '%s\n' "$esc" >> "$tmp/fake/$f"; done ;;
            ov-multirow) # step pr answered twice, a second step still pending
                for f in overview.T-A.2 overview.T-A; do printf '%s\n%s\n%s\n%s\n%s\n' "$esc" "$row" "$row" "- [headless] plan: x, options: y (blocked-move: moved)" "" >> "$tmp/fake/$f"; done ;;
            balanced) for f in overview.T-A.2 overview.T-A; do printf '%s\n%s\n' "$esc" "$row" >> "$tmp/fake/$f"; done; touch "$tmp/fake/stopeffective" ;;
            lag) touch "$tmp/fake/stopeffective"; echo 2 > "$tmp/fake/stoplag" ;;
        esac
        assert_eq "chain-$case_: exit 0" 0 "$(run_bg_queue "$tmp")"
        case "$case_" in
            balanced|lag)
                assert_eq "chain-$case_: one finish launch" 1 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
                assert_eq "chain-$case_: outcome merged" merged "$(runs_outcome "$tmp/queue.md" T-A)" ;;
            *)
                assert_eq "chain-$case_: no finish launch" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
                assert_eq "chain-$case_: no marker" no "$([ -e "$tmp/.chained-T-A" ] && echo yes || echo no)"
                assert_eq "chain-$case_: never logs stopped" 0 "$(grep -cF 'stopped blocked child' "$tmp/output.txt" || true)" ;;
        esac
        case "$case_" in
            escalated|marker|ov-*)
                assert_eq "chain-$case_: reason" "finish:child-escalated" "$(plan_cell "$tmp/queue.md" 1 9)"
                [ "$case_" = ov-done ] || assert_eq "chain-$case_: child not stopped" no "$(grep -qxF 00000001 "$tmp/fake/stopped" 2>/dev/null && echo yes || echo no)" ;;
            stopfail) assert_eq "chain-stopfail: reason" "finish:child-stop-failed" "$(plan_cell "$tmp/queue.md" 1 9)" ;;
        esac
        rm -rf "$tmp"
    done
    # TQ-1: the marker-write-failed exit (marker path is a directory) and the already-evaluated exit.
    tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working done"
    chain_setup "$tmp" true true
    gh_overview "$tmp/fake/overview.T-A" 1
    mkdir "$tmp/.chained-T-A"
    assert_eq "chain-markerfail: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "chain-markerfail: no finish launch" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
    assert_eq "chain-markerfail: reason" "finish:marker-write-failed" "$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
    # TQ-2: restart sweep, no marker, escalated overview, child done: no finish launch.
    tmp=$(mktemp -d); chain_restart_setup "$tmp" launched; rm -f "$tmp/.chained-T-A"
    printf '%s\n' "$esc" >> "$tmp/n1home/memory/T-A/overview.md"
    assert_eq "chain-restart-escalated: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "chain-restart-escalated: no finish launch" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
    assert_eq "chain-restart-escalated: no marker" no "$([ -e "$tmp/.chained-T-A" ] && echo yes || echo no)"
    rm -rf "$tmp"
    tmp=$(mktemp -d); chain_restart_setup "$tmp" launched
    assert_eq "chain-evaluated: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "chain-evaluated: logged" 1 "$(grep -cF '[1] T-A chain: already evaluated (marker=launched)' "$tmp/output.txt" || true)"
    rm -rf "$tmp"
}

# AC2: either flag off -> behaviour unchanged (stops at PR, no finish session).
# N1-240 AC4: the chain_authorized=false exit writes a runner.log line.
test_bg_chain_flags_off() {
    local tmp combo
    for combo in "false true" "true false"; do
        tmp=$(mktemp -d)
        mk_bg "$tmp" bgq "T-A:working done"
        chain_setup "$tmp" "${combo% *}" "${combo#* }"
        gh_overview "$tmp/fake/overview.T-A" 1
        echo done > "$tmp/fake/states.T-A.fin"; touch "$tmp/fake/fin-merge.T-A"
        assert_eq "chain-off ($combo): exit 0" 0 "$(run_bg_queue "$tmp")"
        assert_eq "chain-off ($combo): no finish launch" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
        assert_eq "chain-off ($combo): outcome pr" pr "$(runs_outcome "$tmp/queue.md" T-A)"
        assert_eq "chain-off ($combo): PR left open" OPEN "$(cat "$tmp/fake/gh-state")"
        assert_eq "chain-off ($combo): skip logged" 1 \
            "$(grep -cF '[1] T-A chain: skipped (chain_authorized=false)' "$tmp/output.txt" || true)"
        rm -rf "$tmp"
    done
}

# A finish that ends without merging (CI red, DIRTY, pin mismatch) leaves pr + reason, never retried.
test_bg_chain_finish_stops() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working done"
    chain_setup "$tmp" true true
    gh_overview "$tmp/fake/overview.T-A" 1
    echo "working done" > "$tmp/fake/states.T-A.fin"
    assert_eq "chain-stop: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "chain-stop: one finish launch" 1 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
    assert_eq "chain-stop: outcome pr" pr "$(runs_outcome "$tmp/queue.md" T-A)"
    assert_eq "chain-stop: Plan status pr" pr "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "chain-stop: reason recorded" "finish:finish-stopped" "$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "chain-stop: no merged event" "" \
        "$(jq -r 'select(.outcome == "merged") | .ticket' "$tmp/events.jsonl")"
    rm -rf "$tmp"
}

# AC5 + chain-owed sweep: a restarted runner never re-runs a pr row, runs a chain still owed, then
# continues pending rows; a chain already made in this run is not made again.
test_bg_chain_restart() {
    local tmp marker
    # no = chain owed; yes = chain already made this run; stale = pr row from an earlier run id.
    for marker in no yes stale; do
        tmp=$(mktemp -d)
        mk_bg "$tmp" bgq "T-A:done" "T-B:done"
        chain_setup "$tmp" true true
        n1_write_frontmatter "$tmp/queue.md" run_id R1
        n1_queue_row_status "$tmp/queue.md" 1 pr
        echo '| T-A | 2026-01-01T00:00:00Z | | pr | https://github.com/o/r/pull/1 | 00000009 |' >> "$tmp/queue.md"
        mkdir -p "$tmp/n1home/memory/T-A"; gh_overview "$tmp/n1home/memory/T-A/overview.md" 1
        # finalize stamps queue_run_id on the overview; the sweep only chains rows stamped with this run id.
        n1_write_frontmatter "$tmp/n1home/memory/T-A/overview.md" queue_run_id "$([ "$marker" = stale ] && echo R0 || echo R1)"
        echo done > "$tmp/fake/states.T-A.fin"; touch "$tmp/fake/fin-merge.T-A"
        # yes: the previous runner died while the -fin session ran; the orphan merged the PR meanwhile.
        [ "$marker" = yes ] && { echo R1 > "$tmp/.chained-T-A"; echo MERGED > "$tmp/fake/gh-state"; }
        assert_eq "restart ($marker): exit 0" 0 "$(run_bg_queue "$tmp")"
        assert_eq "restart ($marker): pr row never re-run" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1')"
        assert_eq "restart ($marker): pending row continues" 1 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-B-2')"
        if [ "$marker" = yes ]; then
            assert_eq "restart (yes): no finish launch" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
            assert_eq "restart (yes): merge recorded" merged "$(runs_outcome "$tmp/queue.md" T-A)"
            assert_eq "restart (yes): merged event" 1 "$(jq -r 'select(.outcome == "merged") | .ticket' "$tmp/events.jsonl" | grep -c T-A)"
        elif [ "$marker" = no ]; then
            assert_eq "restart: owed chain runs once" 1 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
            assert_eq "restart: owed chain merged" merged "$(runs_outcome "$tmp/queue.md" T-A)"
        else
            assert_eq "restart ($marker): no finish launch" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
            assert_eq "restart ($marker): row stays pr" pr "$(runs_outcome "$tmp/queue.md" T-A)"
        fi
        rm -rf "$tmp"
    done
}
test_bg_chain_reconcile() {
    local tmp
    # Intended-but-unconfirmed launch + OPEN PR: the owed finish is launched (once).
    tmp=$(mktemp -d); chain_restart_setup "$tmp" pending
    assert_eq "reconcile-pending: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "reconcile-pending: owed finish launched once" 1 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
    assert_eq "reconcile-pending: merged" merged "$(runs_outcome "$tmp/queue.md" T-A)"
    assert_eq "reconcile-pending: marker confirmed" launched "$(sed -n 2p "$tmp/.chained-T-A")"
    rm -rf "$tmp"
    # Confirmed launch + OPEN PR: never a second finish.
    tmp=$(mktemp -d); chain_restart_setup "$tmp" launched
    assert_eq "reconcile-launched: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "reconcile-launched: no finish launch" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
    rm -rf "$tmp"
    # Outcome already merged (runner died before the sync): the sync is retried and its failure recorded.
    tmp=$(mktemp -d); chain_restart_setup "$tmp" launched
    echo MERGED > "$tmp/fake/gh-state"
    printf '| T-A | 2026-01-01T00:00:00Z | | merged | https://github.com/o/r/pull/1 | 00000009 |\n' >> "$tmp/queue.md"
    sed -i '/| T-A | 2026-01-01T00:00:00Z | | pr |/d' "$tmp/queue.md"
    assert_eq "reconcile-sync: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "reconcile-sync: sync retried for a merged row" "finish:sync-failed" "$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
    # A -fin session that stays live past the timeout and cannot be stopped: halt, next ticket not launched.
    tmp=$(mktemp -d); chain_restart_setup "$tmp" launched
    mk_bg "$tmp" bgq "T-A:done" "T-B:done"; chain_setup "$tmp" true true
    n1_write_frontmatter "$tmp/queue.md" run_id R1
    n1_queue_row_status "$tmp/queue.md" 1 pr
    printf '/n1:n1-finish T-A chained\n' > "$tmp/fake/prompt.n1-bgq-T-A-1-fin"; echo 0000000f > "$tmp/fake/id.n1-bgq-T-A-1-fin"
    echo working > "$tmp/fake/states.T-A.fin"
    assert_eq "reconcile-live: halts (exit 2)" 2 "$(run_bg_queue "$tmp")"
    assert_eq "reconcile-live: stop attempted" 1 "$(grep -c 0000000f "$tmp/fake/stopped" || true)"
    assert_eq "reconcile-live: next ticket not launched" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-B-2')"
    rm -rf "$tmp"
}

# The authorization predicate is evaluated with the ROW's own N1 Home, not the runner's: the runner's
# home has both flags off, the row's home has both on, so only a per-row read launches the finish.
test_bg_chain_row_home() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working done"
    chain_setup "$tmp" false false
    mkdir "$tmp/rowhome"; ln -s "$tmp/n1home/memory" "$tmp/rowhome/memory"
    printf '{"autonomy":{"fullAuto":true},"finishWork":{"mergeOnFinish":true}}\n' > "$tmp/rowhome/config.json"
    sed -i "s#| $tmp/n1home |#| $tmp/rowhome |#" "$tmp/queue.md"
    gh_overview "$tmp/fake/overview.T-A" 1
    echo "working done" > "$tmp/fake/states.T-A.fin"; touch "$tmp/fake/fin-merge.T-A"
    assert_eq "row-home: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "row-home: finish launched from the row's config" 1 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1-fin')"
    assert_eq "row-home: outcome merged" merged "$(runs_outcome "$tmp/queue.md" T-A)"
    rm -rf "$tmp"
}

# N1-291/N1-292: in a story run the child launch carries the story env. The runner merges the PR itself, so even with
# fullAuto + mergeOnFinish there is no chained finish or clean session, and the Done session carries no story env.
test_bg_chain_story_env_scoped() {
    local tmp; tmp=$(mktemp -d)
    story_merge_fixture "$tmp" "T-A:working done"
    cfg_set "$tmp" '.autonomy.fullAuto = true | .finishWork.mergeOnFinish = true'
    assert_eq "story-chain: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "story-chain: no finish or clean launch" 0 "$(grep -cE '^launch n1-sq-T-A-1-(fin|clean)$' "$tmp/fake/events" || true)"
    assert_eq "story-chain: child launch carries story env" "S-1,story/S-1" \
        "$(jq -r '[.env.N1_STORY_ID,.env.N1_STORY_BRANCH]|join(",")' "$tmp/fake/settings.n1-sq-T-A-1")"
    assert_eq "story-chain: Done launch carries no story env" 0 "$(grep -c N1_STORY_ "$tmp/fake/settings.n1-sq-T-A-1-done" || true)"
    rm -rf "$tmp"
}

# N1-292 AC1: a green, reviewed story child is merged by the runner into story/S-1 at the pin, without fullAuto.
test_story_merge_green() {
    local tmp; tmp=$(mktemp -d)
    story_merge_fixture "$tmp" "T-A:working done"
    assert_eq "story-merge: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "story-merge: one merge at the pin, squash default" \
        "pr merge https://github.com/o/r/pull/1 --squash --match-head-commit $SM_PIN" "$(cat "$tmp/fake/gh-merge" 2>/dev/null)"
    assert_eq "story-merge: Outcome merged" merged "$(runs_outcome "$tmp/queue.md" T-A)"
    assert_eq "story-merge: Status pr, Reason merged" "pr|merged" "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "story-merge: one Done session" 1 "$(count_x "$tmp/fake/events" 'launch n1-sq-T-A-1-done')"
    assert_eq "story-merge: Done prompt ends with the ticket" "Ticket: T-A" "$(grep -o 'Ticket: T-A$' "$tmp/fake/prompt.n1-sq-T-A-1-done")"
    assert_eq "story-merge: Done prompt forbids merging" yes "$(grep -qF 'no merge' "$tmp/fake/prompt.n1-sq-T-A-1-done" && echo yes || echo no)"
    assert_eq "story-merge: marker done" "$(n1_read_frontmatter "$tmp/queue.md" run_id),done" "$(head -n2 "$tmp/.chained-T-A" | paste -sd,)"
    assert_eq "story-merge: local story branch fast-forwarded" "$(git -C "$tmp/origin" rev-parse story/S-1)" \
        "$(git -C "$tmp/repo" rev-parse story/S-1 2>/dev/null)"
    assert_eq "story-merge: merged event" T-A \
        "$(jq -r 'select(.event == "ticket_finished" and .outcome == "merged") | .ticket' "$tmp/events.jsonl")"
    rm -rf "$tmp"
    tmp=$(mktemp -d)
    story_merge_fixture "$tmp" "T-A:working done"
    cfg_set "$tmp" '.finishWork.mergeMethod = "rebase"'
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-merge: finishWork.mergeMethod honoured" yes "$(grep -qF -- '--rebase --match-head-commit' "$tmp/fake/gh-merge" && echo yes || echo no)"
    rm -rf "$tmp"
}

# N1-292 AC2: wrong base, moved head, gh view error, foreign repo, no pin or a non-OPEN PR merge nothing.
test_story_merge_refusals() {
    local tmp spec c want mk
    for spec in wrong-base:wrong-base:done head-moved:head-moved:done view-error:pr-state-unreadable: \
                repo-mismatch:pr-repo-mismatch:done no-pin:no-pin:done not-open:pr-not-open:done \
                pin-unavailable:pin-unavailable:; do
        IFS=: read -r c want mk <<< "$spec"
        tmp=$(mktemp -d); story_merge_fixture "$tmp" "T-A:working done"
        case "$c" in
            wrong-base) printf 'OPEN\tmain\t%s\n' "$SM_PIN" > "$tmp/fake/gh-view.1" ;;
            head-moved) printf 'OPEN\tstory/S-1\t%s\n' "$(printf '%040d' 0 | tr 0 2)" > "$tmp/fake/gh-view.1" ;;
            view-error) rm -f "$tmp/fake/gh-view.1" ;;
            repo-mismatch) echo x/y > "$tmp/fake/gh-repo" ;;
            no-pin) rm -f "$tmp/n1home/review-pins/o_r_1" ;;
            pin-unavailable) touch "$tmp/fake/gh-repo-fail-from2" ;;   # CR-3: a failed pin lookup is retryable, not no-pin
            not-open) printf 'CLOSED\tstory/S-1\t%s\n' "$SM_PIN" > "$tmp/fake/gh-view.1" ;;
        esac
        run_bg_queue "$tmp" >/dev/null
        assert_eq "story-refuse $c: nothing merged" 0 "$(nlines "$tmp/fake/gh-merge")"
        assert_eq "story-refuse $c: row pr, reason" "pr|finish:$want" "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
        assert_eq "story-refuse $c: marker" "$mk" "$(sed -n 2p "$tmp/.chained-T-A" 2>/dev/null || true)"
        assert_eq "story-refuse $c: no Done session" 0 "$(count_x "$tmp/fake/events" 'launch n1-sq-T-A-1-done')"
        rm -rf "$tmp"
    done
}

# sm_ci_case <label> <checks-json> <rc> <stderr> <merges> <reason> <marker> — one CI class through the runner.
sm_ci_case() {
    local tmp; tmp=$(mktemp -d); story_merge_fixture "$tmp" "T-A:working done"
    printf '%s' "$2" > "$tmp/fake/gh-checks"; printf '%s' "$3" > "$tmp/fake/gh-checks-rc"; printf '%s' "$4" > "$tmp/fake/gh-checks-err"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-ci $1: merges" "$5" "$(nlines "$tmp/fake/gh-merge")"
    assert_eq "story-ci $1: status|reason" "pr|$6" "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "story-ci $1: marker" "$7" "$(sed -n 2p "$tmp/.chained-T-A" 2>/dev/null || true)"
    [ "$1" != zero ] || assert_eq "story-ci zero: runner.log names it" yes \
        "$(grep -qF 'merged https://github.com/o/r/pull/1 (merged: no CI on story base)' "$tmp/output.txt" && echo yes || echo no)"
    [ "$1" != red ] || assert_eq "story-ci red: no strike, no halt" 0 "$(grep -c HALTED "$tmp/output.txt" || true)"
    rm -rf "$tmp"
}

# N1-292 AC3/AC4 + ledger: red and pending CI and unreadable checks merge nothing and leave the marker unwritten
# (--run retries). Zero checks merges and records "no CI on story base".
test_story_merge_ci() {
    sm_ci_case red '[{"bucket":"pass"},{"bucket":"fail"}]' 1 '' 0 finish:ci-red ''
    sm_ci_case pending '[{"bucket":"pending"}]' 8 '' 0 finish:ci-pending ''
    sm_ci_case unreadable '' 1 'HTTP 502: Bad Gateway' 0 finish:ci-unreadable ''
    sm_ci_case zero '' 1 "no checks reported on the 'feat' branch" 1 'merged: no CI on story base' done
}

# N1-292: a refused merge (DIRTY) is not auto-resolved or looped. A base that reads other than the story branch after
# the merge (TOCTOU retarget) raises an escalation and records no merge.
test_story_merge_refused_and_retarget() {
    local tmp; tmp=$(mktemp -d); story_merge_fixture "$tmp" "T-A:working done"
    echo 1 > "$tmp/fake/gh-merge-rc"
    echo 'Pull request o/r#1 is not mergeable: the merge commit cannot be cleanly created.' > "$tmp/fake/gh-merge-err"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-dirty: one attempt, row pr finish:dirty" "1|pr|finish:dirty" \
        "$(nlines "$tmp/fake/gh-merge")|$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "story-dirty: marker removed" no "$([ -e "$tmp/.chained-T-A" ] && echo yes || echo no)"
    assert_eq "story-dirty: Outcome not merged" no "$([ "$(runs_outcome "$tmp/queue.md" T-A)" = merged ] && echo yes || echo no)"
    rm -rf "$tmp"
    tmp=$(mktemp -d); story_merge_fixture "$tmp" "T-A:working done"
    echo main > "$tmp/fake/gh-view-after"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-retarget: row flagged" "pr|finish:merged-off-story" "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "story-retarget: escalated event" 1 \
        "$(jq -r 'select(.event == "escalated") | .ticket' "$tmp/events.jsonl" | grep -c '^T-A$' || true)"
    assert_eq "story-retarget: no Done session" 0 "$(count_x "$tmp/fake/events" 'launch n1-sq-T-A-1-done')"
    rm -rf "$tmp"
}

# N1-292 SEC-2: a post-merge base that cannot be read is not a clean merge: escalate, record no merge, no Done session.
test_story_merge_base_unverified() {
    local tmp; tmp=$(mktemp -d); story_merge_fixture "$tmp" "T-A:working done"
    touch "$tmp/fake/gh-view-gone-after"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-unverified: one merge attempt, not recorded merged" "1|no" \
        "$(nlines "$tmp/fake/gh-merge")|$([ "$(runs_outcome "$tmp/queue.md" T-A)" = merged ] && echo yes || echo no)"
    assert_eq "story-unverified: row flagged" "pr|finish:merge-base-unverified" "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "story-unverified: escalated event" 1 "$(jq -r 'select(.event == "escalated") | .ticket' "$tmp/events.jsonl" | grep -c '^T-A$' || true)"
    assert_eq "story-unverified: no Done session" 0 "$(count_x "$tmp/fake/events" 'launch n1-sq-T-A-1-done')"
    rm -rf "$tmp"
}

# A merge that leaves the PR OPEN (merge queue) is not recorded merged: marker removed so a resume re-evaluates.
test_story_merge_queued_not_recorded() {
    local tmp; tmp=$(mktemp -d); story_merge_fixture "$tmp" "T-A:working done"
    touch "$tmp/fake/gh-merge-queued"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-queued: not recorded merged, row finish:merge-pending" "no|finish:merge-pending" \
        "$([ "$(runs_outcome "$tmp/queue.md" T-A)" = merged ] && echo yes || echo no)|$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "story-queued: marker removed, no Done session" "no|0" \
        "$([ -e "$tmp/.chained-T-A" ] && echo yes || echo no)|$(count_x "$tmp/fake/events" 'launch n1-sq-T-A-1-done')"
    rm -rf "$tmp"
}

# N1-292 SEC-1: a forged pending marker does not skip the escalation guard before the runner merges.
test_story_pending_marker_guarded() {
    local tmp; tmp=$(mktemp -d); story_restart_setup "$tmp" pending OPEN
    touch "$tmp/.escalated-T-A"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-forged-pending: nothing merged, child-escalated" "0|finish:child-escalated" "$(nlines "$tmp/fake/gh-merge")|$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
}

# N1-292 SEC-3: story mode is fixed at run start. A child that rewrites a tag queue to story mode gets no runner merge.
test_story_mode_snapshot() {
    local tmp; tmp=$(mktemp -d); story_merge_fixture "$tmp" "T-A:working done"
    sed -i -e '/^mode: story$/d' -e '/^story_id: S-1$/d' "$tmp/queue.md"
    printf '%s' "$tmp/repo" > "$tmp/fake/forge-story"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-forged-mode: nothing merged" 0 "$(nlines "$tmp/fake/gh-merge")"
    assert_eq "story-forged-mode: row refused" "pr|finish:story-branch-invalid" "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
}

# N1-292 AC9: a resumed run never merges twice. A PR already merged into the story branch is only recorded (Done
# session once). A recorded merge is left alone. A pending marker re-runs the head-pinned merge. A red-CI row
# (marker removed) is re-evaluated, and its stale finish:ci-red Reason is overwritten.
test_story_resume() {
    local tmp
    tmp=$(mktemp -d); story_restart_setup "$tmp" done MERGED
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-resume merged: recorded, no merge call" "merged|0" "$(runs_outcome "$tmp/queue.md" T-A)|$(nlines "$tmp/fake/gh-merge")"
    assert_eq "story-resume merged: one Done session" 1 "$(count_x "$tmp/fake/events" 'launch n1-sq-T-A-1-done')"
    rm -rf "$tmp"
    tmp=$(mktemp -d); story_restart_setup "$tmp" done MERGED
    n1_queue_runs_outcome "$tmp/queue.md" T-A merged
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-resume recorded: no merge, no Done relaunch" "0|0" \
        "$(nlines "$tmp/fake/gh-merge")|$(count_x "$tmp/fake/events" 'launch n1-sq-T-A-1-done')"
    rm -rf "$tmp"
    tmp=$(mktemp -d); story_restart_setup "$tmp" done OPEN
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-resume done+OPEN: already evaluated, no merge" 0 "$(nlines "$tmp/fake/gh-merge")"
    assert_eq "story-resume done+OPEN: log line" yes "$(grep -qF 'T-A chain: already evaluated (marker=done)' "$tmp/output.txt" && echo yes || echo no)"
    rm -rf "$tmp"
    tmp=$(mktemp -d); story_restart_setup "$tmp" pending OPEN
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-resume pending+OPEN: one merge, merged" "1|merged" "$(nlines "$tmp/fake/gh-merge")|$(runs_outcome "$tmp/queue.md" T-A)"
    rm -rf "$tmp"
    tmp=$(mktemp -d); story_restart_setup "$tmp" "" OPEN
    n1_queue_row_status "$tmp/queue.md" 1 pr "finish:ci-red"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-resume after red CI: merged, stale reason overwritten" "1|merged" "$(nlines "$tmp/fake/gh-merge")|$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
}

# N1-292 AC6: a held story child starts after the runner merged its blocker into story/S-1, without fullAuto.
test_story_held_released_after_runner_merge() {
    local tmp done_a launch_b; tmp=$(mktemp -d)
    story_merge_fixture "$tmp" "T-A:working done" "T-B:done"
    n1_queue_row_status "$tmp/queue.md" 2 held "blocked_on T-A"
    assert_eq "story-held: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "story-held: T-B launched once" 1 "$(count_x "$tmp/fake/events" 'launch n1-sq-T-B-2')"
    done_a=$(line_of "$tmp/fake/events" 'launch n1-sq-T-A-1-done'); launch_b=$(line_of "$tmp/fake/events" 'launch n1-sq-T-B-2')
    assert_eq "story-held: T-B launches after T-A merged" yes \
        "$([ -n "$done_a" ] && [ -n "$launch_b" ] && [ "$launch_b" -gt "$done_a" ] && echo yes || echo no)"
    assert_eq "story-held: both merged by the runner" "merged,merged,2" \
        "$(runs_outcome "$tmp/queue.md" T-A),$(runs_outcome "$tmp/queue.md" T-B),$(nlines "$tmp/fake/gh-merge")"
    rm -rf "$tmp"
}

# N1-292 AC7: a dependent of a finish:ci-red child does not run and names the blocker. Independents run, and the
# 3-strike count is unchanged (ci-red is no strike: T-C failing plus its deferred retry make 2, no halt).
test_story_dependents_of_ci_red() {
    local tmp; tmp=$(mktemp -d)
    story_merge_fixture "$tmp" "T-A:working done" "T-B:done" "T-C:failed"
    n1_queue_row_status "$tmp/queue.md" 2 held "blocked_on T-A"
    echo '[{"bucket":"fail"}]' > "$tmp/fake/gh-checks"; echo 1 > "$tmp/fake/gh-checks-rc"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-red: blocker row" "pr|finish:ci-red" "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "story-red: dependent skipped, names blocker" "skip|blocked by T-A (finish:ci-red)" \
        "$(plan_cell "$tmp/queue.md" 2 8)|$(plan_cell "$tmp/queue.md" 2 9)"
    assert_eq "story-red: dependent never launched" 0 "$(count_x "$tmp/fake/events" 'launch n1-sq-T-B-2')"
    assert_eq "story-red: independent ran" 1 "$(count_x "$tmp/fake/events" 'launch n1-sq-T-C-3')"
    assert_eq "story-red: no halt" 0 "$(grep -c HALTED "$tmp/output.txt" || true)"
    rm -rf "$tmp"
}

# N1-446 AC3: a green, reviewed child of a list queue with integration: queue is merged by the runner into the queue
# branch at the pin, without fullAuto (fixture config has fullAuto and mergeOnFinish off).
test_queue_merge_green() {
    local tmp; tmp=$(mktemp -d)
    queue_merge_fixture "$tmp" "T-A:working done"
    assert_eq "queue-merge: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "queue-merge: one merge at the pin" \
        "pr merge https://github.com/o/r/pull/1 --squash --match-head-commit $SM_PIN" "$(cat "$tmp/fake/gh-merge" 2>/dev/null)"
    assert_eq "queue-merge: Outcome merged" merged "$(runs_outcome "$tmp/queue.md" T-A)"
    assert_eq "queue-merge: child env carries the queue branch" "${QB#queue/},$QB" \
        "$(jq -r '[.env.N1_STORY_ID,.env.N1_STORY_BRANCH]|join(",")' "$tmp/fake/settings.n1-sq-T-A-1")"
    assert_eq "queue-merge: local queue branch fast-forwarded" "$(git -C "$tmp/origin" rev-parse "$QB")" \
        "$(git -C "$tmp/repo" rev-parse "$QB" 2>/dev/null)"
    rm -rf "$tmp"
}

# N1-446 AC3: a held row of a queue with integration: queue starts once the runner merged its blocker into the queue
# branch (merge off would otherwise leave it held for a human merge).
test_queue_held_released_after_runner_merge() {
    local tmp; tmp=$(mktemp -d)
    queue_merge_fixture "$tmp" "T-A:working done" "T-B:done"
    n1_queue_row_status "$tmp/queue.md" 2 held "blocked_on T-A"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "queue-held: blocker merged" merged "$(runs_outcome "$tmp/queue.md" T-A)"
    assert_eq "queue-held: successor launched" 1 "$(count_x "$tmp/fake/events" 'launch n1-sq-T-B-2')"
    rm -rf "$tmp"
}

# N1-446 SEC-3: integration is fixed at run start. A child that flips integration: queue to none gets its row
# refused: no merge, and no fall-through to the tag chain.
test_queue_integration_snapshot() {
    local tmp; tmp=$(mktemp -d)
    queue_merge_fixture "$tmp" "T-A:working done"
    echo none > "$tmp/fake/forge-integration"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "queue-forged-integration: nothing merged" 0 "$(nlines "$tmp/fake/gh-merge")"
    assert_eq "queue-forged-integration: row refused" "pr|finish:story-branch-invalid" \
        "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
}

# N1-446 AC4/AC5: at run end a queue with integration: queue opens one final PR per repo from the queue branch into
# main, with queue wording, the conventions (version bump) applied once in the final session, and no tracker read.
test_queue_final_pr() {
    local tmp s="n1-sq-${QB#queue/}-final-1"; tmp=$(mktemp -d)
    queue_merge_fixture "$tmp" "T-A:working done"
    touch "$tmp/fake/final-create"
    printf 'UNKNOWN\t\nMERGEABLE\tCLEAN\n' > "$tmp/fake/gh-mergeable-seq"
    assert_eq "queue-final: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "queue-final: one final session" 1 "$(count_x "$tmp/fake/events" "launch $s")"
    assert_eq "queue-final: PR from the queue branch into main" yes \
        "$(grep -qF "gh pr create --head $QB --base main" "$tmp/fake/prompt.$s" && echo yes || echo no)"
    assert_eq "queue-final: push only the queue branch" yes \
        "$(grep -qF "git push origin HEAD:refs/heads/$QB" "$tmp/fake/prompt.$s" && echo yes || echo no)"
    assert_eq "queue-final: conventions applied once here" yes \
        "$(grep -qF 'conventions that queue children skipped' "$tmp/fake/prompt.$s" && echo yes || echo no)"
    assert_eq "queue-final: fixed title, no tracker read" "yes,0" \
        "$(grep -qF "Queue ${QB#queue/}: queued tickets" "$tmp/fake/prompt.$s" && echo yes || echo no),$(grep -cF 'tracker issue' "$tmp/fake/prompt.$s" || true)"
    assert_eq "queue-final: body heading" "## Queue ${QB#queue/}: final PR" "$(head -n1 "$tmp/final-1.body.md")"
    assert_eq "queue-final: Final PRs row, waits for a human (merge off)" \
        $'https://github.com/o/r/pull/9\tready\tMERGEABLE (CLEAN)\twaits: not-authorized' "$(fin_row "$tmp" "$tmp/repo")"
    rm -rf "$tmp"
}

# N1-447 AC3: while the predecessor final PR is unmerged, the queue's final PR opens as a draft naming it, is never
# marked ready or merged by the runner, and its Note says what it waits for.
test_queue_final_waits_predecessor() {
    local tmp s="n1-sq-${QB#queue/}-final-1"; tmp=$(mktemp -d)
    queue_merge_fixture "$tmp" "T-A:working done"
    touch "$tmp/fake/final-create"; printf 'UNKNOWN\t\nMERGEABLE\tCLEAN\n' > "$tmp/fake/gh-mergeable-seq"
    n1_queue_pred_set "$tmp/queue.md" "$tmp/repo" "$QC_ID" "$QC_P" https://github.com/o/r/pull/5 "$SM_PIN" "$SM_PIN" waiting
    printf 'OPEN\tmain\t%s\n' "$SM_PIN" > "$tmp/fake/gh-view.5"
    assert_eq "pred-wait: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "pred-wait: final PR opened as a draft" yes "$(grep -qF -- '--draft' "$tmp/fake/prompt.$s" && echo yes || echo no)"
    assert_eq "pred-wait: body names the predecessor" 1 "$(grep -cF "cut from $QC_P (https://github.com/o/r/pull/5)" "$tmp/final-1.body.md")"
    assert_eq "pred-wait: Final PRs row" \
        "$(printf 'https://github.com/o/r/pull/9\tdraft\tMERGEABLE (CLEAN)\twaits: predecessor %s (waiting); waits: not-authorized' "$QC_ID")" \
        "$(fin_row "$tmp" "$tmp/repo")"
    assert_eq "pred-wait: never marked ready" 0 "$(cat "$tmp/fake/gh-refresh-calls" 2>/dev/null | grep -c 'pr ready' || true)"
    assert_eq "pred-wait: final PR not merged" 0 "$(cat "$tmp/fake/gh-merge" 2>/dev/null | grep -c 'pull/9' || true)"
    assert_eq "pred-wait: row still waiting" waiting "$(n1_queue_preds "$tmp/queue.md" | cut -f7)"
    rm -rf "$tmp"
}

# N1-292 AC8: a failed Done launch is a ticket_done failed event. The merge stands and is never retried.
test_story_done_launch_failed() {
    local tmp; tmp=$(mktemp -d); story_merge_fixture "$tmp" "T-A:working done"
    touch "$tmp/fake/refuse-done"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-done-fail: one merge, Outcome merged" "1|merged" "$(nlines "$tmp/fake/gh-merge")|$(runs_outcome "$tmp/queue.md" T-A)"
    assert_eq "story-done-fail: Reason stays merged" merged "$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "story-done-fail: ticket_done failed event" 1 \
        "$(jq -r 'select(.event == "ticket_done" and .outcome == "failed") | .ticket' "$tmp/events.jsonl" | grep -c '^T-A$' || true)"
    rm -rf "$tmp"
}

# N1-183: launcher wiring (setsid with nohup fallback, liveness busy guard, interrupted resume/status).
test_lifecycle_wiring() {
    local s="$REPO_ROOT/skills/n1-queue"
    has() { grep -qF -- "$1" "$2" && echo yes || echo no; }
    assert_eq "wiring: runner launched with setsid" yes "$(has 'setsid bash "$N1_ROOT/scripts/n1-queue-run.sh"' "$s/steps/run.md")"
    assert_eq "wiring: nohup fallback when setsid is absent" yes "$(has 'command -v setsid' "$s/steps/run.md")"
    assert_eq "wiring: busy guard uses runner liveness" yes "$(has 'n1_queue_runner_alive "$OLD_PID"' "$s/steps/run.md")"
    assert_eq "wiring: --run detects an interrupted run" yes "$(has 'INTERRUPTED=yes' "$s/steps/run.md")"
    assert_eq "wiring: resume keeps the run id" yes "$(has 'if [ "<RESUME>" = 1 ]' "$s/steps/run.md")"
    assert_eq "wiring: --status reports interrupted runs" yes "$(has 'n1_queue_interrupted_note "$QUEUE_FILE"' "$s/steps/report.md")"
    assert_eq "wiring: --status reports dispatch skips (N1-309)" yes "$(has 'n1_queue_dispatch_skips' "$s/steps/report.md")"
    assert_eq "wiring: run.md streams the session watch (N1-359)" yes "$(has "the watch command's output lines to this session" "$s/steps/run.md")"
    assert_eq "wiring: report.md streams the adopted watch (N1-359)" yes "$(has "the watch command's output lines to this session" "$s/steps/report.md")"
    assert_eq "wiring: run.md re-arms the watch at the deadline (N1-359)" yes "$(has "start the identical command again" "$s/steps/run.md")"
    assert_eq "wiring: SKILL.md documents resume" yes "$(has 'resumes an interrupted run' "$s/SKILL.md")"
    assert_eq "N1-339: runner contains no worktree removal" 0 "$(grep -cE 'git worktree remove|n1_orca_rm|n1_finish_cleanup|n1_clean_ticket|worktree rm' "$REPO_ROOT/scripts/n1-queue-run.sh")"
    assert_eq "N1-339: chain_merged launches chain_clean" yes "$(grep -A6 '^chain_merged()' "$REPO_ROOT/scripts/n1-queue-run.sh" | grep -q 'chain_clean' && echo yes || echo no)"
    assert_eq "N1-339: chain_clean called from three merged paths" 3 "$(grep -c 'chain_clean "' "$REPO_ROOT/scripts/n1-queue-run.sh")"
}

# N1-185 AC3: run.md held-ticket wording (finish.md and session-start covered in test_orchestrator_guardrails.sh and test_hooks.sh).
test_merge_wording() {
    local has; has() { grep -qF -- "$1" "$2" && echo yes || echo no; }
    assert_eq "wording: held tickets start on a user or chain merge" yes \
        "$(has "merged (by the user, or by the runner's fullAuto chain)" "$REPO_ROOT/skills/n1-queue/steps/run.md")"
    assert_eq "wording: SKILL.md names the story runner merge (N1-292)" yes \
        "$(has 'the runner itself merges each green, reviewed child PR into `story/<STORY_ID>`' "$REPO_ROOT/skills/n1-queue/SKILL.md")"
    assert_eq "wording: run.md story release (N1-292)" yes \
        "$(has 'once the runner merged the blocker into the story branch' "$REPO_ROOT/skills/n1-queue/steps/run.md")"
    assert_eq "wording: architecture documents story_merge (N1-292)" yes \
        "$(has 'Story mode (N1-292): the runner itself merges' "$REPO_ROOT/references/architecture.md")"
    assert_eq "wording: architecture lists ticket_done (N1-292)" yes \
        "$(has '`ticket_done` (N1-292' "$REPO_ROOT/references/architecture.md")"
}

test_bg_held_not_launched() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgh "T-A:working done" "T-B:done"
    n1_queue_row_status "$tmp/queue.md" 2 held "blocked_on T-A"
    printf '#!/bin/sh\necho OPEN\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
    assert_eq "bg-held: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-held: blocker pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-held: T-B never launched" "0" "$(ls "$tmp/fake" | grep -c '^prompt\..*T-B' || true)"
    assert_eq "bg-held: expired to skip" "skip|blocked by T-A (not merged)" \
        "$(plan_cell "$tmp/queue.md" 2 8)|$(plan_cell "$tmp/queue.md" 2 9)"
    assert_eq "bg-held: step done" "done" "$(n1_read_frontmatter "$tmp/queue.md" step)"
    rm -rf "$tmp"
}

test_bg_held_blocker_failed() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgf "T-A:failed" "T-B:done"
    n1_queue_row_status "$tmp/queue.md" 2 held "blocked_on T-A"
    assert_eq "bg-held-fail: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-held-fail: T-B skipped" "blocked by T-A (failed)" "$(plan_cell "$tmp/queue.md" 2 9)"
    assert_eq "bg-held-fail: T-B never launched" "0" "$(ls "$tmp/fake" | grep -c '^prompt\..*T-B' || true)"
    rm -rf "$tmp"
}

# N1-114: the user merges the blocker's PR -> the runner releases and launches the held ticket.
test_bg_held_user_merge() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgm "T-A:working done" "T-B:done"
    n1_queue_row_status "$tmp/queue.md" 2 held "blocked_on T-A"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://github.com/o/r/pull/7\n' > "$tmp/fake/overview.T-A"
    git init -q -b main "$tmp/origin"
    git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m init
    git init -q -b work "$tmp"
    git -C "$tmp" remote add origin "$tmp/origin"
    printf '#!/bin/sh\ncase "$*" in *"pr view"*"--json state"*) echo MERGED main ;; esac\n' > "$tmp/bin/gh"
    chmod +x "$tmp/bin/gh"
    assert_eq "bg-held-merge: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-held-merge: T-B launched once" "1" "$(ls "$tmp/fake" | grep -c '^prompt\..*T-B' || true)"
    assert_eq "bg-held-merge: T-B finished pr" "pr" "$(plan_cell "$tmp/queue.md" 2 8)"
    assert_eq "bg-held-merge: local main synced" "$(git -C "$tmp/origin" rev-parse main)" "$(git -C "$tmp" rev-parse main)"
    rm -rf "$tmp"
}

# N1-114 TQ-1: the user merges on the very tick the held wait runs out (HELD_WAIT >= timeout:
# 1 min, 30 s poll -> third idle sweep). The released row must still launch, not expire.
test_bg_held_merge_at_timeout() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgt "T-A:working done" "T-B:done"
    n1_queue_row_status "$tmp/queue.md" 2 held "blocked_on T-A"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://github.com/o/r/pull/7\n' > "$tmp/fake/overview.T-A"
    git init -q -b main "$tmp/origin"
    git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m init
    git init -q -b work "$tmp"
    git -C "$tmp" remote add origin "$tmp/origin"
    cat > "$tmp/bin/gh" <<EOF
#!/bin/sh
case "\$*" in *"pr view"*"--json state"*)
    n=\$((\$(cat "$tmp/ghcalls" 2>/dev/null || echo 0) + 1)); echo \$n > "$tmp/ghcalls"
    [ \$n -ge 3 ] && echo MERGED main || echo OPEN ;;
esac
EOF
    chmod +x "$tmp/bin/gh"
    assert_eq "bg-held-timeout: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-held-timeout: merged on the timeout tick" "3" "$(cat "$tmp/ghcalls")"
    assert_eq "bg-held-timeout: T-B launched once" "1" "$(ls "$tmp/fake" | grep -c '^prompt\..*T-B' || true)"
    assert_eq "bg-held-timeout: T-B finished pr" "pr" "$(plan_cell "$tmp/queue.md" 2 8)"
    rm -rf "$tmp"
}

# N1-293 AC1/AC2/AC4: all children merged -> one ready final PR, opened by a session in a detached worktree; recorded
# in ## Final PRs with mergeable state, evented before queue_done; the main checkout is untouched.
test_final_pr_ready() {
    local tmp s=n1-sq-S-1-final-1; tmp=$(mktemp -d)
    final_fixture "$tmp" "T-A:working done"
    assert_eq "final: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "final: one final session" 1 "$(count_x "$tmp/fake/events" "launch $s")"
    assert_eq "final: n1-run prompt without --draft" "yes,0" \
        "$(grep -q '^/n1:n1-run ' "$tmp/fake/prompt.$s" && echo yes || echo no),$(grep -cF -- '--draft' "$tmp/fake/prompt.$s" || true)"
    assert_eq "final: PR into the default branch" yes \
        "$(grep -qF 'gh pr create --head story/S-1 --base main' "$tmp/fake/prompt.$s" && echo yes || echo no)"
    assert_eq "final: cwd is the queue's worktree" "$tmp/final-1" "$(cat "$tmp/fake/cwd.$s")"
    assert_eq "final: worktree removed" no "$([ -e "$tmp/final-1" ] && echo yes || echo no)"
    assert_eq "final: no worktree left registered" 1 "$(git -C "$tmp/repo" worktree list | wc -l | tr -d ' ')"
    assert_eq "final: main checkout untouched" main "$(git -C "$tmp/repo" symbolic-ref --short HEAD)"
    assert_eq "final: settings N1_HOME, no story env" "$tmp/n1home,0" \
        "$(jq -r '[.env.N1_HOME, ([.env|keys[]|select(startswith("N1_STORY"))]|length)]|map(tostring)|join(",")' "$tmp/fake/settings.$s")"
    assert_eq "final: body lists the landed child" yes \
        "$(grep -qxF -- '- T-A: https://github.com/o/r/pull/1 (merged)' "$tmp/final-1.body.md" && echo yes || echo no)"
    assert_eq "final: Final PRs row" $'https://github.com/o/r/pull/9\tready\tMERGEABLE (CLEAN)\twaits: not-authorized' "$(fin_row "$tmp" "$tmp/repo")"
    assert_eq "final: ## Runs stays last" "## Runs" "$(grep '^## ' "$tmp/queue.md" | tail -1)"
    assert_eq "final: opened event" "https://github.com/o/r/pull/9|ready mergeable=MERGEABLE" \
        "$(jq -r 'select(.event == "final_pr_opened") | "\(.pr)|\(.reason)"' "$tmp/events.jsonl")"
    assert_eq "final: recorded before queue_done" "final_pr_opened,queue_done" \
        "$(jq -r '.event' "$tmp/events.jsonl" | grep -E '^(final_pr_opened|queue_done)$' | paste -sd,)"
    assert_eq "final: marker done for this run" "$(n1_read_frontmatter "$tmp/queue.md" run_id),done" "$(head -n2 "$tmp/.final-1" | paste -sd,)"
    assert_eq "final: step done" done "$(n1_read_frontmatter "$tmp/queue.md" step)"
    rm -rf "$tmp"
}

# N1-293 AC2 (D4): a child that did not land makes the final PR a draft; the body names it with status and reason.
test_final_pr_draft() {
    local tmp s=n1-sq-S-1-final-1; tmp=$(mktemp -d)
    final_fixture "$tmp" "T-A:working done" "T-B:working done"
    printf 'OPEN\tmain\t%s\n' "$SM_PIN" > "$tmp/fake/gh-view.2"   # T-B targets main: wrong-base, never merged
    assert_eq "final-draft: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "final-draft: prompt asks for --draft" yes "$(grep -qF -- '--draft' "$tmp/fake/prompt.$s" && echo yes || echo no)"
    assert_eq "final-draft: body lists the not-landed child" 1 \
        "$(grep -cE -- '^- T-B: pr, PR .* \(finish:wrong-base\)$' "$tmp/final-1.body.md" || true)"
    assert_eq "final-draft: row draft" draft "$(fin_row "$tmp" "$tmp/repo" | cut -f2)"
    rm -rf "$tmp"
}

# N1-293 AC1: a repo without a merged child gets no final PR, only a no-merged-children row.
test_final_pr_repo_without_merge() {
    local tmp; tmp=$(mktemp -d)
    final_fixture "$tmp" "T-A:working done" "T-B:working done"
    git clone -q "$tmp/origin" "$tmp/repo2" 2>/dev/null
    sed -i "/^| 2 | T-B /s#| $tmp/repo |#| $tmp/repo2 |#" "$tmp/queue.md"
    printf 'OPEN\tmain\t%s\n' "$SM_PIN" > "$tmp/fake/gh-view.2"
    assert_eq "final-2repo: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "final-2repo: one session, for repo 1" "1,0" \
        "$(count_x "$tmp/fake/events" 'launch n1-sq-S-1-final-1'),$(count_x "$tmp/fake/events" 'launch n1-sq-S-1-final-2')"
    assert_eq "final-2repo: repo 1 ready" ready "$(fin_row "$tmp" "$tmp/repo" | cut -f2)"
    assert_eq "final-2repo: repo 2 not opened" $'-\t-\t-\tno-merged-children' "$(fin_row "$tmp" "$tmp/repo2")"
    rm -rf "$tmp"
}

# N1-293: resume safety: an OPEN final PR for the story head is reused; no session is launched.
test_final_pr_reused() {
    local tmp; tmp=$(mktemp -d)
    final_fixture "$tmp" "T-A:working done"; rm -f "$tmp/fake/final-create"
    echo '[{"url":"https://github.com/o/r/pull/7","isDraft":false,"headRefName":"story/S-1","baseRefName":"main","isCrossRepository":false,"headRepositoryOwner":{"login":"o"}}]' > "$tmp/fake/gh-final-list.main"
    assert_eq "final-reuse: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "final-reuse: no session" 0 "$(count_x "$tmp/fake/events" 'launch n1-sq-S-1-final-1')"
    assert_eq "final-reuse: existing PR recorded" https://github.com/o/r/pull/7 "$(fin_row "$tmp" "$tmp/repo" | cut -f1)"
    assert_eq "final-reuse: body refreshed by the runner" yes \
        "$(grep -qF -- "pr edit --body-file $tmp/final-1.body.md -- https://github.com/o/r/pull/7" "$tmp/fake/gh-refresh-calls" && echo yes || echo no)"
    assert_eq "final-reuse: ready PR is not re-readied" 0 "$(grep -c 'pr ready' "$tmp/fake/gh-refresh-calls" || true)"
    rm -rf "$tmp"
}

# N1-293 CR-2: a reused draft PR whose children all landed is refreshed and marked ready by the runner; when the refresh
# fails the row keeps the note.
test_final_pr_reused_draft() {
    local tmp; tmp=$(mktemp -d)
    final_fixture "$tmp" "T-A:working done"; rm -f "$tmp/fake/final-create"
    echo '[{"url":"https://github.com/o/r/pull/7","isDraft":true,"headRefName":"story/S-1","baseRefName":"main","isCrossRepository":false,"headRepositoryOwner":{"login":"o"}}]' > "$tmp/fake/gh-final-list.main"
    assert_eq "final-reuse-draft: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "final-reuse-draft: edit then ready" "yes,yes" \
        "$(grep -qF -- 'pr edit --body-file' "$tmp/fake/gh-refresh-calls" && echo yes || echo no),$(grep -qF -- 'pr ready -- https://github.com/o/r/pull/7' "$tmp/fake/gh-refresh-calls" && echo yes || echo no)"
    assert_eq "final-reuse-draft: row ready, not-authorized note" "ready,waits: not-authorized" "$(fin_row "$tmp" "$tmp/repo" | awk -F'\t' '{print $2","$4}')"
    rm -rf "$tmp"
    tmp=$(mktemp -d)
    final_fixture "$tmp" "T-A:working done"; rm -f "$tmp/fake/final-create"; touch "$tmp/fake/gh-edit-fail"
    echo '[{"url":"https://github.com/o/r/pull/7","isDraft":true,"headRefName":"story/S-1","baseRefName":"main","isCrossRepository":false,"headRepositoryOwner":{"login":"o"}}]' > "$tmp/fake/gh-final-list.main"
    assert_eq "final-reuse-draft: failed refresh exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "final-reuse-draft: failed refresh never calls ready" 0 "$(grep -c 'pr ready' "$tmp/fake/gh-refresh-calls" || true)"
    assert_eq "final-reuse-draft: failed refresh keeps draft and the mismatch note" "draft,draft-mismatch (expected ready); waits: not-authorized" \
        "$(fin_row "$tmp" "$tmp/repo" | awk -F'\t' '{print $2","$4}')"
    rm -rf "$tmp"
}

# N1-293 CR-1: an unreadable agents list says nothing about the final session: its worktree is left in place.
test_final_pr_unreadable_keeps_worktree() {
    local tmp; tmp=$(mktemp -d)
    final_fixture "$tmp" "T-A:working done"
    rm -f "$tmp/fake/final-create"; echo working > "$tmp/fake/states.S-1.final"; touch "$tmp/fake/agents-fail-final"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "final-unreadable: worktree kept" yes "$([ -e "$tmp/final-1" ] && echo yes || echo no)"
    assert_eq "final-unreadable: row notes agents-unreadable" agents-unreadable "$(fin_row "$tmp" "$tmp/repo" | cut -f4)"
    rm -rf "$tmp"
}


# N1-293: the session ran but no PR exists: row "-" not-created, failed event, needs-you notice, run still exits 0.
test_final_pr_not_created() {
    local tmp; tmp=$(mktemp -d)
    story_merge_fixture "$tmp" "T-A:working done"
    assert_eq "final-none: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "final-none: row" $'-\t-\t-\tnot-created' "$(fin_row "$tmp" "$tmp/repo")"
    assert_eq "final-none: failed event" not-created "$(jq -r 'select(.event == "final_pr_failed") | .reason' "$tmp/events.jsonl")"
    assert_eq "final-none: notice" yes "$(grep -qF 'no final PR for story S-1' "$tmp/notes" && echo yes || echo no)"
    rm -rf "$tmp"
}

# N1-293: a final session that never ends is stopped at the timeout and recorded as timeout.
test_final_pr_timeout() {
    local tmp s=n1-sq-S-1-final-1; tmp=$(mktemp -d)
    story_merge_fixture "$tmp" "T-A:working done"
    echo working > "$tmp/fake/states.S-1.final"
    cfg_set "$tmp" '.queue.subtaskTimeoutMinutes = 1'
    assert_eq "final-timeout: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "final-timeout: session stopped" yes "$(grep -qxF "$(cat "$tmp/fake/id.$s")" "$tmp/fake/stopped" && echo yes || echo no)"
    assert_eq "final-timeout: row" $'-\t-\t-\ttimeout' "$(fin_row "$tmp" "$tmp/repo")"
    assert_eq "final-timeout: stopped session's worktree removed" no "$([ -e "$tmp/final-1" ] && echo yes || echo no)"
    rm -rf "$tmp"
    # a stop that fails leaves the session possibly alive: its worktree is kept
    tmp=$(mktemp -d)
    story_merge_fixture "$tmp" "T-A:working done"
    echo working > "$tmp/fake/states.S-1.final"; touch "$tmp/fake/stopfail.00000003"
    cfg_set "$tmp" '.queue.subtaskTimeoutMinutes = 1'
    run_bg_queue "$tmp" >/dev/null
    assert_eq "final-timeout-stopfail: worktree kept" yes "$([ -e "$tmp/final-1" ] && echo yes || echo no)"
    rm -rf "$tmp"
}

# N1-293: a row still open (awaiting-human) at the tail: no final PR yet, no lookup.
test_final_pr_rows_open() {
    local tmp; tmp=$(mktemp -d)
    final_fixture "$tmp" "T-A:working done" "T-B:blocked"
    assert_eq "final-open: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "final-open: no session" 0 "$(grep -c -- '-final-' "$tmp/fake/events" || true)"
    assert_eq "final-open: no lookup" no "$([ -e "$tmp/fake/gh-final-calls" ] && echo yes || echo no)"
    assert_eq "final-open: logged" yes "$(grep -qF 'final PRs: skipped (rows still open)' "$tmp/output.txt" && echo yes || echo no)"
    rm -rf "$tmp"
}

# N1-293 AC5: a story run that halts after a child merged opens no final PR (final_prs sits after the halt_now).
# T-A merges, T-B escalates (strike 1), T-C fails and its deferred retry fails (strikes 2-3) -> HALTED.
test_final_pr_halted() {
    local tmp; tmp=$(mktemp -d)
    final_fixture "$tmp" "T-A:working done" "T-B:done" "T-C:working"
    printf -- '---\nstep: escalated\n---\n# T\n\n## Escalations\n- blocked\n' > "$tmp/fake/overview.T-B"
    assert_eq "final-halt: exit 2" 2 "$(run_bg_queue "$tmp")"
    assert_eq "final-halt: a child merged first" merged "$(runs_outcome "$tmp/queue.md" T-A)"
    assert_eq "final-halt: no session" 0 "$(grep -c -- '-final-' "$tmp/fake/events" || true)"
    assert_eq "final-halt: no lookup" no "$([ -e "$tmp/fake/gh-final-calls" ] && echo yes || echo no)"
    assert_eq "final-halt: no Final PRs section" 0 "$(grep -c '^## Final PRs' "$tmp/queue.md" || true)"
    rm -rf "$tmp"
}

# N1-293: the base is the row N1 Home's git.defaultBranch, in the prompt and in the lookup.
test_final_pr_default_branch() {
    local tmp s=n1-sq-S-1-final-1; tmp=$(mktemp -d)
    final_fixture "$tmp" "T-A:working done"
    cfg_set "$tmp" '.git.defaultBranch = "develop"'
    assert_eq "final-base: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "final-base: prompt base develop" yes "$(grep -qF -- '--base develop' "$tmp/fake/prompt.$s" && echo yes || echo no)"
    assert_eq "final-base: lookup base develop" yes "$(grep -qF -- '--base develop' "$tmp/fake/gh-final-calls" && echo yes || echo no)"
    assert_eq "final-base: PR recorded" https://github.com/o/r/pull/9 "$(fin_row "$tmp" "$tmp/repo" | cut -f1)"
    rm -rf "$tmp"
}

# N1-424 AC1: fullAuto + mergeOnFinish, ready, MERGEABLE, Codex clean, checks green: merged at the head the gates saw.
test_final_pr_merged_when_authorized() {
    local tmp s=n1-sq-S-1-final-1; tmp=$(mktemp -d)
    final_merge_fixture "$tmp" "T-A:working done"
    assert_eq "final-merge: exit 0" 0 "$(run_fm "$tmp")"
    assert_eq "final-merge: merged at the gated head" "pr merge https://github.com/o/r/pull/9 --squash --match-head-commit $FM_HEAD" \
        "$(grep 'pull/9 ' "$tmp/fake/gh-merge")"
    assert_eq "final-merge: Codex reviewed that head" "$FM_HEAD" "$(cat "$tmp/fake/codex-head" 2>/dev/null)"
    assert_eq "final-merge: review worktree removed" no "$(has_file "$tmp/final-1-review")"
    assert_eq "final-merge: only the final worktree list entry left" 1 "$(git -C "$tmp/repo" worktree list | wc -l | tr -d ' ')"
    assert_eq "final-merge: note" merged "$(fin_note "$tmp")"
    assert_eq "final-merge: event" "merged|merged" "$(fm_event "$tmp")"
    assert_eq "final-merge: no n1-finish for the story" 0 "$(cat "$tmp"/fake/prompt.* | grep -cF 'n1-finish S-1' || true)"
    assert_eq "final-merge: one story session, the final one" "launch $s" "$(grep '^launch n1-sq-S-1-' "$tmp/fake/events")"
    rm -rf "$tmp"
    # no checks reported counts as passing (N1-289 D5) for a PR that existed before this run (reused: the fake session
    # is not needed, gh pr list already answers PR 9)
    tmp=$(mktemp -d); final_merge_fixture "$tmp" "T-A:working done"; echo '[]' > "$tmp/fake/gh-checks.9"
    rm -f "$tmp/fake/final-create"
    echo '[{"url":"https://github.com/o/r/pull/9","isDraft":false,"headRefName":"story/S-1","baseRefName":"main","isCrossRepository":false,"headRepositoryOwner":{"login":"o"}}]' > "$tmp/fake/gh-final-list.main"
    run_fm "$tmp" >/dev/null
    assert_eq "final-merge-nochecks: first read waits" "0,waits: checks-unregistered" "$(fm_merges "$tmp" 9),$(fin_note "$tmp")"
    run_fm "$tmp" >/dev/null   # same head seen again with no checks: passes
    assert_eq "final-merge-nochecks: merged" "1,merged" "$(fm_merges "$tmp" 9),$(fin_note "$tmp")"
    rm -rf "$tmp"
    # a Codex skip (disabled) does not block; the note records it and no review ran
    tmp=$(mktemp -d); final_merge_fixture "$tmp" "T-A:working done"; cfg_set "$tmp" '.crossHostReview.enabled = false'
    run_fm "$tmp" >/dev/null
    assert_eq "final-merge-skip: merged, skip noted" "1,merged; codex: skipped disabled" "$(fm_merges "$tmp" 9),$(fin_note "$tmp")"
    assert_eq "final-merge-skip: no review ran" no "$(has_file "$tmp/fake/codex-calls")"
    rm -rf "$tmp"
}

# N1-424 AC2: the head moves while Codex runs: nothing merges, no retry on the new head.
test_final_pr_head_moved() {
    local tmp; tmp=$(mktemp -d)
    final_merge_fixture "$tmp" "T-A:working done"; echo move > "$tmp/fake/codex-mode"
    assert_eq "final-moved: exit 0" 0 "$(run_fm "$tmp")"
    assert_eq "final-moved: no merge" 0 "$(fm_merges "$tmp" 9)"
    assert_eq "final-moved: note" "waits: head-moved" "$(fin_note "$tmp")"
    assert_eq "final-moved: event" "waits|waits: head-moved" "$(fm_event "$tmp")"
    rm -rf "$tmp"
}

# N1-424 AC3/AC4: fullAuto off, or fullAuto on with mergeOnFinish off: no merge, PR stays open, no Codex, no notice.
test_final_pr_not_authorized() {
    local tmp f
    for f in '.autonomy.fullAuto = false' '.finishWork.mergeOnFinish = false'; do
        tmp=$(mktemp -d)
        final_merge_fixture "$tmp" "T-A:working done"; cfg_set "$tmp" "$f"
        assert_eq "final-noauth ($f): exit 0" 0 "$(run_fm "$tmp")"
        assert_eq "final-noauth ($f): no merge" 0 "$(fm_merges "$tmp" 9)"
        assert_eq "final-noauth ($f): PR open, ready" "OPEN,ready" "$(cut -f1 "$tmp/fake/gh-view.9"),$(fin_row "$tmp" "$tmp/repo" | cut -f2)"
        assert_eq "final-noauth ($f): note" "waits: not-authorized" "$(fin_note "$tmp")"
        assert_eq "final-noauth ($f): no review" no "$(has_file "$tmp/fake/codex-calls")"
        assert_eq "final-noauth ($f): no notice for the PR" no "$(grep -qF 'pull/9' "$tmp/notes" 2>/dev/null && echo yes || echo no)"
        rm -rf "$tmp"
    done
}

# N1-424 AC5: red, pending or unreadable checks: no merge, reason recorded (read after Codex; no wait).
test_final_pr_checks_gate() {
    local tmp c
    for c in 'red:[{"bucket":"fail"}]' 'pending:[{"bucket":"pending"}]' 'error:not json'; do
        tmp=$(mktemp -d)
        final_merge_fixture "$tmp" "T-A:working done"; printf '%s\n' "${c#*:}" > "$tmp/fake/gh-checks.9"
        assert_eq "final-checks ${c%%:*}: exit 0" 0 "$(run_fm "$tmp")"
        assert_eq "final-checks ${c%%:*}: no merge" 0 "$(fm_merges "$tmp" 9)"
        assert_eq "final-checks ${c%%:*}: note" "waits: checks-${c%%:*}" "$(fin_note "$tmp")"
        rm -rf "$tmp"
    done
    # no checks reported on a PR this run just created (the fake final session opens PR 9): CI may not have registered yet
    tmp=$(mktemp -d)
    final_merge_fixture "$tmp" "T-A:working done"; echo '[]' > "$tmp/fake/gh-checks.9"
    run_fm "$tmp" >/dev/null
    assert_eq "final-checks fresh-none: no merge, note" "0,waits: checks-unregistered" "$(fm_merges "$tmp" 9),$(fin_note "$tmp")"
    rm -rf "$tmp"
}

# N1-424 AC6: a draft final PR (a child did not land) is never merged, also when the PR reads ready (draft-mismatch).
test_final_pr_draft_not_merged() {
    local tmp; tmp=$(mktemp -d)
    final_merge_fixture "$tmp" "T-A:working done" "T-B:working done"
    printf 'OPEN\tmain\t%s\n' "$SM_PIN" > "$tmp/fake/gh-view.2"   # T-B targets main: wrong-base, does not land
    assert_eq "final-draft-gate: exit 0" 0 "$(run_fm "$tmp")"
    assert_eq "final-draft-gate: no merge" 0 "$(fm_merges "$tmp" 9)"
    assert_eq "final-draft-gate: note" "waits: draft" "$(fin_note "$tmp")"
    assert_eq "final-draft-gate: no review" no "$(has_file "$tmp/fake/codex-calls")"
    rm -rf "$tmp"
    tmp=$(mktemp -d)
    final_merge_fixture "$tmp" "T-A:working done" "T-B:working done"; rm -f "$tmp/fake/final-create"
    printf 'OPEN\tmain\t%s\n' "$SM_PIN" > "$tmp/fake/gh-view.2"
    echo '[{"url":"https://github.com/o/r/pull/7","isDraft":false,"headRefName":"story/S-1","baseRefName":"main","isCrossRepository":false,"headRepositoryOwner":{"login":"o"}}]' > "$tmp/fake/gh-final-list.main"
    assert_eq "final-draft-mismatch: exit 0" 0 "$(run_fm "$tmp")"
    assert_eq "final-draft-mismatch: no merge" 0 "$(fm_merges "$tmp" 7)"
    assert_eq "final-draft-mismatch: note" "draft-mismatch (expected draft); waits: draft" "$(fin_note "$tmp")"
    rm -rf "$tmp"
}

# N1-424 AC7: CONFLICTING, or UNKNOWN on every bounded read: no merge, reason recorded.
test_final_pr_mergeable_gate() {
    local tmp; tmp=$(mktemp -d)
    final_merge_fixture "$tmp" "T-A:working done"; printf 'CONFLICTING\tDIRTY\n' > "$tmp/fake/gh-mergeable-seq"
    run_fm "$tmp" >/dev/null
    assert_eq "final-conflict: no merge, note" "0,waits: conflicting" "$(fm_merges "$tmp" 9),$(fin_note "$tmp")"
    rm -rf "$tmp"
    tmp=$(mktemp -d)
    final_merge_fixture "$tmp" "T-A:working done"; printf 'UNKNOWN\t\n' > "$tmp/fake/gh-mergeable-seq"
    run_fm "$tmp" >/dev/null
    assert_eq "final-unknown: no merge, note" "0,waits: mergeable-unknown" "$(fm_merges "$tmp" 9),$(fin_note "$tmp")"
    rm -rf "$tmp"
}

# N1-424 AC8: failed, timed-out, findings or untriaged Codex review: no merge, reason recorded, worktree removed.
test_final_pr_codex_gate() {
    local tmp m
    for m in fail:codex-failed hang:codex-timeout findings:codex-findings optout:codex-findings-unavailable; do
        tmp=$(mktemp -d)
        final_merge_fixture "$tmp" "T-A:working done"
        if [ "${m%%:*}" = optout ]; then cfg_set "$tmp" '.crossHostReview.autoTriage = false'; else echo "${m%%:*}" > "$tmp/fake/codex-mode"; fi
        assert_eq "final-codex ${m%%:*}: exit 0" 0 "$(N1_CROSS_HOST_REVIEW_TIMEOUT=1 run_fm "$tmp")"
        assert_eq "final-codex ${m%%:*}: no merge" 0 "$(fm_merges "$tmp" 9)"
        assert_eq "final-codex ${m%%:*}: note" "waits: ${m#*:}" "$(fin_note "$tmp")"
        assert_eq "final-codex ${m%%:*}: review worktree removed" no "$(has_file "$tmp/final-1-review")"
        rm -rf "$tmp"
    done
}

# N1-424 CR-2/SEC-2: only disabled|not-installed|no-auth skips pass. A broken login probe (auth-error) or a login
# timeout (auth-timeout) is a failed review; a positive "not logged in" still passes and is noted.
test_final_pr_codex_skip_allowlist() {
    local tmp m
    for m in broken:auth-error hang:auth-timeout; do
        tmp=$(mktemp -d)
        final_merge_fixture "$tmp" "T-A:working done"; echo "${m%%:*}" > "$tmp/fake/codex-login"
        N1_CODEX_AUTH_TIMEOUT=1 run_fm "$tmp" >/dev/null
        assert_eq "final-skip ${m#*:}: no merge, note" "0,waits: codex-failed" "$(fm_merges "$tmp" 9),$(fin_note "$tmp")"
        rm -rf "$tmp"
    done
    tmp=$(mktemp -d)
    final_merge_fixture "$tmp" "T-A:working done"; echo notlogged > "$tmp/fake/codex-login"
    run_fm "$tmp" >/dev/null
    assert_eq "final-skip no-auth: merged, noted" "1,merged; codex: skipped no-auth" "$(fm_merges "$tmp" 9),$(fin_note "$tmp")"
    rm -rf "$tmp"
}

# N1-424 SEC-1: a story diff that adds, changes or deletes an agent-instruction or Codex config file is never merged on
# a clean Codex review (Codex reads those files from the reviewed checkout as instructions); Codex does not run.
test_final_pr_instruction_files() {
    local tmp f
    for f in AGENTS.md sub/dir/CLAUDE.md AGENTS.override.md .codex/config.toml .claude/settings.json; do
        tmp=$(mktemp -d)
        final_merge_fixture "$tmp" "T-A:working done"
        git -C "$tmp/origin" checkout -q story/S-1
        mkdir -p "$tmp/origin/$(dirname "$f")"; echo x > "$tmp/origin/$f"
        git -C "$tmp/origin" add -f -A
        git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q -m instr
        git -C "$tmp/origin" checkout -q main
        printf 'OPEN\tmain\t%s\n' "$(git -C "$tmp/origin" rev-parse story/S-1)" > "$tmp/fake/gh-view.9"
        run_fm "$tmp" >/dev/null
        assert_eq "final-instr $f: no merge, note" "0,waits: codex-instructions-changed" "$(fm_merges "$tmp" 9),$(fin_note "$tmp")"
        assert_eq "final-instr $f: Codex did not run" no "$(has_file "$tmp/fake/codex-calls")"
        assert_eq "final-instr $f: worktree removed" no "$(has_file "$tmp/final-1-review")"
        rm -rf "$tmp"
    done
}

# N1-424: a refused merge is recorded, never retried; a queued merge is merge-pending; a merge that lands off the
# default branch escalates (needs-you), as story_merge SEC-2.
test_final_pr_merge_refused() {
    local tmp; tmp=$(mktemp -d)
    final_merge_fixture "$tmp" "T-A:working done"; echo 1 > "$tmp/fake/gh-merge-rc.9"; echo 'GraphQL: protected branch' > "$tmp/fake/gh-merge-err.9"
    run_fm "$tmp" >/dev/null
    assert_eq "final-refused: one attempt, note" "1,waits: merge-failed" "$(fm_merges "$tmp" 9),$(fin_note "$tmp")"
    rm -rf "$tmp"
    tmp=$(mktemp -d)
    final_merge_fixture "$tmp" "T-A:working done"; touch "$tmp/fake/gh-merge-queued.9"
    run_fm "$tmp" >/dev/null
    assert_eq "final-queued: note" "waits: merge-pending" "$(fin_note "$tmp")"
    rm -rf "$tmp"
    tmp=$(mktemp -d)
    final_merge_fixture "$tmp" "T-A:working done"; echo develop > "$tmp/fake/gh-view-after.9"
    run_fm "$tmp" >/dev/null
    assert_eq "final-offbase: note" "waits: merged-off-default" "$(fin_note "$tmp")"
    assert_eq "final-offbase: escalated" "runner merge landed on develop, not main" \
        "$(jq -r 'select(.event == "escalated") | .reason' "$tmp/events.jsonl" | tail -n1)"
    assert_eq "final-offbase: notice" yes "$(grep -qF 'final PR https://github.com/o/r/pull/9' "$tmp/notes" 2>/dev/null && echo yes || echo no)"
    rm -rf "$tmp"
}

# N1-424: a resume whose recorded final PR is already MERGED into the default branch launches no session, merges
# nothing and keeps the row (n1_queue_final_pr_find lists OPEN PRs only).
test_final_pr_merged_resume() {
    local tmp; tmp=$(mktemp -d)
    final_merge_fixture "$tmp" "T-A:working done"
    n1_queue_final_pr_set "$tmp/queue.md" "$tmp/repo" https://github.com/o/r/pull/9 ready MERGEABLE "waits: checks-pending"
    printf 'MERGED\tmain\t%s\n' "$FM_HEAD" > "$tmp/fake/gh-view.9"
    assert_eq "final-resume: exit 0" 0 "$(run_fm "$tmp")"
    assert_eq "final-resume: no final session" 0 "$(count_x "$tmp/fake/events" 'launch n1-sq-S-1-final-1')"
    assert_eq "final-resume: no merge call" 0 "$(fm_merges "$tmp" 9)"
    assert_eq "final-resume: note" "merged (outside the runner)" "$(fin_note "$tmp")"
    assert_eq "final-resume: summary reader still lists it" https://github.com/o/r/pull/9 \
        "$(n1_queue_final_prs "$tmp/queue.md" "$tmp/events.jsonl" "$(n1_read_frontmatter "$tmp/queue.md" run_id)" | cut -f2)"
    rm -rf "$tmp"
    tmp=$(mktemp -d)
    final_merge_fixture "$tmp" "T-A:working done"
    n1_queue_final_pr_set "$tmp/queue.md" "$tmp/repo" https://github.com/o/r/pull/9 ready MERGEABLE "merged; codex: skipped no-auth"
    printf 'MERGED\tmain\t%s\n' "$FM_HEAD" > "$tmp/fake/gh-view.9"
    run_fm "$tmp" >/dev/null
    assert_eq "final-resume-kept: runner note kept" "merged; codex: skipped no-auth" "$(fin_note "$tmp")"
    rm -rf "$tmp"
    # a recorded URL of another repository is never trusted: the normal flow runs (a session opens the final PR)
    tmp=$(mktemp -d)
    final_merge_fixture "$tmp" "T-A:working done"
    n1_queue_final_pr_set "$tmp/queue.md" "$tmp/repo" https://github.com/x/y/pull/9 ready MERGEABLE ""
    printf 'MERGED\tmain\t%s\n' "$FM_HEAD" > "$tmp/fake/gh-view.9"
    run_fm "$tmp" >/dev/null
    assert_eq "final-resume-foreign: a final session launched" 1 "$(count_x "$tmp/fake/events" 'launch n1-sq-S-1-final-1')"
    rm -rf "$tmp"
    # CR-1/SEC-7: a merged PR of this repo whose head is not the story branch, or a URL with a suffix, is never trusted
    local u
    for u in "https://github.com/o/r/pull/9:other-branch"; do   # a URL with a suffix cannot be recorded (final_pr_set rejects it)
        tmp=$(mktemp -d)
        final_merge_fixture "$tmp" "T-A:working done"
        n1_queue_final_pr_set "$tmp/queue.md" "$tmp/repo" "${u%:*}" ready MERGEABLE ""
        printf 'MERGED\tmain\t%s\n' "$FM_HEAD" > "$tmp/fake/gh-view.9"
        echo "${u##*:}" > "$tmp/fake/gh-headref.9"
        run_fm "$tmp" >/dev/null
        assert_eq "final-resume-untrusted ($u): a final session launched" 1 "$(count_x "$tmp/fake/events" 'launch n1-sq-S-1-final-1')"
        rm -rf "$tmp"
    done
}

# N1-293: tag mode is unchanged: no lookup, no final session, no table.
test_final_pr_tag_mode() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:done"
    assert_eq "final-tag: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "final-tag: no lookup" no "$([ -e "$tmp/fake/gh-final-calls" ] && echo yes || echo no)"
    assert_eq "final-tag: no session" 0 "$(grep -c -- '-final-' "$tmp/fake/events" || true)"
    assert_eq "final-tag: no table" 0 "$(grep -c '^## Final PRs$' "$tmp/queue.md" || true)"
    rm -rf "$tmp"
}

test_bg_held_not_launched
test_bg_held_blocker_failed
test_bg_held_user_merge
test_bg_held_merge_at_timeout
test_bg_chain_merges
test_bg_chain_fin_wait_unchanged
test_bg_chain_sync_ok
test_bg_chain_clean_marker
test_bg_chain_clean_launch_failed
test_bg_chain_clean_done
test_bg_chain_pr_closed
test_bg_chain_pr_state_retry
test_bg_chain_pr_state_unreadable
test_bg_chain_flags_off
test_bg_chain_finish_stops
test_bg_chain_missing_is_busy
test_bg_chain_blocked_child
test_bg_chain_blocked_guards
test_bg_chain_restart
test_bg_chain_reconcile
test_bg_chain_row_home
test_bg_chain_story_env_scoped
test_story_merge_green
test_story_merge_refusals
test_story_merge_ci
test_story_merge_refused_and_retarget
test_story_done_launch_failed
test_story_merge_base_unverified
test_story_merge_queued_not_recorded
test_story_pending_marker_guarded
test_story_mode_snapshot
test_story_resume
test_story_held_released_after_runner_merge
test_story_dependents_of_ci_red
test_queue_merge_green
test_queue_held_released_after_runner_merge
test_queue_integration_snapshot
test_queue_final_pr
test_queue_final_waits_predecessor
test_final_pr_ready
test_final_pr_draft
test_final_pr_repo_without_merge
test_final_pr_reused
test_final_pr_reused_draft
test_final_pr_unreadable_keeps_worktree
test_final_pr_not_created
test_final_pr_timeout
test_final_pr_rows_open
test_final_pr_halted
test_final_pr_default_branch
test_final_pr_merged_when_authorized
test_final_pr_head_moved
test_final_pr_not_authorized
test_final_pr_checks_gate
test_final_pr_draft_not_merged
test_final_pr_mergeable_gate
test_final_pr_codex_gate
test_final_pr_codex_skip_allowlist
test_final_pr_instruction_files
test_final_pr_merge_refused
test_final_pr_merged_resume
test_final_pr_tag_mode
test_lifecycle_wiring
test_merge_wording

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

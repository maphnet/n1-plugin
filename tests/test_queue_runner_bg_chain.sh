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

# N1-609 AC3: one transient gh repo view failure inside story_merge is retried, so a PR already merged into the story
# branch is recorded in the same run instead of ending finish:pr-state-unreadable.
test_story_repo_read_retry() {
    local tmp; tmp=$(mktemp -d); story_restart_setup "$tmp" "" MERGED
    echo 1 > "$tmp/fake/gh-repo-fail"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-repo-retry: recorded merged, marker done" "merged|done" \
        "$(runs_outcome "$tmp/queue.md" T-A)|$(sed -n 2p "$tmp/.chained-T-A" 2>/dev/null || true)"
    rm -rf "$tmp"
}

# N1-609 AC1/AC4: a retryable story_merge refusal leaves a pr row that --run counts (n1_queue_pr_resume_rows) and the
# relaunched runner lands. Unreadable repo identity, then the PR merged: the resume records it without a merge call.
# Red CI, then green: the resume merges. Bugs caught: the row not counted for --run; a resumed row merged twice.
test_story_refusal_resume() {
    local tmp
    tmp=$(mktemp -d); story_restart_setup "$tmp" "" MERGED
    echo 99 > "$tmp/fake/gh-repo-fail"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-refusal unreadable: pr, reason, marker removed" "pr|finish:pr-state-unreadable|no" \
        "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)|$([ -e "$tmp/.chained-T-A" ] && echo yes || echo no)"
    assert_eq "story-refusal unreadable: --run counts the row" "T-A" "$(n1_queue_pr_resume_rows "$tmp/queue.md" | cut -f2)"
    rm -f "$tmp/fake/gh-repo-fail"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-refusal unreadable then merged: recorded, no merge call" "merged|0" \
        "$(runs_outcome "$tmp/queue.md" T-A)|$(nlines "$tmp/fake/gh-merge")"
    assert_eq "story-refusal unreadable then merged: no longer counted" "" "$(n1_queue_pr_resume_rows "$tmp/queue.md")"
    rm -rf "$tmp"
    tmp=$(mktemp -d); story_restart_setup "$tmp" "" OPEN
    printf '%s' '[{"bucket":"pass"},{"bucket":"fail"}]' > "$tmp/fake/gh-checks"; printf '1' > "$tmp/fake/gh-checks-rc"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-refusal red CI: nothing merged, reason, counted" "0|finish:ci-red|T-A" \
        "$(nlines "$tmp/fake/gh-merge")|$(plan_cell "$tmp/queue.md" 1 9)|$(n1_queue_pr_resume_rows "$tmp/queue.md" | cut -f2)"
    echo '[{"bucket":"pass"}]' > "$tmp/fake/gh-checks"; printf '0' > "$tmp/fake/gh-checks-rc"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "story-refusal red then green CI: resume merges once" "1|merged" \
        "$(nlines "$tmp/fake/gh-merge")|$(runs_outcome "$tmp/queue.md" T-A)"
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

# N1-612: a refused pin names its reason. The child's pr-report.md carries `pin:refused review-failed`, so the child
# Reason is finish:no-pin (review-failed), the dependent carries it through, the runner says the review FAILed at the
# fix cap, and nothing merges. The no-marker case is the no-pin entry of test_story_merge_refusals (bare finish:no-pin).
test_story_no_pin_reason() {
    local tmp; tmp=$(mktemp -d)
    story_merge_fixture "$tmp" "T-A:working done" "T-B:done"
    n1_queue_row_status "$tmp/queue.md" 2 held "blocked_on T-A"
    rm -f "$tmp/n1home/review-pins/o_r_1"
    mkdir -p "$tmp/n1home/memory/T-A"
    printf 'PR: https://github.com/o/r/pull/1\npin:refused review-failed T-A (the review verdict is not PASS; fix and re-review)\n' \
        > "$tmp/n1home/memory/T-A/pr-report.md"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "no-pin-reason: nothing merged" 0 "$(nlines "$tmp/fake/gh-merge")"
    assert_eq "no-pin-reason: child row names the refusal" "pr|finish:no-pin (review-failed)" \
        "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "no-pin-reason: dependent carries the reason" "skip|blocked by T-A (finish:no-pin (review-failed))" \
        "$(plan_cell "$tmp/queue.md" 2 8)|$(plan_cell "$tmp/queue.md" 2 9)"
    assert_eq "no-pin-reason: dependent never launched" 0 "$(count_x "$tmp/fake/events" 'launch n1-sq-T-B-2')"
    assert_eq "no-pin-reason: runner points to review.md" 1 \
        "$(grep -cF 'T-A review FAILed at the fix cap; open findings are in review.md (not a CI or PR comment issue)' "$tmp/output.txt" || true)"
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
    assert_eq "queue-merge: no Done session (N1-532)" 0 "$(count_x "$tmp/fake/events" 'launch n1-sq-T-A-1-done')"
    assert_eq "queue-merge: Status pr, Reason defers Done" "pr|merged; done at final PR" \
        "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "queue-merge: log names the deferral" yes \
        "$(grep -qF 'T-A done deferred to the final PR' "$tmp/output.txt" && echo yes || echo no)"
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
    assert_eq "queue-held: no Done session for either child (N1-532)" "0|0" \
        "$(count_x "$tmp/fake/events" 'launch n1-sq-T-A-1-done')|$(count_x "$tmp/fake/events" 'launch n1-sq-T-B-2-done')"
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




# N1-447 AC4: predecessor squash-merged -> rebase --onto main <Base>, lease push, row rebased; the queue branch then
# carries only its own commit over main. An open draft final PR whose children all landed is refreshed and marked ready.
test_queue_chain_rebase() {
    local tmp tip; tmp=$(mktemp -d)
    qc_fixture "$tmp" "T-A:done"
    n1_queue_row_status "$tmp/queue.md" 1 pr
    echo '| T-A | 2026-01-01T00:00:00Z | | merged | https://github.com/o/r/pull/1 | 00000009 |' >> "$tmp/queue.md"
    n1_queue_final_pr_set "$tmp/queue.md" "$tmp/repo" https://github.com/o/r/pull/9 draft MERGEABLE "waits: predecessor"
    final_list "$tmp" "$QB" 9 true
    assert_eq "chain: exit 0" 0 "$(run_chain "$tmp")"
    assert_eq "chain: queue branch sits on main" "$(git -C "$tmp/origin" rev-parse main)" "$(git -C "$tmp/origin" rev-parse "$QB^")"
    assert_eq "chain: only Q2's commit over main" 1 "$(git -C "$tmp/origin" rev-list --count "main..$QB")"
    assert_eq "chain: row rebased, Base/Head kept" "$QC_BASE $QC_BASE rebased" "$(n1_queue_preds "$tmp/queue.md" | awk -F'\t' '{ print $5, $6, $7 }')"
    assert_eq "chain: rebased event" 1 "$(grep -c 'queue_chain_rebased' "$tmp/events.jsonl" || true)"
    assert_eq "chain: final PR marked ready" 1 "$(count_x "$tmp/fake/gh-refresh-calls" 'pr ready -- https://github.com/o/r/pull/9')"
    assert_eq "chain: Final PRs row ready" $'https://github.com/o/r/pull/9\tready\tMERGEABLE\trebased onto main' "$(fin_row "$tmp" "$tmp/repo")"
    assert_eq "chain: worktree removed" "" "$(find "$tmp" -maxdepth 1 -type d -name 'chain-*')"
    tip=$(git -C "$tmp/origin" rev-parse "$QB"); run_chain "$tmp" >/dev/null
    assert_eq "chain: second run is a no-op" "$tip" "$(git -C "$tmp/origin" rev-parse "$QB")"
    rm -rf "$tmp"
}

# N1-447 AC5 / ticket item 3: predecessor closed unmerged, predecessor head moved (gained commits after the cut), or a
# rebase conflict -> no push, row stopped, needs-you notice. A refused push stays waiting (a later trigger retries).
# Rows still open -> nothing at all.
test_queue_chain_stops() {
    local tmp spec c want ev why q2
    for spec in "closed|stopped|queue_chain_stopped|predecessor closed unmerged" \
                "moved|stopped|queue_chain_stopped|predecessor gained commits after cut" \
                "conflict|stopped|queue_chain_stopped|rebase conflict" \
                "pushfail|waiting|queue_chain_push_failed|chain-push-failed" \
                "open|waiting||"; do
        IFS='|' read -r c want ev why <<< "$spec"
        tmp=$(mktemp -d); qc_fixture "$tmp" "T-A:done"
        n1_queue_final_pr_set "$tmp/queue.md" "$tmp/repo" https://github.com/o/r/pull/9 draft MERGEABLE "waits: predecessor"
        [ "$c" = open ] || n1_queue_row_status "$tmp/queue.md" 1 pr
        case "$c" in
            closed) printf 'CLOSED\tmain\t%s\n' "$QC_BASE" > "$tmp/fake/gh-view.5" ;;
            moved) printf 'MERGED\tmain\t%s\n' "$SM_PIN" > "$tmp/fake/gh-view.5" ;;
            conflict) echo other > "$tmp/origin/f"
                      git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q -am other ;;
            pushfail) printf '#!/bin/sh\nexit 1\n' > "$tmp/origin/.git/hooks/pre-receive"; chmod +x "$tmp/origin/.git/hooks/pre-receive" ;;
        esac
        q2=$(git -C "$tmp/origin" rev-parse "$QB")
        assert_eq "chain-$c: exit 0" 0 "$(run_chain "$tmp")"
        assert_eq "chain-$c: queue branch not pushed" "$q2" "$(git -C "$tmp/origin" rev-parse "$QB")"
        assert_eq "chain-$c: row $want" "$want" "$(n1_queue_preds "$tmp/queue.md" | cut -f7)"
        assert_eq "chain-$c: no worktree left" "" "$(find "$tmp" -maxdepth 1 -type d -name 'chain-*')"
        if [ -n "$why" ]; then
            assert_eq "chain-$c: needs-you notice" yes "$(grep -qF "$why" "$tmp/chain.txt" 2>/dev/null && echo yes || echo no)"
            assert_eq "chain-$c: event" 1 "$(grep -c "$ev" "$tmp/events.jsonl" || true)"
            assert_eq "chain-$c: Final PRs row keeps its PR, Note says why" \
                "$(printf 'https://github.com/o/r/pull/9\tdraft\tMERGEABLE\tchain: %s' "$why")" "$(fin_row "$tmp" "$tmp/repo")"
        else
            assert_eq "chain-$c: skipped" "yes" \
                "$(grep -qF 'rows still open' "$tmp/chain.txt" && echo yes || echo no)"
        fi
        rm -rf "$tmp"
    done
}

# N1-447 chain of 3: rebasing Q2 moves the Head of every queue waiting on Q2 to Q2's new tip; Base stays the old tip,
# so Q3's later --onto drops exactly the commits it inherited from Q2.
test_queue_chain_three() {
    local tmp old q3; tmp=$(mktemp -d)
    qc_fixture "$tmp" "T-A:done"; n1_queue_row_status "$tmp/queue.md" 1 pr
    old=$(git -C "$tmp/origin" rev-parse "$QB")
    q3="$tmp/n1home/queue/q3/queue.md"; pred_queue "$tmp/n1home" q3 "$tmp/repo" queue/q3-20261107T000000Z
    n1_queue_pred_set "$q3" "$tmp/repo" "${QB#queue/}" "$QB" https://github.com/o/r/pull/9 "$old" "$old" waiting
    n1_queue_pred_set "$q3" "$tmp/repoB" "${QB#queue/}" "$QB" https://github.com/o/r/pull/9 "$old" "$old" waiting
    run_chain "$tmp" >/dev/null
    assert_eq "chain-3: other repo's row untouched" "$old" "$(n1_queue_preds "$q3" | awk -F'\t' -v r="$tmp/repoB" '$1 == r { print $6 }')"
    assert_eq "chain-3: Q3 Base kept, Head = Q2's new tip" "$old $(git -C "$tmp/origin" rev-parse "$QB") waiting" \
        "$(n1_queue_preds "$q3" | awk -F'\t' -v r="$tmp/repo" '$1 == r { print $5, $6, $7 }')"
    assert_eq "chain-3: marker binds Q3's Base to Q2's new tip" "$old $(git -C "$tmp/origin" rev-parse "$QB")" \
        "$(cat "$tmp"/n1home/queue/q3/.chain-rebased-* 2>/dev/null)"
    rm -rf "$tmp"
}

# N1-447 Codex: a push that went through but was not recorded (row still waiting, marker present) is resumed, not
# stopped because Base left the rewritten branch's history.
test_queue_chain_resume() {
    local tmp old new; tmp=$(mktemp -d)
    qc_fixture "$tmp" "T-A:done"; n1_queue_row_status "$tmp/queue.md" 1 pr
    old=$(git -C "$tmp/origin" rev-parse "$QB")
    run_chain "$tmp" >/dev/null
    new=$(git -C "$tmp/origin" rev-parse "$QB")
    n1_queue_pred_set "$tmp/queue.md" "$tmp/repo" "$QC_ID" "$QC_P" https://github.com/o/r/pull/5 "$QC_BASE" "$QC_BASE" waiting
    echo "$old $new" > "$tmp/.chain-push-$(cksum <<< "$tmp/repo" | cut -d' ' -f1)"
    run_chain "$tmp" >/dev/null
    assert_eq "chain-resume: row rebased, not stopped" rebased "$(n1_queue_preds "$tmp/queue.md" | cut -f7)"
    assert_eq "chain-resume: branch untouched" "$new" "$(git -C "$tmp/origin" rev-parse "$QB")"
    assert_eq "chain-resume: marker removed" "" "$(ls -A "$tmp" | grep '^\.chain-push-' || true)"
    rm -rf "$tmp"
}

# N1-447 SEC-1/SEC-2/CR-2: a row that names a branch of another queue, a Base outside the predecessor PR, a PR other than
# --pred, or a PR whose child is still open against the branch pushes nothing.
test_queue_chain_bound() {
    local tmp c want why q2 other args
    for c in own base pred open; do
        tmp=$(mktemp -d); qc_fixture "$tmp" "T-A:done"; n1_queue_row_status "$tmp/queue.md" 1 pr
        args=(--own "$QB" "$tmp/queue.md"); want=stopped; why=""
        case "$c" in
            own) args=(--own queue/other-20261106T000000Z "$tmp/queue.md"); why="own queue branch" ;;
            base) other=$(git -C "$tmp/origin" rev-parse "$QB"); git -C "$tmp/origin" update-ref refs/pull/5/head "$(git -C "$tmp/origin" rev-parse main)"
                  printf 'MERGED\tmain\t%s\n' "$(git -C "$tmp/origin" rev-parse main)" > "$tmp/fake/gh-view.5"
                  n1_queue_pred_set "$tmp/queue.md" "$tmp/repo" "$QC_ID" "$QC_P" https://github.com/o/r/pull/5 "$QC_BASE" "$(git -C "$tmp/origin" rev-parse main)" waiting
                  why="base not in" ;;
            pred) args=(--pred https://github.com/o/r/pull/77 --own "$QB" "$tmp/queue.md"); want=waiting ;;
            open) echo '| T-A | 2026-01-01T00:00:00Z | | open | https://github.com/o/r/pull/1 | 00000009 |' >> "$tmp/queue.md"
                  printf 'OPEN\tmain\t%040d\n' 3 > "$tmp/fake/gh-view.1"; want=waiting ;;
        esac
        q2=$(git -C "$tmp/origin" rev-parse "$QB")
        assert_eq "chain-bound-$c: exit 0" 0 "$(run_chain "$tmp" "${args[@]}")"
        assert_eq "chain-bound-$c: queue branch not pushed" "$q2" "$(git -C "$tmp/origin" rev-parse "$QB")"
        assert_eq "chain-bound-$c: row $want" "$want" "$(n1_queue_preds "$tmp/queue.md" | cut -f7)"
        [ -z "$why" ] || assert_eq "chain-bound-$c: reason recorded" yes "$(grep -qF "$why" "$tmp/chain.txt" && echo yes || echo no)"
        rm -rf "$tmp"
    done
    tmp=$(mktemp -d); qc_fixture "$tmp" "T-A:done"; n1_queue_row_status "$tmp/queue.md" 1 pr
    run_chain "$tmp" --pred https://github.com/o/r/pull/5 --own "$QB" "$tmp/queue.md" >/dev/null
    assert_eq "chain-bound: matching --pred rebases" rebased "$(n1_queue_preds "$tmp/queue.md" | cut -f7)"
    rm -rf "$tmp"
    tmp=$(mktemp -d); qc_fixture "$tmp" "T-A:done"; n1_queue_row_status "$tmp/queue.md" 1 pr
    run_chain "$tmp" "$tmp/queue.md" >/dev/null
    assert_eq "chain-bound: without --own the branch must match the queue dir name" stopped "$(n1_queue_preds "$tmp/queue.md" | cut -f7)"
    rm -rf "$tmp"
    tmp=$(mktemp -d); qc_fixture "$tmp" "T-A:done"; n1_queue_row_status "$tmp/queue.md" 1 pr
    mkdir -p "$tmp/n1home/queue/sq" && cp "$tmp/queue.md" "$tmp/n1home/queue/sq/queue.md"
    run_chain "$tmp" "$tmp/n1home/queue/sq/queue.md" >/dev/null
    assert_eq "chain-bound: derived branch queue/<dir>-<stamp> accepted" rebased "$(n1_queue_preds "$tmp/n1home/queue/sq/queue.md" | cut -f7)"
    rm -rf "$tmp"
}

# N1-447 AC4 end to end: a --run after the predecessor merged rebases the queue branch before its final PR, which then
# opens ready (every child landed, no predecessor wait).
test_queue_chain_run_e2e() {
    local tmp s="n1-sq-${QB#queue/}-final-1"; tmp=$(mktemp -d)
    qc_fixture "$tmp" "T-A:working done"
    touch "$tmp/fake/final-create"; printf 'UNKNOWN\t\nMERGEABLE\tCLEAN\n' > "$tmp/fake/gh-mergeable-seq"
    assert_eq "chain-run: exit 0" 0 "$(export "${GIT_TEST_ID[@]}"; run_bg_queue "$tmp")"
    assert_eq "chain-run: row rebased" rebased "$(n1_queue_preds "$tmp/queue.md" | cut -f7)"
    assert_eq "chain-run: queue branch on main" "$(git -C "$tmp/origin" rev-parse main)" "$(git -C "$tmp/origin" rev-parse "$QB^")"
    assert_eq "chain-run: final PR not a draft" no "$(grep -qF -- '--draft' "$tmp/fake/prompt.$s" && echo yes || echo no)"
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
    # 3 poll calls up to the timeout tick + 1 from the Done-section reconcile (N1-481) of T-A's still-pr row.
    assert_eq "bg-held-timeout: merged on the timeout tick" "4" "$(cat "$tmp/ghcalls")"
    assert_eq "bg-held-timeout: T-B launched once" "1" "$(ls "$tmp/fake" | grep -c '^prompt\..*T-B' || true)"
    assert_eq "bg-held-timeout: T-B finished pr" "pr" "$(plan_cell "$tmp/queue.md" 2 8)"
    rm -rf "$tmp"
}


























# N1-478 AC1. Bug caught: § Launch printed $!. With job control, setsid forks, so $! is the setsid parent that already
# exited, and the session watch ended at once ("runner (pid N) is gone"). The launcher must report the pid the runner
# itself wrote to queue.md, on the setsid-fork path and the nohup path, and report nothing when the runner never writes one.
test_launch_pid() {
    local tmp pid got rc; tmp=$(mktemp -d)
    mkdir -p "$tmp/scripts" "$tmp/bin"
    cat > "$tmp/scripts/n1-queue-run.sh" <<'EOF'
source "$R/lib/frontmatter.sh"
[ -n "${NOPID:-}" ] || n1_write_frontmatter "$1" pid "$$"
sleep 30
EOF
    # Fake setsid that always forks and exits at once: what real setsid does when the caller leads its process group.
    printf '#!/usr/bin/env bash\n"$@" &\nexit 0\n' > "$tmp/bin/setsid"; chmod +x "$tmp/bin/setsid"
    # (a) setsid fork: $! is the exited parent.
    printf -- '---\nstep: run\n---\n' > "$tmp/q1.md"
    R="$REPO_ROOT" "$tmp/bin/setsid" bash "$tmp/scripts/n1-queue-run.sh" "$tmp/q1.md" >/dev/null 2>&1 < /dev/null &
    pid=$!
    got=$(n1_queue_launch_pid "$tmp/q1.md" 10)
    assert_eq "launch-pid: setsid fork reports the runner pid, not \$!" "yes" \
        "$([ -n "$got" ] && [ "$got" != "$pid" ] && [ "$got" = "$(n1_read_frontmatter "$tmp/q1.md" pid)" ] && echo yes || echo no)"
    [ -n "$got" ] && { pkill -P "$got" 2>/dev/null; kill "$got" 2>/dev/null; }; wait "$pid" 2>/dev/null || true
    # (b) nohup path (no setsid): the runner pid is $! itself.
    printf -- '---\nstep: run\n---\n' > "$tmp/q2.md"
    R="$REPO_ROOT" nohup bash "$tmp/scripts/n1-queue-run.sh" "$tmp/q2.md" >/dev/null 2>&1 < /dev/null &
    pid=$!
    got=$(n1_queue_launch_pid "$tmp/q2.md" 10)
    assert_eq "launch-pid: nohup path reports the runner pid" "$pid" "$got"
    pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    # (c) the runner never writes a pid: nothing printed, rc 1, after the given tries.
    printf -- '---\nstep: run\n---\n' > "$tmp/q3.md"
    NOPID=1 R="$REPO_ROOT" nohup bash "$tmp/scripts/n1-queue-run.sh" "$tmp/q3.md" >/dev/null 2>&1 < /dev/null &
    pid=$!
    rc=0; got=$(n1_queue_launch_pid "$tmp/q3.md" 2) || rc=$?
    assert_eq "launch-pid: timeout prints nothing and fails" "|1" "$got|$rc"
    pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    # (d) run.md wiring: § Launch uses the helper and no longer trusts $!.
    local md="$REPO_ROOT/skills/n1-queue/steps/run.md"
    assert_eq "launch-pid: run.md reads the pid through n1_queue_launch_pid" "1|0" \
        "$(grep -cF 'RUNNER_PID=$(n1_queue_launch_pid "$QUEUE_FILE")' "$md" || true)|$(grep -cF 'RUNNER_PID=$!' "$md" || true)"
    rm -rf "$tmp"
}


n1_only_filter
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
test_story_repo_read_retry
test_story_refusal_resume
test_story_held_released_after_runner_merge
test_story_dependents_of_ci_red
test_story_no_pin_reason
test_queue_merge_green
test_queue_held_released_after_runner_merge
test_queue_integration_snapshot
test_queue_chain_rebase
test_queue_chain_stops
test_queue_chain_three
test_queue_chain_resume
test_queue_chain_bound
test_queue_chain_run_e2e
test_lifecycle_wiring
test_merge_wording
test_launch_pid

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

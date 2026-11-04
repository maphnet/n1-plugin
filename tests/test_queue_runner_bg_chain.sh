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

test_bg_held_not_launched
test_bg_held_blocker_failed
test_bg_held_user_merge
test_bg_held_merge_at_timeout
test_bg_chain_merges
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
test_lifecycle_wiring
test_merge_wording

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Tests for lib/queue.sh and scripts/n1-queue-run.sh: background-session runner core.
# Shared setup and fixtures: tests/queue_runner_lib.sh (N1-304 split).
set -euo pipefail
source "$(dirname "$0")/queue_runner_lib.sh"

# --- Integration: runner -----------------------------------------------------
test_runner_three_strikes() {
    local tmp; tmp=$(mktemp -d)
    # trap 'rm -rf "$tmp"' RETURN  # keep for debugging on failure

    mk_bg "$tmp" test-q "T-A:done" "T-B:done" "T-C:working"
    printf -- '---\nstep: escalated\n---\n# T\n\n## Escalations\n- blocked\n' > "$tmp/fake/overview.T-B"
    local exit_code; exit_code=$(run_bg_queue "$tmp")

    # T-A: pr, T-B: escalated (consecutive=1), T-C deferred (consecutive=2),
    # T-C retry failed (consecutive=3) -> HALTED
    assert_eq "runner: exit 2 (halted)" "2" "$exit_code"

    local step; step=$(n1_read_frontmatter "$tmp/queue.md" step)
    assert_eq "runner: step halted" "halted" "$step"

    # Check Plan statuses
    local sa; sa=$(awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$8)} $2=="1"{print $8}' "$tmp/queue.md")
    assert_eq "runner: T-A status pr" "pr" "$sa"

    local sb; sb=$(awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$8)} $2=="2"{print $8}' "$tmp/queue.md")
    assert_eq "runner: T-B status escalated" "escalated" "$sb"

    local sc; sc=$(awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$8)} $2=="3"{print $8}' "$tmp/queue.md")
    assert_eq "runner: T-C row 3 deferred" "deferred" "$sc"

    # Row 4 should exist (deferred-retry of T-C) and be failed
    local sd; sd=$(awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$8)} $2=="4"{print $8}' "$tmp/queue.md")
    assert_eq "runner: T-C row 4 failed" "failed" "$sd"

    # Row 4 keeps the deferred-retry marker; no row 5 (defer-once, even on timeout)
    local rd; rd=$(awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$9)} $2=="4"{print $9}' "$tmp/queue.md")
    assert_eq "runner: T-C row 4 reason" "deferred-retry (timeout)" "$rd"
    local r5; r5=$(awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2)} $2=="5"' "$tmp/queue.md")
    assert_eq "runner: no row 5" "" "$r5"
    # Runs rows have exactly 7 cells incl. Session (no phantom trailing cell)
    local bad; bad=$(awk '/^## Runs/{f=1;next} f && /^\| T-/{ if (gsub(/\|/,"|") != 7) print }' "$tmp/queue.md")
    assert_eq "runner: Runs rows have 7 cells" "" "$bad"

    local halted_msg; halted_msg=$(grep -c "HALTED" "$tmp/output.txt" || true)
    assert_eq "runner: HALTED message printed" "1" "$halted_msg"

    assert_eq "events-3s: sequence" \
        "queue_started,ticket_started,ticket_finished,ticket_started,escalated,ticket_finished,ticket_started,ticket_finished,ticket_started,ticket_finished,halted" \
        "$(jq -r .event "$tmp/events.jsonl" | paste -sd, -)"
    assert_eq "events-3s: outcomes" "pr,escalated,deferred,failed" \
        "$(jq -r 'select(.event=="ticket_finished") | .outcome' "$tmp/events.jsonl" | paste -sd, -)"
    assert_eq "events-3s: escalation text" "blocked" \
        "$(jq -r 'select(.event=="escalated") | .reason' "$tmp/events.jsonl")"
    assert_eq "events-3s: escalated event carries outcome=terminal (stopped-path)" "terminal" \
        "$(jq -r 'select(.event=="escalated") | .outcome' "$tmp/events.jsonl")"
    assert_eq "events-3s: uniform schema" "true" "$(jq -s 'all(keys | length == 10)' "$tmp/events.jsonl")"
    assert_eq "notify-3s: needs-you (esc), info (final fail), needs-you (halt); none for pr/deferred" \
        "needs-you,info,needs-you" "$(jq -r .kind "$tmp/notes" | paste -sd, -)"
    assert_eq "notify-3s: halt text" "yes" \
        "$(jq -r 'select(.kind=="needs-you") | .text' "$tmp/notes" | grep -q '^Queue test-q halted: ' && echo yes || echo no)"

    # N1-74: T-B's bg session is stopped on the success-path escalated finalize, and
    # its resume hint points at n1-start (not a stale "claude attach" on a dead session).
    assert_eq "3s: T-B session stopped" "yes" "$(grep -qx 00000002 "$tmp/fake/stopped" && echo yes || echo no)"
    assert_eq "3s: escalated resume hint is n1-start" "yes" \
        "$(jq -r 'select(.kind=="needs-you") | .text' "$tmp/notes" | grep -qF 'resume: n1-start T-B' && echo yes || echo no)"
    assert_eq "3s: no stale attach hint for T-B" "0" \
        "$(jq -r 'select(.kind=="needs-you") | .text' "$tmp/notes" | grep -c 'claude attach' || true)"

    rm -rf "$tmp"
}

test_runner_all_pr() {
    local tmp; tmp=$(mktemp -d)

    mk_bg "$tmp" test-q2 "T-X:done" "T-Y:done"
    local exit_code; exit_code=$(run_bg_queue "$tmp")

    assert_eq "runner-allpr: exit 0" "0" "$exit_code"

    local step; step=$(n1_read_frontmatter "$tmp/queue.md" step)
    assert_eq "runner-allpr: step done" "done" "$step"

    # pid should be removed
    local pid; pid=$(n1_read_frontmatter "$tmp/queue.md" pid)
    assert_eq "runner-allpr: pid removed" "" "$pid"

    assert_eq "events-allpr: sequence" "queue_started,ticket_started,ticket_finished,ticket_started,ticket_finished,queue_done" \
        "$(jq -r .event "$tmp/events.jsonl" | paste -sd, -)"
    assert_eq "events-allpr: pr url" "https://x/pr/1" \
        "$(jq -r 'select(.event=="ticket_finished") | .pr' "$tmp/events.jsonl" | head -1)"
    assert_eq "events-allpr: queue_done digest" "2 PR / 0 awaiting / 0 failed" \
        "$(jq -r 'select(.event=="queue_done") | .reason' "$tmp/events.jsonl")"
    assert_eq "notify-allpr: exactly one done, no per-PR notify" "done|Queue test-q2: 2 PR / 0 awaiting / 0 failed" \
        "$(jq -r '.kind + "|" + .text' "$tmp/notes" | paste -sd, -)"

    rm -rf "$tmp"
}

# NP-199: tag mode forwards N1_QUEUE_TAG, a re-queued ticket's release flag is reset at
# launch, and finalize stamps queue_run_id into overview.md.
test_runner_tag_release() {
    local tmp; tmp=$(mktemp -d)

    mk_bg "$tmp" n1-auto "T-R:done"
    sed -i 's/^queue_id: n1-auto$/&\nmode: tag/' "$tmp/queue.md"
    mkdir -p "$tmp/n1home/memory/T-R"
    printf -- '---\nstep: pr\nqueue_run_id: OLD\nqueue_tag_removed: true\n---\n' > "$tmp/n1home/memory/T-R/overview.md"
    export N1_QUEUE_RELEASE_STUB=/bin/true
    local exit_code; exit_code=$(run_bg_queue "$tmp")
    unset N1_QUEUE_RELEASE_STUB

    assert_eq "tag-release: exit 0" "0" "$exit_code"
    assert_eq "tag-release: child sees N1_QUEUE_TAG" "n1-auto" "$(jq -r .env.N1_QUEUE_TAG "$tmp/fake/settings.n1-n1-auto-T-R-1")"
    assert_eq "queue-dir: child sees absolute N1_QUEUE_DIR" "$(cd "$tmp" && pwd)" "$(jq -r .env.N1_QUEUE_DIR "$tmp/fake/settings.n1-n1-auto-T-R-1")"
    assert_eq "tag-release: flag reset before child starts" "queue_tag_removed: false" "$(cat "$tmp/fake/flag.T-R")"
    assert_eq "tag-release: finalize stamps queue_run_id" \
        "$(n1_read_frontmatter "$tmp/queue.md" run_id)" \
        "$(n1_read_frontmatter "$tmp/n1home/memory/T-R/overview.md" queue_run_id)"

    rm -rf "$tmp"
}

# N1-440: tag-mode queue_id carries a per-plan suffix; children get the tag from frontmatter `tag`.
test_runner_tag_attr() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" n1-auto-20261106T101530Z "T-R:done"
    sed -i 's/^queue_id: n1-auto-20261106T101530Z$/&\nmode: tag\ntag: n1-auto/' "$tmp/queue.md"
    mkdir -p "$tmp/n1home/memory/T-R"
    printf -- '---\nstep: pr\n---\n' > "$tmp/n1home/memory/T-R/overview.md"
    export N1_QUEUE_RELEASE_STUB=/bin/true
    local exit_code; exit_code=$(run_bg_queue "$tmp")
    unset N1_QUEUE_RELEASE_STUB
    assert_eq "tag-attr: exit 0" "0" "$exit_code"
    assert_eq "tag-attr: child sees N1_QUEUE_TAG from frontmatter tag" "n1-auto" \
        "$(jq -r .env.N1_QUEUE_TAG "$tmp/fake/settings.n1-n1-auto-20261106T101530Z-T-R-1")"
    rm -rf "$tmp"
}

# NP-199 (CCR fix): report.md's release wiring only runs on --status/--watch. Without
# an automatic backstop, a failed tag-mode ticket's tag would stay attached until a
# human happens to check. The runner must fire the backstop itself when the run ends.
test_runner_auto_release_backstop() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" n1-auto "T-F:failed"
    sed -i 's/^queue_id: n1-auto$/&\nmode: tag/' "$tmp/queue.md"
    cat > "$tmp/release-seen.sh" <<WEOF2
#!/usr/bin/env bash
printf '%s\n' "\$1" > "$tmp/release-called"
WEOF2
    chmod +x "$tmp/release-seen.sh"
    export N1_QUEUE_RELEASE_STUB="$tmp/release-seen.sh"
    run_bg_queue "$tmp" >/dev/null
    unset N1_QUEUE_RELEASE_STUB

    assert_eq "auto-release: backstop fired for a failed tag-mode row" "n1-auto" \
        "$(cat "$tmp/release-called" 2>/dev/null || echo "not called")"

    rm -rf "$tmp"
}

# NP-199 (CCR fix): halt() exits the process directly (exit 2), bypassing the normal
# "Done" tail — the backstop must also fire from inside halt() or a halted run's
# tickets never get released either.
test_runner_release_backstop_on_halt() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" n1-auto "T-1:done" "T-2:done" "T-3:done"
    sed -i 's/^queue_id: n1-auto$/&\nmode: tag/' "$tmp/queue.md"
    printf -- '---\nstep: escalated\n---\n# T\n\n## Escalations\n- blocked\n' > "$tmp/fake/overview.T-1"
    printf -- '---\nstep: escalated\n---\n# T\n\n## Escalations\n- blocked\n' > "$tmp/fake/overview.T-2"
    printf -- '---\nstep: escalated\n---\n# T\n\n## Escalations\n- blocked\n' > "$tmp/fake/overview.T-3"
    cat > "$tmp/release-seen.sh" <<WEOF2
#!/usr/bin/env bash
printf '%s\n' "\$1" > "$tmp/release-called"
WEOF2
    chmod +x "$tmp/release-seen.sh"
    export N1_QUEUE_RELEASE_STUB="$tmp/release-seen.sh"
    local exit_code; exit_code=$(run_bg_queue "$tmp")
    unset N1_QUEUE_RELEASE_STUB

    assert_eq "auto-release-halt: runner halted" "2" "$exit_code"
    assert_eq "auto-release-halt: backstop still fired" "n1-auto" \
        "$(cat "$tmp/release-called" 2>/dev/null || echo "not called")"

    rm -rf "$tmp"
}

# N1-423: a list queue (mode: list) is untagged: children get no N1_QUEUE_TAG and the
# tag-release backstop never fires, even for a failed row.
test_runner_list_mode_untagged() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" list-0a1b2c3d "T-R:done" "T-F:failed"
    sed -i 's/^queue_id: list-0a1b2c3d$/&\nmode: list/' "$tmp/queue.md"
    cat > "$tmp/release-seen.sh" <<WEOF2
#!/usr/bin/env bash
printf '%s\n' "\$1" > "$tmp/release-called"
WEOF2
    chmod +x "$tmp/release-seen.sh"
    export N1_QUEUE_RELEASE_STUB="$tmp/release-seen.sh"
    run_bg_queue "$tmp" >/dev/null
    unset N1_QUEUE_RELEASE_STUB

    local st="$tmp/fake/settings.n1-list-0a1b2c3d-T-R-1"
    assert_eq "list-mode: child launched" "yes" "$([ -f "$st" ] && echo yes || echo no)"
    assert_eq "list-mode: child gets no N1_QUEUE_TAG" "" "$(jq -r '.env.N1_QUEUE_TAG // ""' "$st" 2>/dev/null)"
    assert_eq "list-mode: no tag-release backstop" "not called" \
        "$(cat "$tmp/release-called" 2>/dev/null || echo "not called")"

    rm -rf "$tmp"
}

test_bg_sequential() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working working done" "T-B:done"
    assert_eq "bg-seq: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-seq: step done" "done" "$(n1_read_frontmatter "$tmp/queue.md" step)"
    assert_eq "bg-seq: pid removed" "" "$(n1_read_frontmatter "$tmp/queue.md" pid)"
    assert_eq "bg-seq: T-A pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-seq: T-B pr" "pr" "$(plan_cell "$tmp/queue.md" 2 8)"
    local a_done b_launch
    a_done=$(line_of "$tmp/fake/events" "state n1-bgq-T-A-1 done")
    b_launch=$(line_of "$tmp/fake/events" "launch n1-bgq-T-B-2")
    assert_eq "bg-seq: T-B launched only after T-A finished" "yes" \
        "$([ -n "$a_done" ] && [ -n "$b_launch" ] && [ "$b_launch" -gt "$a_done" ] && echo yes || echo no)"
    assert_eq "bg-seq: launch flags" "yes" \
        "$(case "$(cat "$tmp/fake/args.n1-bgq-T-A-1")" in *"--model sonnet --permission-mode bypassPermissions --settings "*) echo yes ;; *) echo no ;; esac)"
    assert_eq "bg-seq: prompt" "/n1:n1-start T-A" "$(cat "$tmp/fake/prompt.n1-bgq-T-A-1")"
    assert_eq "bg-seq: settings env + isolation" "1,ask,none" \
        "$(jq -r '[.env.N1_HEADLESS,.env.N1_UNATTENDED,.worktree.bgIsolation]|join(",")' "$tmp/fake/settings.n1-bgq-T-A-1")"
    assert_eq "bg-seq: no N1_HOST in settings" "false" "$(jq -r '.env|has("N1_HOST")' "$tmp/fake/settings.n1-bgq-T-A-1")"
    assert_eq "bg-seq: run id in settings" "$(n1_read_frontmatter "$tmp/queue.md" run_id)" \
        "$(jq -r .env.N1_QUEUE_RUN_ID "$tmp/fake/settings.n1-bgq-T-A-1")"
    assert_eq "bg-seq: session id stored" "00000001" "$(n1_queue_session_id "$tmp/queue.md" T-A)"
    assert_eq "bg-seq: PR url recorded" "https://x/pr/1" \
        "$(awk -F'|' '/^## Runs/{f=1;next} f && $2 ~ /T-A/ { gsub(/ /,"",$6); print $6 }' "$tmp/queue.md")"
    local bad; bad=$(awk '/^## Runs/{f=1;next} f && /^\| T-/{ if (gsub(/\|/,"|") != 7) print }' "$tmp/queue.md")
    assert_eq "bg-seq: Runs rows have 7 cells" "" "$bad"
    # N1-74: success-path finalize must stop each finished child's bg session.
    assert_eq "bg-seq: both sessions stopped" "00000001,00000002" "$(paste -sd, "$tmp/fake/stopped")"
    rm -rf "$tmp"
}

# N1-470. Bug caught: a child that ended step done with no pr_url was recorded pr with an empty PR cell and the
# fullAuto finish chain ran on the empty URL (Reason finish:pr-state-unreadable). Now: no-pr everywhere, one info
# notification naming the ticket and its gate3.md, no chain, the queue ends.
test_bg_no_pr() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:done" "T-B:done"
    printf -- '---\nstep: done\n---\n# T\n' > "$tmp/fake/overview.T-A"
    jq '.autonomy.fullAuto = true | .finishWork.mergeOnFinish = true' "$tmp/n1home/config.json" > "$tmp/cfg" && mv "$tmp/cfg" "$tmp/n1home/config.json"
    assert_eq "bg-no-pr: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-no-pr: queue step done" "done" "$(n1_read_frontmatter "$tmp/queue.md" step)"
    assert_eq "bg-no-pr: Plan status no-pr, Reason empty (no chain)" "no-pr|" "$(plan_cell "$tmp/queue.md" 1 8)|$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "bg-no-pr: Runs outcome" "no-pr" "$(runs_outcome "$tmp/queue.md" T-A)"
    assert_eq "bg-no-pr: event outcome" "no-pr" \
        "$(jq -R -r 'fromjson? | select(.event == "ticket_finished" and .ticket == "T-A") | .outcome' "$tmp/events.jsonl")"
    assert_eq "bg-no-pr: one notification naming ticket and gate3.md" "1" \
        "$(jq -r 'select(.kind == "info") | .text' "$tmp/notes" | grep -c '^T-A ended without a PR (see .*/memory/T-A/gate3\.md)$' || true)"
    assert_eq "bg-no-pr: next row still runs" "T-B" "$(grep -o 'launch n1-bgq-T-B-[0-9]*' "$tmp/fake/events" | head -1 | sed 's/launch n1-bgq-//; s/-[0-9]*$//')"
    rm -rf "$tmp"
}

test_bg_awaiting_alternatives() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked blocked working done" "T-B:working done"
    # N1-216: alternatives survive packing (strip + per-field cap like options), so the
    # watch fallback can render them after the question file is removed.
    printf '{"ticket":"T-A","question":"Pick a DB?","options":["A","B"],"recommended":"A","rationale":"faster","alternatives":{"B":"works when\\u0007 the team runs B"}}' \
        > "$tmp/.question-T-A.json"
    assert_eq "bg-await-alt: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "N1-216: escalated event carries alternatives, control chars stripped" "works when  the team runs B" \
        "$(jq -r 'select(.event=="escalated") | (.reason | fromjson?) | .alternatives.B' "$tmp/events.jsonl")"
    rm -rf "$tmp"
}

test_bg_awaiting() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked blocked working done" "T-B:working done"
    # N1-60: a mirrored question present when the ticket first parks must be packed into the
    # escalated event's reason, durably, even though the file itself is later removed.
    printf '{"ticket":"T-A","question":"Pick a DB?","options":["A","B"],"recommended":"A","rationale":"faster"}' \
        > "$tmp/.question-T-A.json"
    assert_eq "bg-await: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "N1-60: escalated event carries full mirrored question" "Pick a DB?" \
        "$(jq -r 'select(.event=="escalated") | (.reason | fromjson?) | .question' "$tmp/events.jsonl")"
    assert_eq "N1-60: escalated event carries options" "A,B" \
        "$(jq -r 'select(.event=="escalated") | (.reason | fromjson?) | .options | join(",")' "$tmp/events.jsonl")"
    assert_eq "N1-60: escalated event carries recommended/rationale" "A|faster" \
        "$(jq -r 'select(.event=="escalated") | (.reason | fromjson?) | "\(.recommended)|\(.rationale)"' "$tmp/events.jsonl")"
    assert_eq "N1-216: payload without alternatives packs without the key" "false" \
        "$(jq -r 'select(.event=="escalated") | (.reason | fromjson?) | has("alternatives")' "$tmp/events.jsonl")"
    # Removing the mirrored question file (as the answer path does) does not touch the
    # already-written durable record.
    rm -f "$tmp/.question-T-A.json"
    assert_eq "N1-60: record survives question-file removal" "Pick a DB?" \
        "$(jq -r 'select(.event=="escalated") | (.reason | fromjson?) | .question' "$tmp/events.jsonl")"
    assert_eq "bg-await: T-A parked message" "1" "$(grep -c 'T-A -> awaiting-human' "$tmp/output.txt" || true)"
    local a_block b_launch a_done
    a_block=$(line_of "$tmp/fake/events" "state n1-bgq-T-A-1 blocked")
    b_launch=$(line_of "$tmp/fake/events" "launch n1-bgq-T-B-2")
    a_done=$(line_of "$tmp/fake/events" "state n1-bgq-T-A-1 done")
    assert_eq "bg-await: T-B launched while T-A parked" "yes" \
        "$([ -n "$a_block" ] && [ -n "$b_launch" ] && [ -n "$a_done" ] && [ "$a_block" -lt "$b_launch" ] && [ "$b_launch" -lt "$a_done" ] && echo yes || echo no)"
    assert_eq "bg-await: T-A pr after answer" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-await: T-B pr" "pr" "$(plan_cell "$tmp/queue.md" 2 8)"
    assert_eq "bg-await: no retry row" "" "$(plan_cell "$tmp/queue.md" 3 8)"
    assert_eq "bg-await: step done" "done" "$(n1_read_frontmatter "$tmp/queue.md" step)"
    assert_eq "events-await: T-A lifecycle" "ticket_started,escalated,unblocked,ticket_finished" \
        "$(jq -r 'select(.ticket=="T-A") | .event' "$tmp/events.jsonl" | paste -sd, -)"
    assert_eq "events-await: session on ticket_started" "00000001" \
        "$(jq -r 'select(.ticket=="T-A" and .event=="ticket_started") | .session' "$tmp/events.jsonl")"
    assert_eq "notify-await: needs-you then done" "needs-you,done" "$(jq -r .kind "$tmp/notes" | paste -sd, -)"
    assert_eq "notify-await: attach hint" "yes" \
        "$(jq -r 'select(.kind=="needs-you") | .text' "$tmp/notes" | grep -qF '(resume: claude attach 00000001)' && echo yes || echo no)"
    rm -rf "$tmp"
}

test_bg_awaiting_oversized_question() {
    # N1-60 [SEC-1]/[CR-2]: a mirrored question file far bigger than execve's 128 KiB per-arg
    # limit must still produce a valid, bounded escalated row (not a dropped/truncated one).
    local tmp big; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked blocked working done"
    big=$(head -c 200000 /dev/zero | tr '\0' 'x')
    { printf '{"question":"%s","options":["%s","%s"],"recommended":"A","rationale":"%s"}' \
        "$big" "$big" "$big" "$big"; } > "$tmp/.question-T-A.json"
    assert_eq "bg-await-big: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-await-big: escalated row is valid JSON" "escalated" \
        "$(jq -r 'select(.event=="escalated") | .event' "$tmp/events.jsonl")"
    assert_eq "bg-await-big: reason is valid JSON, bounded" "2000,2000" \
        "$(jq -r 'select(.event=="escalated") | (.reason | fromjson) | "\(.question|length),\(.rationale|length)"' "$tmp/events.jsonl")"
    assert_eq "bg-await-big: options capped at 10, each bounded" "2,2000" \
        "$(jq -r 'select(.event=="escalated") | (.reason | fromjson) | "\(.options|length),\(.options[0]|length)"' "$tmp/events.jsonl")"
    rm -rf "$tmp"
}

test_bg_awaiting_oversized_control_chars() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked blocked working done"
    mk_oversized_question "$tmp" T-A '\u0001'
    assert_eq "bg-await-ctrl: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-await-ctrl: escalated row is valid JSON" "escalated" \
        "$(jq -r 'select(.event=="escalated") | .event' "$tmp/events.jsonl")"
    assert_eq "bg-await-ctrl: packed reason is valid JSON" "ok" \
        "$(jq -r 'select(.event=="escalated") | (.reason | fromjson | if . then "ok" else "bad" end)' "$tmp/events.jsonl")"
    assert_eq "bg-await-ctrl: control chars stripped, cap unaffected" "2000,2000" \
        "$(jq -r 'select(.event=="escalated") | (.reason | fromjson) | "\(.question|length),\(.rationale|length)"' "$tmp/events.jsonl")"
    assert_eq "bg-await-ctrl: packed reason stays within the 32 KiB budget" "yes" \
        "$(jq -r 'select(.event=="escalated") | (.reason | (utf8bytelength < 32768 | if . then "yes" else "no" end))' "$tmp/events.jsonl")"
    rm -rf "$tmp"
}

test_bg_awaiting_oversized_emoji() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked blocked working done"
    mk_oversized_question "$tmp" T-A "$(printf '\xf0\x9f\x98\x80')"
    assert_eq "bg-await-emoji: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-await-emoji: escalated row is valid JSON" "escalated" \
        "$(jq -r 'select(.event=="escalated") | .event' "$tmp/events.jsonl")"
    assert_eq "bg-await-emoji: packed reason is valid JSON" "ok" \
        "$(jq -r 'select(.event=="escalated") | (.reason | fromjson | if . then "ok" else "bad" end)' "$tmp/events.jsonl")"
    # 4-byte UTF-8 at the normal 2000-char cap would still blow past the 32 KiB
    # budget, so the fallback shrinks the per-field cap to 200.
    assert_eq "bg-await-emoji: per-field cap shrunk by the byte-size fallback" "200,200" \
        "$(jq -r 'select(.event=="escalated") | (.reason | fromjson) | "\(.question|length),\(.rationale|length)"' "$tmp/events.jsonl")"
    assert_eq "bg-await-emoji: packed reason stays within the 32 KiB budget" "yes" \
        "$(jq -r 'select(.event=="escalated") | (.reason | (utf8bytelength < 32768 | if . then "yes" else "no" end))' "$tmp/events.jsonl")"
    rm -rf "$tmp"
}

test_bg_awaiting_timeout() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked"
    assert_eq "bg-await-to: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-await-to: step done" "done" "$(n1_read_frontmatter "$tmp/queue.md" step)"
    assert_eq "bg-await-to: row stays awaiting-human" "awaiting-human" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-await-to: no retry row" "" "$(plan_cell "$tmp/queue.md" 2 8)"
    assert_eq "bg-await-to: session not stopped" "no" "$([ -f "$tmp/fake/stopped" ] && echo yes || echo no)"
    assert_eq "bg-await-to: single launch" "1" "$(grep -c '^launch' "$tmp/fake/events" || true)"
    assert_eq "bg-await-to: resume hint" "T-A: claude attach 00000001" "$(n1_queue_awaiting_hints "$tmp/queue.md")"
    assert_eq "events-await-to: digest counts awaiting" "0 PR / 1 awaiting / 0 failed" \
        "$(jq -r 'select(.event=="queue_done") | .reason' "$tmp/events.jsonl")"
    rm -rf "$tmp"
}

test_bg_working_timeout() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working"
    assert_eq "bg-wto: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-wto: row 1 deferred" "deferred" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-wto: row 2 failed" "failed" "$(plan_cell "$tmp/queue.md" 2 8)"
    assert_eq "bg-wto: row 2 reason" "deferred-retry (timeout)" "$(plan_cell "$tmp/queue.md" 2 9)"
    assert_eq "bg-wto: no row 3" "" "$(plan_cell "$tmp/queue.md" 3 8)"
    assert_eq "bg-wto: retry uses a new session name" "yes" "$([ -f "$tmp/fake/settings.n1-bgq-T-A-2" ] && echo yes || echo no)"
    assert_eq "bg-wto: both sessions stopped" "00000001,00000002" "$(paste -sd, "$tmp/fake/stopped")"
    rm -rf "$tmp"
}

test_bg_missing_grace() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq
    # subtaskTimeoutMinutes large enough that the working-timeout path never preempts
    # the missing-session grace (BG_POLL_GRACE=10 polls) below.
    echo '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":600,"notify":"none"}}' > "$tmp/n1home/config.json"
    # The defer-once retry (row 2) launches for real; give it a states file so it
    # resolves immediately instead of chaining another grace period.
    printf 'done\n' > "$tmp/fake/states.T-X"
    cat > "$tmp/queue.md" <<EOF
---
step: plan
queue_id: bgq
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-X | Fix X | $tmp | $tmp/n1home | sonnet | in-progress | |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
| T-X | | | | | ffffffff |
EOF
    assert_eq "bg-miss: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-miss: row 1 deferred" "deferred" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-miss: row 1 reason" "bg-session-not-listed" "$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "bg-miss: row 2 pr (retry succeeds)" "pr" "$(plan_cell "$tmp/queue.md" 2 8)"
    rm -rf "$tmp"
}

# --- NP-216: overview.md reconciliation, non-empty reasons, notify check -----

test_bg_reconcile_working() {
    local tmp; tmp=$(mktemp -d)
    # N1-74: one extra "working" poll after the overview reaches pr, then "done" — the
    # runner must defer the stop until the bg session itself goes idle.
    mk_bg "$tmp" bgq "T-A:working done"
    echo '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":0,"notify":"none"}}' > "$tmp/n1home/config.json"
    mkdir -p "$tmp/n1home/memory/T-A"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/9\n' > "$tmp/n1home/memory/T-A/overview.md"
    assert_eq "bg-recw: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-recw: row 1 pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-recw: PR url recorded" "https://x/pr/9" \
        "$(awk -F'|' '/^## Runs/{f=1;next} f && $2 ~ /T-A/ { gsub(/ /,"",$6); print $6 }' "$tmp/queue.md")"
    assert_eq "bg-recw: no deferred-retry row" "" "$(plan_cell "$tmp/queue.md" 2 8)"
    # N1-74: the bg session is stopped once the success-path finalize runs.
    assert_eq "bg-recw: session stopped" "00000001" "$(cat "$tmp/fake/stopped" 2>/dev/null || true)"
    rm -rf "$tmp"
}

test_bg_drain_defers_until_idle() {
    # N1-74 [SEC-1]: a child's overview can reach a terminal step while its bg session is
    # still "working" (CI watch/finish/finalize) or "blocked" (a question is waiting) — the
    # runner must not stop it until the session itself goes idle (done/failed), and must
    # never stop a blocked one at all.
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working working done" "T-B:blocked"
    printf '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":5,"notify":"command","notifyCommand":"cat >> %s/notes"}}\n' "$tmp" > "$tmp/n1home/config.json"
    mkdir -p "$tmp/n1home/memory/T-A" "$tmp/n1home/memory/T-B"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/9\n' > "$tmp/n1home/memory/T-A/overview.md"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/9\n' > "$tmp/n1home/memory/T-B/overview.md"
    assert_eq "drain: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "drain: only the idle (done) session is stopped" "00000001" "$(cat "$tmp/fake/stopped" 2>/dev/null || true)"
    assert_eq "drain: the still-blocked session is left running" "yes" \
        "$(grep -q 'left running' "$tmp/output.txt" && grep -qF 00000002 "$tmp/output.txt" && echo yes || echo no)"
    # N1-76: a drained session that blocks is escalated exactly once, across the run's
    # several polls (subtaskTimeoutMinutes=5 / pollSeconds=30 => T-B stays blocked for ~10 polls).
    assert_eq "drain: T-B escalated exactly once" "1" \
        "$(jq -c 'select(.event == "escalated" and .ticket == "T-B")' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    assert_eq "drain: T-B needs-you notify uses the attach hint, not resume: n1-start" "1" \
        "$(jq -r 'select(.kind == "needs-you") | .text' "$tmp/notes" | grep -c 'T-B needs you.*resume: claude attach')"
    # N1-76: timeout break path also fires one leftover needs-you notify naming T-B.
    assert_eq "drain: timeout break fires one leftover needs-you notify for T-B" "1" \
        "$(jq -r 'select(.kind == "needs-you") | .text' "$tmp/notes" | grep -c '^still finishing up: T-B$')"
    rm -rf "$tmp"
}

test_bg_drain_rearms_after_answer() {
    # N1-76: blocked -> answered (working) -> blocked again escalates the second question too.
    # The first state is consumed by run_bg's pre-finalize poll, before T-B enters DRAIN.
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-B:working blocked working blocked"
    printf '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":5,"notify":"none"}}\n' > "$tmp/n1home/config.json"
    mkdir -p "$tmp/n1home/memory/T-B"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/9\n' > "$tmp/n1home/memory/T-B/overview.md"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "drain: re-blocked T-B escalated once per question" "2" \
        "$(jq -c 'select(.event == "escalated" and .ticket == "T-B")' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    # N1-241: the drain back-to-working transition emits unblocked so the watch dedupe resets too.
    assert_eq "drain: back-to-working emits unblocked for T-B" "1" \
        "$(jq -c 'select(.event == "unblocked" and .ticket == "T-B")' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    rm -rf "$tmp"
}

# N1-241: a child blocked after its PR whose overview only holds autonomous records under
# ## Escalations surfaces once with an empty reason, never "Plan review: ..." / "auto-decided".
test_bg_drain_benign_reason() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-B:working blocked"
    printf '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":5,"notify":"none"}}\n' > "$tmp/n1home/config.json"
    mkdir -p "$tmp/n1home/memory/T-B"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/9\n\n## Key Decisions\n\n## Escalations\n- Plan review: FIXED - tightened Task 3\n- Approach A auto-decided (21/25)\n' > "$tmp/n1home/memory/T-B/overview.md"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "benign-drain: one escalated event" "1" \
        "$(jq -c 'select(.event == "escalated" and .ticket == "T-B")' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    assert_eq "benign-drain: reason carries no autonomous record" "" \
        "$(jq -r 'select(.event == "escalated" and .ticket == "T-B") | .reason' "$tmp/events.jsonl")"
    rm -rf "$tmp"

    # AC1 regression guard: plan review FIXED + auto-decided and a child that just finishes -> no escalated event.
    tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-C:working done"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/3\n\n## Key Decisions\n\n## Escalations\n- Plan review: FIXED - tightened Task 3\n- Approach A auto-decided (21/25)\n' > "$tmp/fake/overview.T-C"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "benign-done: no escalated event" "0" \
        "$(jq -c 'select(.event == "escalated")' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    assert_eq "benign-done: row pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    rm -rf "$tmp"
}

# N1-241: park (blocked) -> overview reaches step pr while still blocked -> drain. The same
# escalation must not be emitted twice. A stale marker from an earlier run is cleared at launch.
test_bg_escalation_dedupe() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked blocked blocked"
    printf '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":5,"notify":"none"}}\n' > "$tmp/n1home/config.json"
    printf -- '---\nstep: implementation\n---\n# T\n\n## Escalations\n- [headless] plan: pick A or B\n' > "$tmp/fake/overview.T-A.1"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/1\n\n## Escalations\n- [headless] plan: pick A or B\n' > "$tmp/fake/overview.T-A.2"
    printf '%s' '[headless] plan: pick A or B' > "$tmp/.esc-reason-T-A"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "esc-dedupe: park then drain escalates once" "1" \
        "$(jq -c 'select(.event == "escalated" and .ticket == "T-A")' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    assert_eq "esc-dedupe: reason is the headless entry" "[headless] plan: pick A or B" \
        "$(jq -r 'select(.event == "escalated" and .ticket == "T-A") | .reason' "$tmp/events.jsonl" | head -1)"
    rm -rf "$tmp"
}

# N1-241: same as above, but the child mirrored a question file at park time (reason packed from
# it) and finalize removes it before drain; the drain escalate must still dedupe on the overview text.
test_bg_escalation_dedupe_question_file() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked blocked blocked"
    printf '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":5,"notify":"none"}}\n' > "$tmp/n1home/config.json"
    printf -- '---\nstep: implementation\n---\n# T\n\n## Escalations\n- [headless] plan: pick A or B\n' > "$tmp/fake/overview.T-A.1"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/1\n\n## Escalations\n- [headless] plan: pick A or B\n' > "$tmp/fake/overview.T-A.2"
    printf '{"question":"Pick A or B?","options":["A","B"]}' > "$tmp/.question-T-A.json"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "esc-dedupe-qfile: park then drain escalates once" "1" \
        "$(jq -c 'select(.event == "escalated" and .ticket == "T-A")' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    rm -rf "$tmp"
}

# N1-241 SEC-1: a terminal escalation (state "stopped") or an appended entry is not swallowed by an
# earlier park escalation whose first-entry text is unchanged.
test_bg_escalation_rearm_on_new_entry() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked blocked blocked"
    printf '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":5,"notify":"none"}}\n' > "$tmp/n1home/config.json"
    printf -- '---\nstep: implementation\n---\n# T\n\n## Escalations\n- [headless] plan: pick A or B\n' > "$tmp/fake/overview.T-A.1"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/1\n\n## Escalations\n- [headless] plan: pick A or B\n- [headless] pr: second stop\n' > "$tmp/fake/overview.T-A.2"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "esc-rearm: appended entry re-emits" "2" \
        "$(jq -c 'select(.event == "escalated" and .ticket == "T-A")' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    # CR-4: the re-armed event carries the new entry, so the watch's ticket+reason dedupe relays it.
    assert_eq "esc-rearm: re-armed event has a distinct reason" "2" \
        "$(jq -r 'select(.event == "escalated" and .ticket == "T-A") | .reason' "$tmp/events.jsonl" | sort -u | wc -l | tr -d ' ')"
    rm -rf "$tmp"
}

test_bg_halt_drains() {
    # N1-74 [CR-1]: a halt (three escalated strikes) must still drain the session whose
    # finalize tripped it, not exit with it resident.
    local tmp t; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:done" "T-B:done" "T-C:done"
    for t in T-A T-B T-C; do
        printf -- '---\nstep: escalated\n---\n# T\n\n## Escalations\n- blocked\n' > "$tmp/fake/overview.$t"
    done
    assert_eq "halt-drain: exit 2" "2" "$(run_bg_queue "$tmp")"
    assert_eq "halt-drain: halting child's session stopped" "yes" \
        "$(grep -qx 00000003 "$tmp/fake/stopped" 2>/dev/null && echo yes || echo no)"
    assert_eq "halt-drain: pid stripped after drain" "" "$(n1_read_frontmatter "$tmp/queue.md" pid)"
    rm -rf "$tmp"
}

test_bg_drain_stop_retries_on_failure() {
    # N1-74 [CR-2]: a failed stop must not drop the sid from DRAIN — it's retried on the
    # next tick instead of leaking a running session.
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:done"
    echo '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":1,"notify":"none"}}' > "$tmp/n1home/config.json"
    mkdir -p "$tmp/n1home/memory/T-A"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/9\n' > "$tmp/n1home/memory/T-A/overview.md"
    touch "$tmp/fake/stopfail.00000001"
    assert_eq "drain-retry: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "drain-retry: first stop attempt failed" "00000001" "$(cat "$tmp/fake/stopfail-log" 2>/dev/null || true)"
    assert_eq "drain-retry: retried and eventually stopped" "00000001" "$(cat "$tmp/fake/stopped" 2>/dev/null || true)"
    rm -rf "$tmp"
}

test_bg_reconcile_missing() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:missing missing missing"
    echo '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":0,"notify":"none"}}' > "$tmp/n1home/config.json"
    mkdir -p "$tmp/n1home/memory/T-A"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/9\n' > "$tmp/n1home/memory/T-A/overview.md"
    assert_eq "bg-recm: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-recm: row 1 pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-recm: no deferred-retry row" "" "$(plan_cell "$tmp/queue.md" 2 8)"
    rm -rf "$tmp"
}

test_bg_reconcile_working_stale_escalation() {
    # CR-1 regression: a still-working child with a non-terminal step and a stale
    # (append-only, ask-mode) ## Escalations entry must not be finalized as
    # "escalated" mid-run — it should be reconciled as "pr" once it truly finishes.
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working working done"
    echo '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":1,"notify":"none"}}' > "$tmp/n1home/config.json"
    mkdir -p "$tmp/n1home/memory/T-A"
    printf -- '---\nstep: qa\n---\n# T\n\n## Escalations\n- [asked] resolved, continuing\n' > "$tmp/n1home/memory/T-A/overview.md"
    assert_eq "bg-recw-stale: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-recw-stale: row 1 pr (not escalated)" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    rm -rf "$tmp"
}

test_bg_blocked_first_tick_parks() {
    # CR-2 second variant: bg state blocked on the first tick, before the child has
    # written any ## Escalations entry, still parks as awaiting-human (unaffected).
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked blocked working done"
    mkdir -p "$tmp/n1home/memory/T-A"
    printf -- '---\nstep: implementation\n---\n# T\n' > "$tmp/n1home/memory/T-A/overview.md"
    assert_eq "bg-blocked-first: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-blocked-first: parked message" "1" "$(grep -c 'T-A -> awaiting-human' "$tmp/output.txt" || true)"
    assert_eq "bg-blocked-first: row 1 pr after answer" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    rm -rf "$tmp"
}

test_bg_reason_child_exited_incomplete() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:done"
    echo '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":1,"notify":"none"}}' > "$tmp/n1home/config.json"
    echo "developer" > "$tmp/fake/finish-step.T-A"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "bg-reason-exited: row 1 deferred" "deferred" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-reason-exited: row 1 reason" "child-exited-incomplete" "$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
}

test_bg_reason_bg_state_catchall() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:zzz"
    echo '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":1,"notify":"none"}}' > "$tmp/n1home/config.json"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "bg-reason-catchall: row 1 deferred" "deferred" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-reason-catchall: row 1 reason" "bg-state:failed" "$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"
}

# N1-55: n1_queue_answer stops then bg-resumes a parked child; a fresh relay marker must keep the
# runner from finalizing that gap (stopped -> failed, missing -> grace burn), a stale one must not.
test_bg_relay_marker() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked stopped missing working done"
    echo '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":2,"notify":"none"}}' > "$tmp/n1home/config.json"
    touch "$tmp/fake/relay.T-A" "$tmp/.question-T-A.json"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "relay: fresh marker holds stopped/missing child" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "relay: resumed child unblocks and finishes" "ticket_started,escalated,unblocked,ticket_finished" \
        "$(jq -r 'select(.ticket=="T-A") | .event' "$tmp/events.jsonl" | paste -sd, -)"
    assert_eq "relay: finalize removes marker + question file (CR-5)" "no" \
        "$([ -e "$tmp/.relay-T-A" ] || [ -e "$tmp/.question-T-A.json" ] && echo yes || echo no)"
    rm -rf "$tmp"

    # TTL boundary (TQ-1): just under 2 minutes holds, just past 2 minutes does not.
    tmp=$(mktemp -d)
    touch -d '-110 seconds' "$tmp/.relay-T-A"
    assert_eq "relay: marker at 110s active" "yes" "$(n1_queue_relay_active "$tmp" T-A && echo yes || echo no)"
    touch -d '-125 seconds' "$tmp/.relay-T-A"
    assert_eq "relay: marker at 125s expired" "no" "$(n1_queue_relay_active "$tmp" T-A && echo yes || echo no)"
    mk_bg "$tmp" bgq "T-A:blocked stopped"
    touch -d '-125 seconds' "$tmp/fake/relay.T-A"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "relay: just-expired marker -> normal finalize" "deferred" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "relay: just-expired marker reason" "bg-state:failed" "$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"

    # SEC-3: a marker kept fresh cannot hold a dead child past the subtask timeout.
    tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked stopped"
    touch -d '+1 hour' "$tmp/fake/relay.T-A"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "relay: refreshed marker still times out" "timeout" "$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp"

    # CR-1: a resumed child re-blocking on a new question before any poll sees it working is
    # escalated again (question file newer than the relay marker).
    tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked stopped blocked working done"
    echo '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":2,"notify":"none"}}' > "$tmp/n1home/config.json"
    touch -d '-30 seconds' "$tmp/fake/relay.T-A"; touch "$tmp/.question-T-A.json"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "relay: re-block escalates twice" "ticket_started,escalated,escalated,unblocked,ticket_finished" \
        "$(jq -r 'select(.ticket=="T-A") | .event' "$tmp/events.jsonl" | paste -sd, -)"
    assert_eq "relay: re-block ends pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    rm -rf "$tmp"

    # CR-7 (TQ-2): a second question after the child was seen working escalates exactly once;
    # the first-park branch drops the stale relay marker from the previous answer.
    tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked stopped working blocked blocked working done"
    echo '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":2,"notify":"none"}}' > "$tmp/n1home/config.json"
    touch -d '-30 seconds' "$tmp/fake/relay.T-A"; touch "$tmp/.question-T-A.json"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "relay: second question after working escalates once" \
        "ticket_started,escalated,unblocked,escalated,unblocked,ticket_finished" \
        "$(jq -r 'select(.ticket=="T-A") | .event' "$tmp/events.jsonl" | paste -sd, -)"
    rm -rf "$tmp"

    # TQ-2: a relay marker newer than the question means no new question -> no re-escalation.
    tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked stopped blocked blocked working done"
    echo '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":2,"notify":"none"}}' > "$tmp/n1home/config.json"
    touch -d '-30 seconds' "$tmp/.question-T-A.json"; touch "$tmp/fake/relay.T-A"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "relay: marker newer than question -> single escalation" \
        "ticket_started,escalated,unblocked,ticket_finished" \
        "$(jq -r 'select(.ticket=="T-A") | .event' "$tmp/events.jsonl" | paste -sd, -)"
    rm -rf "$tmp"
}

# N1-77: n1_queue_relay_active's `find` runs between the stale OUTCOME read and the timeout
# stop; a fake find flips overview.md to step: pr there, on the poll where the timeout fires.
# N1-76 follow-up: a 4th poll then reports "blocked" after the ticket already drained into
# DRAIN via timeout_stop (not the run_bg per-row escalate), so the only way the escalation
# below carries ticket=T-A is if DRAIN's timeout_stop push kept the sid<TAB>ticket<TAB>n1home
# tuple shape the other DRAIN push and its consumers (drain_stop) expect.
test_bg_timeout_race_terminal_overview() {
    local tmp real_find; tmp=$(mktemp -d); real_find=$(command -v find)
    # Marker refreshed (SEC-3 style) so relay-active holds the child past the subtask timeout;
    # "stopped" repeats so without the fix the child would be killed on poll 3.
    mk_bg "$tmp" bgq "T-A:stopped stopped stopped blocked"
    echo '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":1,"notify":"none"}}' > "$tmp/n1home/config.json"
    touch -d '+1 hour' "$tmp/fake/relay.T-A"
    cat > "$tmp/bin/find" <<FAKEEOF
#!/usr/bin/env bash
t=""
case "\$1" in *.relay-*) t="\${1##*.relay-}" ;; esac
c=0
if [ -n "\$t" ]; then
    cf="$tmp/fake/findcalls.\$t"
    c=\$(( \$(cat "\$cf" 2>/dev/null || echo 0) + 1 )); echo "\$c" > "\$cf"
fi
"$real_find" "\$@"; rc=\$?
if [ "\$t" = "T-A" ] && [ "\$c" = 3 ]; then
    mkdir -p "$tmp/n1home/memory/T-A"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/1\n' > "$tmp/n1home/memory/T-A/overview.md"
fi
exit \$rc
FAKEEOF
    chmod +x "$tmp/bin/find"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "timeout-race: find seam fired exactly once at call 3" "3" \
        "$(cat "$tmp/fake/findcalls.T-A" 2>/dev/null || echo 0)"
    assert_eq "timeout-race: row finalizes as pr, not timed out" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "timeout-race: no retry row" "" "$(plan_cell "$tmp/queue.md" 2 8)"
    assert_eq "timeout-race: session never directly stopped (timeout path not taken)" "no" \
        "$([ -f "$tmp/fake/stopped" ] && echo yes || echo no)"
    assert_eq "timeout-race: drained child later blocked escalates exactly once" "1" \
        "$(jq -r 'select(.event=="escalated") | .ticket' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    assert_eq "timeout-race: escalation carries the drained ticket" "T-A" \
        "$(jq -r 'select(.event=="escalated") | .ticket' "$tmp/events.jsonl")"
    rm -rf "$tmp"
}

test_notify_check() {
    assert_eq "notify-check: none is silent" "" \
        "$(N1_HOME="$(mktemp -d)" bash -c "source '$REPO_ROOT/lib/config.sh'; source '$REPO_ROOT/lib/frontmatter.sh'; source '$REPO_ROOT/lib/queue.sh'; n1_queue_val() { [ \"\$1\" = notify ] && echo none; }; n1_queue_notify_check")"
    assert_eq "notify-check: command without notifyCommand warns" "yes" \
        "$(out=$(bash -c "source '$REPO_ROOT/lib/config.sh'; source '$REPO_ROOT/lib/frontmatter.sh'; source '$REPO_ROOT/lib/queue.sh'; n1_queue_val() { [ \"\$1\" = notify ] && echo command; }; n1_queue_notify_check"); [ -n "$out" ] && echo yes || echo no)"
    assert_eq "notify-check: ntfy without ntfyTopic warns" "yes" \
        "$(out=$(bash -c "source '$REPO_ROOT/lib/config.sh'; source '$REPO_ROOT/lib/frontmatter.sh'; source '$REPO_ROOT/lib/queue.sh'; n1_queue_val() { [ \"\$1\" = notify ] && echo ntfy; }; n1_queue_notify_check"); [ -n "$out" ] && echo yes || echo no)"
    local bash_bin; bash_bin=$(command -v bash)
    assert_eq "notify-check: desktop with no notifier warns" "yes" \
        "$(out=$(PATH=/nonexistent "$bash_bin" -c "source '$REPO_ROOT/lib/config.sh'; source '$REPO_ROOT/lib/frontmatter.sh'; source '$REPO_ROOT/lib/queue.sh'; n1_queue_val() { [ \"\$1\" = notify ] && echo desktop; }; n1_queue_notify_check"); [ -n "$out" ] && echo yes || echo no)"
}

test_bg_disclaimer() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:done" "T-B:done"
    touch "$tmp/fake/refuse"
    assert_eq "bg-disc: exit 2" "2" "$(run_bg_queue "$tmp")"
    assert_eq "bg-disc: step halted" "halted" "$(n1_read_frontmatter "$tmp/queue.md" step)"
    assert_eq "bg-disc: pid removed" "" "$(n1_read_frontmatter "$tmp/queue.md" pid)"
    assert_eq "bg-disc: row 1 failed" "failed" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-disc: row 1 reason" "bypass-permissions-disclaimer" "$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "bg-disc: row 2 untouched" "pending" "$(plan_cell "$tmp/queue.md" 2 8)"
    assert_eq "bg-disc: single launch attempt" "1" "$(grep -c '^launch' "$tmp/fake/events" || true)"
    assert_eq "bg-disc: fix hint printed" "yes" "$(grep -q 'dangerously-skip-permissions' "$tmp/output.txt" && echo yes || echo no)"
    assert_eq "events-disc: halted recorded" "halted" "$(jq -r .event "$tmp/events.jsonl" | tail -1)"
    assert_eq "notify-disc: one needs-you" "needs-you" "$(jq -r .kind "$tmp/notes" | paste -sd, -)"
    rm -rf "$tmp"
}

# N1-183: runner liveness, interrupted detection, one-shot queue_interrupted event + resume line.
test_queue_interrupted() {
    local tmp dead; tmp=$(mktemp -d)
    start_fake_runner
    sleep 0 & dead=$!; wait "$dead"
    assert_eq "alive: runner-named live pid" yes "$(n1_queue_runner_alive "$FAKE_RUNNER_PID" && echo yes || echo no)"
    assert_eq "alive: dead pid" no "$(n1_queue_runner_alive "$dead" && echo yes || echo no)"
    assert_eq "alive: live pid that is not a runner (recycled)" no "$(n1_queue_runner_alive "$$" && echo yes || echo no)"
    assert_eq "alive: empty pid" no "$(n1_queue_runner_alive "" && echo yes || echo no)"
    assert_eq "alive: runner of this queue" yes "$(n1_queue_runner_alive "$FAKE_RUNNER_PID" /x/queue.md && echo yes || echo no)"
    assert_eq "alive: runner of another queue" no "$(n1_queue_runner_alive "$FAKE_RUNNER_PID" /y/queue.md && echo yes || echo no)"
    # SEC-2: a process that merely mentions the script (pager, grep) is not a runner.
    bash -c 'sleep 30; :' less /x/scripts/n1-queue-run.sh >/dev/null 2>&1 & local other=$!
    assert_eq "alive: pager naming the script is not a runner" no "$(n1_queue_runner_alive "$other" /x/scripts/n1-queue-run.sh && echo yes || echo no)"
    bash -c 'sleep 30; :' /x/n1-queue-run /x/queue.md >/dev/null 2>&1 & local other2=$!
    assert_eq "alive: name without scripts/ suffix is not a runner" no "$(n1_queue_runner_alive "$other2" /x/queue.md && echo yes || echo no)"
    kill "$other" "$other2" 2>/dev/null; wait "$other" "$other2" 2>/dev/null || true
    printf -- '---\nqueue_id: q1\nrun_id: R1\nstep: run\npid: %s\n---\n## Plan\n' "$dead" > "$tmp/queue.md"
    assert_eq "interrupted: step run + dead pid" yes "$(n1_queue_interrupted "$tmp/queue.md" && echo yes || echo no)"
    assert_eq "interrupted: note with one-command resume" \
        "interrupted: runner pid $dead is gone; resume: /n1:n1-queue --run q1" "$(n1_queue_interrupted_note "$tmp/queue.md")"
    n1_queue_interrupted_note "$tmp/queue.md" >/dev/null
    assert_eq "interrupted: event emitted once per run id" 1 "$(grep -c '"event":"queue_interrupted"' "$tmp/events.jsonl")"
    stop_fake_runner; start_fake_runner "$REPO_ROOT" "$tmp/queue.md"
    n1_write_frontmatter "$tmp/queue.md" pid "$FAKE_RUNNER_PID"
    assert_eq "interrupted: live runner is not interrupted" no "$(n1_queue_interrupted "$tmp/queue.md" && echo yes || echo no)"
    n1_write_frontmatter "$tmp/queue.md" pid "$dead"
    n1_write_frontmatter "$tmp/queue.md" step done
    assert_eq "interrupted: finished run is not interrupted" no "$(n1_queue_interrupted "$tmp/queue.md" && echo yes || echo no)"
    assert_eq "interrupted: no note when not interrupted" "" "$(n1_queue_interrupted_note "$tmp/queue.md")"
    stop_fake_runner
    rm -rf "$tmp"
}

# N1-333 AC1 (lib side): the exit trace writes one line + one queue_interrupted event only while step is run,
# and never touches step or pid (resume detection needs both).
test_queue_note_interrupt() {
    local tmp out s; tmp=$(mktemp -d)
    printf -- '---\nqueue_id: q1\nrun_id: R1\nstep: run\npid: 4242\n---\n## Plan\n' > "$tmp/queue.md"
    out=$(n1_queue_note_interrupt "$tmp/queue.md" "signal TERM")
    assert_eq "note-interrupt: runner.log line" \
        "runner interrupted: signal TERM (pid 4242, step run kept; resume: /n1:n1-queue --run q1)" "$out"
    assert_eq "note-interrupt: one event with run id and reason" "queue_interrupted|R1|runner signal TERM pid 4242" \
        "$(jq -r '[.event, .run_id, .reason] | join("|")' "$tmp/events.jsonl")"
    assert_eq "note-interrupt: step and pid kept" "run 4242" \
        "$(n1_read_frontmatter "$tmp/queue.md" step) $(n1_read_frontmatter "$tmp/queue.md" pid)"
    for s in done halted preview; do
        rm -f "$tmp/events.jsonl"; n1_write_frontmatter "$tmp/queue.md" step "$s"
        assert_eq "note-interrupt: step $s is silent" "|no" \
            "$(n1_queue_note_interrupt "$tmp/queue.md" x)|$([ -e "$tmp/events.jsonl" ] && echo yes || echo no)"
    done
    rm -rf "$tmp"
}

# N1-185/N1-183: the digest counts merged tickets and labels an interrupted run.
test_queue_digest_chain_states() {
    local tmp ev; tmp=$(mktemp -d); mkdir -p "$tmp/queue/q1"; ev="$tmp/queue/q1/events.jsonl"
    n1_queue_event "$ev" q1 R1 queue_started
    n1_queue_event "$ev" q1 R1 ticket_finished ticket=T-A outcome=pr pr=u
    n1_queue_event "$ev" q1 R1 ticket_finished ticket=T-A outcome=merged pr=u
    n1_queue_event "$ev" q1 R1 queue_interrupted reason="runner pid 1 gone"
    assert_eq "digest: merged count + interrupted label" "Queue q1: 1 merged, interrupted" "$(n1_queue_digest "$tmp")"
    rm -rf "$tmp"
}

# N1-333 AC4: the digest reads each queue.md's step/pid (local only). Step run + dead runner -> "runner gone".
test_queue_digest_runner_gone() {
    local tmp ev q dead; tmp=$(mktemp -d); mkdir -p "$tmp/queue/q1"; ev="$tmp/queue/q1/events.jsonl"; q="$tmp/queue/q1/queue.md"
    sleep 0 & dead=$!; wait "$dead"
    n1_queue_event "$ev" q1 R1 queue_started
    n1_queue_event "$ev" q1 R1 ticket_started ticket=T-X
    assert_eq "digest: no queue.md -> unchanged" "Queue q1: running T-X" "$(n1_queue_digest "$tmp")"
    printf -- '---\nqueue_id: q1\nrun_id: R1\nstep: run\npid: %s\n---\n' "$dead" > "$q"
    assert_eq "digest: step run + dead pid -> runner gone" "Queue q1: runner gone" "$(n1_queue_digest "$tmp")"
    start_fake_runner "$REPO_ROOT" "$q"; n1_write_frontmatter "$q" pid "$FAKE_RUNNER_PID"
    assert_eq "digest: live runner -> running" "Queue q1: running T-X" "$(n1_queue_digest "$tmp")"
    stop_fake_runner
    n1_write_frontmatter "$q" pid "$dead"; n1_write_frontmatter "$q" step done
    assert_eq "digest: finished step -> running (events only)" "Queue q1: running T-X" "$(n1_queue_digest "$tmp")"
    n1_write_frontmatter "$q" step run
    n1_queue_event "$ev" q1 R1 queue_interrupted reason="runner signal TERM pid $dead"
    assert_eq "digest: trap event is not repeated as interrupted" "Queue q1: runner gone" "$(n1_queue_digest "$tmp")"
    rm -rf "$tmp"
}

# N1-333 AC4: --status marks in-progress rows runner-gone for step run + dead runner; awaiting-human rows keep their state.
test_status_runner_gone() {
    local tmp dead st; tmp=$(mktemp -d); sleep 0 & dead=$!; wait "$dead"
    mkdir -p "$tmp/bin"; printf '#!/bin/sh\necho "[]"\n' > "$tmp/bin/claude"; chmod +x "$tmp/bin/claude"   # never the real CLI
    printf -- '---\nqueue_id: q1\nrun_id: R1\nstep: run\npid: %s\n---\n## Plan\n| # | Ticket | Title | Repo | Home | Model | Status | Reason |\n|---|---|---|---|---|---|---|---|\n| 1 | T-A | a | /r | %s | m | in-progress | |\n| 2 | T-B | b | /r | %s | m | awaiting-human | |\n' \
        "$dead" "$tmp" "$tmp" > "$tmp/queue.md"
    : > "$tmp/events.jsonl"
    st() { PATH="$tmp/bin:$PATH" n1_queue_status_table "$tmp/queue.md" "$tmp/events.jsonl" | cut -f2 | paste -sd' '; }
    assert_eq "status: dead runner -> in-progress row runner-gone, parked row kept" "runner-gone awaiting-human" "$(st)"
    start_fake_runner "$REPO_ROOT" "$tmp/queue.md"; n1_write_frontmatter "$tmp/queue.md" pid "$FAKE_RUNNER_PID"
    assert_eq "status: live runner -> stored state" "in-progress awaiting-human" "$(st)"
    stop_fake_runner
    n1_write_frontmatter "$tmp/queue.md" pid "$dead"; n1_write_frontmatter "$tmp/queue.md" step done
    assert_eq "status: finished run -> stored state" "in-progress awaiting-human" "$(st)"
    rm -rf "$tmp"
}

test_live_by_name() {
    local j='[{"kind":"background","id":"0000000a","name":"n1-q-T-A-1","state":"working"},{"kind":"background","id":"0000000b","name":"n1-q-T-B-2","state":"done"},{"kind":"background","id":"0000000c","name":"n1-q-T-C-3","state":"blocked"}]'
    assert_eq "live-by-name: working" 0000000a "$(n1_queue_live_by_name "$j" n1-q-T-A-1)"
    assert_eq "live-by-name: blocked" 0000000c "$(n1_queue_live_by_name "$j" n1-q-T-C-3)"
    assert_eq "live-by-name: done is not live" "" "$(n1_queue_live_by_name "$j" n1-q-T-B-2)"
    assert_eq "live-by-name: unknown name" "" "$(n1_queue_live_by_name "$j" n1-q-T-Z-9)"
    assert_eq "live-by-name: bad json" "" "$(n1_queue_live_by_name 'not json' n1-q-T-A-1)"
}

# N1-82: a row this run already launched is adopted, never launched twice; another run's lock never blocks.
test_bg_launch_guard() {
    local tmp
    # Restart between launch and the Session-cell write: in-progress row, empty Session, live session.
    tmp=$(mktemp -d); mk_bg "$tmp" bgq "T-A:working done"
    n1_write_frontmatter "$tmp/queue.md" run_id R1
    n1_queue_row_status "$tmp/queue.md" 1 in-progress
    echo R1 > "$tmp/.launch-1"
    seed_live_session "$tmp" n1-bgq-T-A-1 T-A 0000000a
    assert_eq "guard-orphan: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "guard-orphan: no second launch of the row" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1')"
    assert_eq "guard-orphan: no retry row launched" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-2')"
    assert_eq "guard-orphan: adopted session" 0000000a "$(n1_queue_session_id "$tmp/queue.md" T-A)"
    assert_eq "guard-orphan: row pr" pr "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "guard-orphan: lock removed on finalize" no "$([ -e "$tmp/.launch-1" ] && echo yes || echo no)"
    rm -rf "$tmp"
    # Same run, pending row whose lock holds this run id and whose session is live: adopt, no launch.
    tmp=$(mktemp -d); mk_bg "$tmp" bgq "T-A:working done"
    n1_write_frontmatter "$tmp/queue.md" run_id R1
    echo R1 > "$tmp/.launch-1"
    seed_live_session "$tmp" n1-bgq-T-A-1 T-A 0000000a
    assert_eq "guard-same-run: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "guard-same-run: two launches never both run" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1')"
    assert_eq "guard-same-run: adopted session" 0000000a "$(n1_queue_session_id "$tmp/queue.md" T-A)"
    assert_eq "guard-same-run: row pr" pr "$(plan_cell "$tmp/queue.md" 1 8)"
    rm -rf "$tmp"
    # New run id: an older run's lock never blocks a relaunch, even with a same-name live session.
    tmp=$(mktemp -d); mk_bg "$tmp" bgq "T-A:working done"
    n1_write_frontmatter "$tmp/queue.md" run_id R2
    echo R1 > "$tmp/.launch-1"
    seed_live_session "$tmp" n1-bgq-T-A-1 T-A 0000000a
    assert_eq "guard-new-run: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "guard-new-run: relaunched once" 1 "$(count_x "$tmp/fake/events" 'launch n1-bgq-T-A-1')"
    rm -rf "$tmp"
}

# Review fix: the runner lock is published atomically (never visible empty) and reclaimed by rename.
test_runner_lock_atomic() {
    local s="$REPO_ROOT/scripts/n1-queue-run.sh"
    assert_eq "lock-atomic: published by hard link from a private mktemp file" yes \
        "$(grep -q 'ln "$t" "$LOCK"' "$s" && grep -q 'mktemp "$LOCK.XXXXXX"' "$s" && echo yes || echo no)"
    assert_eq "lock-atomic: no noclobber redirect (create + write were separate)" no \
        "$(grep -q 'set -C' "$s" && echo yes || echo no)"
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgl "T-A:done"
    : > "$tmp/queue.md.lock"
    assert_eq "lock-atomic: empty lock reclaimed" 0 "$(run_bg_queue "$tmp")"
    assert_eq "lock-atomic: no leftover temp files" 0 "$(ls "$tmp" | grep -c '^queue.md.lock' || true)"
    rm -rf "$tmp"
}

test_busy_guard() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    start_fake_runner "$REPO_ROOT" "$tmp/queue.md"

    cat > "$tmp/queue.md" <<EOF
---
step: run
pid: $FAKE_RUNNER_PID
queue_id: test-q3
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
EOF

    local exit_code=0
    bash "$REPO_ROOT/scripts/n1-queue-run.sh" "$tmp/queue.md" > "$tmp/output.txt" 2>&1 || exit_code=$?
    assert_eq "busy: exit 3" "3" "$exit_code"
    grep -q "already running" "$tmp/output.txt"
    assert_eq "busy: message" "0" "$?"
    stop_fake_runner
}

# N1-82 (a): an atomic lock, so two runners started together cannot both pass the busy guard.
test_runner_lock() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgl "T-A:done"
    start_fake_runner "$REPO_ROOT" "$tmp/queue.md"
    printf '%s\n' "$FAKE_RUNNER_PID" > "$tmp/queue.md.lock"
    assert_eq "lock: live holder -> exit 3" 3 "$(run_bg_queue "$tmp")"
    assert_eq "lock: nothing launched while held" 0 "$(count_x "$tmp/fake/events" 'launch n1-bgl-T-A-1')"
    stop_fake_runner
    assert_eq "lock: dead holder reclaimed -> exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "lock: launched after reclaim" 1 "$(count_x "$tmp/fake/events" 'launch n1-bgl-T-A-1')"
    assert_eq "lock: released at exit" no "$([ -e "$tmp/queue.md.lock" ] && echo yes || echo no)"
    rm -rf "$tmp"
}

# N1-447 AC1/AC2: a new queue whose repo has an earlier queue with an open final PR is cut from that branch's tip and
# records it in ## Predecessor; an earlier queue without an open final PR (running, interrupted, merged) changes nothing.
test_runner_queue_chain_cut() {
    local tmp tmp2 tip qb
    for tmp in "$(mktemp -d)" "$(mktemp -d)"; do
        qb_fixture "$tmp"; echo o/r > "$tmp/fake/gh-repo"
        git -C "$tmp/origin" checkout -q -b "$QC_P"
        git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m q1
        git -C "$tmp/origin" checkout -q main
        pred_queue "$tmp/n1home" p1 "$tmp/repo" "$QC_P"
        [ -z "${tmp2:-}" ] || continue
        tmp2="$tmp"
    done
    tip=$(git -C "$tmp2/origin" rev-parse "$QC_P")
    final_list "$tmp2" "$QC_P" 5; printf 'OPEN\tmain\t%s\n' "$tip" > "$tmp2/fake/gh-view.5"
    assert_eq "chain-cut: exit 0" 0 "$(run_bg_queue "$tmp2")"
    qb=$(n1_queue_story_branch_get "$tmp2/queue.md" "$tmp2/repo")
    assert_eq "chain-cut: queue branch at the predecessor tip" "$tip" "$(git -C "$tmp2/origin" rev-parse -q --verify "refs/heads/$qb")"
    assert_eq "chain-cut: ## Predecessor row" \
        "$(printf '%s\t%s\t%s\thttps://github.com/o/r/pull/5\t%s\t%s\twaiting' "$tmp2/repo" "$QC_ID" "$QC_P" "$tip" "$tip")" \
        "$(n1_queue_preds "$tmp2/queue.md")"
    # Second fixture: the predecessor has no open final PR -> N1-446 behaviour (cut from main, no section).
    assert_eq "chain-none: exit 0" 0 "$(run_bg_queue "$tmp")"
    qb=$(n1_queue_story_branch_get "$tmp/queue.md" "$tmp/repo")
    assert_eq "chain-none: queue branch at origin/main" "$(git -C "$tmp/origin" rev-parse main)" "$(git -C "$tmp/origin" rev-parse -q --verify "refs/heads/$qb")"
    assert_eq "chain-none: no ## Predecessor" 0 "$(count_x "$tmp/queue.md" '## Predecessor')"
    rm -rf "$tmp" "$tmp2"
}

# N1-53: a bg child that ends at step pr with no PR URL is a failure, never a phantom pr.
test_bg_pr_lifecycle() {
    local tmp published next_launch step
    tmp=$(mktemp -d)
    mk_bg "$tmp" bgn "T-A:working working done" "T-B:done"
    printf -- '---\nstep: pr\n---\n# T\n' > "$tmp/fake/overview.T-A.1"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/53\n' > "$tmp/fake/overview.T-A.2"
    assert_eq "bg-pr: live PR step without URL stays running" "running" \
        "$(n1_queue_child_status "$tmp/fake/overview.T-A.1" 0 1)"
    assert_eq "bg-pr: delayed URL exit 0" "0" "$(run_bg_queue "$tmp")"
    published=$(line_of "$tmp/fake/events" "overview n1-bgn-T-A-1 2")
    next_launch=$(line_of "$tmp/fake/events" "launch n1-bgn-T-B-2")
    assert_eq "bg-pr: next child waits for PR URL" "yes" \
        "$([ -n "$published" ] && [ -n "$next_launch" ] && [ "$next_launch" -gt "$published" ] && echo yes || echo no)"
    assert_eq "bg-pr: delayed URL finalizes as pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-pr: Runs records delayed URL" "https://x/pr/53" \
        "$(awk -F'|' '/^## Runs/{f=1;next} f && $2 ~ /T-A/ { gsub(/ /,"",$6); print $6 }' "$tmp/queue.md")"
    assert_eq "bg-pr: event records delayed URL exactly once" "pr,https://x/pr/53" \
        "$(jq -r 'select(.event=="ticket_finished" and .ticket=="T-A") | [.outcome,.pr] | join(",")' "$tmp/events.jsonl")"
    rm -rf "$tmp"

    tmp=$(mktemp -d)
    mk_bg "$tmp" bgn "T-A:working done"
    printf -- '---\nstep: pr\n---\n# T\n' > "$tmp/fake/overview.T-A"
    cp "$tmp/fake/overview.T-A" "$tmp/fake/overview.T-A.1"
    assert_eq "bg-nourl: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-nourl: first row deferred" "deferred" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-nourl: first failure is incomplete exit" "child-exited-incomplete" "$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "bg-nourl: no pr rows" "0" "$(n1_queue_pending_rows "$tmp/queue.md" pr | wc -l | tr -d ' ')"
    assert_eq "bg-nourl: retry failed" "failed" "$(plan_cell "$tmp/queue.md" 2 8)"
    assert_eq "bg-nourl: retry preserves failure reason" "deferred-retry (child-exited-incomplete)" "$(plan_cell "$tmp/queue.md" 2 9)"
    assert_eq "bg-nourl: no second retry" "" "$(plan_cell "$tmp/queue.md" 3 8)"
    assert_eq "bg-nourl: failure events retain outcomes and reasons" \
        $'deferred,child-exited-incomplete\nfailed,deferred-retry (child-exited-incomplete)' \
        "$(jq -r 'select(.event=="ticket_finished") | [.outcome,.reason] | join(",")' "$tmp/events.jsonl")"
    rm -rf "$tmp"

    # N1-182: an off-script child that opened a PR but never wrote pr_url is a pr, not a retry.
    tmp=$(mktemp -d)
    mk_bg "$tmp" bgn "T-A:working done"
    printf -- '---\nstep: pr\n---\n# T\n' > "$tmp/fake/overview.T-A"
    cp "$tmp/fake/overview.T-A" "$tmp/fake/overview.T-A.1"
    mkdir -p "$tmp/n1home/memory/T-A/telemetry/raw/steps"
    printf '{"layer":"envelope","run_id":"r1","ticket_id":"T-A","branch":"me/T-A","started_at":"x","config_snapshot":{}}\n' \
        > "$tmp/n1home/memory/T-A/telemetry/raw/steps/r1.jsonl"
    touch -d "+1 hour" "$tmp/n1home/memory/T-A/telemetry/raw/steps/r1.jsonl"  # as if written after launch: the runner ignores an envelope older than the child start, and the start can land in the next second
    git -C "$tmp" init -q; git -C "$tmp" -c user.name=t -c user.email=t@t -c commit.gpgSign=false commit -q --allow-empty -m i; git -C "$tmp" branch me/T-A
    printf 'https://github.com/o/r/pull/77\t%s\n' "$(git -C "$tmp" rev-parse refs/heads/me/T-A)" > "$tmp/fake/gh-pr"
    assert_eq "bg-openpr: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-openpr: finalizes as pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-openpr: no deferred-retry row" "" "$(plan_cell "$tmp/queue.md" 2 8)"
    assert_eq "bg-openpr: Runs records the PR" "https://github.com/o/r/pull/77" \
        "$(awk -F'|' '/^## Runs/{f=1;next} f && $2 ~ /T-A/ { gsub(/ /,"",$6); print $6 }' "$tmp/queue.md")"
    assert_eq "bg-openpr: event outcome pr" "pr,https://github.com/o/r/pull/77" \
        "$(jq -r 'select(.event=="ticket_finished" and .ticket=="T-A") | [.outcome,.pr] | join(",")' "$tmp/events.jsonl")"
    assert_eq "bg-openpr: asked gh for the envelope branch" "1" "$(grep -c -- '--head me/T-A' "$tmp/fake/gh-calls")"
    assert_eq "bg-openpr: gh query drops fork PRs (SEC-2)" "1" "$(grep -c -- 'isCrossRepository' "$tmp/fake/gh-calls")"
    rm -rf "$tmp"

    # SEC-2/SEC-4: a PR whose head is not the local branch tip (stale PR of an earlier run) is not recorded.
    tmp=$(mktemp -d)
    mk_bg "$tmp" bgs "T-A:working done"
    printf -- '---\nstep: pr\n---\n# T\n' > "$tmp/fake/overview.T-A"
    cp "$tmp/fake/overview.T-A" "$tmp/fake/overview.T-A.1"
    mkdir -p "$tmp/n1home/memory/T-A/telemetry/raw/steps"
    printf '{"layer":"envelope","run_id":"r1","ticket_id":"T-A","branch":"me/T-A","started_at":"x","config_snapshot":{}}\n' \
        > "$tmp/n1home/memory/T-A/telemetry/raw/steps/r1.jsonl"
    touch -d "+1 hour" "$tmp/n1home/memory/T-A/telemetry/raw/steps/r1.jsonl"  # as if written after launch: the runner ignores an envelope older than the child start, and the start can land in the next second
    git -C "$tmp" init -q; git -C "$tmp" -c user.name=t -c user.email=t@t -c commit.gpgSign=false commit -q --allow-empty -m i; git -C "$tmp" branch me/T-A
    printf 'https://github.com/o/r/pull/77\t%s\n' "0000000000000000000000000000000000000000" > "$tmp/fake/gh-pr"
    assert_eq "bg-stalepr: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-stalepr: not recorded as pr" "" "$(awk -F'|' '/^## Runs/{f=1;next} f && $2 ~ /T-A/ { gsub(/ /,"",$6); print $6 }' "$tmp/queue.md")"
    rm -rf "$tmp"

    # N1-182 unit: helper rejects non-PR output, falls back to the ticket id, fails open.
    tmp=$(mktemp -d); mkdir -p "$tmp/bin" "$tmp/fake"
    printf '#!/usr/bin/env bash\necho "$*" >> "%s/fake/gh-calls"; cat "%s/fake/gh-pr" 2>/dev/null\n' "$tmp" "$tmp" > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
    echo "not a url" > "$tmp/fake/gh-pr"
    assert_eq "open-pr: non-PR output ignored" "" "$(PATH="$tmp/bin:$PATH" n1_queue_child_open_pr T-Z "$tmp/n1h" "$tmp")"
    assert_eq "open-pr: no envelope -> asks for the ticket id" "1" "$(grep -c -- '--head T-Z' "$tmp/fake/gh-calls")"
    git -C "$tmp" init -q; git -C "$tmp" -c user.name=t -c user.email=t@t -c commit.gpgSign=false commit -q --allow-empty -m i; git -C "$tmp" branch T-Z
    printf 'https://github.com/o/r/pull/9\t%s\n' "$(git -C "$tmp" rev-parse refs/heads/T-Z)" > "$tmp/fake/gh-pr"
    assert_eq "open-pr: PR at local tip accepted" "https://github.com/o/r/pull/9" "$(PATH="$tmp/bin:$PATH" n1_queue_child_open_pr T-Z "$tmp/n1h" "$tmp")"
    printf 'https://github.com/o/r/pull/9\tdeadbeef\n' > "$tmp/fake/gh-pr"
    assert_eq "open-pr: PR head != local tip ignored" "" "$(PATH="$tmp/bin:$PATH" n1_queue_child_open_pr T-Z "$tmp/n1h" "$tmp")"
    mkdir -p "$tmp/n1h/memory/T-Z/telemetry/raw/steps"
    printf '{"layer":"envelope","branch":"old/T-Z"}\n' > "$tmp/n1h/memory/T-Z/telemetry/raw/steps/a.jsonl"; touch -d '2020-01-01' "$tmp/n1h/memory/T-Z/telemetry/raw/steps/a.jsonl"
    printf '{"layer":"envelope","branch":"new/T-Z"}\n' > "$tmp/n1h/memory/T-Z/telemetry/raw/steps/b.jsonl"
    : > "$tmp/fake/gh-calls"; PATH="$tmp/bin:$PATH" n1_queue_child_open_pr T-Z "$tmp/n1h" "$tmp" >/dev/null || true
    assert_eq "open-pr: only the newest run's envelope branch is asked" "0" "$(grep -c -- '--head old/T-Z' "$tmp/fake/gh-calls")"
    assert_eq "open-pr: newest envelope branch is asked" "1" "$(grep -c -- '--head new/T-Z' "$tmp/fake/gh-calls")"
    printf 'https://github.com/o/r/pull/9\t%s\n' "$(git -C "$tmp" rev-parse refs/heads/T-Z)" > "$tmp/fake/gh-pr"
    assert_eq "open-pr: envelope older than child start -> nothing" "" "$(PATH="$tmp/bin:$PATH" n1_queue_child_open_pr T-Z "$tmp/n1h" "$tmp" "$(( $(date +%s) + 100 ))")"
    assert_eq "open-pr: envelope newer than child start -> considered" "1" "$(PATH="$tmp/bin:$PATH" n1_queue_child_open_pr T-Z "$tmp/n1h" "$tmp" "$(( $(date +%s) - 100 ))" | grep -c pull/9)"
    assert_eq "open-pr: missing repo dir -> nothing" "" "$(PATH="$tmp/bin:$PATH" n1_queue_child_open_pr T-Z "$tmp/n1h" "$tmp/nope")"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/gh"
    assert_eq "open-pr: gh failure -> nothing" "" "$(PATH="$tmp/bin:$PATH" n1_queue_child_open_pr T-Z "$tmp/n1h" "$tmp")"
    rm -rf "$tmp"

    for step in ci done; do
        tmp=$(mktemp -d)
        mk_bg "$tmp" bgn "T-A:working done"
        printf -- '---\nstep: %s\n---\n# T\n' "$step" > "$tmp/fake/overview.T-A.1"
        cp "$tmp/fake/overview.T-A.1" "$tmp/fake/overview.T-A"
        assert_eq "bg-pr: step $step exit 0" "0" "$(run_bg_queue "$tmp")"
        # N1-470: step done without a URL is no-pr; step ci keeps mapping to pr
        want=pr; [ "$step" = done ] && want=no-pr
        assert_eq "bg-pr: step $step without URL finalizes as $want" "$want" "$(plan_cell "$tmp/queue.md" 1 8)"
        assert_eq "bg-pr: step $step success event" "$want" \
            "$(jq -r 'select(.event=="ticket_finished") | .outcome' "$tmp/events.jsonl")"
        assert_eq "bg-pr: step $step has no retry" "" "$(plan_cell "$tmp/queue.md" 2 8)"
        rm -rf "$tmp"
    done
}

# N1-290: a story run cuts story/<story_id> once per repo before any child launches, a resume reuses it untouched,
# tag mode creates none, and a failed push halts before any launch.
test_runner_story_branches() {
    local tmp tmp2 tmp3 tmp4 tmp5 bad main adv
    # Creation: two rows in one repo -> one branch, one mapping row, cut from origin/main; local clone untouched.
    tmp=$(mktemp -d); sb_fixture "$tmp" story
    main=$(git -C "$tmp/origin" rev-parse main)
    assert_eq "story-run: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "story-run: story/S-1 on origin at origin/main" "$main" "$(git -C "$tmp/origin" rev-parse -q --verify refs/heads/story/S-1)"
    assert_eq "story-run: mapping recorded" "story/S-1" "$(n1_queue_story_branch_get "$tmp/queue.md" "$tmp/repo")"
    assert_eq "story-run: one row for one repo" "1" "$(count_x "$tmp/queue.md" "| $tmp/repo | story/S-1 |")"
    assert_eq "story-run: section before ## Runs" "yes" \
        "$([ "$(line_of "$tmp/queue.md" '## Story Branches')" -lt "$(line_of "$tmp/queue.md" '## Runs')" ] 2>/dev/null && echo yes || echo no)"
    assert_eq "story-run: no local story branch" "" "$(git -C "$tmp/repo" for-each-ref --format='%(refname)' refs/heads/story)"
    assert_eq "story-run: children launched" "yes" "$(grep -q '^launch ' "$tmp/fake/events" && echo yes || echo no)"
    # N1-291: each n1-start child gets the story env (chained launches never do: test_bg_chain_story_env_scoped).
    assert_eq "story-run: child settings carry story env" "S-1,story/S-1" \
        "$(jq -r '[.env.N1_STORY_ID,.env.N1_STORY_BRANCH]|join(",")' "$tmp/fake/settings.n1-sq-T-A-1")"

    # Resume: the branch exists on origin and has moved on; an interrupted run with no row recorded yet
    # reuses it (no reset, no force push) and records the mapping row (proves the block ran on resume).
    adv=$(git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit-tree -p refs/heads/story/S-1 -m story 'refs/heads/story/S-1^{tree}')
    git -C "$tmp/origin" update-ref refs/heads/story/S-1 "$adv"
    tmp2=$(mktemp -d); sb_fixture "$tmp2" story "$tmp/origin"
    n1_write_frontmatter "$tmp2/queue.md" run_id R1; n1_write_frontmatter "$tmp2/queue.md" step run
    assert_eq "story-resume: exit 0" "0" "$(run_bg_queue "$tmp2")"
    assert_eq "story-resume: branch not reset" "$adv" "$(git -C "$tmp/origin" rev-parse refs/heads/story/S-1)"
    assert_eq "story-resume: one row recorded" "1" "$(count_x "$tmp2/queue.md" "| $tmp2/repo | story/S-1 |")"
    assert_eq "story-resume: one heading" "1" "$(count_x "$tmp2/queue.md" '## Story Branches')"

    # Tag mode with a recorded integration: none (mk_bg default): no integration branch, no section.
    tmp3=$(mktemp -d); sb_fixture "$tmp3" tag
    run_bg_queue "$tmp3" >/dev/null   # exit code not asserted: tag-mode finalize paths are not this ticket's concern
    assert_eq "story-tag: children launched" "yes" "$(grep -q '^launch ' "$tmp3/fake/events" && echo yes || echo no)"
    assert_eq "story-tag: no story env in any launch" "0" "$(cat "$tmp3/fake"/settings.* | grep -c N1_STORY_ || true)"
    assert_eq "story-tag: no story branch on origin" "" "$(git -C "$tmp3/origin" for-each-ref --format='%(refname)' refs/heads/story)"
    assert_eq "story-tag: no section" "0" "$(count_x "$tmp3/queue.md" '## Story Branches')"

    # Failure: origin rejects the push -> halt before any child launches.
    tmp4=$(mktemp -d); sb_fixture "$tmp4" story
    printf '#!/bin/sh\nexit 1\n' > "$tmp4/origin/.git/hooks/pre-receive"; chmod +x "$tmp4/origin/.git/hooks/pre-receive"
    assert_eq "story-fail: exit 2" "2" "$(run_bg_queue "$tmp4")"
    assert_eq "story-fail: step halted" "halted" "$(n1_read_frontmatter "$tmp4/queue.md" step)"
    assert_eq "story-fail: halt message" "yes" "$(grep -qF "HALTED: story branch story/S-1 could not be created or pushed in $tmp4/repo: n1-queue: story branch: push of story/S-1 to origin failed in $tmp4/repo; fix access, then /n1:n1-queue --run sq" "$tmp4/output.txt" && echo yes || echo no)"
    assert_eq "story-fail: no child launched" "0" "$(grep -c '^launch ' "$tmp4/fake/events" || true)"
    assert_eq "story-fail: no story branch on origin" "" "$(git -C "$tmp4/origin" for-each-ref --format='%(refname)' refs/heads/story)"
    assert_eq "story-fail: no section" "0" "$(count_x "$tmp4/queue.md" '## Story Branches')"
    assert_eq "story-fail: halted event" "yes" "$(jq -e 'select(.event=="halted")' "$tmp4/events.jsonl" >/dev/null 2>&1 && echo yes || echo no)"

    # Bad story id (not the tracker id grammar): halt before any launch, naming the id; nothing on origin or in queue.md.
    for bad in 'A|B' '"VEL-1"'; do
        tmp5=$(mktemp -d); sb_fixture "$tmp5" story
        n1_write_frontmatter "$tmp5/queue.md" story_id "$bad"
        assert_eq "story-badid $bad: exit 2" "2" "$(run_bg_queue "$tmp5")"
        assert_eq "story-badid $bad: halt names the id" "yes" "$(grep -qF "n1-queue: story branch: invalid story id $bad" "$tmp5/output.txt" && echo yes || echo no)"
        assert_eq "story-badid $bad: no child launched" "0" "$(grep -c '^launch ' "$tmp5/fake/events" || true)"
        assert_eq "story-badid $bad: nothing on origin" "" "$(git -C "$tmp5/origin" for-each-ref --format='%(refname)' refs/heads/story)"
        assert_eq "story-badid $bad: no section" "0" "$(count_x "$tmp5/queue.md" '## Story Branches')"
        rm -rf "$tmp5"
    done
    rm -rf "$tmp" "$tmp2" "$tmp3" "$tmp4"
}

# N1-446 AC1/AC2/AC6: a list queue of 2+ rows with merge off decides integration: queue at first start and cuts
# queue/<QUEUE_ID>-<UTC stamp> before any launch; a resume reuses the recorded name and ignores a config flip;
# one row or merge on decides none; story mode records no integration key.
test_runner_queue_branches() {
    local tmp tmp2 tmp3 tmp4 tmp5 tmp6 qb main
    tmp=$(mktemp -d); qb_fixture "$tmp"
    main=$(git -C "$tmp/origin" rev-parse main)
    assert_eq "queue-run: exit 0" 0 "$(run_bg_queue "$tmp")"
    assert_eq "queue-run: integration persisted" queue "$(n1_read_frontmatter "$tmp/queue.md" integration)"
    assert_eq "queue-run: mode kept" list "$(n1_read_frontmatter "$tmp/queue.md" mode)"
    qb=$(n1_queue_story_branch_get "$tmp/queue.md" "$tmp/repo")
    assert_eq "queue-run: name queue/<QUEUE_ID>-<UTC stamp>" yes "$([[ "$qb" =~ ^queue/sq-[0-9]{8}T[0-9]{6}Z$ ]] && echo yes || echo no)"
    assert_eq "queue-run: branch on origin at origin/main" "$main" "$(git -C "$tmp/origin" rev-parse -q --verify "refs/heads/$qb")"
    assert_eq "queue-run: no story branch" "" "$(git -C "$tmp/origin" for-each-ref --format='%(refname)' refs/heads/story)"
    assert_eq "queue-run: child settings carry the queue branch" "${qb#queue/},$qb" \
        "$(jq -r '[.env.N1_STORY_ID,.env.N1_STORY_BRANCH]|join(",")' "$tmp/fake/settings.n1-sq-T-A-1")"

    # Resume: recorded name reused, no second queue branch, a config flip to merge on does not re-decide.
    tmp2=$(mktemp -d); qb_fixture "$tmp2" "$tmp/origin"
    n1_write_frontmatter "$tmp2/queue.md" integration queue
    n1_queue_story_branch_set "$tmp2/queue.md" "$tmp2/repo" "$qb"
    n1_write_frontmatter "$tmp2/queue.md" run_id R1; n1_write_frontmatter "$tmp2/queue.md" step run
    chain_setup "$tmp2" true true
    run_bg_queue "$tmp2" >/dev/null
    assert_eq "queue-resume: integration kept" queue "$(n1_read_frontmatter "$tmp2/queue.md" integration)"
    assert_eq "queue-resume: name reused" "$qb" "$(n1_queue_story_branch_get "$tmp2/queue.md" "$tmp2/repo")"
    assert_eq "queue-resume: one queue branch on origin" 1 "$(git -C "$tmp/origin" for-each-ref --format='%(refname)' refs/heads/queue | wc -l | tr -d ' ')"

    # Tag mode with a free-text tag as QUEUE_ID: the branch id is reduced to the safe grammar, not halted on.
    tmp6=$(mktemp -d); qb_fixture "$tmp6" "" ; sed -i 's/^mode: .*/mode: tag/' "$tmp6/queue.md"
    n1_write_frontmatter "$tmp6/queue.md" queue_id 'n1+auto:x'
    run_bg_queue "$tmp6" >/dev/null
    assert_eq "queue-tag: id reduced to the safe grammar" yes \
        "$([[ "$(n1_queue_story_branch_get "$tmp6/queue.md" "$tmp6/repo")" =~ ^queue/n1-auto-x-[0-9]{8}T[0-9]{6}Z$ ]] && echo yes || echo no)"
    assert_eq "queue-tag: mode stays tag" tag "$(n1_read_frontmatter "$tmp6/queue.md" mode)"

    # One row: integration none, no branch, no env.
    tmp3=$(mktemp -d); qb_fixture "$tmp3"
    sed -i '/| T-B |/d' "$tmp3/queue.md"
    run_bg_queue "$tmp3" >/dev/null
    assert_eq "queue-one-row: integration none" none "$(n1_read_frontmatter "$tmp3/queue.md" integration)"
    assert_eq "queue-one-row: no queue branch" "" "$(git -C "$tmp3/origin" for-each-ref --format='%(refname)' refs/heads/queue)"
    assert_eq "queue-one-row: no section" 0 "$(count_x "$tmp3/queue.md" '## Story Branches')"
    assert_eq "queue-one-row: no story env in any launch" 0 "$(cat "$tmp3/fake"/settings.* 2>/dev/null | grep -c N1_STORY_ || true)"

    # Merge on (fullAuto + mergeOnFinish): integration none, behaves as today.
    tmp4=$(mktemp -d); qb_fixture "$tmp4"
    chain_setup "$tmp4" true true
    run_bg_queue "$tmp4" >/dev/null
    assert_eq "queue-merge-on: integration none" none "$(n1_read_frontmatter "$tmp4/queue.md" integration)"
    assert_eq "queue-merge-on: no queue branch" "" "$(git -C "$tmp4/origin" for-each-ref --format='%(refname)' refs/heads/queue)"

    # Story mode: no integration decision is recorded (story_id drives it).
    tmp5=$(mktemp -d); sb_fixture "$tmp5" story
    sed -i '/^integration: /d' "$tmp5/queue.md"
    run_bg_queue "$tmp5" >/dev/null
    assert_eq "queue-story: no integration key" "" "$(n1_read_frontmatter "$tmp5/queue.md" integration)"
    assert_eq "queue-story: story/S-1 recorded" story/S-1 "$(n1_queue_story_branch_get "$tmp5/queue.md" "$tmp5/repo")"
    rm -rf "$tmp" "$tmp2" "$tmp3" "$tmp4" "$tmp5" "$tmp6"
}

test_bg_pr_lifecycle
test_runner_three_strikes
test_runner_all_pr
test_runner_tag_release
test_runner_tag_attr
test_runner_auto_release_backstop
test_runner_release_backstop_on_halt
test_runner_list_mode_untagged
test_runner_story_branches
test_runner_queue_branches
test_bg_sequential
test_bg_no_pr
test_bg_awaiting
test_bg_awaiting_alternatives
test_bg_awaiting_oversized_question
test_bg_awaiting_oversized_control_chars
test_bg_awaiting_oversized_emoji
test_bg_awaiting_timeout
test_bg_working_timeout
test_bg_missing_grace
test_bg_reconcile_working
test_bg_drain_defers_until_idle
test_bg_drain_rearms_after_answer
test_bg_drain_benign_reason
test_bg_escalation_dedupe
test_bg_escalation_dedupe_question_file
test_bg_escalation_rearm_on_new_entry
test_bg_halt_drains
test_bg_drain_stop_retries_on_failure
test_bg_reconcile_missing
test_bg_reconcile_working_stale_escalation
test_bg_blocked_first_tick_parks
test_bg_reason_child_exited_incomplete
test_bg_reason_bg_state_catchall
test_bg_relay_marker
test_bg_timeout_race_terminal_overview
test_notify_check
test_bg_disclaimer
test_busy_guard
test_queue_interrupted
test_queue_note_interrupt
test_queue_digest_chain_states
test_queue_digest_runner_gone
test_status_runner_gone
test_runner_lock
test_live_by_name
test_bg_launch_guard
test_runner_lock_atomic
test_runner_queue_chain_cut

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

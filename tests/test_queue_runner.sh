#!/usr/bin/env bash
# Tests for lib/queue.sh and scripts/n1-queue-run.sh: parsing, plan/status/report, decisions, desc-hash chain, wiring greps, notify, held helpers.
# Shared setup and fixtures: tests/queue_runner_lib.sh (N1-304 split).
set -euo pipefail
source "$(dirname "$0")/queue_runner_lib.sh"
source "$REPO_ROOT/lib/memory.sh"

# --- n1_story_parse_service (migrated from test_story_lib.sh) ----------------
test_parse_service() {
    assert_eq "parse: prefix present" "inference" "$(n1_story_parse_service 'inference | Add batching endpoint')"
    assert_eq "parse: odd spacing" "tailnet-acl" "$(n1_story_parse_service 'tailnet-acl |Grant SSH')"
    assert_eq "parse: no prefix" "" "$(n1_story_parse_service 'Add batching endpoint')"
    assert_eq "parse: pipe later in title only" "" "$(n1_story_parse_service 'Support a|b syntax')"
}

# --- n1_story_find_repo (migrated from test_story_lib.sh) -------------------
test_find_repo() {
    local root; root=$(mktemp -d); trap 'rm -rf "$root"' RETURN
    mkdir -p "$root/inference" "$root/tailnet-acl" "$root/scratch"
    echo '{"ticketTagging":{"enabled":true,"service":"inference"},"repoPath":"/repos/inference"}' > "$root/inference/config.json"
    echo '{"ticketTagging":{"enabled":true,"service":"Tailnet-ACL"}}' > "$root/tailnet-acl/config.json"
    echo 'not json' > "$root/scratch/notes.txt"

    local out
    out=$(n1_story_find_repo "inference" "$root")
    assert_eq "find: exact match" "$root/inference/config.json	/repos/inference" "$out"
    out=$(n1_story_find_repo "tailnet-acl" "$root")
    assert_eq "find: case-insensitive, missing repoPath" "$root/tailnet-acl/config.json	" "$out"
    if n1_story_find_repo "nope" "$root" >/dev/null; then
        assert_eq "find: no match exits 1" "1" "0"
    else
        assert_eq "find: no match exits 1" "1" "1"
    fi
}

# --- n1_story_pick_model (migrated from test_story_lib.sh) ------------------
test_pick_model() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    echo '{}' > "$tmp/config.json"
    local TEST_CONFIG="$tmp/config.json"
    n1_config_file() { echo "$TEST_CONFIG"; }

    assert_eq "model: XS -> sonnet" "sonnet" "$(n1_story_pick_model XS)"
    assert_eq "model: S -> sonnet" "sonnet" "$(n1_story_pick_model S)"
    assert_eq "model: M -> opus (default threshold)" "opus" "$(n1_story_pick_model M)"
    assert_eq "model: XL -> opus" "opus" "$(n1_story_pick_model XL)"
    assert_eq "model: empty size -> sonnet" "sonnet" "$(n1_story_pick_model '')"
    assert_eq "model: S + security -> opus" "opus" "$(n1_story_pick_model S security)"
    assert_eq "model: XS + contract -> opus" "opus" "$(n1_story_pick_model XS 'docs,contract')"
    assert_eq "model: XS + unknown flag -> sonnet" "sonnet" "$(n1_story_pick_model XS docs)"

    echo '{"queue":{"opusFromSize":"L"}}' > "$tmp/config.json"
    assert_eq "model: threshold L, M -> sonnet" "sonnet" "$(n1_story_pick_model M)"
    assert_eq "model: threshold L, L -> opus" "opus" "$(n1_story_pick_model L)"
    assert_eq "val: config override" "L" "$(n1_queue_val opusFromSize)"
    assert_eq "val: default fallback" "30" "$(n1_queue_val pollSeconds)"
    unset -f n1_config_file
}

# --- NP-199: release procedure wiring ------------------------------------------
test_release_wiring() {
    local s="$REPO_ROOT/skills"
    assert_eq "wiring: release procedure exists" "yes" \
        "$([ -f "$s/n1-queue/procedures/release-tag.md" ] && echo yes || echo no)"
    assert_eq "wiring: procedure writes flag" "yes" \
        "$(grep -q 'queue_tag_removed true' "$s/n1-queue/procedures/release-tag.md" 2>/dev/null && echo yes || echo no)"
    assert_eq "wiring: intake uses already-run check" "yes" \
        "$(grep -q 'n1_queue_already_run' "$s/n1-queue/steps/intake.md" && echo yes || echo no)"
    assert_eq "wiring: report releases rows" "yes" \
        "$(grep -q 'n1_queue_release_rows' "$s/n1-queue/steps/report.md" && grep -q 'release-tag.md' "$s/n1-queue/steps/report.md" && echo yes || echo no)"
    assert_eq "wiring: headless escalation releases tag" "yes" \
        "$(grep -q 'release-tag.md' "$s/n1-start/procedures/autonomy-headless.md" && grep -q 'to re-queue this ticket' "$s/n1-start/procedures/autonomy-headless.md" && echo yes || echo no)"
    assert_eq "wiring: PR step releases tag" "yes" \
        "$(grep -q 'release-tag.md' "$s/n1-pr/steps/02-push-create.md" && echo yes || echo no)"
    # Non-queue PR runs must not fall back to the config default tag (CR-1).
    assert_eq "wiring: PR step tag has no config fallback" "yes" \
        "$(grep -qF '"${N1_QUEUE_TAG:-}"' "$s/n1-pr/steps/02-push-create.md" && ! grep -q 'n1_queue_val' "$s/n1-pr/steps/02-push-create.md" && echo yes || echo no)"
    assert_eq "wiring: PR step skips release on empty tag" "yes" \
        "$(grep -q 'Empty `TAG` -> skip' "$s/n1-pr/steps/02-push-create.md" && echo yes || echo no)"
}

# --- NP-199: already-run exclusion and tag release list -----------------------
test_already_run() {
    local tmp; tmp=$(mktemp -d)
    local ov="$tmp/overview.md"
    assert_eq "already-run: no overview -> include" "1" \
        "$(n1_queue_already_run "$ov" >/dev/null && echo 0 || echo 1)"
    printf -- '---\nstep: implement\n---\n' > "$ov"
    assert_eq "already-run: manual run, never queued -> include" "1" \
        "$(n1_queue_already_run "$ov" >/dev/null && echo 0 || echo 1)"
    printf -- '---\nstep: implement\nqueue_run_id: R1\n---\n' > "$ov"
    assert_eq "already-run: queued, flag absent (release failed) -> exclude" "R1" \
        "$(n1_queue_already_run "$ov" || echo include)"
    printf -- '---\nstep: pr\nqueue_run_id: R1\nqueue_tag_removed: false\n---\n' > "$ov"
    assert_eq "already-run: queued, flag false -> exclude" "R1" \
        "$(n1_queue_already_run "$ov" || echo include)"
    printf -- '---\nstep: pr\nqueue_run_id: R1\nqueue_tag_removed: true\n---\n' > "$ov"
    assert_eq "already-run: tag released then re-added by human -> include" "1" \
        "$(n1_queue_already_run "$ov" >/dev/null && echo 0 || echo 1)"
    rm -rf "$tmp"
}

test_release_rows() {
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/h/memory/T-2" "$tmp/h/memory/T-3"
    printf -- '---\nstep: pr\nqueue_tag_removed: true\n---\n' > "$tmp/h/memory/T-2/overview.md"
    printf -- '---\nstep: escalated\n---\n' > "$tmp/h/memory/T-3/overview.md"
    cat > "$tmp/q.md" <<EOF
---
mode: tag
queue_id: n1-auto
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-1 | A | /r | $tmp/h | sonnet | deferred | |
| 2 | T-2 | B | /r | $tmp/h | sonnet | pr | |
| 3 | T-3 | C | /r | $tmp/h | sonnet | escalated | |
| 4 | T-4 | D | /r | $tmp/h | sonnet | pending | |
| 5 | T-5 | E | /r | $tmp/h | sonnet | awaiting-human | |
| 6 | T-1 | A | /r | $tmp/h | sonnet | failed | deferred-retry |
| 7 | T-6 | F | /r | $tmp/h | sonnet | skip | |
| 8 | T-7 | G | /r | $tmp/h | sonnet | stopped | stopped by user |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
EOF
    # N1-268 CR-2: a stopped ticket keeps no queue tag (the next tag-mode queue would re-pick it).
    assert_eq "release-rows: pr/escalated/failed/stopped not yet released, deduped" \
        "$(printf 'T-1\t%s/h,T-3\t%s/h,T-7\t%s/h' "$tmp" "$tmp" "$tmp")" \
        "$(n1_queue_release_rows "$tmp/q.md" | paste -sd, -)"
    sed -i 's/^mode: tag$/mode: story/' "$tmp/q.md"
    assert_eq "release-rows: story mode -> none" "" "$(n1_queue_release_rows "$tmp/q.md")"
    rm -rf "$tmp"
}

# NP-199 (CCR fix): the automatic tag-release backstop (Task 2) needs a stubbable
# command builder, the same test-hook pattern n1_queue_child_cmd already uses.
test_release_cmd() {
    local out
    out=$(N1_QUEUE_RELEASE_STUB=/tmp/release-stub.sh n1_queue_release_cmd n1-auto /r /tmp/log)
    assert_eq "release_cmd: stub hook" '"/tmp/release-stub.sh" "n1-auto"' "$out"
    out=$(unset N1_QUEUE_RELEASE_STUB; n1_queue_release_cmd n1-auto /r /tmp/log)
    assert_eq "release_cmd: claude real command shape" "yes" \
        "$(case "$out" in *'claude -p '*n1-queue*--status*n1-auto*) echo yes ;; *) echo "no: $out" ;; esac)"
}

# --- n1_queue_child_status ---------------------------------------------------
test_child_status() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\nawaiting: merge\npr_url: https://x/pr/1\n' > "$tmp/pr.md"
    printf -- '---\nstep: pr\n---\n# T\n' > "$tmp/pr-nourl.md"
    printf -- '---\nstep: ci\n---\n# T\n' > "$tmp/ci.md"
    printf -- '---\nstep: done\n---\n# T\n' > "$tmp/done.md"
    printf -- '---\nstep: escalated\n---\n# T\n\n## Escalations\n- blocked\n' > "$tmp/esc.md"
    printf -- '---\nstep: qa\n---\n# T\n\n## Escalations\n- QA fail\n' > "$tmp/esc2.md"
    printf -- '---\nstep: implementation\n---\n# T\n' > "$tmp/mid.md"
    printf -- '---\nstep: done\n---\n# T\n\n## Escalations\n- [asked] resolved, continuing\n\npr_url: https://example.com/pr/1\n' > "$tmp/asked-done.md"
    printf -- '---\nstep: qa\n---\n# T\n\n## Escalations\n- Plan review: FIXED - x\n- Approach A auto-decided\n' > "$tmp/benign.md"

    assert_eq "qstatus: step pr -> pr" "pr" "$(n1_queue_child_status "$tmp/pr.md" 0)"
    # N1-53: step pr is written when the PR step begins; only a recorded pr_url makes it terminal.
    assert_eq "qstatus: step pr without url, exit 0 -> running" "running" "$(n1_queue_child_status "$tmp/pr-nourl.md" 0)"
    assert_eq "qstatus: step pr without url, exit 1 -> failed" "failed" "$(n1_queue_child_status "$tmp/pr-nourl.md" 1)"
    assert_eq "qstatus strict: step pr without url -> running" "running" "$(n1_queue_child_status "$tmp/pr-nourl.md" 0 1)"
    assert_eq "qstatus: step ci -> pr" "pr" "$(n1_queue_child_status "$tmp/ci.md" 0)"
    assert_eq "qstatus: step done -> pr" "pr" "$(n1_queue_child_status "$tmp/done.md" 0)"
    assert_eq "qstatus: step escalated" "escalated" "$(n1_queue_child_status "$tmp/esc.md" 0)"
    assert_eq "qstatus: escalations section" "escalated" "$(n1_queue_child_status "$tmp/esc2.md" 0)"
    assert_eq "qstatus: mid-run exit 0 -> running" "running" "$(n1_queue_child_status "$tmp/mid.md" 0)"
    assert_eq "qstatus: mid-run exit 1 -> failed" "failed" "$(n1_queue_child_status "$tmp/mid.md" 1)"
    assert_eq "qstatus: missing file exit 1 -> failed" "failed" "$(n1_queue_child_status "$tmp/none.md" 1)"
    assert_eq "qstatus: missing file exit 0 -> running" "running" "$(n1_queue_child_status "$tmp/none.md" 0)"
    assert_eq "qstatus: ask-mode answered then done -> pr, not escalated" "pr" "$(n1_queue_child_status "$tmp/asked-done.md" 0)"
    # N1-241: autonomous records under ## Escalations are not an escalation.
    assert_eq "qstatus: benign-only escalations, exit 0 -> running" "running" "$(n1_queue_child_status "$tmp/benign.md" 0)"
    assert_eq "qstatus: benign-only escalations, exit 1 -> failed" "failed" "$(n1_queue_child_status "$tmp/benign.md" 1)"

    # NP-216 CR-1: strict mode (live-poll callers) ignores a stale/append-only
    # ## Escalations entry unless step is explicitly "escalated".
    assert_eq "qstatus strict: step escalated" "escalated" "$(n1_queue_child_status "$tmp/esc.md" 0 1)"
    assert_eq "qstatus strict: escalations section but not step -> running" "running" "$(n1_queue_child_status "$tmp/esc2.md" 0 1)"
}

# --- n1_queue_row_status -----------------------------------------------------
test_row_status() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    cat > "$tmp/q.md" <<'EOF'
---
step: plan
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-1 | Fix A | /r | /h | sonnet | pending | |
| 2 | T-2 | Fix B | /r | /h | opus | pending | |
EOF
    n1_queue_row_status "$tmp/q.md" "1" "in-progress"
    local s1; s1=$(awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$8)} $2 ~ /^ *1 *$/ && NF>=9 {print $8}' "$tmp/q.md")
    assert_eq "row_status: in-progress" "in-progress" "$s1"

    n1_queue_row_status "$tmp/q.md" "1" "failed" "timeout"
    local r1; r1=$(awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$9)} $2 ~ /^ *1 *$/ && NF>=9 {print $9}' "$tmp/q.md")
    assert_eq "row_status: reason set" "timeout" "$r1"

    # SEC-3: literal backslash-escapes in a status/reason cell never split the row or forge a `|`.
    n1_queue_row_status "$tmp/q.md" "1" 'st\n1' 'reason\n|inject\174'
    assert_eq "row_status: literal \\n never splits the row" "1" "$(grep -c '^| 1 ' "$tmp/q.md")"
    local r2; r2=$(awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$9)} $2 ~ /^ *1 *$/ && NF>=9 {print $9}' "$tmp/q.md")
    assert_eq "row_status: literal \\n and \\174 in reason never forge a pipe" "reasonninject174" "$r2"
    # Every other cell of the written row, and the sibling row, are untouched.
    assert_eq "row_status: other cells of row 1 untouched" "1" "$(grep -cxF '| 1 | T-1 | Fix A | /r | /h | sonnet | stn1 | reasonninject174 |' "$tmp/q.md")"
    assert_eq "row_status: row 2 untouched" "1" "$(grep -cxF '| 2 | T-2 | Fix B | /r | /h | opus | pending | |' "$tmp/q.md")"

    # NP-203 SEC-4 / CR-1: n1_queue_row_title writes the Title cell ($4), never the Ticket cell ($3).
    n1_queue_row_title "$tmp/q.md" "2" 'evil title\n|inject\174'
    assert_eq "row_title: sanitizes title (no split, no pipe)" "evil titleninject174" "$(plan_cell "$tmp/q.md" 2 4)"
    assert_eq "row_title: Ticket cell unchanged" "T-2" "$(plan_cell "$tmp/q.md" 2 3)"
    assert_eq "row_title: other cells of row 2 untouched" "1" "$(grep -cxF '| 2 | T-2 | evil titleninject174 | /r | /h | opus | pending | |' "$tmp/q.md")"
    assert_eq "row_title: row 1 untouched" "1" "$(grep -cxF '| 1 | T-1 | Fix A | /r | /h | sonnet | stn1 | reasonninject174 |' "$tmp/q.md")"
    # N1-271: an empty reason leaves Reason alone; "clear" empties it (--retry), keeping the row's cell shape.
    n1_queue_row_status "$tmp/q.md" "2" "failed" "boom"
    n1_queue_row_status "$tmp/q.md" "2" "in-progress"
    assert_eq "row_status: empty reason keeps Reason" "boom" "$(plan_cell "$tmp/q.md" 2 9)"
    n1_queue_row_status "$tmp/q.md" "2" "pending" "" clear
    assert_eq "row_status: clear empties Reason" "1" "$(grep -cxF '| 2 | T-2 | evil titleninject174 | /r | /h | opus | pending | |' "$tmp/q.md")"
}

# N1-271: --retry resets exactly one failed/escalated row. Bugs caught: other rows rewritten; a pr/skip row reset;
# the old Reason kept; a reset while the runner is live; a halted/done queue --run cannot resume; stale markers or
# identity of the previous attempt leaking into the relaunch; another ticket's markers removed.
test_queue_retry() {
    local tmp q h out rc pid _wf; source "$REPO_ROOT/lib/orca-queue.sh"   # before the RETURN trap: sourcing fires it
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    q="$tmp/queue/q1/queue.md"; h="$tmp/h"; mkdir -p "${q%/*}" "$h/queue/sentinels"
    cat > "$q" <<EOF
---
queue_id: q1
run_id: R1
step: halted
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-1 | Fix A | /r | $h | sonnet | pr | |
| 2 | T-2 | Fix B | /r | $h | opus | failed | orca-worktree-name-taken |
| 3 | T-3 | Fix C | /r | $h | opus | escalated | review fix cap |
| 4 | T-4 | Fix D | /r | $h | opus | skip | excluded |
EOF
    cp "$q" "$tmp/orig.md"
    _same() { cmp -s "$q" "$tmp/orig.md" && echo same || echo changed; }
    rc=0; HOME="$tmp" n1_queue_retry "$q" 'T-1;rm' 2>/dev/null || rc=$?
    assert_eq "retry: invalid id refused" "1|same" "$rc|$(_same)"
    rc=0; out=$(HOME="$tmp" n1_queue_retry "$q" T-1 2>&1) || rc=$?
    assert_eq "retry: pr row refused, status named" "1|yes|same" "$rc|$(grep -qF 'T-1 is pr' <<< "$out" && echo yes || echo no)|$(_same)"
    rc=0; HOME="$tmp" n1_queue_retry "$q" T-4 2>/dev/null || rc=$?
    assert_eq "retry: skip row refused" "1|same" "$rc|$(_same)"
    rc=0; out=$(HOME="$tmp" n1_queue_retry "$q" T-9 2>&1) || rc=$?
    assert_eq "retry: no row refused" "1|yes|same" "$rc|$(grep -qF 'no row for T-9' <<< "$out" && echo yes || echo no)|$(_same)"
    # A live runner of this queue (cmdline carries scripts/n1-queue-run.sh <queue.md>) is refused.
    bash -c 'sleep 30; :' "$REPO_ROOT/scripts/n1-queue-run.sh" "$q" & pid=$!
    n1_write_frontmatter "$q" pid "$pid"; cp "$q" "$tmp/orig.md"
    rc=0; HOME="$tmp" n1_queue_retry "$q" T-2 2>/dev/null || rc=$?
    assert_eq "retry: live runner refused" "1|same" "$rc|$(_same)"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    # Success: markers and identity of T-2 go, T-3's stay; the halted queue goes to step: run.
    : > "${q%/*}/.launch-2"; : > "${q%/*}/.esc-reason-T-2"; : > "${q%/*}/.ask-T-2"; : > "${q%/*}/.escalated-T-2"
    : > "${q%/*}/.question-T-2.json"; : > "${q%/*}/.ask-T-3"
    # An identity needs a task and a readable worker list showing no live worker for it (stubbed here as empty).
    n1_write_frontmatter "$q" orca_run_id run-1
    n1_orca_liveness() { :; }
    printf 'N1_ORCA_TASK=task-2\n' > "$h/queue/sentinels/T-2.env"; printf 'N1_ORCA_TASK=task-3\n' > "$h/queue/sentinels/T-3.env"
    out=$(HOME="$tmp" n1_queue_retry "$q" T-2)
    assert_eq "retry: prints the resume command" "Retry queued: /n1:n1-queue --run q1" "$out"
    assert_eq "retry: row pending, Reason cleared" "pending|" "$(plan_cell "$q" 2 8)|$(plan_cell "$q" 2 9)"
    assert_eq "retry: other rows unchanged" "3" "$(grep -cxF -e "| 1 | T-1 | Fix A | /r | $h | sonnet | pr | |" \
        -e "| 3 | T-3 | Fix C | /r | $h | opus | escalated | review fix cap |" -e "| 4 | T-4 | Fix D | /r | $h | opus | skip | excluded |" "$q")"
    assert_eq "retry: halted queue set to step run" "run" "$(n1_read_frontmatter "$q" step)"
    assert_eq "retry: run_id not rotated" "R1" "$(n1_read_frontmatter "$q" run_id)"
    assert_eq "retry: previous attempt's markers removed" "0" \
        "$(ls -A "${q%/*}" | grep -cE '^\.(launch-2|esc-reason-T-2|ask-T-2|escalated-T-2|question-T-2\.json)$' || true)"
    assert_eq "retry: another ticket's marker kept" "yes" "$([ -e "${q%/*}/.ask-T-3" ] && echo yes || echo no)"
    assert_eq "retry: identity dropped, other identity kept" "no|yes" \
        "$([ -e "$h/queue/sentinels/T-2.env" ] && echo yes || echo no)|$([ -e "$h/queue/sentinels/T-3.env" ] && echo yes || echo no)"
    # Interrupted run (step run, runner dead): accepted; step stays run.
    out=$(HOME="$tmp" n1_queue_retry "$q" T-3)
    assert_eq "retry: interrupted run accepted" "pending|run" "$(plan_cell "$q" 3 8)|$(n1_read_frontmatter "$q" step)"
    # A planned queue keeps step planned.
    n1_write_frontmatter "$q" step planned; n1_queue_row_status "$q" 1 failed "boom"
    HOME="$tmp" n1_queue_retry "$q" T-1 > /dev/null
    assert_eq "retry: planned queue stays planned" "pending|planned" "$(plan_cell "$q" 1 8)|$(n1_read_frontmatter "$q" step)"
    # SEC-1: the identity file decides whether a worker may be live, not the Runs row. Retry must refuse (changing
    # nothing: row, identity, session pins) while a listed worker of the identity's task is not exited/done, on an
    # unreadable worker list, and on an identity without a task; a readable list with no such worker retries.
    # T-5 started worker, failed row; T-6 worker-start timeout (Runs Session empty, scripts/n1-queue-run.sh);
    # T-7 identity names another task than the Runs row; T-8 identity without a task.
    printf '| %s | T-%s | Fix | /r | %s | opus | failed | %s |\n' 5 5 "$h" worker-failed-after-start 6 6 "$h" worker-start-timeout \
        7 7 "$h" relaunch-start-failed 8 8 "$h" identity-without-task > "$tmp/plan5"
    sed -i "/^| 4 | T-4/r $tmp/plan5" "$q"
    printf '\n## Runs\n| Started | Ticket | Title | Branch | Outcome | Session |\n|---|---|---|---|---|---|\n| s | T-5 | Fix | b | failed | orca:task-5/d-5 |\n| s | T-6 | Fix | b | failed | |\n| s | T-7 | Fix | b | failed | orca:task-old/d-7 |\n' >> "$q"
    mkdir -p "$h/queue/sessions"
    local n; for n in 5 6 7 8; do : > "$h/queue/sessions/T-$n.pin"; done
    printf 'N1_ORCA_TASK=task-5\n' > "$h/queue/sentinels/T-5.env"; printf 'N1_ORCA_TASK=task-6\n' > "$h/queue/sentinels/T-6.env"
    printf 'N1_ORCA_TASK=task-new-7\n' > "$h/queue/sentinels/T-7.env"; printf 'N1_ORCA_RUN=run-1\n' > "$h/queue/sentinels/T-8.env"
    cp "$q" "$tmp/orig.md"
    _kept() { [ -e "$h/queue/sentinels/T-$1.env" ] && echo yes || echo no; [ -e "$h/queue/sessions/T-$1.pin" ] && echo yes || echo no; }
    n1_orca_liveness() { printf 'd-5\ttask-5\tlive\t\nd-6\ttask-6\tlive\t\nd-7\ttask-new-7\tlive\t\n'; }
    rc=0; out=$(HOME="$tmp" n1_queue_retry "$q" T-5 2>&1) || rc=$?
    assert_eq "retry: started live worker refused, nothing changed" "1|yes|same|yes yes" "$rc|$(grep -qF 'may still be running' <<< "$out" && echo yes || echo no)|$(_same)|$(_kept 5 | paste -sd' ')"
    rc=0; HOME="$tmp" n1_queue_retry "$q" T-6 >/dev/null 2>&1 || rc=$?
    assert_eq "retry: worker-start timeout (empty Session) with live worker refused, identity and pins kept" "1|same|yes yes" "$rc|$(_same)|$(_kept 6 | paste -sd' ')"
    rc=0; HOME="$tmp" n1_queue_retry "$q" T-7 >/dev/null 2>&1 || rc=$?
    assert_eq "retry: identity naming another task than the Runs row, worker live, refused" "1|same|yes yes" "$rc|$(_same)|$(_kept 7 | paste -sd' ')"
    rc=0; HOME="$tmp" n1_queue_retry "$q" T-8 >/dev/null 2>&1 || rc=$?
    assert_eq "retry: identity without a task refused" "1|same|yes yes" "$rc|$(_same)|$(_kept 8 | paste -sd' ')"
    n1_orca_liveness() { return 1; }
    rc=0; HOME="$tmp" n1_queue_retry "$q" T-6 >/dev/null 2>&1 || rc=$?
    assert_eq "retry: unreadable worker list refused, identity kept" "1|same|yes yes" "$rc|$(_same)|$(_kept 6 | paste -sd' ')"
    n1_orca_liveness() { printf 'd-5\ttask-5\texited\t\nd-6\ttask-6\tlive\tdone\n'; }
    rc=0; HOME="$tmp" n1_queue_retry "$q" T-5 >/dev/null 2>&1 || rc=$?
    assert_eq "retry: exited worker retried, identity and pins dropped" "0|pending|no no" "$rc|$(plan_cell "$q" 5 8)|$(_kept 5 | paste -sd' ')"
    rc=0; HOME="$tmp" n1_queue_retry "$q" T-6 >/dev/null 2>&1 || rc=$?
    assert_eq "retry: done worker (empty Session row) retried" "0|pending|no no" "$rc|$(plan_cell "$q" 6 8)|$(_kept 6 | paste -sd' ')"
    n1_orca_liveness() { :; }
    rc=0; HOME="$tmp" n1_queue_retry "$q" T-7 >/dev/null 2>&1 || rc=$?
    assert_eq "retry: readable list with no worker for the task retried" "0|pending|no no" "$rc|$(plan_cell "$q" 7 8)|$(_kept 7 | paste -sd' ')"
    # A failed step write changes nothing, and a second retry works once the file is writable again.
    printf '| %s | T-%s | Fix | /r | %s | opus | failed | x |\n' 9 9 "$h" >> "$tmp/plan9"
    sed -i "/^| 8 | T-8/r $tmp/plan9" "$q"
    printf 'N1_ORCA_TASK=task-9\nN1_ORCA_RUN=run-1\n' > "$h/queue/sentinels/T-9.env"; : > "${q%/*}/.ask-T-9"
    sed -i 's/^step: .*/step: halted/' "$q"; n1_orca_liveness() { :; }
    _wf=$(declare -f n1_write_frontmatter); n1_write_frontmatter() { return 1; }
    cp "$q" "$tmp/orig.md"
    rc=0; HOME="$tmp" n1_queue_retry "$q" T-9 >/dev/null 2>&1 || rc=$?
    assert_eq "retry: failed step write leaves row, marker and identity intact" "1|same|yes|yes" \
        "$rc|$(_same)|$([ -e "${q%/*}/.ask-T-9" ] && echo yes || echo no)|$([ -e "$h/queue/sentinels/T-9.env" ] && echo yes || echo no)"
    eval "$_wf"
    rc=0; HOME="$tmp" n1_queue_retry "$q" T-9 >/dev/null 2>&1 || rc=$?
    assert_eq "retry: second retry after the failed write succeeds" "0|pending|no" \
        "$rc|$(plan_cell "$q" 9 8)|$([ -e "$h/queue/sentinels/T-9.env" ] && echo yes || echo no)"
    unset -f n1_orca_liveness; source "$REPO_ROOT/lib/orca-queue.sh"   # restore the real helper
    # Missing queue file.
    rc=0; out=$(HOME="$tmp" n1_queue_retry "" T-1 2>&1) || rc=$?
    assert_eq "retry: no queue" "1|No queue runs found." "$rc|$out"
}

# --- run.md § Write plan cell-fill snippet (NP-203): free text with quotes via cells.tsv ---
test_write_plan_cells() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/desc"
    cat > "$tmp/queue.md" <<'EOF2'
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-1 |  | /r | /h | sonnet | pending |  |
| 2 | T-2 |  | /r | /h | opus | pending |  |

## Decisions
| Ticket | Touches | Order | Stop-List Pre-Decision | Desc Checksum | Notes |
|--------|---------|-------|-------------------------|---------------|-------|
| T-1 |  |  |  |  |  |
| T-2 |  |  |  |  |  |
EOF2
    printf "Fix the user's \"login\" \$(touch %s/pwned)" "$tmp" > "$tmp/desc/T-1.title"; printf 'd1' > "$tmp/desc/T-1.txt"
    printf 'Plain B' > "$tmp/desc/T-2.title"; printf 'd2' > "$tmp/desc/T-2.txt"
    printf "1\tT-1\ttag match · it's first\tr:lib\t\tsecurity: narrow\tnarrow:don't touch \"auth\"\n2\tT-2\t\t\tafter T-1 (r:lib)\t\tkeep\tthis" > "$tmp/cells.tsv"  # no trailing newline; tab in last Notes
    # Run the snippet exactly as run.md ships it (minus the preamble line).
    local snip; snip=$(awk '/^while IFS= read -r line \|\| \[ -n "\$line" \]; do$/,/^done < "\$QUEUE_DIR\/cells.tsv"$/' "$REPO_ROOT/skills/n1-queue/steps/run.md")
    QUEUE_DIR="$tmp" bash -c "source '$REPO_ROOT/lib/config.sh'; source '$REPO_ROOT/lib/queue.sh'; QUEUE_FILE=\"\$QUEUE_DIR/queue.md\"; $snip"
    assert_eq "write-plan: title with quotes lands in Title cell" "Fix the user's \"login\" \$(touch $tmp/pwned)" "$(plan_cell "$tmp/queue.md" 1 4)"
    assert_eq "write-plan: title never executed" "no" "$([ -e "$tmp/pwned" ] && echo yes || echo no)"
    assert_eq "write-plan: reason with apostrophe" "tag match · it's first" "$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "write-plan: row 2 title" "Plain B" "$(plan_cell "$tmp/queue.md" 2 4)"
    assert_eq "write-plan: notes with quotes" "narrow:don't touch \"auth\"" "$(n1_queue_decisions_row "$tmp/queue.md" T-1 | cut -f5)"
    assert_eq "write-plan: empty touches stays empty, order kept" "	after T-1 (r:lib)" "$(n1_queue_decisions_row "$tmp/queue.md" T-2 | cut -f1,2)"
    assert_eq "write-plan: last row without trailing newline still written" "keep this" "$(n1_queue_decisions_row "$tmp/queue.md" T-2 | cut -f5)"
    assert_eq "write-plan: checksum from desc files" "$(n1_queue_content_hash "$tmp/desc/T-2.title" "$tmp/desc/T-2.txt")" "$(n1_queue_decisions_row "$tmp/queue.md" T-2 | cut -f4)"
}

# --- n1_queue_pending_rows ---------------------------------------------------
test_pending_rows() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    cat > "$tmp/q.md" <<'EOF'
---
step: plan
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-1 | Fix A | /repo1 | /home1 | sonnet | pr | |
| 2 | T-2 | Fix B | /repo2 | /home2 | opus | pending | |
| 3 | T-3 | Fix C | /repo3 | /home3 | sonnet | pending | |
EOF
    local out; out=$(n1_queue_pending_rows "$tmp/q.md")
    local count; count=$(echo "$out" | wc -l)
    assert_eq "pending: count" "2" "$count"
    local first; first=$(echo "$out" | head -1)
    assert_eq "pending: first row" "2	T-2	/home2	opus" "$(echo "$first" | cut -f1,2,4,5)"
}


# --- Background-session helpers ----------------------------------------------
test_bg_helpers() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

    assert_eq "launch: session id" "a1b2c3d4" \
        "$(n1_queue_parse_launch $'Starting session\nbackgrounded \xc2\xb7 a1b2c3d4 \xc2\xb7 n1-q-T-1-1')"
    assert_eq "launch: session id (ANSI-colored, NP-209)" "8aa56c97" \
        "$(n1_queue_parse_launch $'backgrounded \xc2\xb7 \x1b[36m8aa56c97\x1b[39m \xc2\xb7 n1-n1-auto-NP-193-1')"
    assert_eq "launch: disclaimer" "bypass-permissions-disclaimer" \
        "$(n1_queue_parse_launch 'Accept the disclaimer first: run claude --dangerously-skip-permissions')"
    assert_eq "launch: generic failure" "bg-launch-failed" \
        "$(n1_queue_parse_launch 'error: unknown option --bg')"

    local j='{"agents":[{"kind":"background","id":"aaaaaaaa","sessionId":"aaaaaaaa-0000-0000-0000-000000000000","name":"a","state":"working"},{"kind":"background","id":"bbbbbbbb","sessionId":"bbbbbbbb-0000-0000-0000-000000000000","name":"b","state":"blocked","waitingFor":"input"},{"kind":"background","id":"cccccccc","sessionId":"cccccccc-0000-0000-0000-000000000000","name":"c","state":"done"},{"kind":"background","id":"dddddddd","sessionId":"dddddddd-0000-0000-0000-000000000000","name":"d","state":"stopped"},{"kind":"background","id":"eeeeeeee","sessionId":"eeeeeeee-0000-0000-0000-000000000000","name":"e","state":"failed"}]}'
    assert_eq "bgstate: working" "working" "$(n1_queue_bg_state "$j" aaaaaaaa)"
    assert_eq "bgstate: blocked" "blocked" "$(n1_queue_bg_state "$j" bbbbbbbb)"
    assert_eq "bgstate: done" "done" "$(n1_queue_bg_state "$j" cccccccc)"
    assert_eq "bgstate: stopped -> failed" "failed" "$(n1_queue_bg_state "$j" dddddddd)"
    assert_eq "bgstate: failed" "failed" "$(n1_queue_bg_state "$j" eeeeeeee)"
    assert_eq "bgstate: missing" "missing" "$(n1_queue_bg_state "$j" 0f0f0f0f)"
    assert_eq "bgstate: bare array" "blocked" "$(n1_queue_bg_state '[{"id":"bbbbbbbb","state":"blocked"}]' bbbbbbbb)"

    # Stale record with the same name but a different id must not shadow the live child.
    local jstale='{"agents":[{"kind":"background","id":"11111111","sessionId":"11111111-0000","name":"n1-q-T-1-1","state":"done"},{"kind":"background","id":"22222222","sessionId":"22222222-0000","name":"n1-q-T-1-1","state":"working"}]}'
    assert_eq "bgstate: stale same-name record ignored" "working" "$(n1_queue_bg_state "$jstale" 22222222)"

    # Not listed on the first poll (supervisor lag), appears later as done.
    assert_eq "bgstate: missing then done" "missing" "$(n1_queue_bg_state '{"agents":[]}' 33333333)"
    assert_eq "bgstate: missing then done (appears)" "done" \
        "$(n1_queue_bg_state '{"agents":[{"id":"33333333","state":"done"}]}' 33333333)"

    # SEC-1: an empty or malformed session id must never match any listed session via startswith("").
    assert_eq "bgstate: empty sid -> failed" "failed" "$(n1_queue_bg_state "$j" "")"
    assert_eq "bgstate: non-hex sid -> failed" "failed" "$(n1_queue_bg_state "$j" zzzzzzzz)"

    local cc
    cc=$(unset N1_STORY_PLUGIN_DIR; n1_queue_child_cmd /r T-1 sonnet RUN1 /tmp/log n1-q-T-1-1)
    assert_eq "child_cmd: claude-code bg launch" "yes" "$(case "$cc" in "cd /r && claude --bg --name n1-q-T-1-1 --model sonnet --permission-mode bypassPermissions --settings "*bgIsolation*"/n1:n1-start\ T-1"*) echo yes ;; *) echo "no: $cc" ;; esac)"
    assert_eq "child_cmd: claude-code has N1_UNATTENDED=ask" "yes" \
        "$(case "$cc" in *'N1_UNATTENDED'*'ask'*) echo yes ;; *) echo no ;; esac)"

    cc=$(unset N1_STORY_PLUGIN_DIR; N1_QUEUE_TAG=n1-auto n1_queue_child_cmd /r T-1 sonnet RUN1 /tmp/log n1-q-T-1-1)
    assert_eq "child_cmd: claude-code forwards N1_QUEUE_TAG" "yes" \
        "$(case "$cc" in *'N1_QUEUE_TAG'*'n1-auto'*) echo yes ;; *) echo "no: $cc" ;; esac)"
    cc=$(unset N1_STORY_PLUGIN_DIR; N1_QUEUE_DIR=/q/dir n1_queue_child_cmd /r T-1 sonnet RUN1 /tmp/log n1-q-T-1-1)
    assert_eq "child_cmd: claude-code forwards N1_QUEUE_DIR" "yes" \
        "$(case "$cc" in *'N1_QUEUE_DIR'*'/q/dir'*) echo yes ;; *) echo "no: $cc" ;; esac)"

    cat > "$tmp/q.md" <<'EOF'
---
step: run
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-1 | A | /r | /h | sonnet | pr | |
| 2 | T-2 | B | /r | /h | sonnet | awaiting-human | |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
| T-1 | s | | pr | u | 00000001 |
| T-2 | s | | | | 0000abcd |
EOF
    assert_eq "session_id: last Runs row" "0000abcd" "$(n1_queue_session_id "$tmp/q.md" T-2)"
    assert_eq "session_id: unknown ticket" "" "$(n1_queue_session_id "$tmp/q.md" T-9)"
    assert_eq "rows: status filter + status field" "2	T-2	/r	/h	sonnet	awaiting-human" \
        "$(n1_queue_pending_rows "$tmp/q.md" 'awaiting-human')"
    assert_eq "awaiting hints" "T-2: claude attach 0000abcd" "$(n1_queue_awaiting_hints "$tmp/q.md")"
}

# --- n1_queue_event / n1_queue_escalation_text ------------------------------
test_queue_event() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    local f="$tmp/events.jsonl"
    n1_queue_event "$f" q1 R1 ticket_finished ticket=T-1 outcome=pr pr=https://x/pr/1 duration_s=42 reason='a=b'
    n1_queue_event "$f" q1 R1 queue_started
    assert_eq "event: two lines" "2" "$(wc -l < "$f" | tr -d ' ')"
    assert_eq "event: uniform 10 keys" "true" "$(jq -s 'all(keys | length == 10)' "$f")"
    assert_eq "event: fields" "q1|R1|ticket_finished|T-1|pr|42|a=b" \
        "$(head -1 "$f" | jq -r '[.queue,.run_id,.event,.ticket,.outcome,(.duration_s|tostring),.reason]|join("|")')"
    assert_eq "event: duration number" "number" "$(head -1 "$f" | jq -r '.duration_s|type')"
    assert_eq "event: missing duration null" "null" "$(tail -1 "$f" | jq -r '.duration_s')"
    assert_eq "event: missing ticket empty" "" "$(tail -1 "$f" | jq -r '.ticket')"
    assert_eq "event: ts format" "yes" "$(tail -1 "$f" | jq -r .ts | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' && echo yes || echo no)"
    local rc=0; n1_queue_event "$tmp/no/such/dir/e.jsonl" q1 R1 x || rc=$?
    assert_eq "event: unwritable path is fail-open" "0" "$rc"
}

test_escalation_text() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    printf -- '---\nstep: escalated\n---\n# T\n\n## Escalations\n\n- Which DB should we use?\n- second\n\n## Notes\nx\n' > "$tmp/o.md"
    assert_eq "esc-text: first entry" "Which DB should we use?" "$(n1_queue_escalation_text "$tmp/o.md")"
    printf -- '---\nstep: pr\n---\n# T\n\n## Escalations\n\n## Notes\nx\n' > "$tmp/o2.md"
    assert_eq "esc-text: empty section" "" "$(n1_queue_escalation_text "$tmp/o2.md")"
    assert_eq "esc-text: missing file" "" "$(n1_queue_escalation_text "$tmp/none.md")"
    # N1-241: autonomous records are not escalations; unknown shapes and [headless] entries are.
    printf -- '---\nstep: pr\n---\n# T\n\n## Key Decisions\n- Plan review: FIXED - tightened Task 3\n- Approach A auto-decided (21/25)\n\n## Escalations\n\n## Notes\nx\n' > "$tmp/kd.md"
    assert_eq "esc-text: Key Decisions-only overview" "" "$(n1_queue_escalation_text "$tmp/kd.md")"
    printf -- '---\nstep: pr\n---\n# T\n\n## Key Decisions\n\n## Escalations\n- Plan review: FIXED - tightened Task 3\n- Approach A auto-decided (21/25)\n- [auto-decided] storage: sqlite\n' > "$tmp/benign.md"
    assert_eq "esc-text: benign-only Escalations" "" "$(n1_queue_escalation_text "$tmp/benign.md")"
    printf -- '---\nstep: qa\n---\n# T\n\n## Escalations\n- Plan review: FIXED - x\n- finish: merge blocked by required review\n' > "$tmp/mixed.md"
    assert_eq "esc-text: benign then real -> real" "finish: merge blocked by required review" "$(n1_queue_escalation_text "$tmp/mixed.md")"
    printf -- '---\nstep: escalated\n---\n# T\n\n## Escalations\n- [headless] plan: approach auto-decided? options: a, b\n' > "$tmp/hl.md"
    assert_eq "esc-text: [headless] never skipped" "[headless] plan: approach auto-decided? options: a, b" "$(n1_queue_escalation_text "$tmp/hl.md")"
    printf -- '---\nstep: qa\n---\n# T\n\n## Escalations\n- finish: blocked, cannot be auto-decided\n' > "$tmp/neg.md"
    assert_eq "esc-text: unanchored auto-decided not skipped" "finish: blocked, cannot be auto-decided" "$(n1_queue_escalation_text "$tmp/neg.md")"
    # N1-241 review: verdict-anchored plan review, exact [auto] shapes, continuation lines.
    printf -- '---\nstep: qa\n---\n# T\n\n## Escalations\n- Plan review failed: needs human\n' > "$tmp/pr.md"
    assert_eq "esc-text: unverdicted plan review printed" "Plan review failed: needs human" "$(n1_queue_escalation_text "$tmp/pr.md")"
    printf -- '---\nstep: qa\n---\n# T\n\n## Escalations\n- [automerge] blocked, need you\n' > "$tmp/am.md"
    assert_eq "esc-text: [automerge] printed" "[automerge] blocked, need you" "$(n1_queue_escalation_text "$tmp/am.md")"
    printf -- '---\nstep: qa\n---\n# T\n\n## Escalations\n- Plan review: FIXED - tightened\n  wrapped continuation\n- real stop\n' > "$tmp/wrap.md"
    assert_eq "esc-text: continuation of skipped entry skipped" "real stop" "$(n1_queue_escalation_text "$tmp/wrap.md")"
    # N1-241 SEC-5: only an indented line directly after the skipped entry is its continuation.
    printf -- '---\nstep: qa\n---\n# T\n\n## Escalations\n- Plan review: FIXED - x\n\nfinish: merge blocked\n' > "$tmp/blank.md"
    assert_eq "esc-text: blank line ends continuation" "finish: merge blocked" "$(n1_queue_escalation_text "$tmp/blank.md")"
    printf -- '---\nstep: qa\n---\n# T\n\n## Escalations\n- [auto-decided] x\nworktree setup auto-retry attempted\n' > "$tmp/unind.md"
    assert_eq "esc-text: un-indented line after skipped entry printed" "worktree setup auto-retry attempted" "$(n1_queue_escalation_text "$tmp/unind.md")"
    printf -- '---\nstep: qa\n---\n# T\n\n## Escalations\n- real one\n  wrapped\n- real two\n' > "$tmp/last.md"
    assert_eq "esc-text: last mode prints newest entry" "real two" "$(n1_queue_escalation_text "$tmp/last.md" last)"
    assert_eq "esc-text: headless step still resolves" "plan" "$(_n1_queue_escalated_step "$tmp/hl.md")"
}

# --- n1_desktop_notify / n1_notify -------------------------------------------
test_desktop_notify() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/bin"; ln -s "$(command -v timeout)" "$tmp/bin/timeout"
    printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/notify-send"            # present but broken
    printf '#!/bin/sh\necho "$@" > "%s/osa"\n' "$tmp" > "$tmp/bin/osascript"
    chmod +x "$tmp/bin/notify-send" "$tmp/bin/osascript"
    local rc=0; ( export PATH="$tmp/bin"; n1_desktop_notify "Title" "Body" ) || rc=$?
    assert_eq "desktop: falls through broken backend" "0" "$rc"
    assert_eq "desktop: osascript used" "yes" "$([ -f "$tmp/osa" ] && echo yes || echo no)"
    rm -f "$tmp/bin/notify-send" "$tmp/bin/osascript"
    rc=0; ( export PATH="$tmp/bin"; n1_desktop_notify "Title" "Body" ) || rc=$?
    assert_eq "desktop: none available -> 1" "1" "$rc"
    printf '#!/bin/sh\necho "$N1_NT|$N1_NB" > "%s/ps"\n' "$tmp" > "$tmp/ps.exe"; chmod +x "$tmp/ps.exe"
    rc=0; ( export PATH="$tmp/bin"; N1_WSL_POWERSHELL="$tmp/ps.exe" n1_desktop_notify "Title" "Body" ) || rc=$?
    assert_eq "desktop: WSL powershell off PATH used" "0|Title|Body" "$rc|$(cat "$tmp/ps" 2>/dev/null)"
}

test_desktop_notify_stdin() {   # N1-265: no desktop backend may consume the caller's stdin (WSL powershell.exe drains it)
    local tmp b out; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/bin"; ln -s "$(command -v timeout)" "$tmp/bin/timeout"
    printf '#!/bin/sh\nwhile read -r _; do :; done\nexit 0\n' > "$tmp/drain"; chmod +x "$tmp/drain"
    for b in notify-send osascript; do
        rm -f "$tmp/bin/notify-send" "$tmp/bin/osascript"; cp "$tmp/drain" "$tmp/bin/$b"
        out=$(printf 'a\nb\nc\n' | { read -r _; ( export PATH="$tmp/bin"; n1_desktop_notify T B ); cat; } | paste -sd, -)
        assert_eq "desktop-stdin: $b leaves caller stdin alone" "b,c" "$out"
    done
    rm -f "$tmp/bin/notify-send" "$tmp/bin/osascript"
    out=$(printf 'a\nb\nc\n' | { read -r _; ( export PATH="$tmp/bin"; N1_WSL_POWERSHELL="$tmp/drain" n1_desktop_notify T B ); cat; } | paste -sd, -)
    assert_eq "desktop-stdin: powershell leaves caller stdin alone" "b,c" "$out"
}

test_notify_backends() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    local TEST_CONFIG="$tmp/config.json"
    n1_config_file() { echo "$TEST_CONFIG"; }

    assert_eq "notify: default backend desktop" "desktop" "$(n1_queue_val notify)"

    printf '{"queue":{"notify":"command","notifyCommand":"cat >> %s/notes"}}' "$tmp" > "$TEST_CONFIG"
    n1_notify needs-you "T-1 needs you"
    n1_notify done "Queue q: 1 PR / 0 awaiting / 0 failed"
    assert_eq "notify: command gets JSON on stdin" "needs-you|T-1 needs you" "$(head -1 "$tmp/notes" | jq -r '.kind + "|" + .text')"
    assert_eq "notify: one line per call" "2" "$(wc -l < "$tmp/notes" | tr -d ' ')"

    printf '{"queue":{"notify":"command","notifyCommand":"exit 7"}}' > "$TEST_CONFIG"
    local rc=0; n1_notify info "x" || rc=$?
    assert_eq "notify: failing command is fail-open" "0" "$rc"

    printf '{"queue":{"notify":"command","notifyCommand":"sleep 30"}}' > "$TEST_CONFIG"
    local start end elapsed
    start=$(date +%s); rc=0; n1_notify info "x" || rc=$?; end=$(date +%s)
    elapsed=$((end - start))
    assert_eq "notify: hanging command is fail-open" "0" "$rc"
    assert_eq "notify: hanging command bounded by timeout" "yes" "$([ "$elapsed" -lt 20 ] && echo yes || echo no)"

    printf '{"queue":{"notify":"none","notifyCommand":"cat >> %s/none"}}' "$tmp" > "$TEST_CONFIG"
    n1_notify info "x"
    assert_eq "notify: none is a no-op" "no" "$([ -f "$tmp/none" ] && echo yes || echo no)"

    # desktop with no notifier on PATH: skip line on stderr, rc 0
    mkdir -p "$tmp/bin"; local c
    for c in jq timeout date; do ln -s "$(command -v "$c")" "$tmp/bin/$c"; done
    printf '{"queue":{"notify":"desktop"}}' > "$TEST_CONFIG"
    rc=0; ( export PATH="$tmp/bin"; n1_notify needs-you "T-2 needs you" ) 2> "$tmp/err" || rc=$?
    assert_eq "notify: desktop skip rc 0" "0" "$rc"
    assert_eq "notify: desktop skip logged" "yes" "$(grep -q 'no desktop notifier available; skipped (needs-you: T-2 needs you)' "$tmp/err" && echo yes || echo no)"
    unset -f n1_config_file
}

# --- n1_queue_decision_counts ------------------------------------------------
test_decision_counts() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

    # Overview for T-A: 2 headless rows + 1 non-headless
    mkdir -p "$tmp/n1home/memory/T-A" "$tmp/n1home/memory/T-B" "$tmp/n1home/memory/T-C"
    printf '| implementation | headless | detail |\n| implementation | headless | detail |\n| implementation | developer | detail |\n' \
        > "$tmp/n1home/memory/T-A/overview.md"
    # Overview for T-B (escalated): 1 headless row
    printf '| qa | headless | blocked |\n' > "$tmp/n1home/memory/T-B/overview.md"
    # Overview for T-C (pending): 5 headless rows — must NOT count
    printf '| implementation | headless | x |\n%.0s' {1..5} > "$tmp/n1home/memory/T-C/overview.md"

    cat > "$tmp/queue.md" <<EOF
---
queue_id: test-dc
step: run
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-A | Fix A | /r | $tmp/n1home | sonnet | pr | |
| 2 | T-B | Fix B | /r | $tmp/n1home | sonnet | escalated | |
| 3 | T-C | Fix C | /r | $tmp/n1home | sonnet | pending | |

## Decision Ledger
| Step | Decision | Detail |
|------|----------|--------|
| preview | edit | change 1 |
| preview | edit | change 2 |
| preview | skip | no change |

## Runs
EOF

    local out; out=$(n1_queue_decision_counts "$tmp/queue.md")
    assert_eq "decision_counts: 2 plan 3 auto 1 esc" "$(printf '2\t3\t1')" "$out"
}

# --- n1_queue_digest ---------------------------------------------------------
test_queue_digest() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    assert_eq "digest: no queues -> nothing" "" "$(n1_queue_digest "$tmp")"
    mkdir -p "$tmp/queue/q1" "$tmp/queue/q2" "$tmp/queue/q3"
    local e1="$tmp/queue/q1/events.jsonl" e2="$tmp/queue/q2/events.jsonl"
    # q2: an older failed run is ignored; the latest run finished with one PR
    n1_queue_event "$e2" q2 R0 ticket_finished ticket=T-8 outcome=failed
    n1_queue_event "$e2" q2 R1 queue_started
    n1_queue_event "$e2" q2 R1 ticket_started ticket=T-9
    n1_queue_event "$e2" q2 R1 ticket_finished ticket=T-9 outcome=pr
    n1_queue_event "$e2" q2 R1 queue_done reason="1 PR / 0 awaiting / 0 failed"
    assert_eq "digest: finished queue" "Queue q2: 1 PR, done" "$(n1_queue_digest "$tmp")"
    # q1: running, one needs you; wins over q2; a corrupt line is tolerated
    n1_queue_event "$e1" q1 R1 queue_started
    n1_queue_event "$e1" q1 R1 ticket_started ticket=T-1
    n1_queue_event "$e1" q1 R1 ticket_finished ticket=T-1 outcome=pr
    n1_queue_event "$e1" q1 R1 ticket_started ticket=T-2
    echo 'not json {' >> "$e1"
    n1_queue_event "$e1" q1 R1 escalated ticket=T-2
    n1_queue_event "$e1" q1 R1 ticket_started ticket=T-3
    assert_eq "digest: needs-you queue preferred" "Queue q1: 1 PR, 1 needs you (T-2), running T-3" "$(n1_queue_digest "$tmp")"
    # N1-359: an informational worker_stopped event (last for its ticket) must not hide needs-you or running
    n1_queue_event "$e1" q1 R1 worker_stopped ticket=T-2 reason="stopped (finished): x"
    n1_queue_event "$e1" q1 R1 worker_stopped ticket=T-3 reason="stopped (finished): y"
    assert_eq "digest: worker_stopped ignored" "Queue q1: 1 PR, 1 needs you (T-2), running T-3" "$(n1_queue_digest "$tmp")"
    # N1-315: an informational stalled event on a live ticket must not drop it from running
    n1_queue_event "$e1" q1 R1 stalled ticket=T-3 reason="phase=impl age=31m"
    assert_eq "digest: stalled ignored" "Queue q1: 1 PR, 1 needs you (T-2), running T-3" "$(n1_queue_digest "$tmp")"
    # q3: stale (older than 24h) never shows, even with an escalation
    rm -rf "$tmp/queue/q1" "$tmp/queue/q2"
    printf '{"ts":"2020-01-01T00:00:00Z","queue":"q3","run_id":"R1","event":"escalated","ticket":"T-5","outcome":"","pr":"","session":"","duration_s":null,"reason":""}\n' \
        > "$tmp/queue/q3/events.jsonl"
    assert_eq "digest: stale queue hidden" "" "$(n1_queue_digest "$tmp")"
}

test_fmt_elapsed() {
    assert_eq "elapsed: sub-minute" "<1m" "$(n1_fmt_elapsed 30)"
    assert_eq "elapsed: minutes" "5m" "$(n1_fmt_elapsed 300)"
    assert_eq "elapsed: hours+minutes" "1h5m" "$(n1_fmt_elapsed 3900)"
    assert_eq "elapsed: empty input" "" "$(n1_fmt_elapsed '')"
    assert_eq "elapsed: non-numeric input" "" "$(n1_fmt_elapsed abc)"
}

# N1-55: main-thread answer relay (stop + bg-resume) for a child parked on a question.
test_queue_answer() {
    local tmp q out rc; tmp=$(mktemp -d)
    q="$tmp/n1home/queue/q1"; mkdir -p "$q" "$tmp/bin" "$tmp/repo"
    local af="$tmp/n1home/queue/.answer-T-1.txt"
    mkq() { # <status>
        printf -- '---\nqueue_id: q1\nrun_id: R1\nmode: tag\n---\n## Plan\n| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |\n|---|---|---|---|---|---|---|---|\n| 1 | T-1 | Fix | %s | %s | sonnet | %s | |\n\n## Runs\n| Ticket | Started | Exit | Outcome | PR | Session |\n|---|---|---|---|---|---|\n| T-1 | x | | | | 0000abcd |\n' \
            "$tmp/repo" "$tmp/n1home" "$1" > "$q/queue.md"
        printf '{"ticket":"T-1","step":"brainstorm","question":"Back-port?","options":["Back-port","Skip"],"recommended":"Back-port"}' > "$q/.question-T-1.json"
        : > "$q/events.jsonl"; rm -f "$tmp/log" "$tmp/prompt" "$tmp/fail-resume" "$tmp/no-full" "$q/.relay-T-1"
        echo blocked > "$tmp/state"
    }
    cat > "$tmp/bin/claude" <<'FAKEEOF'
#!/usr/bin/env bash
L="$FAKE_DIR/log"
case "$1" in
    agents) st=$(cat "$FAKE_DIR/state"); grep -q '^stop' "$L" 2>/dev/null && st=stopped
            if [ -f "$FAKE_DIR/no-full" ]; then printf '[{"id":"0000abcd","state":"%s"}]\n' "$st"
            else printf '[{"id":"0000abcd","sessionId":"0000abcd-1111-2222","state":"%s"}]\n' "$st"; fi ;;
    stop) echo "stop $2" >> "$L" ;;
    --bg) echo "resume $3" >> "$L"
          printf '%s' "$4" > "$FAKE_DIR/prompt"; [ ! -f "$FAKE_DIR/fail-resume" ] ;;
esac
FAKEEOF
    printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/sleep"
    chmod +x "$tmp/bin/claude" "$tmp/bin/sleep"
    ans() { [ -e "$af" ] || printf B > "$af"; rc=0; out=$(FAKE_DIR="$tmp" PATH="$tmp/bin:$PATH" n1_queue_answer "$tmp/n1home" "$@" 2>&1) || rc=$?; }

    # Happy path: hostile-looking answer reaches the child as one literal argv element.
    mkq awaiting-human
    # N1-60: seed the escalated event the runner would already have written (full question
    # packed into reason, as escalate() in scripts/n1-queue-run.sh does) before --answer runs.
    jq -nc '{ts:"t",queue:"q1",run_id:"R1",event:"escalated",ticket:"T-1",outcome:"",pr:"",
        session:"0000abcd",duration_s:null,
        reason:({question:"Back-port?",options:["Back-port","Skip"],recommended:"Back-port",rationale:""}|tostring)}' \
        >> "$q/events.jsonl"
    printf '%s' 'stale reason' > "$q/.esc-reason-T-1"
    printf '%s' "B; \$(touch $tmp/pwned) \"q\"" > "$af"
    ans T-1
    assert_eq "answer: rc 0" "0" "$rc"
    assert_eq "answer: stop then resume (full session id)" \
        "stop 0000abcd|resume 0000abcd-1111-2222" "$(paste -sd'|' "$tmp/log")"
    assert_eq "answer: prompt is prefixed literal answer" "[n1-queue answer] B; \$(touch $tmp/pwned) \"q\"" "$(cat "$tmp/prompt")"
    assert_eq "answer: never shell-interpolated" "no" "$([ -e "$tmp/pwned" ] && echo yes || echo no)"
    assert_eq "answer: answer file deleted after read" "no" "$([ -e "$af" ] && echo yes || echo no)"
    assert_eq "answer: question file removed" "no" "$([ -e "$q/.question-T-1.json" ] && echo yes || echo no)"
    assert_eq "answer: relay marker written" "yes" "$([ -e "$q/.relay-T-1" ] && echo yes || echo no)"
    assert_eq "answer: escalation marker cleared (N1-241)" "no" "$([ -e "$q/.esc-reason-T-1" ] && echo yes || echo no)"
    assert_eq "answer: answer_delivered event" "answer_delivered,T-1,0000abcd,R1" \
        "$(jq -r 'select(.event=="answer_delivered") | [.event,.ticket,.session,.run_id]|join(",")' "$q/events.jsonl")"
    assert_eq "N1-60: full question survives --answer + file removal" "Back-port?" \
        "$(jq -r 'select(.event=="escalated") | (.reason | fromjson?) | .question' "$q/events.jsonl")"

    # Size cap: 5000 chars -> 4000 + marker.
    mkq awaiting-human
    head -c 5000 /dev/zero | tr '\0' x > "$af"
    ans T-1
    # "[n1-queue answer] " (18) + 4000 + "... [truncated]" (15)
    assert_eq "answer: capped at 4000 chars" "4033" "$(wc -c < "$tmp/prompt")"

    # Refusals: no CLI side effects.
    mkq awaiting-human; rm -f "$q/.question-T-1.json"
    ans T-1
    assert_eq "answer: no question file -> rc 1" "1" "$rc"
    assert_eq "answer: no question file -> no claude calls" "no" "$([ -e "$tmp/log" ] && echo yes || echo no)"
    mkq in-progress
    ans T-1
    assert_eq "answer: row not awaiting-human -> rc 1" "1" "$rc"
    mkq awaiting-human; echo working > "$tmp/state"
    ans T-1
    assert_eq "answer: working session -> rc 1" "1" "$rc"
    assert_eq "answer: working session -> not stopped" "no" "$([ -e "$tmp/log" ] && echo yes || echo no)"
    mkq awaiting-human
    ans ../x
    assert_eq "answer: bad ticket id -> rc 1" "1" "$rc"
    assert_eq "answer: bad ticket id -> no file read/deleted (SEC-4)" "yes" "$([ -e "$af" ] && echo yes || echo no)"

    # Resume failure: question kept for retry, no answer_delivered, attach hint printed.
    mkq awaiting-human; touch "$tmp/fail-resume"
    ans T-1
    assert_eq "answer: resume fail -> rc 1" "1" "$rc"
    assert_eq "answer: resume fail -> question kept" "yes" "$([ -e "$q/.question-T-1.json" ] && echo yes || echo no)"
    assert_eq "answer: resume fail -> no event" "" "$(cat "$q/events.jsonl")"
    assert_eq "answer: resume fail -> interactive resume hint (session stopped)" "yes" \
        "$(case "$out" in *"claude --resume 0000abcd-1111-2222"*) echo yes ;; *) echo no ;; esac)"
    assert_eq "answer: resume fail -> no attach hint" "no" "$(case "$out" in *"claude attach"*) echo yes ;; *) echo no ;; esac)"
    assert_eq "answer: resume fail -> answer file deleted" "no" "$([ -e "$af" ] && echo yes || echo no)"
    # Retry after the failed resume: session already stopped -> resume only, no second stop.
    rm -f "$tmp/fail-resume"
    ans T-1
    assert_eq "answer: retry -> rc 0" "0" "$rc"
    assert_eq "answer: retry -> resume only" "stop 0000abcd|resume 0000abcd-1111-2222|resume 0000abcd-1111-2222" \
        "$(paste -sd'|' "$tmp/log")"

    # Full session id unresolvable: refuse before any stop/resume, keep the question, attach hint.
    mkq awaiting-human; touch "$tmp/no-full"
    ans T-1
    assert_eq "answer: no sessionId -> rc 1" "1" "$rc"
    assert_eq "answer: no sessionId -> no stop/resume" "no" "$([ -e "$tmp/log" ] && echo yes || echo no)"
    assert_eq "answer: no sessionId -> question kept" "yes" "$([ -e "$q/.question-T-1.json" ] && echo yes || echo no)"
    assert_eq "answer: no sessionId -> answer file deleted" "no" "$([ -e "$af" ] && echo yes || echo no)"
    assert_eq "answer: no sessionId -> attach hint" "yes" "$(case "$out" in *"claude attach 0000abcd"*) echo yes ;; *) echo no ;; esac)"
    rm -rf "$tmp"
}

test_status_table_claude_code() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    mk_status_queue "$tmp"
    mkdir -p "$tmp/bin"
    cat > "$tmp/bin/claude" <<'FAKEEOF'
#!/usr/bin/env bash
case "$1" in
    agents) echo '{"agents":[{"id":"0000abcd","state":"working"},{"id":"11112222","state":"blocked"}]}' ;;
    attach) echo "attached $2" ;;
esac
FAKEEOF
    chmod +x "$tmp/bin/claude"
    local out
    out=$(PATH="$tmp/bin:$PATH" n1_queue_status_table "$tmp/q.md" "$tmp/events.jsonl")
    assert_eq "status: T-1 terminal state" "pr" "$(echo "$out" | awk -F'\t' '$1=="T-1"{print $2}')"
    assert_eq "status: T-1 elapsed from events.jsonl" "1m" "$(echo "$out" | awk -F'\t' '$1=="T-1"{print $4}')"
    assert_eq "status: T-1 PR" "https://x/pr/1" "$(echo "$out" | awk -F'\t' '$1=="T-1"{print $6}')"
    assert_eq "status: T-2 live-overridden state" "in-progress" "$(echo "$out" | awk -F'\t' '$1=="T-2"{print $2}')"
    assert_eq "status: T-2 step from overview.md" "review" "$(echo "$out" | awk -F'\t' '$1=="T-2"{print $3}')"
    assert_eq "status: T-3 awaiting-human" "awaiting-human" "$(echo "$out" | awk -F'\t' '$1=="T-3"{print $2}')"
    assert_eq "status: T-3 attach command" "claude attach 11112222" "$(echo "$out" | awk -F'\t' '$1=="T-3"{print $7}')"
    assert_eq "status: T-4 escalated step from last headless Escalations line" "implementation" "$(echo "$out" | awk -F'\t' '$1=="T-4"{print $3}')"
    printf '## Finish\n- **Cleanup:** worktree:removed, branch:deleted (/w)\n' >> "$tmp/h/memory/T-2/overview.md"
    out=$(PATH="$tmp/bin:$PATH" n1_queue_status_table "$tmp/q.md" "$tmp/events.jsonl")
    assert_eq "N1-339 status: Cleanup field" "worktree:removed, branch:deleted (/w)" "$(awk -F'\t' '$1=="T-2"{print $8}' <<<"$out")"
    assert_eq "status: cost always em dash" "4" "$(echo "$out" | awk -F'\t' '$5=="\xe2\x80\x94"' | wc -l | tr -d ' ')"
}

test_status_table_running_step() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    mk_status_queue "$tmp"
    mkdir -p "$tmp/bin"
    printf '#!/usr/bin/env bash\ncase "$1" in agents) echo '"'"'{"agents":[{"id":"0000abcd","state":"working"}]}'"'"' ;; esac\n' > "$tmp/bin/claude"
    chmod +x "$tmp/bin/claude"
    local ov="$tmp/h/memory/T-2/overview.md" out
    _t2_step() { PATH="$tmp/bin:$PATH" n1_queue_status_table "$tmp/q.md" "$tmp/events.jsonl" | awk -F'\t' '$1=="T-2"{print $3}'; }
    assert_eq "running step: before begin shows last completed step" "review" "$(_t2_step)"
    # No N1_RUN_ID: the running step must still be written (subshell keeps env clean).
    ( source "$REPO_ROOT/lib/step.sh"; unset N1_RUN_ID; N1_HOME="$tmp/h" ID=T-2; n1_step_begin implementation 7 ) 2>/dev/null
    assert_eq "running step: begin shows current step" "implementation" "$(_t2_step)"
    assert_eq "running step: begin leaves step untouched" "review" "$(n1_read_frontmatter "$ov" step)"
    ( source "$REPO_ROOT/lib/step.sh"; unset N1_RUN_ID; N1_HOME="$tmp/h" ID=T-2; n1_step_end implementation 7 success ) 2>/dev/null
    assert_eq "running step: end sets step" "implementation" "$(n1_read_frontmatter "$ov" step)"
    assert_eq "running step: end clears current_step" "" "$(n1_read_frontmatter "$ov" current_step)"
    assert_eq "running step: after end falls back to step" "implementation" "$(_t2_step)"
}

test_escalated_step_fallback() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    printf -- '---\nstep: escalated\n---\n\n## Escalations\n\n- no headless prefix here\n' > "$tmp/o.md"
    assert_eq "escalated step: falls back when no headless line" "escalated" \
        "$(_n1_queue_escalated_step "$tmp/o.md")"
}

test_status_table_pre_np197_fixture() {
    # copy of a real pre-NP-197 queue.md (no `host` frontmatter, no Session column
    # in Runs); events.jsonl absent — must degrade to Plan status without crashing
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    cat > "$tmp/queue.md" <<'FIXTUREEOF'
---
queue_id: n1-auto
mode: tag
story_id:
step: done
started: 2026-09-23T19:59:00Z
run_id: 20260923T195909Z
---
# Queue n1-auto

## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | TP-6 | Add short_url field to link responses | /home/maphsky/dev/test-project | /home/maphsky/.n1/test-project | sonnet | pr | |
| 2 | TP-7 | Replace X-API-Key header auth with hashed Bearer tokens | /home/maphsky/dev/test-project | /home/maphsky/.n1/test-project | sonnet | pr | |
| 3 | TP-8 | Generated slugs must be 8 characters long | /home/maphsky/dev/test-project | /home/maphsky/.n1/test-project | sonnet | deferred | |
| 4 | TP-8 | Generated slugs must be 8 characters long | /home/maphsky/dev/test-project | /home/maphsky/.n1/test-project | sonnet | escalated | deferred-retry |

## Excluded
| Ticket | Reason |
|--------|--------|
| TP-9 | blocked by TP-6 |
| TP-10 | story: run with --story TP-10 |

## Decision Ledger
| Step | Decision | Detail |
|------|----------|--------|

## Runs
| Ticket | Started | Exit | Outcome | PR |
|--------|---------|------|---------|----|
| TP-6 | 2026-09-23T19:59:09Z | 0 | pr | https://github.com/maphnet/test-project/pull/3 |
| TP-7 | 2026-09-23T20:21:28Z | 0 | pr | https://github.com/maphnet/test-project/pull/4 |
| TP-8 | 2026-09-23T20:51:22Z | 0 | failed |  |
| TP-8 | 2026-09-23T20:53:57Z | 0 | escalated |  |
FIXTUREEOF
    sed "s|/home/maphsky/.n1/test-project|$tmp/n1home|g" "$tmp/queue.md" > "$tmp/q" && mv "$tmp/q" "$tmp/queue.md"
    chmod 444 "$tmp/queue.md"
    mkdir -p "$tmp/bin"
    printf '#!/usr/bin/env bash\necho "[]"\n' > "$tmp/bin/claude"
    chmod +x "$tmp/bin/claude"
    local out rc=0
    out=$(PATH="$tmp/bin:$PATH" n1_queue_status_table "$tmp/queue.md" "$tmp/nonexistent-events.jsonl") || rc=$?
    assert_eq "pre-NP-197 fixture: exits 0" "0" "$rc"
    assert_eq "pre-NP-197 fixture: TP-6 status from Plan" "pr" \
        "$(echo "$out" | awk -F'\t' '$1=="TP-6"{print $2}')"
    assert_eq "pre-NP-197 fixture: TP-6 PR from Runs" "https://github.com/maphnet/test-project/pull/3" \
        "$(echo "$out" | awk -F'\t' '$1=="TP-6"{print $6}')"
}

test_held_helpers() {
    local tmp; tmp=$(mktemp -d)
    mk_held_plan "$tmp/q.md" pr
    assert_eq "held: blocker parsed" "T-1" "$(n1_queue_blocker_of "$tmp/q.md" 2)"
    assert_eq "held: no blocker on plain row" "" "$(n1_queue_blocker_of "$tmp/q.md" 1)"
    assert_eq "held: ticket status" "pr" "$(n1_queue_ticket_status "$tmp/q.md" T-1)"
    assert_eq "held: not launchable" "" "$(n1_queue_pending_rows "$tmp/q.md" | cut -f2)"
    assert_eq "held: blocker pr -> both still wait" "2" "$(n1_queue_held_sweep "$tmp/q.md")"
    mk_held_plan "$tmp/q.md" failed
    assert_eq "held: failed blocker -> chain skipped in plan order" "0" "$(n1_queue_held_sweep "$tmp/q.md")"
    assert_eq "held: T-2 skipped" "skip" "$(plan_cell "$tmp/q.md" 2 8)"
    assert_eq "held: T-2 reason" "blocked by T-1 (failed)" "$(plan_cell "$tmp/q.md" 2 9)"
    assert_eq "held: nothing left for next sweep" "0" "$(n1_queue_held_sweep "$tmp/q.md")"
    assert_eq "held: T-3 skipped" "blocked by T-2 (skip)" "$(plan_cell "$tmp/q.md" 3 9)"
    mk_held_plan "$tmp/q.md" pr
    n1_queue_held_expire "$tmp/q.md"
    assert_eq "held: expire" "skip|blocked by T-1 (not merged)" "$(plan_cell "$tmp/q.md" 2 8)|$(plan_cell "$tmp/q.md" 2 9)"
    rm -rf "$tmp"
}

# N1-114: a user merge of the blocker's PR releases its held rows (runner-side sweep).
test_held_user_merge() {
    local tmp P; tmp=$(mktemp -d); P="$tmp/bin:$PATH"
    mkdir -p "$tmp/bin" "$tmp/h/memory/T-1"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://github.com/o/r/pull/5\n' > "$tmp/h/memory/T-1/overview.md"
    git init -q -b main "$tmp/origin"
    git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m init
    git clone -q "$tmp/origin" "$tmp/repo" 2>/dev/null
    git -C "$tmp/repo" checkout -q -b work
    git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m blocker
    mkq() { mk_held_plan "$tmp/q.md" pr; sed -i "s#| /r | /h |#| $tmp/repo | $tmp/h |#g" "$tmp/q.md"; }
    fakegh() { printf '#!/bin/sh\n%s\n' "$1" > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"; }

    fakegh 'echo OPEN'; mkq
    assert_eq "user-merge: open PR -> both still wait" "2" "$(PATH="$P" n1_queue_held_sweep "$tmp/q.md")"
    assert_eq "user-merge: open PR -> T-2 held" "held" "$(plan_cell "$tmp/q.md" 2 8)"

    fakegh 'echo "boom: rate limited" >&2; echo "second line" >&2; exit 1'; mkq
    assert_eq "user-merge: gh error -> both still wait" "2" "$(PATH="$P" n1_queue_held_sweep "$tmp/q.md" 2>"$tmp/err")"
    assert_eq "user-merge: gh error -> T-2 held" "held" "$(plan_cell "$tmp/q.md" 2 8)"
    assert_eq "user-merge: first gh stderr line surfaced (CR-5)" "boom: rate limited" "$(cat "$tmp/err")"

    fakegh 'echo CLOSED'; mkq
    assert_eq "user-merge: closed PR -> chain skipped (CR-4)" "0" "$(PATH="$P" n1_queue_held_sweep "$tmp/q.md")"
    assert_eq "user-merge: closed PR -> T-2 skip" "skip|blocked by T-1 (PR closed)" "$(plan_cell "$tmp/q.md" 2 8)|$(plan_cell "$tmp/q.md" 2 9)"
    assert_eq "user-merge: closed PR -> T-3 skip" "skip" "$(plan_cell "$tmp/q.md" 3 8)"

    fakegh 'case "$*" in *"-- https://github.com/o/r/pull/5") echo MERGED main;; *) echo OPEN;; esac'; mkq
    sed -i 's#pr_url: .*#pr_url: https://evil.example/o/r/pull/5#' "$tmp/h/memory/T-1/overview.md"
    assert_eq "user-merge: non-GitHub pr_url -> not merged (SEC-2)" "held" "$(PATH="$P" n1_queue_held_sweep "$tmp/q.md" >/dev/null; plan_cell "$tmp/q.md" 2 8)"
    fakegh 'echo MERGED main'; mkq
    sed -i 's#pr_url: .*#pr_url: https://github.com/o$x/r/pull/5#' "$tmp/h/memory/T-1/overview.md"
    assert_eq "user-merge: owner outside [A-Za-z0-9._-] -> not merged (SEC-5c2)" "held" "$(PATH="$P" n1_queue_held_sweep "$tmp/q.md" >/dev/null; plan_cell "$tmp/q.md" 2 8)"
    sed -i 's#pr_url: .*#pr_url: https://github.com/o/r/pull/5#' "$tmp/h/memory/T-1/overview.md"

    fakegh 'echo MERGED release/x'; mkq
    assert_eq "user-merge: merged into non-default base -> both still wait" "2" "$(PATH="$P" n1_queue_held_sweep "$tmp/q.md" 2>/dev/null)"
    assert_eq "user-merge: merged into non-default base -> T-2 held" "held" "$(plan_cell "$tmp/q.md" 2 8)"

    fakegh 'case "$*" in *"-- https://github.com/o/r/pull/5") echo MERGED main;; *) echo OPEN;; esac'; mkq
    assert_eq "user-merge: merged -> released row still counted" "2" "$(PATH="$P" n1_queue_held_sweep "$tmp/q.md" 2>/dev/null)"
    assert_eq "user-merge: T-2 released" "pending|released: T-1 merged" "$(plan_cell "$tmp/q.md" 2 8)|$(plan_cell "$tmp/q.md" 2 9)"
    assert_eq "user-merge: T-3 waits on T-2" "held" "$(plan_cell "$tmp/q.md" 3 8)"
    assert_eq "user-merge: local default synced" "$(git -C "$tmp/origin" rev-parse main)" "$(git -C "$tmp/repo" rev-parse main)"

    mkq_story() { mkq; printf '\n## Story Branches\n| Repo | Branch |\n| :--- | --- |\n| %s | story/S-1 |\n' "$tmp/repo" >> "$tmp/q.md"; }
    fakegh 'echo MERGED story/S-1'; mkq_story
    assert_eq "user-merge story: merged into story branch -> T-2 released" "pending|released: T-1 merged" "$(PATH="$P" n1_queue_held_sweep "$tmp/q.md" >/dev/null 2>&1; plan_cell "$tmp/q.md" 2 8)|$(plan_cell "$tmp/q.md" 2 9)"
    fakegh 'echo MERGED main'; mkq_story
    assert_eq "user-merge story: merged into default -> T-2 still held" "held" "$(PATH="$P" n1_queue_held_sweep "$tmp/q.md" >/dev/null 2>&1; plan_cell "$tmp/q.md" 2 8)"

    git -C "$tmp/repo" remote set-url origin "$tmp/no-such-origin"; mkq
    assert_eq "user-merge: sync failure -> both still wait" "2" "$(PATH="$P" n1_queue_held_sweep "$tmp/q.md" 2>/dev/null)"
    assert_eq "user-merge: sync failure -> T-2 held" "held" "$(plan_cell "$tmp/q.md" 2 8)"
    rm -rf "$tmp"
}

# N1-292: in story mode a held row whose blocker's runner merge ended finish:<why> is skipped and names the blocker.
# MERGED into the story branch is checked first. Tag mode is unchanged (still held).
test_held_sweep_story_finish_skip() {
    local tmp sweep; tmp=$(mktemp -d)
    mk_bg "$tmp" hs "T-A:done" "T-B:done"
    n1_queue_row_status "$tmp/queue.md" 1 pr "finish:ci-red"
    n1_queue_row_status "$tmp/queue.md" 2 held "blocked_on T-A"
    mkdir -p "$tmp/n1home/memory/T-A"; gh_overview "$tmp/n1home/memory/T-A/overview.md" 1
    n1_queue_story_branch_set "$tmp/queue.md" "$tmp" story/S-1
    sweep() { PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp/fake" n1_queue_held_sweep "$tmp/queue.md" >/dev/null 2>&1; }
    echo "OPEN story/S-1" > "$tmp/fake/gh-state"; sweep
    assert_eq "held-story: finish:* blocker skips the dependent" "skip|blocked by T-A (finish:ci-red)" \
        "$(plan_cell "$tmp/queue.md" 2 8)|$(plan_cell "$tmp/queue.md" 2 9)"
    n1_queue_row_status "$tmp/queue.md" 2 held "blocked_on T-A"
    echo "MERGED story/S-1" > "$tmp/fake/gh-state"; sweep
    assert_eq "held-story: MERGED first, stale finish:* Reason still releases" "pending|released: T-A merged" \
        "$(plan_cell "$tmp/queue.md" 2 8)|$(plan_cell "$tmp/queue.md" 2 9)"
    n1_queue_row_status "$tmp/queue.md" 1 pr "merged"
    n1_queue_row_status "$tmp/queue.md" 2 held "blocked_on T-A"
    echo "OPEN story/S-1" > "$tmp/fake/gh-state"; sweep
    assert_eq "held-story: non-finish Reason keeps waiting" held "$(plan_cell "$tmp/queue.md" 2 8)"
    rm -rf "$tmp"
    tmp=$(mktemp -d)
    mk_bg "$tmp" hs "T-A:done" "T-B:done"
    n1_queue_row_status "$tmp/queue.md" 1 pr "finish:ci-red"
    n1_queue_row_status "$tmp/queue.md" 2 held "blocked_on T-A"
    mkdir -p "$tmp/n1home/memory/T-A"; gh_overview "$tmp/n1home/memory/T-A/overview.md" 1
    echo "OPEN main" > "$tmp/fake/gh-state"; sweep
    assert_eq "held-tag: finish:* blocker still held (tag mode unchanged)" held "$(plan_cell "$tmp/queue.md" 2 8)"
    rm -rf "$tmp"
}

# N1-64 CR-1: n1_queue_sync_default fast-forwards the blocker repo's local default branch.
test_sync_default() {
    local tmp origin repo; tmp=$(mktemp -d)
    origin="$tmp/origin"; repo="$tmp/repo"
    git init -q -b main "$origin"
    git -C "$origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m init
    git clone -q "$origin" "$repo" 2>/dev/null
    git -C "$repo" -c user.email=t@t -c user.name=t checkout -q -b other-branch
    git -C "$origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m new
    assert_eq "sync: checked out elsewhere, updates local ref" "0" "$(n1_queue_sync_default "$repo" >/dev/null 2>&1; echo $?)"
    git -C "$repo" checkout -q main
    assert_eq "sync: local main advanced" "$(git -C "$origin" rev-parse main)" "$(git -C "$repo" rev-parse main)"
    # N1-64 TQ-2: default branch checked out (the ff-only merge path, not the fetch-into-ref path).
    git -C "$origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m newer
    local before after; before=$(git -C "$repo" rev-parse HEAD)
    assert_eq "sync: ff-only path, default checked out" "0" "$(n1_queue_sync_default "$repo" >/dev/null 2>&1; echo $?)"
    after=$(git -C "$repo" rev-parse HEAD)
    assert_eq "sync: ff-only path advanced HEAD" "$(git -C "$origin" rev-parse main)" "$after"
    [ "$before" != "$after" ] && echo "PASS: sync: ff-only path actually moved HEAD" && PASS=$((PASS+1)) \
        || { echo "FAIL: sync: ff-only path actually moved HEAD"; FAIL=$((FAIL+1)); }
    git -C "$repo" remote set-url origin "$tmp/no-such-origin"
    assert_eq "sync: unreachable remote -> failure, no unblock" "1" "$(n1_queue_sync_default "$repo" >/dev/null 2>&1; echo $?)"
    rm -rf "$tmp"
}

# N1-290: story-branch helpers — the ## Story Branches mapping and the remote story/<ID> ensure.
test_story_branch_helpers() {
    local bad
    local tmp q before adv; tmp=$(mktemp -d); q="$tmp/q.md"
    # Mapping: read, upsert, fail closed.
    mk_held_plan "$q" pending
    assert_eq "story-map: no section -> empty, status 0" "|0" "$(n1_queue_story_branch_get "$q" /r; echo "|$?")"
    assert_eq "story-map: missing file -> empty, status 0" "|0" "$(n1_queue_story_branch_get "$tmp/none.md" /r; echo "|$?")"
    n1_queue_story_branch_set "$q" /r story/S-1
    n1_queue_story_branch_set "$q" /r story/S-1
    n1_queue_story_branch_set "$q" /r2 story/S-1
    assert_eq "story-map: get /r" "story/S-1" "$(n1_queue_story_branch_get "$q" /r)"
    assert_eq "story-map: get /r2" "story/S-1" "$(n1_queue_story_branch_get "$q" /r2)"
    assert_eq "story-map: unknown repo -> empty" "" "$(n1_queue_story_branch_get "$q" /other)"
    assert_eq "story-map: upsert keeps one row per repo" "1" "$(count_x "$q" '| /r | story/S-1 |')"
    assert_eq "story-map: one heading" "1" "$(count_x "$q" '## Story Branches')"
    assert_eq "story-map: ## Runs stays last" "## Runs" "$(grep '^## ' "$q" | tail -1)"
    n1_queue_story_branch_set "$q" /r story/S-9
    assert_eq "story-map: upsert replaces the branch" "story/S-9|0" "$(n1_queue_story_branch_get "$q" /r)|$(count_x "$q" '| /r | story/S-1 |')"
    n1_queue_story_branch_set "$q" '/x|y' story/S-1
    assert_eq "story-map: repo cell sanitized" "1" "$(count_x "$q" '| /xy | story/S-1 |')"
    assert_eq "story-map: sanitized key reads back" "story/S-1" "$(n1_queue_story_branch_get "$q" '/x|y')"
    printf -- '---\nmode: story\n---\n## Story Branches\n| Repo | Branch |\n| :--- | --- |\n| /keep | story/K |\n\n## Runs\n' > "$tmp/sp.md"
    n1_queue_story_branch_set "$tmp/sp.md" /new story/S-2
    n1_queue_story_branch_set "$tmp/sp.md" /keep story/K2
    assert_eq "story-map: spaced/aligned separator -> new row" "story/S-2" "$(n1_queue_story_branch_get "$tmp/sp.md" /new)"
    assert_eq "story-map: spaced/aligned separator -> upsert keeps row" "story/K2" "$(n1_queue_story_branch_get "$tmp/sp.md" /keep)"
    before=$(cksum < "$q")
    assert_eq "story-map: branch the cell would alter -> set fails" "1" "$(n1_queue_story_branch_set "$q" /r4 'story/S-1|evil'; echo $?)"
    assert_eq "story-map: rejected branch leaves file untouched" "$before" "$(cksum < "$q")"
    printf '\n## Story Branches\n' >> "$q"   # a second heading (portable; no GNU sed \n)
    before=$(cksum < "$q")
    assert_eq "story-map: duplicate heading -> set fails" "1" "$(n1_queue_story_branch_set "$q" /r3 story/S-1; echo $?)"
    assert_eq "story-map: duplicate heading -> file untouched" "$before" "$(cksum < "$q")"
    assert_eq "story-map: duplicate heading -> get fails closed" "|1" "$(n1_queue_story_branch_get "$q" /r; echo "|$?")"
    printf -- '---\nmode: story\n---\n## Plan\n' > "$tmp/noruns.md"
    assert_eq "story-map: no ## Runs -> set fails" "1" "$(n1_queue_story_branch_set "$tmp/noruns.md" /r story/S-1; echo $?)"

    # Ensure: cut from a freshly fetched origin/<default>, reuse an existing branch, fail with a reason.
    git init -q -b main "$tmp/origin"
    git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m init
    git clone -q "$tmp/origin" "$tmp/repo" 2>/dev/null
    git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m ahead
    before=$(git -C "$tmp/repo" rev-parse main)
    assert_eq "story-ensure: create -> 0" "0" "$(n1_queue_story_branch_ensure "$tmp/repo" S-1 main >/dev/null 2>&1; echo $?)"
    assert_eq "story-ensure: cut from the fetched origin/main" "$(git -C "$tmp/origin" rev-parse main)" "$(git -C "$tmp/origin" rev-parse refs/heads/story/S-1)"
    assert_eq "story-ensure: local main not moved" "$before" "$(git -C "$tmp/repo" rev-parse main)"
    assert_eq "story-ensure: no local story branch" "" "$(git -C "$tmp/repo" for-each-ref --format='%(refname)' refs/heads/story)"
    assert_eq "story-ensure: prints nothing on stdout" "" "$(n1_queue_story_branch_ensure "$tmp/repo" S-1 main 2>/dev/null)"
    adv=$(git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit-tree -p refs/heads/story/S-1 -m story 'refs/heads/story/S-1^{tree}')
    git -C "$tmp/origin" update-ref refs/heads/story/S-1 "$adv"
    assert_eq "story-ensure: existing branch -> 0" "0" "$(n1_queue_story_branch_ensure "$tmp/repo" S-1 main >/dev/null 2>&1; echo $?)"
    assert_eq "story-ensure: existing branch not reset" "$adv" "$(git -C "$tmp/origin" rev-parse refs/heads/story/S-1)"
    assert_eq "story-ensure: empty story id -> 1" "1" "$(n1_queue_story_branch_ensure "$tmp/repo" '' main >/dev/null 2>&1; echo $?)"
    assert_eq "story-ensure: invalid story id -> 1" "1" "$(n1_queue_story_branch_ensure "$tmp/repo" 'S..1' main >/dev/null 2>&1; echo $?)"
    for bad in 'A|B' 'x;y' '"VEL-1"' '-x' 'a b' 'a/b' '$(id)'; do
        assert_eq "story-ensure: story id '$bad' -> 1, names the id" "n1-queue: story branch: invalid story id $bad" \
            "$(n1_queue_story_branch_ensure "$tmp/repo" "$bad" main 2>&1 >/dev/null | tail -1)"
    done
    assert_eq "story-ensure: bad ids push nothing" "story/S-1" "$(git -C "$tmp/origin" for-each-ref --format='%(refname:short)' refs/heads/story)"
    assert_eq "story-ensure: invalid default -> 1" "1" "$(n1_queue_story_branch_ensure "$tmp/repo" S-1 'ma..in' >/dev/null 2>&1; echo $?)"
    assert_eq "story-ensure: no such repo -> 1" "1" "$(n1_queue_story_branch_ensure "$tmp/nope" S-1 main >/dev/null 2>&1; echo $?)"
    printf '#!/bin/sh\nexit 1\n' > "$tmp/origin/.git/hooks/pre-receive"; chmod +x "$tmp/origin/.git/hooks/pre-receive"
    assert_eq "story-ensure: rejected push -> reason" "n1-queue: story branch: push of story/S-2 to origin failed in $tmp/repo" \
        "$(n1_queue_story_branch_ensure "$tmp/repo" S-2 main 2>&1 >/dev/null | tail -1)"
    rm -f "$tmp/origin/.git/hooks/pre-receive"
    git -C "$tmp/repo" remote set-url origin "$tmp/no-such-origin"
    assert_eq "story-ensure: unreachable origin -> reason" "n1-queue: story branch: ls-remote origin failed in $tmp/repo" \
        "$(n1_queue_story_branch_ensure "$tmp/repo" S-1 main 2>&1 >/dev/null | tail -1)"
    rm -rf "$tmp"
}

# N1-446: queue prefix creates queue/<id>; fresh=1 refuses a name already on origin; fresh=0 reuses; bad prefix/id refused.
test_queue_branch_ensure() {
    local tmp; tmp=$(mktemp -d)
    git init -q -b main "$tmp/origin"
    git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m init
    git clone -q "$tmp/origin" "$tmp/repo" 2>/dev/null
    assert_eq "queue-ensure: fresh create -> 0" 0 "$(n1_queue_story_branch_ensure "$tmp/repo" sq-1 main queue 1 >/dev/null 2>&1; echo $?)"
    assert_eq "queue-ensure: queue/sq-1 on origin at main" "$(git -C "$tmp/origin" rev-parse main)" \
        "$(git -C "$tmp/origin" rev-parse -q --verify refs/heads/queue/sq-1)"
    assert_eq "queue-ensure: no story branch" "" "$(git -C "$tmp/origin" for-each-ref --format='%(refname)' refs/heads/story)"
    assert_eq "queue-ensure: fresh on an existing name -> refused" "n1-queue: queue branch: queue/sq-1 already exists on origin in $tmp/repo" \
        "$(n1_queue_story_branch_ensure "$tmp/repo" sq-1 main queue 1 2>&1 >/dev/null | tail -1)"
    assert_eq "queue-ensure: resume (fresh 0) reuses -> 0" 0 "$(n1_queue_story_branch_ensure "$tmp/repo" sq-1 main queue 0 >/dev/null 2>&1; echo $?)"
    assert_eq "queue-ensure: unknown prefix -> 1" 1 "$(n1_queue_story_branch_ensure "$tmp/repo" sq-1 main release >/dev/null 2>&1; echo $?)"
    assert_eq "queue-ensure: invalid id names the kind" "n1-queue: queue branch: invalid queue id a|b" \
        "$(n1_queue_story_branch_ensure "$tmp/repo" 'a|b' main queue 1 2>&1 >/dev/null | tail -1)"
    rm -rf "$tmp"
}

# N1-291: n1_story_base — validated story branch for a story child; empty for non-story; rc 2 fails closed.
test_story_base() {
    sb() { ( unset N1_STORY_ID N1_STORY_BRANCH N1_QUEUE_RUN_ID; for kv in "$@"; do export "$kv"; done; n1_story_base 2>/dev/null; echo "|$?" ); }
    assert_eq "story-base: non-story -> empty, rc 0" "|0" "$(sb)"
    assert_eq "story-base: hand-run N1_STORY_ID only -> empty, rc 0" "|0" "$(sb N1_STORY_ID=S-1)"
    assert_eq "story-base: valid branch and id" "story/S-1|0" "$(sb N1_STORY_ID=S-1 N1_STORY_BRANCH=story/S-1)"
    assert_eq "story-base: branch without id" "story/S-1|0" "$(sb N1_STORY_BRANCH=story/S-1)"
    assert_eq "story-base: branch != story/<id> -> rc 2" "|2" "$(sb N1_STORY_ID=S-2 N1_STORY_BRANCH=story/S-1)"
    assert_eq "story-base: not under story/ -> rc 2" "|2" "$(sb N1_STORY_BRANCH=main)"
    assert_eq "story-base: dot-dot -> rc 2" "|2" "$(sb N1_STORY_BRANCH=story/a..b)"
    assert_eq "story-base: .lock (check-ref-format) -> rc 2" "|2" "$(sb N1_STORY_BRANCH=story/x.lock)"
    assert_eq "story-base: shell metachar -> rc 2" "|2" "$(sb 'N1_STORY_BRANCH=story/x;rm')"
    assert_eq "story-base: queue child lost its branch -> rc 2" "|2" "$(sb N1_STORY_ID=S-1 N1_QUEUE_RUN_ID=R1)"
    # N1-446: a queue integration branch is a valid base; the id pairing and fail-closed cases still hold.
    assert_eq "story-base: queue branch and id" "queue/sq-20261106T000000Z|0" \
        "$(sb N1_STORY_ID=sq-20261106T000000Z N1_STORY_BRANCH=queue/sq-20261106T000000Z)"
    assert_eq "story-base: queue branch != queue/<id> -> rc 2" "|2" "$(sb N1_STORY_ID=S-1 N1_STORY_BRANCH=queue/sq-1)"
    assert_eq "story-base: queue dot-dot -> rc 2" "|2" "$(sb N1_STORY_BRANCH=queue/a..b)"
    assert_eq "story-base: other prefix -> rc 2" "|2" "$(sb N1_STORY_BRANCH=release/x)"
    assert_eq "story-base: rc 2 explains on stderr" "yes" \
        "$( ( export N1_STORY_BRANCH=main; n1_story_base 2>&1 >/dev/null || : ) | grep -q 'invalid story branch' && echo yes || echo no)"
}

# N1-291: bg settings carry the story env only when N1_STORY_BRANCH is set; non-story JSON is unchanged.
test_story_bg_settings() {
    local plain story
    plain=$(unset N1_STORY_ID N1_STORY_BRANCH; N1_QUEUE_TAG= N1_QUEUE_DIR=/q _n1_queue_bg_settings R1)
    assert_eq "story-settings: non-story env keys and order unchanged" \
        "N1_HEADLESS,N1_QUEUE_RUN_ID,N1_QUEUE_TAG,N1_QUEUE_DIR,N1_PARENT_SESSION_ID,N1_UNATTENDED" \
        "$(jq -r '.env|keys_unsorted|join(",")' <<< "$plain")"
    story=$(N1_STORY_ID=S-1 N1_STORY_BRANCH=story/S-1 N1_QUEUE_TAG= N1_QUEUE_DIR=/q _n1_queue_bg_settings R1)
    assert_eq "story-settings: story keys present" "S-1,story/S-1" "$(jq -r '[.env.N1_STORY_ID,.env.N1_STORY_BRANCH]|join(",")' <<< "$story")"
    assert_eq "story-settings: story JSON = non-story JSON + two keys" "$plain" "$(jq -c '.env |= del(.N1_STORY_ID,.N1_STORY_BRANCH)' <<< "$story")"
    assert_eq "story-settings: id without branch adds nothing" "$plain" \
        "$(unset N1_STORY_BRANCH; N1_STORY_ID=S-1 N1_QUEUE_TAG= N1_QUEUE_DIR=/q _n1_queue_bg_settings R1)"
}

# N1-291: every default-branch site reads n1_story_base; bump-skip and PR-base wording present.
test_story_base_wiring() {
    local ws="$REPO_ROOT/skills/n1-start/procedures/workspace-isolation.md"
    assert_eq "story-wiring: workspace-isolation calls n1_story_base in adopt and ensure" "2" "$(grep -c 'n1_story_base' "$ws")"
    assert_eq "story-wiring: adopt rebases onto the story tip" "yes" "$(grep -qF 'rebase "origin/$SB"' "$ws" && echo yes || echo no)"
    assert_eq "story-wiring: ensure cuts the branch from BASE" "yes" "$(grep -qF 'git branch <TARGET> "$BASE"' "$ws" && echo yes || echo no)"
    assert_eq "story-wiring: ensure keeps checkout of the default" "yes" "$(grep -qF 'git checkout $DEFAULT' "$ws" && echo yes || echo no)"
    local f
    for f in skills/n1-start/steps/review.md skills/n1-start/steps/implementation.md skills/n1-start/steps/qa.md \
             skills/n1-start/procedures/cross-repo.md skills/n1-review/steps/01-analyze.md; do
        assert_eq "story-wiring: $f calls n1_story_base" "yes" "$(grep -q 'n1_story_base' "$REPO_ROOT/$f" && echo yes || echo no)"
    done
    assert_eq "story-wiring: qa passes story base to break-check" "yes" \
        "$(grep -qF '"${SB:-${BC_DEF:-main}}"' "$REPO_ROOT/skills/n1-start/steps/qa.md" && echo yes || echo no)"
    assert_eq "story-wiring: implementation bump skip" "yes" \
        "$(grep -q 'Story child: make no version-bump commit' "$REPO_ROOT/skills/n1-start/steps/implementation.md" && echo yes || echo no)"
    local pp="$REPO_ROOT/skills/n1-pr/steps/01-prepare.md" pc="$REPO_ROOT/skills/n1-pr/steps/02-push-create.md"
    assert_eq "story-wiring: prepare reads story base for DEFAULT_BRANCH and rules BASE" "3" "$(grep -c 'n1_story_base' "$pp")"
    assert_eq "story-wiring: prepare bump skip" "yes" "$(grep -q 'Story child or queue child: make no version-bump commit' "$pp" && echo yes || echo no)"
    assert_eq "story-wiring: rebase target via DEFAULT_BRANCH" "yes" "$(grep -qF 'git rebase "origin/$DEFAULT_BRANCH"' "$pc" && echo yes || echo no)"
    assert_eq "story-wiring: PR base via DEFAULT_BRANCH" "yes" "$(grep -qF -- '--base "$DEFAULT_BRANCH"' "$pc" && echo yes || echo no)"
    assert_eq "story-wiring: every push-create snippet re-derives the base from n1_story_base (SEC-1)" "4" "$(grep -c 'DEFAULT_BRANCH="\$SB"' "$pc")"
    assert_eq "story-wiring: adopt checkout re-anchors branch-point (CR-2)" "yes" \
        "$(grep -qF 'rev-parse "origin/$SB" > "$BP"' "$REPO_ROOT/skills/n1-start/procedures/workspace-isolation.md" && echo yes || echo no)"
    assert_eq "story-wiring: push-create names the story branch" "yes" "$(grep -q 'never the default branch' "$pc" && echo yes || echo no)"
}

# N1-290: run.md documents the runner's story-branch step; its halt text matches the runner's.
test_story_branch_wiring() {
    local r="$REPO_ROOT/skills/n1-queue/steps/run.md" k="$REPO_ROOT/scripts/n1-queue-run.sh"
    _sbF() { grep -qF -- "$1" "$2" && echo yes || echo no; }
    assert_eq "story-branch wiring: run.md names the reader helper" "yes" "$(_sbF 'n1_queue_story_branch_get' "$r")"
    assert_eq "story-branch wiring: run.md quotes the halt" "yes" "$(_sbF 'HALTED: story branch story/<STORY_ID> could not be created or pushed in <repo>' "$r")"
    assert_eq "story-branch wiring: runner emits that halt" "yes" "$(_sbF 'HALTED: $RUN_MODE branch $RUN_MODE/$STORY_ID could not be created or pushed in $SB_REPO' "$k")"
}

# --- child status (NP-219 deploy flag no longer a queue outcome) ---
test_child_status_deploy() {
    local tmp; tmp=$(mktemp -d)
    # N1-114: deploy_pending is not a queue outcome (queue children never run n1-finish).
    printf -- '---\nstep: pr\ndeploy_pending: true\n---\n\n## Pending\npr_url: https://x/pr/1\n' > "$tmp/ov.md"
    assert_eq "child-status: deploy_pending ignored -> pr" "pr" "$(n1_queue_child_status "$tmp/ov.md" 0)"
    printf -- '---\nstep: pr\ndeploy_pending: false\n---\n\n## Pending\npr_url: https://x/pr/1\n' > "$tmp/ov.md"
    assert_eq "child-status: deploy done -> pr" "pr" "$(n1_queue_child_status "$tmp/ov.md" 0)"
    printf -- '---\nstep: pr\n---\n\n## Pending\npr_url: https://x/pr/1\n' > "$tmp/ov.md"
    assert_eq "child-status: no delivery -> pr (unchanged)" "pr" "$(n1_queue_child_status "$tmp/ov.md" 0)"
    printf -- '---\nstep: escalated\n---\n' > "$tmp/ov.md"
    assert_eq "child-status: no delivery -> escalated (unchanged)" "escalated" "$(n1_queue_child_status "$tmp/ov.md" 1)"
    rm -rf "$tmp"
}

# NP-203: plan-time ## Decisions lookup and staleness gate.
test_decisions_and_stale() {
    local tmp rc out; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    cat > "$tmp/q.md" <<EOF
---
step: planned
planned_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-1 | Fix A | /r | /h | sonnet | pending | |

## Decisions
| Ticket | Touches | Order | Stop-List Pre-Decision | Desc Checksum | Notes |
|--------|---------|-------|-------------------------|---------------|-------|
| T-1 | r:queue | | security: pre-authorize | 3821 | dup:T-9:continue |
| T-2 | r:queue,r:lib | after T-1 (r:queue) | | 42 | |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
EOF
    assert_eq "decisions: pre-decision cell" "security: pre-authorize" "$(n1_queue_decisions_row "$tmp/q.md" T-1 | cut -f3)"
    assert_eq "decisions: notes cell" "dup:T-9:continue" "$(n1_queue_decisions_row "$tmp/q.md" T-1 | cut -f5)"
    assert_eq "decisions: order cell" "after T-1 (r:queue)" "$(n1_queue_decisions_row "$tmp/q.md" T-2 | cut -f2)"
    assert_eq "decisions: empty pre-decision stays empty" "" "$(n1_queue_decisions_row "$tmp/q.md" T-2 | cut -f3)"
    assert_eq "decisions: checksum after empty cell" "42" "$(n1_queue_decisions_row "$tmp/q.md" T-2 | cut -f4)"
    assert_eq "decisions: Plan/Runs rows never match" "" "$(n1_queue_decisions_row "$tmp/q.md" 1)"
    assert_eq "decisions: unknown ticket" "" "$(n1_queue_decisions_row "$tmp/q.md" T-404)"
    assert_eq "decisions: missing file" "" "$(n1_queue_decisions_row "$tmp/none.md" T-1)"

    assert_eq "stale: fresh plan" "fresh" "$(n1_queue_stale "$tmp/q.md" && echo stale || echo fresh)"
    n1_write_frontmatter "$tmp/q.md" planned_at "2020-01-01T00:00:00Z"
    assert_eq "stale: old plan" "stale" "$(n1_queue_stale "$tmp/q.md" && echo stale || echo fresh)"
    printf -- '---\nstep: planned\n---\n' > "$tmp/p.md"
    assert_eq "stale: missing planned_at counts as stale" "stale" "$(n1_queue_stale "$tmp/p.md" && echo stale || echo fresh)"
    n1_write_frontmatter "$tmp/q.md" planned_at "2099-01-01T00:00:00Z"
    assert_eq "stale: future planned_at counts as stale (SEC-L3)" "stale" "$(n1_queue_stale "$tmp/q.md" && echo stale || echo fresh)"

    # SEC-2: parser fails closed on a forged/duplicated ## Decisions block or duplicate row.
    cat > "$tmp/forged.md" <<'EOF'
## Decisions
| Ticket | Touches | Order | Stop-List Pre-Decision | Desc Checksum | Notes |
|--------|---------|-------|-------------------------|---------------|-------|
| T-1 | r:queue | | security: pre-authorize | 3821 | |

## Decisions
| Ticket | Touches | Order | Stop-List Pre-Decision | Desc Checksum | Notes |
|--------|---------|-------|-------------------------|---------------|-------|
| T-1 | r:evil | | security: pre-authorize | 9999 | |
EOF
    assert_eq "decisions: fails closed on duplicate ## Decisions heading" "" "$(n1_queue_decisions_row "$tmp/forged.md" T-1)"
    cat > "$tmp/dup_row.md" <<'EOF'
## Decisions
| Ticket | Touches | Order | Stop-List Pre-Decision | Desc Checksum | Notes |
|--------|---------|-------|-------------------------|---------------|-------|
| T-1 | r:queue | | security: pre-authorize | 3821 | |
| T-1 | r:evil | | security: pre-authorize | 9999 | |
EOF
    assert_eq "decisions: fails closed on duplicate row for the same ticket" "" "$(n1_queue_decisions_row "$tmp/dup_row.md" T-1)"

    # CR-2: write helper replaces the row and sanitizes cells (untrusted | / newline can't forge columns).
    n1_queue_decisions_write_row "$tmp/q.md" T-1 'r:queue|evil' $'multi\nline' 'security: pre-authorize' abc123 'note|d'
    assert_eq "decisions-write: touches sanitized" "r:queueevil" "$(n1_queue_decisions_row "$tmp/q.md" T-1 | cut -f1)"
    assert_eq "decisions-write: order sanitized (newline stripped)" "multi line" "$(n1_queue_decisions_row "$tmp/q.md" T-1 | cut -f2)"
    assert_eq "decisions-write: checksum replaced" "abc123" "$(n1_queue_decisions_row "$tmp/q.md" T-1 | cut -f4)"
    assert_eq "decisions-write: notes sanitized" "noted" "$(n1_queue_decisions_row "$tmp/q.md" T-1 | cut -f5)"
    assert_eq "decisions-write: other row untouched" "1" "$(grep -cxF '| T-2 | r:queue,r:lib | after T-1 (r:queue) | | 42 | |' "$tmp/q.md")"
    assert_eq "decisions-write: Ticket cell unchanged" "1" "$(grep -cxF '| T-1 | r:queueevil | multi line | security: pre-authorize | abc123 | noted |' "$tmp/q.md")"
    assert_eq "decisions-write: Plan row with the same ticket untouched" "1" "$(grep -cxF '| 1 | T-1 | Fix A | /r | /h | sonnet | pending | |' "$tmp/q.md")"

    # SEC-3: literal backslash-escapes (as awk -v would re-expand them) never split a row or forge a `|`.
    n1_queue_decisions_write_row "$tmp/q.md" T-1 't\n1' 'o\1741' 'security: pre-authorize' cksum2 'note\n|inject\174'
    assert_eq "decisions-write: literal \\n in touches doesn't split the row" "1" "$(grep -c '^| T-1 ' "$tmp/q.md")"
    assert_eq "decisions-write: literal \\174 in order never becomes a pipe" "o1741" "$(n1_queue_decisions_row "$tmp/q.md" T-1 | cut -f2)"
    assert_eq "decisions-write: literal \\n and \\174 in notes never forge a pipe" "noteninject174" "$(n1_queue_decisions_row "$tmp/q.md" T-1 | cut -f5)"

    # CR-5: write helper fails closed on a forged/duplicated ## Decisions heading, like the reader.
    cp "$tmp/forged.md" "$tmp/forged_write.md"
    rc=0; n1_queue_decisions_write_row "$tmp/forged_write.md" T-1 evil evil evil evil evil || rc=$?
    assert_eq "decisions-write: fails closed (nonzero) on duplicate ## Decisions heading (CR-5)" "1" "$rc"
    assert_eq "decisions-write: forged file left untouched on guard failure" "yes" \
        "$(diff -q "$tmp/forged.md" "$tmp/forged_write.md" >/dev/null && echo yes || echo no)"

    # SEC-1/SEC-3/SEC-5: content hash takes two file paths (never inline text), fails closed when either is missing.
    printf 'Title A' > "$tmp/t.txt"
    printf 'a description' > "$tmp/d.txt"
    h1=$(n1_queue_content_hash "$tmp/t.txt" "$tmp/d.txt")
    h2=$(n1_queue_content_hash "$tmp/t.txt" "$tmp/d.txt")
    assert_eq "content-hash: 64 hex chars (sha256)" "yes" "$(case "$h1" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) echo yes ;; *) echo "no: $h1" ;; esac)"
    assert_eq "content-hash: stable for identical input" "$h1" "$h2"
    printf 'a different description' > "$tmp/d2.txt"
    h3=$(n1_queue_content_hash "$tmp/t.txt" "$tmp/d2.txt")
    assert_eq "content-hash: changes with description" "yes" "$([ "$h1" != "$h3" ] && echo yes || echo no)"
    printf 'Title B' > "$tmp/t2.txt"
    h4=$(n1_queue_content_hash "$tmp/t2.txt" "$tmp/d.txt")
    assert_eq "content-hash: changes with title" "yes" "$([ "$h1" != "$h4" ] && echo yes || echo no)"
    rc=0; out=$(n1_queue_content_hash "$tmp/missing-title.txt" "$tmp/d.txt") || rc=$?
    assert_eq "content-hash: fails closed (empty, nonzero) when title file is missing (SEC-5)" "1 " "$rc $out"
    rc=0; out=$(n1_queue_content_hash "$tmp/t.txt" "$tmp/missing-desc.txt") || rc=$?
    assert_eq "content-hash: fails closed (empty, nonzero) when desc file is missing (SEC-5)" "1 " "$rc $out"
}

# NP-231: trusted-hash chain. N1's own description writes stay trusted; a human edit never does.
test_desc_hash_chain() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    local N1_HOME="$tmp/home" N1_QUEUE_DIR="$tmp/q" N1_QUEUE_RUN_ID="run-1"
    local f="$tmp/home/memory/T-1/.desc-hashes" rc h0 h1 h2 h3 h4
    mkdir -p "$N1_QUEUE_DIR" "$tmp/v" "$tmp/home/memory/T-2"
    printf 'Add retry' > "$tmp/v/title"
    printf 'v0' > "$tmp/v/d0"
    printf 'v0 + N1 enrichment' > "$tmp/v/d1"
    printf 'v0 + human scope' > "$tmp/v/d2"
    printf 'human scope + N1 enrichment' > "$tmp/v/d3"
    printf 'v0 + N1 enrichment + N1 estimate' > "$tmp/v/d4"
    h0=$(n1_queue_content_hash "$tmp/v/title" "$tmp/v/d0")
    h1=$(n1_queue_content_hash "$tmp/v/title" "$tmp/v/d1")
    h2=$(n1_queue_content_hash "$tmp/v/title" "$tmp/v/d2")
    h3=$(n1_queue_content_hash "$tmp/v/title" "$tmp/v/d3")
    h4=$(n1_queue_content_hash "$tmp/v/title" "$tmp/v/d4")
    cat > "$N1_QUEUE_DIR/queue.md" <<EOF
---
run_id: run-1
step: run
---
## Decisions
| Ticket | Touches | Order | Stop-List Pre-Decision | Desc Checksum | Notes |
|--------|---------|-------|-------------------------|---------------|-------|
| T-1 | | | security: pre-authorize | $h0 | |
| T-2 | | | security: pre-authorize | | |
EOF
    _chain_trusted() { n1_desc_hash_is_trusted "$1" "$2" && echo TRUSTED || echo UNTRUSTED; }
    # Mirrors the decision line in autonomy-headless.md § Content check (asserted verbatim in test_headless_plan_wiring).
    _chain_guard() {
        local NEW_HASH ID=T-1
        NEW_HASH=$(n1_queue_content_hash "$tmp/v/title" "$1") || NEW_HASH=""
        if [ -n "$NEW_HASH" ] && n1_desc_hash_is_trusted "$ID" "$NEW_HASH"; then echo MATCH; else echo MISMATCH; fi
    }

    assert_eq "chain: plan hash is trusted" "TRUSTED" "$(_chain_trusted T-1 "$h0")"
    assert_eq "chain: guard MATCH on the planned text" "MATCH" "$(_chain_guard "$tmp/v/d0")"
    assert_eq "chain: an unrecorded write is not trusted" "MISMATCH" "$(_chain_guard "$tmp/v/d1")"

    # N1 write after a trusted pre-write hash: recorded and accepted.
    rc=0; n1_desc_hash_record T-1 "$h0" "$h1" || rc=$?
    assert_eq "chain: record after a trusted pre-write hash succeeds" "0" "$rc"
    assert_eq "chain: record line is run_id<TAB>hash" "run-1	$h1" "$(cat "$f")"
    assert_eq "chain: guard MATCH after N1's own write" "MATCH" "$(_chain_guard "$tmp/v/d1")"
    assert_eq "chain: plan hash still trusted after a record" "TRUSTED" "$(_chain_trusted T-1 "$h0")"

    # Regression (AC): a human description edit after planning still produces MISMATCH.
    assert_eq "chain: human edit after planning -> MISMATCH" "MISMATCH" "$(_chain_guard "$tmp/v/d2")"

    # Untrusted pre-write hash: N1's write on top of a human edit is never recorded.
    rc=0; n1_desc_hash_record T-1 "$h2" "$h3" || rc=$?
    assert_eq "chain: record refuses an untrusted pre-write hash" "1" "$rc"
    assert_eq "chain: refused record leaves .desc-hashes untouched" "1" "$(wc -l < "$f" | tr -d ' ')"
    assert_eq "chain: N1 write over a human edit still -> MISMATCH" "MISMATCH" "$(_chain_guard "$tmp/v/d3")"

    # Chained N1 writes: a recorded hash is a valid pre-write hash for the next write; append never clobbers.
    rc=0; n1_desc_hash_record T-1 "$h1" "$h4" || rc=$?
    assert_eq "chain: record after a recorded pre-write hash succeeds" "0" "$rc"
    assert_eq "chain: record appends without clobbering prior lines" "2" "$(wc -l < "$f" | tr -d ' ')"
    assert_eq "chain: guard MATCH after a second N1 write" "MATCH" "$(_chain_guard "$tmp/v/d4")"

    # SEC-5: missing / unreadable .desc-hashes falls back to the plan hash only, never "accept all".
    mv "$f" "$f.bak"
    assert_eq "chain: missing .desc-hashes -> recorded hash untrusted" "UNTRUSTED" "$(_chain_trusted T-1 "$h1")"
    assert_eq "chain: missing .desc-hashes -> plan hash still trusted" "TRUSTED" "$(_chain_trusted T-1 "$h0")"
    mv "$f.bak" "$f"
    if [ "$(id -u)" -ne 0 ]; then
        chmod 000 "$f"
        assert_eq "chain: unreadable .desc-hashes -> recorded hash untrusted" "UNTRUSTED" "$(_chain_trusted T-1 "$h1")"
        assert_eq "chain: unreadable .desc-hashes -> plan hash still trusted" "TRUSTED" "$(_chain_trusted T-1 "$h0")"
        chmod 600 "$f"
    fi

    # Records are scoped to the run that wrote them.
    printf 'run-0\t%s\n' "$h2" >> "$f"
    assert_eq "chain: a hash recorded by another run is not trusted" "UNTRUSTED" "$(_chain_trusted T-1 "$h2")"

    # SEC-L1: no trustworthy plan -> nothing trusted, nothing recorded.
    assert_eq "chain: N1_QUEUE_RUN_ID unset -> plan hash untrusted" "UNTRUSTED" "$(N1_QUEUE_RUN_ID=""; _chain_trusted T-1 "$h0")"
    assert_eq "chain: N1_QUEUE_DIR unset -> recorded hash untrusted" "UNTRUSTED" "$(N1_QUEUE_DIR=""; _chain_trusted T-1 "$h1")"
    assert_eq "chain: queue.md run_id mismatch -> untrusted" "UNTRUSTED" "$(N1_QUEUE_RUN_ID=run-9; _chain_trusted T-1 "$h0")"
    assert_eq "chain: no plan -> record refused" "1" "$(N1_QUEUE_RUN_ID=""; n1_desc_hash_record T-1 "$h0" "$h1" && echo 0 || echo 1)"
    assert_eq "chain: refused records never touch the file" "3" "$(wc -l < "$f" | tr -d ' ')"

    # Empty plan checksum = no chain root, even when .desc-hashes names the hash.
    printf 'run-1\t%s\n' "$h1" > "$tmp/home/memory/T-2/.desc-hashes"
    assert_eq "chain: empty plan checksum -> recorded hash untrusted" "UNTRUSTED" "$(_chain_trusted T-2 "$h1")"

    # Malformed input fails closed.
    assert_eq "chain: empty hash untrusted" "UNTRUSTED" "$(_chain_trusted T-1 "")"
    assert_eq "chain: multi-line hash untrusted" "UNTRUSTED" "$(_chain_trusted T-1 "$(printf 'x\n%s' "$h0")")"
    assert_eq "chain: 63-char hash untrusted" "UNTRUSTED" "$(_chain_trusted T-1 "${h0:0:63}")"
    assert_eq "chain: path-like ticket id untrusted" "UNTRUSTED" "$(_chain_trusted '../T-1' "$h0")"
    assert_eq "chain: malformed post hash never recorded" "1" "$(n1_desc_hash_record T-1 "$h0" 'not-a-hash' && echo 0 || echo 1)"

    # TQ-2 (NP-231 CR-1/SEC-1): a stale .desc-pre.* left by a prior write site must not
    # launder a skipped Before step. Mirrors the Gate's `rm -f` (desc-hash-chain.md § Gate):
    # once cleared, a skipped Before leaves PRE unreadable, so the record fails closed
    # instead of reusing the previous site's trusted PRE hash.
    local M="$tmp/home/memory/T-1" PRE lines_before
    printf 'stale pre title' > "$M/.desc-pre.title"
    printf 'stale pre desc' > "$M/.desc-pre.txt"
    printf 'stale post title' > "$M/.desc-post.title"
    printf 'stale post desc' > "$M/.desc-post.txt"
    rm -f "$M"/.desc-pre.* "$M"/.desc-post.*
    PRE=$(n1_queue_content_hash "$M/.desc-pre.title" "$M/.desc-pre.txt") || PRE=""
    assert_eq "TQ-2: cleared pre files -> PRE hash empty when Before is skipped" "" "$PRE"
    lines_before=$(wc -l < "$f" | tr -d ' ')
    rc=0; n1_desc_hash_record T-1 "$PRE" "$h1" || rc=$?
    assert_eq "TQ-2: empty PRE -> record fails closed" "1" "$rc"
    assert_eq "TQ-2: .desc-hashes untouched by the failed record" "$lines_before" "$(wc -l < "$f" | tr -d ' ')"

    # TQ-3 (NP-231 cycle 2, SEC-1/SEC-5): a human title edit between the pre-write and
    # post-write fetch must never be laundered as an N1 write, even when the description
    # hash chain is otherwise trusted. Exercises the documented After snippet verbatim.
    printf 'Add retry' > "$M/.desc-pre.title"
    printf 'v0 + N1 enrichment' > "$M/.desc-pre.txt"
    printf 'Human retitled this' > "$M/.desc-post.title"
    printf 'v0 + N1 enrichment' > "$M/.desc-post.txt"
    local PRE POST
    PRE=$(n1_queue_content_hash "$M/.desc-pre.title" "$M/.desc-pre.txt")
    POST=$(n1_queue_content_hash "$M/.desc-post.title" "$M/.desc-post.txt")
    cmp -s "$M/.desc-pre.title" "$M/.desc-post.title" || POST=""
    assert_eq "TQ-3: title change clears POST before record" "" "$POST"
    lines_before=$(wc -l < "$f" | tr -d ' ')
    rc=0; n1_desc_hash_record T-1 "$PRE" "$POST" || rc=$?
    assert_eq "TQ-3: title-changed record fails closed" "1" "$rc"
    assert_eq "TQ-3: .desc-hashes untouched when the title changed" "$lines_before" "$(wc -l < "$f" | tr -d ' ')"
}

# N1-164: a description-mode Refined by N1 block edited after queue plan reads MISMATCH at intake.
# Runs the real fenced recipe from references/desc-hash-chain.md § Intake check.
test_refined_intake_check() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    local N1_HOME="$tmp/home" N1_QUEUE_DIR="$tmp/q" N1_QUEUE_RUN_ID="run-1"
    local M="$tmp/home/memory/T-7" h0 h5 rc
    mkdir -p "$N1_QUEUE_DIR" "$tmp/v" "$M"
    printf 'Add retry to uploader' > "$tmp/v/title"
    printf 'Retry failed uploads.\n\n*Refined by N1*\n### Scope\n- uploader only\n### Decisions\n- backoff: exponential [refined]\n### Acceptance Criteria\n- retries 3 times\n*End of Refined by N1*\n' > "$tmp/v/d0"
    printf 'Retry failed uploads.\n\n*Refined by N1*\n### Scope\n- uploader only\n### Decisions\n- backoff: linear [refined]\n### Acceptance Criteria\n- retries 3 times\n*End of Refined by N1*\n' > "$tmp/v/dec"
    printf 'Retry failed uploads.\n\n*Refined by N1*\n### Scope\n- uploader only\n### Decisions\n- backoff: exponential [refined]\n### Acceptance Criteria\n- retries 10 times\n*End of Refined by N1*\n' > "$tmp/v/ac"
    printf 'Retry failed uploads.\n\n*Refined by N1*\n### Scope\n- uploader only\n### Decisions\n- backoff: exponential [refined]\n### Acceptance Criteria\n- retries 3 times\n*End of Refined by N1*\n\n*Estimated by N1*\n' > "$tmp/v/d5"
    h0=$(n1_queue_content_hash "$tmp/v/title" "$tmp/v/d0")
    h5=$(n1_queue_content_hash "$tmp/v/title" "$tmp/v/d5")
    cat > "$N1_QUEUE_DIR/queue.md" <<EOF
---
run_id: run-1
step: run
---
## Decisions
| Ticket | Touches | Order | Stop-List Pre-Decision | Desc Checksum | Notes |
|--------|---------|-------|-------------------------|---------------|-------|
| T-7 | | | | $h0 | |
EOF
    # Run the real fenced recipe from the doc (minus the two `source` lines; lib/queue.sh is already loaded).
    # The section opens with the n1_desc_mark block (N1-326); take the block that holds the hash check.
    local recipe; recipe=$(awk 'index($0,"## Intake check")==1{f=1;next} f&&/^```bash/{b=1;buf="";next} b&&/^```/{if(buf~/n1_desc_hash_is_trusted/){printf "%s",buf;exit} b=0;next} b{buf=buf $0 "\n"}' "$REPO_ROOT/references/desc-hash-chain.md" | { grep -v '^source ' || true; } | sed 's/<ID>/T-7/g')
    assert_eq "intake: recipe extracted from doc" "1" "$(printf '%s' "$recipe" | grep -c n1_desc_hash_is_trusted || true)"
    _intake_check() { # <title-file|""> <desc-file|"">: "" = that file-write failed
        if [ -n "$1" ]; then cp "$1" "$M/.guard-live.title"; fi
        if [ -n "$2" ]; then cp "$2" "$M/.guard-live.txt"; fi
        eval "$recipe"
    }

    # AC2: block unchanged since plan is still used.
    assert_eq "intake: refined block unchanged since plan -> MATCH" "MATCH" "$(_intake_check "$tmp/v/title" "$tmp/v/d0")"
    assert_eq "intake: scratch files removed after the check" "0" "$(find "$M" -name '.guard-live.*' | wc -l | tr -d ' ')"
    # AC1/AC4: post-plan edit inside the block is detected.
    assert_eq "intake: Decision edited after plan -> MISMATCH" "MISMATCH" "$(_intake_check "$tmp/v/title" "$tmp/v/dec")"
    assert_eq "intake: AC edited after plan -> MISMATCH" "MISMATCH" "$(_intake_check "$tmp/v/title" "$tmp/v/ac")"
    printf 'Add retry to uploader v2' > "$tmp/v/title2"
    assert_eq "intake: title edited after plan -> MISMATCH" "MISMATCH" "$(_intake_check "$tmp/v/title2" "$tmp/v/d0")"
    # N1's own recorded write keeps the block trusted.
    assert_eq "intake: unrecorded later text -> MISMATCH" "MISMATCH" "$(_intake_check "$tmp/v/title" "$tmp/v/d5")"
    rc=0; n1_desc_hash_record T-7 "$h0" "$h5" || rc=$?
    assert_eq "intake: N1 write recorded" "0" "$rc"
    assert_eq "intake: N1's own recorded write -> MATCH" "MATCH" "$(_intake_check "$tmp/v/title" "$tmp/v/d5")"
    # Fail closed (SEC-5).
    assert_eq "intake: failed description file-write -> MISMATCH" "MISMATCH" "$(_intake_check "$tmp/v/title" "")"
}

# NP-231: vague-title heuristic behind the queue's "no usable content" exclusion.
test_title_vague() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    _vague() { printf '%s' "$1" > "$tmp/t"; n1_title_vague "$tmp/t" && echo vague || echo ok; }
    assert_eq "title-vague: one word" "vague" "$(_vague 'Fix')"
    assert_eq "title-vague: three words" "vague" "$(_vague 'Fix the thing')"
    assert_eq "title-vague: four words is usable" "ok" "$(_vague 'Add retry to uploader')"
    assert_eq "title-vague: normal title" "ok" "$(_vague 'Brief thin queue tickets at plan time')"
    assert_eq "title-vague: key prefix stripped before counting" "vague" "$(_vague 'NP-231: fix it')"
    assert_eq "title-vague: key-prefixed normal title" "ok" "$(_vague 'NP-231: brief thin queue tickets at plan time')"
    assert_eq "title-vague: empty title" "vague" "$(_vague '')"
    rm -f "$tmp/t"
    assert_eq "title-vague: missing file fails closed (vague -> excluded)" "vague" "$(n1_title_vague "$tmp/t" && echo vague || echo ok)"
    printf '$(touch %s/pwned) `touch %s/pwned2`' "$tmp" "$tmp" > "$tmp/t"
    n1_title_vague "$tmp/t" || true
    assert_eq "title-vague: title text is never executed (SEC-1)" "no" "$([ -e "$tmp/pwned" ] || [ -e "$tmp/pwned2" ] && echo yes || echo no)"
}

# NP-231: every N1 description write in a queue child goes through the hash chain.
test_desc_chain_wiring() {
    local r="$REPO_ROOT" f d="$REPO_ROOT/references/desc-hash-chain.md" pa="$REPO_ROOT/agents/product-analyst.md"
    _hasF() { grep -qF -- "$1" "$2" 2>/dev/null && echo yes || echo no; }
    for f in agents/product-analyst.md skills/n1-start/steps/brainstorm.md \
             skills/n1-start/steps/investigation-deliverable.md; do
        assert_eq "chain-wiring: $f routes its description write through desc-hash-chain.md" "yes" "$(_hasF 'references/desc-hash-chain.md' "$r/$f")"
    done
    assert_eq "chain-wiring: product-analyst wires both write paths (Empty/Skeletal step 3, Weak step 2)" "yes" "$(_hasF 'Empty/Skeletal step 3, Weak step 2' "$pa")"
    assert_eq "chain-wiring: procedure is gated on N1_QUEUE_RUN_ID" "yes" "$(_hasF '[ -n "${N1_QUEUE_RUN_ID:-}" ]' "$d")"
    assert_eq "chain-wiring: pre-write text is hashed from files (SEC-1)" "yes" "$(_hasF 'n1_queue_content_hash "$M/.desc-pre.title" "$M/.desc-pre.txt"' "$d")"
    assert_eq "chain-wiring: post-write text is re-fetched and hashed from files" "yes" "$(_hasF 'n1_queue_content_hash "$M/.desc-post.title" "$M/.desc-post.txt"' "$d")"
    assert_eq "chain-wiring: records only via the gated helper" "yes" "$(_hasF 'n1_desc_hash_record "<ID>" "$PRE" "$POST"' "$d")"
    assert_eq "chain-wiring: a title change clears POST before the record (SEC-1/SEC-5)" "yes" "$(_hasF 'cmp -s "$M/.desc-pre.title" "$M/.desc-post.title" || POST=""' "$d")"
    assert_eq "chain-wiring: forbids appending to .desc-hashes any other way" "yes" "$(_hasF 'Never append to `.desc-hashes` any other way' "$d")"
    assert_eq "chain-wiring: procedure runs no raw append to .desc-hashes" "0" "$(grep -cE '>>[^|]*desc-hashes' "$d" 2>/dev/null || true)"
    assert_eq "chain-wiring: Gate clears stale pre/post scratch files (CR-1/SEC-1)" "2" "$(grep -cF 'rm -f "$M"/.desc-pre.* "$M"/.desc-post.*' "$d" 2>/dev/null || true)"
    # product-analyst: skip markers unchanged; the queue brief never skips enrichment.
    assert_eq "chain-wiring: product-analyst skip markers unchanged" "yes" "$(_hasF 'already contains the marker `*Structured by N1*` or `*Restructured by N1*`, skip enrichment' "$pa")"
    assert_eq "chain-wiring: Briefed marker never on a skip line" "0" "$(grep -F 'skip enrichment' "$pa" | grep -cF 'Briefed' || true)"
    assert_eq "chain-wiring: product-analyst grades briefed tickets normally" "yes" "$(_hasF '`*Briefed by N1 (queue plan)*` (n1-queue'"'"'s plan-time brief) is not an idempotency marker' "$pa")"

    # TQ-3 (NP-231 cycle 2): order assertions so removing the SEC-1/SEC-4 cleanup fails a test.
    local gate_rm chain_echo after_record after_rm
    gate_rm=$(line_of "$d" 'rm -f "$M"/.desc-pre.* "$M"/.desc-post.*' || true)
    chain_echo=$(line_of "$d" 'echo CHAIN' || true)
    assert_eq "chain-wiring: Gate clears scratch files before the CHAIN check" "yes" "$([ -n "$gate_rm" ] && [ -n "$chain_echo" ] && [ "$gate_rm" -lt "$chain_echo" ] && echo yes || echo no)"
    after_record=$(line_of "$d" 'n1_desc_hash_record "<ID>" "$PRE" "$POST"' || true)
    after_rm=$(grep -nF 'rm -f "$M"/.desc-pre.* "$M"/.desc-post.*' "$d" | tail -1 | cut -d: -f1)
    assert_eq "chain-wiring: After's final rm -f runs after the record call" "yes" "$([ -n "$after_record" ] && [ -n "$after_rm" ] && [ "$after_rm" -gt "$after_record" ] && echo yes || echo no)"

    local h="$REPO_ROOT/skills/n1-start/procedures/autonomy-headless-predecision.md" guard_clear_before guard_hash guard_clear_after
    guard_clear_before=$(line_of "$h" 'rm -f "$N1_HOME/memory/$ID"/.guard-live.*' || true)
    guard_hash=$(line_of "$h" 'NEW_HASH=$(n1_queue_content_hash "$M/.guard-live.title" "$M/.guard-live.txt")' || true)
    assert_eq "chain-wiring: guard clears live-fetch files before the hash" "yes" "$([ -n "$guard_clear_before" ] && [ -n "$guard_hash" ] && [ "$guard_clear_before" -lt "$guard_hash" ] && echo yes || echo no)"
    guard_clear_after=$(line_of "$h" 'rm -f "$M"/.guard-live.*' || true)
    assert_eq "chain-wiring: guard clears live-fetch files after computing NEW_HASH" "yes" "$([ -n "$guard_hash" ] && [ -n "$guard_clear_after" ] && [ "$guard_clear_after" -gt "$guard_hash" ] && echo yes || echo no)"

    # N1-164: refined-block Intake check in desc-hash-chain.md.
    assert_eq "chain-wiring: Intake check section exists" "yes" "$(_hasF '## Intake check (refined description block)' "$d")"
    assert_eq "chain-wiring: Intake check hashes the live title/description from files (SEC-1)" "yes" "$(_hasF 'NEW_HASH=$(n1_queue_content_hash "$M/.guard-live.title" "$M/.guard-live.txt")' "$d")"
    assert_eq "chain-wiring: Intake check decision line" "yes" "$(_hasF 'if [ -n "$NEW_HASH" ] && n1_desc_hash_is_trusted "<ID>" "$NEW_HASH"; then echo MATCH; else echo MISMATCH; fi' "$d")"
    assert_eq "chain-wiring: Intake check MISMATCH ignores the description block" "yes" "$(_hasF 'ignore the description block (treat it as absent)' "$d")"
    assert_eq "chain-wiring: Gate also clears stale .guard-live files" "1" "$(grep -cF 'rm -f "$M"/.desc-pre.* "$M"/.desc-post.* "$M"/.guard-live.*' "$d" 2>/dev/null || true)"
    local intake_hash intake_rm
    intake_hash=$(line_of "$d" 'NEW_HASH=$(n1_queue_content_hash "$M/.guard-live.title" "$M/.guard-live.txt")' || true)
    intake_rm=$(line_of "$d" 'rm -f "$M"/.guard-live.*' || true)
    assert_eq "chain-wiring: Intake check clears live files after computing NEW_HASH" "yes" "$([ -n "$intake_hash" ] && [ -n "$intake_rm" ] && [ "$intake_rm" -gt "$intake_hash" ] && echo yes || echo no)"

    # N1-326: the capture hook writes the scratch files; each fetch is marked first and nothing is model-written.
    local mk_pre mk_post mk_guard pre_hash post_hash unmark
    mk_pre=$(line_of "$d" 'n1_desc_mark pre "<ID>"' || true)
    mk_post=$(line_of "$d" 'n1_desc_mark post "<ID>"' || true)
    mk_guard=$(line_of "$d" 'n1_desc_mark guard "<ID>"' || true)
    pre_hash=$(line_of "$d" 'n1_queue_content_hash "$M/.desc-pre.title" "$M/.desc-pre.txt"' || true)
    post_hash=$(line_of "$d" 'n1_queue_content_hash "$M/.desc-post.title" "$M/.desc-post.txt"' || true)
    unmark=$(line_of "$d" 'n1_desc_unmark "<ID>"' || true)
    assert_eq "chain-wiring: Before marks its fetch before the hash (N1-326)" "yes" "$([ -n "$mk_pre" ] && [ -n "$pre_hash" ] && [ "$mk_pre" -lt "$pre_hash" ] && echo yes || echo no)"
    assert_eq "chain-wiring: After marks its re-fetch after Before's mark and before the hash (N1-326)" "yes" "$([ -n "$mk_post" ] && [ -n "$mk_pre" ] && [ "$mk_pre" -lt "$mk_post" ] && [ "$mk_post" -lt "$post_hash" ] && echo yes || echo no)"
    assert_eq "chain-wiring: Intake check marks its fetch before the hash (N1-326)" "yes" "$([ -n "$mk_guard" ] && [ -n "$intake_hash" ] && [ "$mk_guard" -lt "$intake_hash" ] && echo yes || echo no)"
    assert_eq "chain-wiring: Gate drops a pending marker before the CHAIN check (N1-326)" "yes" "$([ -n "$unmark" ] && [ "$gate_rm" -lt "$unmark" ] && [ "$unmark" -lt "$chain_echo" ] && echo yes || echo no)"
    assert_eq "chain-wiring: no model file-write of tracker text left (N1-326)" "0" "$(grep -cE 'file-write( mechanism|,)' "$d" || true)"
    local mk_g
    mk_g=$(line_of "$h" 'n1_desc_mark guard "$ID"' || true)
    assert_eq "chain-wiring: headless guard marks its re-fetch between clear and hash (N1-326)" "yes" "$([ -n "$mk_g" ] && [ "$guard_clear_before" -lt "$mk_g" ] && [ "$mk_g" -lt "$guard_hash" ] && echo yes || echo no)"
    assert_eq "chain-wiring: headless guard never model-writes .guard-live (N1-326)" "0" "$(grep -F '.guard-live' "$h" | grep -cE 'file-write( mechanism|,)' || true)"
}

# NP-231: thin tickets get a plan-time brief instead of a word-count exclusion.
test_brief_wiring() {
    local s="$REPO_ROOT/skills/n1-queue" b c
    _hasF() { grep -qF -- "$1" "$2" 2>/dev/null && echo yes || echo no; }
    assert_eq "brief: intake no longer excludes on word count" "no" "$(grep -qE '30 words|description too thin' "$s/steps/intake.md" && echo yes || echo no)"
    assert_eq "brief: intake's only content exclusion reason" "yes" "$(_hasF 'no usable content: empty description, vague title' "$s/steps/intake.md")"
    assert_eq "brief: intake checks the title from a file (SEC-1)" "yes" "$(_hasF 'n1_title_vague "<QUEUE_DIR>/desc/<KEY>.title"' "$s/steps/intake.md")"
    assert_eq "brief: intake reuses product-analyst tiers" "yes" "$(_hasF 'agents/product-analyst.md' "$s/steps/intake.md")"
    assert_eq "brief: intake never re-briefs a briefed ticket" "yes" "$(_hasF '*Briefed by N1 (queue plan)*' "$s/steps/intake.md")"
    assert_eq "brief: preview writes the marked brief" "yes" "$(_hasF '*Briefed by N1 (queue plan)*' "$s/steps/preview.md")"
    assert_eq "brief: preview re-fetches briefed tickets before the snapshot" "yes" "$(_hasF 'Re-fetch each briefed candidate' "$s/steps/preview.md")"
    b=$(line_of "$s/steps/preview.md" '*Briefed by N1 (queue plan)*' || true)
    c=$(line_of "$s/steps/preview.md" 'n1_queue_content_hash' || true)
    assert_eq "brief: Desc Checksum is taken after the brief" "yes" "$([ -n "$b" ] && [ -n "$c" ] && [ "$b" -lt "$c" ] && echo yes || echo no)"
    assert_eq "brief: preview shows briefs before Start" "yes" "$(_hasF 'Brief <KEY>:' "$s/steps/preview.md")"
    assert_eq "brief: --run re-plan re-runs Plan-Resolve 1 so the checksum stays post-brief" "yes" "$(_hasF 'preview.md § Plan-Resolve 1' "$s/steps/run.md")"
    assert_eq "brief: intake marks each candidate fetch for the capture hook (N1-326)" "yes" "$(_hasF 'n1_desc_mark queue "<KEY>" "<QUEUE_ID>"' "$s/steps/intake.md")"
    assert_eq "brief: a missing captured title keeps the candidate (N1-326 D8)" "yes" "$(_hasF 'echo MISSING' "$s/steps/intake.md")"
}

# N1-271: --retry is routed, documented and wired to the helper; a resumed escalated child re-asks.
test_retry_wiring() {
    local s="$REPO_ROOT/skills/n1-queue"
    _hasF() { grep -qF -- "$1" "$2" 2>/dev/null && echo yes || echo no; }
    assert_eq "retry-wiring: argument-hint offers --retry" "yes" "$(grep -q '^argument-hint:.*\[--retry <ticket>\]' "$s/SKILL.md" && echo yes || echo no)"
    assert_eq "retry-wiring: description usage offers --retry" "yes" "$(grep -q '^description:.*\[--retry <ticket>\]' "$s/SKILL.md" && echo yes || echo no)"
    assert_eq "retry-wiring: Input parses --retry" "yes" "$(_hasF '--retry <ticket> (reset a failed or escalated row to pending' "$s/SKILL.md")"
    assert_eq "retry-wiring: step 1 routes --retry" "yes" "$(_hasF 'If `--retry`: read and follow `<N1_ROOT>/skills/n1-queue/steps/retry.md`. **STOP.**' "$s/SKILL.md")"
    assert_eq "retry-wiring: step calls the helper" "yes" "$(_hasF 'n1_queue_retry "$QUEUE_FILE" "$RETRY_TICKET"' "$s/steps/retry.md")"
    assert_eq "retry-wiring: step validates the ticket id first" "yes" "$(_hasF '^[A-Za-z][A-Za-z0-9_]*-[0-9]+$' "$s/steps/retry.md")"
    assert_eq "retry-wiring: resumed escalated child re-asks" "yes" "$(_hasF 'N1_ORCA_RESUME=1' "$REPO_ROOT/skills/n1-start/procedures/resume.md")"
    assert_eq "retry-wiring: resume re-asks only the last escalation" "yes" "$(_hasF 'last `## Escalations` item' "$REPO_ROOT/skills/n1-start/procedures/resume.md")"
    assert_eq "retry-wiring: resume makes the step reset the first overview.md write" "yes" "$(_hasF 'The step reset is the first overview.md write' "$REPO_ROOT/skills/n1-start/procedures/resume.md")"
    assert_eq "retry-wiring: resume never resets to a runner-terminal step" "yes" "$(_hasF 'If that step is `pr`, `ci` or `done` (terminal for the queue runner poll' "$REPO_ROOT/skills/n1-start/procedures/resume.md")"
    assert_eq "retry-wiring: architecture documents the resumable exception" "yes" "$(_hasF 'n1_orca_worktree_resumable' "$REPO_ROOT/references/architecture.md")"
}


# N1-61: placeholder titles and form-dump descriptions are repaired at intake.
test_form_repair_wiring() {
    local pa="$REPO_ROOT/agents/product-analyst.md" m='*Normalized by N1*'
    _hasF() { grep -qF -- "$1" "$2" 2>/dev/null && echo yes || echo no; }
    assert_eq "repair: Normalized counts as already enriched" "yes" "$(_hasF '`Normalized by N1` (Title & Form Repair' "$pa")"
    assert_eq "repair: title and description go in one editTicket call" "yes" "$(_hasF '`issueIdOrKey`, `summary`, `description`' "$pa")"
    assert_eq "repair: queue children drop the title part" "yes" "$(_hasF 'On `CHAIN`, drop the title part' "$pa")"
    assert_eq "repair: Normalized block uses plain bullets" "0" "$(grep -A8 -F "$m" "$pa" | grep -cF -- '- [ ]' || true)"
    local q="$REPO_ROOT/skills/n1-queue/steps" d="$REPO_ROOT/references/desc-hash-chain.md" r s
    assert_eq "repair: queue intake treats Normalized as Adequate" "yes" "$(_hasF '`Normalized by N1` (with or without' "$q/intake.md")"
    assert_eq "repair: queue preview applies the product-analyst rules" "yes" "$(_hasF 'product-analyst.md` § Title & Form Repair' "$q/preview.md")"
    assert_eq "repair: repaired candidates are re-fetched before the snapshot" "yes" "$(_hasF 'Re-fetch each briefed candidate and each repaired one' "$q/preview.md")"
    r=$(line_of "$q/preview.md" '**Repair (every candidate' || true)
    s=$(line_of "$q/preview.md" 'n1_queue_content_hash' || true)
    assert_eq "repair: repair runs before the Desc Checksum" "yes" "$([ -n "$r" ] && [ -n "$s" ] && [ "$r" -lt "$s" ] && echo yes || echo no)"
    assert_eq "repair: hash chain no longer claims N1 never writes the title" "no" "$(_hasF 'N1 never writes the title' "$d")"
    assert_eq "repair: queue repair re-fetches and skips a changed ticket" "yes" "$(_hasF 'repair skipped (changed)' "$q/preview.md")"
    assert_eq "repair: product-analyst guards whole-field writes" "yes" "$(_hasF '**Stale-write guard:**' "$pa")"
    assert_eq "repair: queue brief re-fetches and skips a changed ticket" "yes" "$(_hasF 'brief skipped (changed)' "$q/preview.md")"
}

# NP-203: overlapping tickets run in creation order; disjoint tickets keep input order.
test_overlap_order() {
    local out
    out=$(printf '%s\t%s\n' 'T-5' 'r:queue, r:lib' 'T-2' 'r:docs' 'T-3' 'R:Queue' 'T-9' '' | n1_queue_overlap_order)
    assert_eq "overlap: execution order" "T-2,T-3,T-5,T-9" "$(printf '%s\n' "$out" | cut -f1 | paste -sd, -)"
    assert_eq "overlap: note on the reordered ticket" "after T-3 (r:queue)" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="T-5"{print $2}')"
    assert_eq "overlap: unrelated ticket flags its own silent shift" "moved up (unrelated overlap elsewhere)" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="T-2"{print $2}')"
    assert_eq "overlap: empty touches never overlaps" "" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="T-9"{print $2}')"
    out=$(printf '%s\t%s\n' 'T-7' 'a' 'T-1' 'b' | n1_queue_overlap_order)
    assert_eq "overlap: disjoint keeps input order" "T-7,T-1" "$(printf '%s\n' "$out" | cut -f1 | paste -sd, -)"
    out=$(printf '%s\t%s\n' 'T-8' 'x' 'T-4' 'y' 'T-6' 'x,y' | n1_queue_overlap_order)
    assert_eq "overlap: transitive chain" "T-4,T-6,T-8" "$(printf '%s\n' "$out" | cut -f1 | paste -sd, -)"
}

# N1-303: plan-time schedule (every earlier Touches overlapper is a predecessor), its wave line, and the
# saved ## Schedule section reproducing the preview's line.
test_schedule_helpers() {
    local out d q rc
    out=$(printf '%s\t%s\n' 'T-1' 'r:a' 'T-2' 'r:b' 'T-3' 'r:a, R:B' 'T-4' '' | n1_queue_overlap_preds)
    assert_eq "schedule: every earlier overlapper is a predecessor (non-transitive)" \
        "T-1|;T-2|;T-3|T-1,T-2;T-4|" "$(printf '%s\n' "$out" | tr '\t' '|' | paste -sd';' -)"
    assert_eq "schedule: wave line" "wave 1: T-1, T-2, T-4 | wave 2: T-3 (after T-1, T-2)" "$(n1_queue_waves <<< "$out")"
    assert_eq "schedule: ticket example" "wave 1: N1-277, N1-284 | wave 2: N1-278 (after N1-277), N1-285 (after N1-284)" \
        "$(printf '%s\t%s\n' N1-277 r:q N1-284 r:w N1-278 r:q N1-285 r:w | n1_queue_overlap_preds | n1_queue_waves)"
    assert_eq "schedule: display-only held edge lands in a later wave" "wave 1: T-1, T-2 | wave 2: T-3 (after T-1)" \
        "$({ printf '%s\t%s\n' T-1 a T-2 b T-3 c | n1_queue_overlap_preds; printf '%s\t%s\n' T-3 T-1; } | n1_queue_waves)"
    assert_eq "schedule: an empty held line is ignored" "wave 1: T-1" "$({ printf '%s\t%s\n' T-1 a | n1_queue_overlap_preds; printf '%s\t%s\n'; } | n1_queue_waves)"

    d=$(mktemp -d); q="$d/queue.md"
    cat > "$q" <<'EOF'
---
step: planned
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-1 | a | /r | /h | sonnet | pending | |
| 2 | T-2 | b | /r | /h | sonnet | pending | |
| 3 | T-3 | c | /r | /h | sonnet | pending | |
| 4 | T-4 | d | /r | /h | sonnet | skip | status changed |

## Decisions
| Ticket | Touches | Order | Stop-List Pre-Decision | Desc Checksum | Notes |
|--------|---------|-------|-------------------------|---------------|-------|
| T-1 | r:a |  |  |  |  |
| T-2 | r:b |  |  |  |  |
| T-3 | r:a, r:b |  |  |  |  |
| T-4 | r:a |  |  |  |  |

## Decision Ledger
| Step | Decision | Detail |
|------|----------|--------|

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
EOF
    assert_eq "schedule: missing section reads as no predecessors" "" "$(n1_queue_schedule_rows "$q")"
    n1_queue_schedule_write "$q"
    assert_eq "schedule: section inserted once (legacy plan)" "1" "$(grep -c '^## Schedule$' "$q" || true)"
    assert_eq "schedule: ## Runs stays last" "## Runs" "$(grep '^## ' "$q" | tail -1)"
    assert_eq "schedule: rows from pending/held Plan rows only" "T-1|;T-2|;T-3|T-1,T-2" \
        "$(n1_queue_schedule_rows "$q" | tr '\t' '|' | paste -sd';' -)"
    assert_eq "schedule: saved plan reproduces the preview line" \
        "$(printf '%s\t%s\n' T-1 r:a T-2 r:b T-3 'r:a, r:b' | n1_queue_overlap_preds | n1_queue_waves)" "$(n1_queue_plan_waves "$q")"
    cp "$q" "$d/before.md"; n1_queue_schedule_write "$q"
    assert_eq "schedule: rewrite is idempotent" "yes" "$(cmp -s "$q" "$d/before.md" && echo yes || echo no)"
    n1_queue_row_status "$q" 2 held "blocked_on T-1"
    assert_eq "schedule: saved plan shows held Blocks edges" \
        "wave 1: T-1 | wave 2: T-2 (after T-1) | wave 3: T-3 (after T-1, T-2)" "$(n1_queue_plan_waves "$q")"
    awk '{ if ($0 == "| T-3 | T-1,T-2 |") print "| T-3 | T-1, rm -rf x, T-2 |"; else print }' "$q" > "$d/forged.md"
    assert_eq "schedule: non-key After entries are dropped" "T-1,T-2" \
        "$(n1_queue_schedule_rows "$d/forged.md" | awk -F'\t' '$1 == "T-3" { print $2 }')"
    awk '/^## Decision Ledger$/ { print "## Schedule" } { print }' "$q" > "$d/dup.md"
    assert_eq "schedule: duplicated heading reads nothing" "" "$(n1_queue_schedule_rows "$d/dup.md")"
    rc=0; n1_queue_schedule_write "$d/dup.md" || rc=$?
    assert_eq "schedule: duplicated heading refuses the write" "1" "$rc"
    rm -rf "$d"
}

# N1-303: per-tick eligibility from ## Schedule: released at pr (merged when the queue merges its own PRs),
# hard edge on a dead or unknown predecessor, waits otherwise; no section = every pending row.
test_eligible_rows() {
    local d q
    d=$(mktemp -d); q="$d/queue.md"
    cat > "$q" <<'EOF'
---
step: run
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-1 | a | /r | /h | sonnet | pr | |
| 2 | T-2 | b | /r | /h | sonnet | pending | |
| 3 | T-3 | c | /r | /h | sonnet | pending | |
| 4 | T-4 | d | /r | /h | sonnet | failed | child-exited-incomplete |
| 5 | T-5 | e | /r | /h | sonnet | pending | |
| 6 | T-6 | f | /r | /h | sonnet | pending | |
| 7 | T-7 | g | /r | /h | sonnet | pending | |

## Schedule
| Ticket | After |
|--------|-------|
| T-2 | T-1 |
| T-3 | T-2 |
| T-5 | T-4 |
| T-6 | T-9 |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
| T-1 | 2026-11-03T00:00:00Z | 0 | pr | https://x/pr/1 | s1 |
EOF
    cp "$q" "$d/merge.md"
    awk '/^## Schedule$/ { s = 1; next } s && /^## / { s = 0 } !s' "$q" > "$d/legacy.md"
    assert_eq "eligible: no-merge mode releases at pr, waits on pending" "T-2,T-7" \
        "$(n1_queue_eligible_rows "$q" false | cut -f2 | paste -sd, -)"
    assert_eq "eligible: failed predecessor skips the successor" "skip" "$(plan_cell "$q" 5 8)"
    assert_eq "eligible: skip reason names it" "yes" "$(case "$(plan_cell "$q" 5 9)" in *"predecessor T-4 failed"*) echo yes ;; *) echo no ;; esac)"
    assert_eq "eligible: predecessor not in plan skips too" "skip" "$(plan_cell "$q" 6 8)"
    assert_eq "eligible: waiting row stays pending" "pending" "$(plan_cell "$q" 3 8)"
    assert_eq "eligible: merge mode waits for a merged predecessor" "T-7" \
        "$(n1_queue_eligible_rows "$d/merge.md" true | cut -f2 | paste -sd, -)"
    awk '{ if ($0 ~ /^\| T-1 \|/ && $0 ~ /\| pr \|/) sub(/\| pr \|/, "| merged |"); print }' "$d/merge.md" > "$d/m2.md"
    assert_eq "eligible: merge mode releases once Runs Outcome is merged" "T-2,T-7" \
        "$(n1_queue_eligible_rows "$d/m2.md" true | cut -f2 | paste -sd, -)"
    assert_eq "eligible: no ## Schedule lists every pending row" "T-2,T-3,T-5,T-6,T-7" \
        "$(n1_queue_eligible_rows "$d/legacy.md" false | cut -f2 | paste -sd, -)"
    assert_eq "eligible: same columns as pending_rows" "$(n1_queue_pending_rows "$d/legacy.md" | head -1)" \
        "$(n1_queue_eligible_rows "$d/legacy.md" false | head -1)"
    # mixed homes: the callback decides per predecessor home (T-1 lives in /h; only /hm merges)
    mh() { [ "$1" = /hm ]; }
    assert_eq "eligible: per-home merge fn, predecessor home not merging releases at pr" "T-2,T-7" \
        "$(n1_queue_eligible_rows "$d/merge.md" mh | cut -f2 | paste -sd, -)"
    sed 's#^| 1 | T-1 | a | /r | /h |#| 1 | T-1 | a | /r | /hm |#' "$d/merge.md" > "$d/mixed.md"
    assert_eq "eligible: per-home merge fn, predecessor home merging waits" "T-7" \
        "$(n1_queue_eligible_rows "$d/mixed.md" mh | cut -f2 | paste -sd, -)"
    n1_queue_gated_expire "$d/merge.md"
    assert_eq "eligible: gated expiry skips the waiting rows" "skip,skip" "$(plan_cell "$d/merge.md" 2 8),$(plan_cell "$d/merge.md" 3 8)"
    rm -rf "$d"
}

# N1-362: an obsolete-ticket escalation (Headless Guard marker + no PR + no diff) releases overlap and held successors;
# any missing piece fails closed. Bugs caught: successors of an obsolete row skipped; a marker alone, a recorded PR, a
# commit past the branch-point, a dirty tree, another escalation or a missing workspace treated as obsolete.
test_obsolete_release() {
    local d h ws ov q
    d=$(mktemp -d); h="$d/h"; ws="$d/ws"; ov="$h/memory/T-1/overview.md"; mkdir -p "${ov%/*}"
    gc() { git -C "$ws" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m "$1"; }
    git init -q "$ws"; gc base
    git -C "$ws" rev-parse HEAD > "$h/memory/T-1/branch-point"
    ob() { n1_queue_child_obsolete T-1 "$h" "$d/norepo" && echo yes || echo no; }
    printf -- '---\nstep: escalated\nworkspace_path: %s\n---\n## Escalations\n- [headless] analysis: ticket obsolete: already on main\n' "$ws" > "$ov"
    assert_eq "obsolete: marker + no PR + no diff" yes "$(ob)"
    touch "$ws/f"; assert_eq "obsolete: dirty tree fails closed" no "$(ob)"; rm -f "$ws/f"
    gc work; assert_eq "obsolete: commit past branch-point fails closed" no "$(ob)"
    git -C "$ws" rev-parse HEAD > "$h/memory/T-1/branch-point"
    printf '## Pending\npr_url: https://github.com/o/r/pull/1\n' >> "$ov"
    assert_eq "obsolete: recorded PR fails closed" no "$(ob)"
    # Guard-shaped overview: Escalations followed by a Decision Ledger table; entry written via the helper (N1-362 CR-1)
    printf -- '---\nstep: escalated\nworkspace_path: %s\n---\n## Escalations\n\n## Decision Ledger\n\n| Step |\n|------|\n| analysis |\n' "$ws" > "$ov"
    n1_append_escalation "$ov" '- [headless] analysis: ticket obsolete: already on main'
    assert_eq "obsolete: entry written by helper before a ledger is readable" yes "$(ob)"
    gc ahead; git -C "$ws" rev-parse HEAD > "$h/memory/T-1/branch-point"; git -C "$ws" reset -q --hard HEAD~1
    assert_eq "obsolete: HEAD behind branch-point fails closed" no "$(ob)"
    git -C "$ws" rev-parse HEAD > "$h/memory/T-1/branch-point"
    printf -- '---\nstep: escalated\nworkspace_path: %s\n---\n## Escalations\n- [headless] analysis: ticket obsolete? options: A | B\n' "$ws" > "$ov"
    assert_eq "obsolete: similarly worded question fails closed" no "$(ob)"
    printf -- '---\nstep: escalated\nworkspace_path: %s\n---\n## Escalations\n- [headless] analysis: Pick a DB?, options: A | B (blocked-move: moved)\n' "$ws" > "$ov"
    assert_eq "obsolete: other escalation fails closed" no "$(ob)"
    printf -- '---\nstep: escalated\nworkspace_path: %s\n---\n## Escalations\n- [headless] analysis: ticket obsolete: x\n' "$d/gone" > "$ov"
    assert_eq "obsolete: missing workspace fails closed" no "$(ob)"
    rm -f "$h/memory/T-1/branch-point"
    printf -- '---\nstep: escalated\nworkspace_path: %s\n---\n## Escalations\n- [headless] analysis: ticket obsolete: x\n' "$ws" > "$ov"
    assert_eq "obsolete: missing branch-point fails closed" no "$(ob)"

    q="$d/q.md"
    cat > "$q" <<'EOF'
---
step: run
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-1 | a | /r | /h | sonnet | escalated | obsolete |
| 2 | T-2 | b | /r | /h | sonnet | pending | |
| 3 | T-3 | c | /r | /h | sonnet | escalated | |
| 4 | T-4 | d | /r | /h | sonnet | pending | |

## Schedule
| Ticket | After |
|--------|-------|
| T-2 | T-1 |
| T-4 | T-3 |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
EOF
    assert_eq "obsolete: overlap successor eligible" "T-2" "$(n1_queue_eligible_rows "$q" false | cut -f2 | paste -sd, -)"
    assert_eq "obsolete: plain escalated predecessor still skips" "skip" "$(plan_cell "$q" 4 8)"
    mk_held_plan "$q" escalated; n1_queue_row_status "$q" 1 escalated obsolete
    assert_eq "obsolete: held sweep counts the released row and its waiting child" "2" "$(n1_queue_held_sweep "$q")"
    assert_eq "obsolete: held row released" "pending|released: T-1 obsolete" "$(plan_cell "$q" 2 8)|$(plan_cell "$q" 2 9)"
    mk_held_plan "$q" escalated
    n1_queue_held_sweep "$q" > /dev/null
    assert_eq "obsolete: plain escalated blocker still skips the held row" "skip" "$(plan_cell "$q" 2 8)"
    rm -rf "$d"
}

# N1-303 fix cycle 1: CR-1 (overlap edge vs reverse Blocks edge), CR-3 (merge mode, chain ended unmerged).
test_schedule_cycle_and_merge_final() {
    local d q out
    d=$(mktemp -d); q="$d/queue.md"
    cat > "$q" <<'EOF'
---
step: run
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-1 | a | /r | /h | sonnet | held | blocked_on T-2 |
| 2 | T-2 | b | /r | /h | sonnet | pending | |

## Decisions
| Ticket | Touches | Order | Stop-List Pre-Decision | Desc Checksum | Notes |
|--------|---------|-------|-------------------------|---------------|-------|
| T-1 | r:a |  |  |  |  |
| T-2 | r:a |  |  |  |  |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
EOF
    n1_queue_schedule_write "$q"
    assert_eq "cr1: held predecessor blocked on its overlap successor stores no reverse edge" "T-1|;T-2|" \
        "$(n1_queue_schedule_rows "$q" | tr '\t' '|' | paste -sd';' -)"
    assert_eq "cr1: plan line shows the Blocks order" "wave 1: T-2 | wave 2: T-1 (after T-2)" "$(n1_queue_plan_waves "$q")"
    assert_eq "cr1: preview pipeline agrees" "$(n1_queue_plan_waves "$q")" \
        "$({ printf '%s\t%s\t%s\n' T-1 r:a T-2 T-2 r:a '' | n1_queue_overlap_preds; printf '%s\t%s\n' T-1 T-2; } | n1_queue_waves)"
    assert_eq "cr1: eligibility lists the pending blocker" "T-2" "$(n1_queue_eligible_rows "$q" false | cut -f2 | paste -sd, -)"
    out=$(printf 'T-1\tT-2\nT-2\tT-1\n' | n1_queue_waves)
    assert_eq "cr1: a cyclic input is reported, not drawn as waves" "yes" "$(case "$out" in cycle*) echo yes ;; *) echo no ;; esac)"
    # N1-318: A (held, blocked_on C), B overlaps both, C: Blocks wins over a transitive overlap cycle
    out=$({ printf '%s\t%s\t%s\n' A r:a C B r:a '' C r:a '' | n1_queue_overlap_preds; printf '%s\t%s\n' A C; } | n1_queue_waves)
    assert_eq "n1-318: three-row overlap plus Blocks has no cycle, waves C, A, B" \
        "wave 1: C | wave 2: A (after C) | wave 3: B (after A)" "$out"
    # N1-318: four rows, two kept-overlap hops (B->A, C->B) before the Blocks hop A->D
    out=$({ printf '%s\t%s\t%s\n' A r:a D B r:a '' C r:a '' D r:a '' | n1_queue_overlap_preds; printf '%s\t%s\n' A D; } | n1_queue_waves)
    assert_eq "n1-318: four-row overlap plus Blocks has no cycle, blocker in wave 1" \
        "wave 1: D | wave 2: A (after D) | wave 3: B (after A) | wave 4: C (after A, B)" "$out"
    # N1-318: chained blockers A->B->D, middle row C overlaps all three
    out=$({ printf '%s\t%s\t%s\n' A r:a B C r:a '' B r:a D D r:a '' | n1_queue_overlap_preds; printf '%s\t%s\n' A B; printf '%s\t%s\n' B D; } | n1_queue_waves)
    assert_eq "n1-318: chained blockers plus overlap have no cycle, valid wave order" \
        "wave 1: D | wave 2: B (after D) | wave 3: A (after B) | wave 4: C (after A)" "$out"
    cat > "$q" <<'EOF'
---
step: run
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-1 | a | /r | /h | sonnet | pr | finish:ci-red |
| 2 | T-2 | b | /r | /h | sonnet | pending | |

## Schedule
| Ticket | After |
|--------|-------|
| T-2 | T-1 |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
| T-1 | 2026-11-03T00:00:00Z | 0 | pr | https://x/pr/1 | s1 |
EOF
    cp "$q" "$d/nomerge.md"
    assert_eq "cr3: no-merge mode still releases at pr" "T-2" "$(n1_queue_eligible_rows "$d/nomerge.md" false | cut -f2)"
    assert_eq "cr3: merge mode lists nothing" "" "$(n1_queue_eligible_rows "$q" true)"
    assert_eq "cr3: successor skipped at once" "skip" "$(plan_cell "$q" 2 8)"
    assert_eq "cr3: reason names the predecessor and the finish failure" "predecessor T-1 not merged (finish:ci-red)" "$(plan_cell "$q" 2 9)"
    cp "$d/nomerge.md" "$d/exp.md"; n1_queue_row_status "$d/exp.md" 1 pr "waiting"
    n1_queue_gated_expire "$d/exp.md"
    assert_eq "cr3: gated expiry reason names the blocking predecessor" "predecessor T-1 not released (not at PR or not merged)" "$(plan_cell "$d/exp.md" 2 9)"
    rm -rf "$d"
}

# NP-203: plan/run split wiring in the n1-queue skill text.
test_plan_wiring() {
    local s="$REPO_ROOT/skills/n1-queue"
    has() { grep -qE -- "$1" "$2" && echo yes || echo no; }
    assert_eq "plan-wiring: SKILL.md parses --plan" "yes" "$(has '\-\-plan' "$s/SKILL.md")"
    assert_eq "plan-wiring: SKILL.md parses --run <queue-id>" "yes" "$(has '\-\-run <queue-id>' "$s/SKILL.md")"
    assert_eq "plan-wiring: SKILL.md validates the queue id" "yes" "$(has 'A-Za-z0-9' "$s/SKILL.md")"
    assert_eq "plan-wiring: dry-run still stops in preview" "yes" "$(has 'Dry run -- nothing launched' "$s/steps/preview.md")"
    assert_eq "plan-wiring: preview resolves duplicates at plan time" "yes" "$(has 'CONTEXT=queue-plan' "$s/steps/preview.md")"
    assert_eq "plan-wiring: preview orders overlaps via helper" "yes" "$(has 'n1_queue_overlap_order' "$s/steps/preview.md")"
    assert_eq "plan-wiring: preview pre-scans the stop list" "yes" "$(has 'alwaysAskOn' "$s/steps/preview.md")"
    assert_eq "plan-wiring: run writes step: planned" "yes" "$(has '^step: planned' "$s/steps/run.md")"
    assert_eq "plan-wiring: run stamps planned_at" "yes" "$(has 'planned_at' "$s/steps/run.md")"
    assert_eq "plan-wiring: run has Decisions section" "yes" "$(has '^## Decisions' "$s/steps/run.md")"
    assert_eq "plan-wiring: --run applies staleness gate" "yes" "$(has 'n1_queue_stale' "$s/steps/run.md")"
    assert_eq "plan-wiring: preview computes the schedule (N1-303)" "yes" "$(has 'n1_queue_overlap_preds$' "$s/steps/preview.md")"
    assert_eq "plan-wiring: run.md re-pins max_concurrent on re-plan" "yes" "$(has 'max_concurrent "\$\(n1_queue_max_concurrent\)"' "$s/steps/run.md")"
    assert_eq "plan-wiring: Start/Edit refresh rewrites the schedule" "yes" "$(sed "/^## Write plan/q" "$s/steps/run.md" | grep -cF 'n1_queue_schedule_write "$QUEUE_DIR' | awk '{print ($1>=2)?"yes":"no"}')"
    assert_eq "plan-wiring: stale re-plan prints the re-pin" "yes" "$(has 'Re-pinned max_concurrent' "$s/steps/run.md")"
    assert_eq "plan-wiring: preview prints the concurrency/usage-limit note" "yes" "$(has 'Parallel workers share your usage limits' "$s/steps/preview.md")"
    assert_eq "plan-wiring: run.md pins max_concurrent in frontmatter" "yes" "$(has '^max_concurrent: <MAX_CONCURRENT>$' "$s/steps/run.md")"
    assert_eq "plan-wiring: run.md has the Schedule section" "yes" "$(has '^## Schedule$' "$s/steps/run.md")"
    assert_eq "plan-wiring: run.md writes the schedule via helper" "yes" "$(has 'n1_queue_schedule_write' "$s/steps/run.md")"
    assert_eq "plan-wiring: --run keeps the stored value when config differs" "yes" "$(has 'Using planned max_concurrent' "$s/steps/run.md")"
    assert_eq "plan-wiring: saved plan prints its schedule" "yes" "$(has 'n1_queue_plan_waves' "$s/steps/run.md")"
    assert_eq "plan-wiring: queue steps never write overview.md" "no" \
        "$(cat "$s/steps/intake.md" "$s/steps/preview.md" "$s/steps/run.md" | grep -qE 'n1_write_frontmatter[^|]*overview' && echo yes || echo no)"
    assert_eq "plan-wiring: staleness re-plan re-orders every pending row (CR-1)" "yes" "$(has 'Re-run overlap order globally' "$s/steps/run.md")"
    assert_eq "plan-wiring: staleness recheck uses the sha256 hash helper, not cksum" "yes" "$(has 'n1_queue_content_hash' "$s/steps/run.md")"
    assert_eq "plan-wiring: run.md no longer pipes through cksum" "no" "$(has 'cksum <' "$s/steps/run.md")"
    assert_eq "plan-wiring: preview snapshot uses the sha256 hash helper, not cksum" "yes" "$(has 'n1_queue_content_hash' "$s/steps/preview.md")"
    assert_eq "plan-wiring: preview.md no longer pipes through cksum" "no" "$(has 'cksum <' "$s/steps/preview.md")"
    assert_eq "plan-wiring: intake validates ticket keys before path use (SEC-L4)" "yes" "$(has '\^\[A-Z\]\[A-Z0-9_\]\*-\[0-9\]\+\$' "$s/steps/intake.md")"

    # SEC-1: the capture hook writes the title/desc files from the fetch; the title is never interpolated into a shell string.
    assert_eq "plan-wiring: preview marks the snapshot fetch for the capture hook (N1-326)" "yes" "$(grep -qF 'n1_desc_mark queue "<KEY>" "<QUEUE_ID>"' "$s/steps/preview.md" && echo yes || echo no)"
    assert_eq "plan-wiring: preview checks missing desc files before the snapshot (N1-326)" "yes" "$(grep -qF 'echo "REFETCH <KEY>"' "$s/steps/preview.md" && echo yes || echo no)"
    assert_eq "plan-wiring: run.md marks the re-plan fetch for the capture hook (N1-326)" "yes" "$(grep -qF 'n1_desc_mark queue "<KEY>" "<QUEUE_ID>"' "$s/steps/run.md" && echo yes || echo no)"
    local fw
    for fw in intake preview run; do
        assert_eq "plan-wiring: $fw.md never model-writes desc/<KEY> files (N1-326)" "0" \
            "$(grep -F 'desc/<KEY>' "$s/steps/$fw.md" | grep -cE 'file-write( mechanism|,)' || true)"
    done
    assert_eq "plan-wiring: preview no longer passes a bare <title> string to content_hash" "no" "$(has 'n1_queue_content_hash "<title>"' "$s/steps/preview.md")"
    assert_eq "plan-wiring: run.md writes the fresh title to a file before hashing" "yes" "$(has '\.title' "$s/steps/run.md")"
    assert_eq "plan-wiring: run.md no longer passes a bare <title> string to content_hash" "no" "$(has 'n1_queue_content_hash "<title>"' "$s/steps/run.md")"

    # SEC-4: initial Plan/Decisions rows are built through the sanitizing write helpers, not prose alone.
    assert_eq "plan-wiring: write plan fills Title via n1_queue_row_title" "yes" "$(has 'n1_queue_row_title' "$s/steps/run.md")"
    assert_eq "plan-wiring: write plan fills Decisions row via n1_queue_decisions_write_row" "yes" "$(has 'n1_queue_decisions_write_row' "$s/steps/run.md")"
    assert_eq "plan-wiring: run.md passes no free text as a quoted literal" "no" "$(has "'<(title|reason|notes)[^>]*>'|changed: <status>" "$s/steps/run.md")"

    # NP-225: blocker/duplicate/touches re-checks must not be re-gated behind the content-hash CHANGED branch.
    assert_eq "NP-225: blocker check re-runs unconditionally on re-plan" "yes" "$(has 'Blocker check \(unconditional' "$s/steps/run.md")"
    assert_eq "NP-225: duplicate check re-runs unconditionally on re-plan" "yes" "$(has 'Duplicate check \(unconditional' "$s/steps/run.md")"
    assert_eq "NP-225: touches extraction re-runs unconditionally on re-plan" "yes" "$(has 'Touches extraction \(unconditional' "$s/steps/run.md")"
    assert_eq "NP-225: duplicate re-check uses interactive plan-time resolution, not the annotate-only context" "yes" "$(has 'Duplicate check \(unconditional.*CONTEXT=queue-plan' "$s/steps/run.md")"
    assert_eq "NP-225: the CHANGED (content-hash) branch no longer re-runs the blocker/duplicate checks itself" "no" \
        "$(has 'CHANGED.: re-plan this ticket only:.*Blocker check.*Duplicate check' "$s/steps/run.md")"

    # NP-225 CR-1: the per-row loop must read the Decisions row once and flush it once,
    # never call n1_queue_decisions_write_row (a full-row replace) from the duplicate check
    # or touches extraction steps directly — that would blank the other 4 fields each time.
    assert_eq "NP-225 CR-1: per-row loop reads the Decisions row once before duplicate check" "yes" \
        "$(has 'n1_queue_decisions_row \"\$QUEUE_FILE\" \"<KEY>\"' "$s/steps/run.md")"
    assert_eq "NP-225 CR-1: duplicate check no longer writes the Decisions row directly" "no" \
        "$(has 'Duplicate check \(unconditional.*n1_queue_decisions_write_row' "$s/steps/run.md")"
    assert_eq "NP-225 CR-1: touches extraction no longer writes the Decisions row directly" "no" \
        "$(has 'Touches extraction \(unconditional.*n1_queue_decisions_write_row' "$s/steps/run.md")"
}

# N1-423: explicit ticket list input and the required-input gate.
test_list_input_wiring() {
    local s="$REPO_ROOT/skills/n1-queue" in="$REPO_ROOT/skills/n1-queue/steps/input.md"
    has() { grep -qE -- "$1" "$2" && echo yes || echo no; }
    hasF() { grep -qF -- "$1" "$2" && echo yes || echo no; }
    assert_eq "list-input: description lists the ticket operand" "yes" \
        "$(sed -n '3p' "$s/SKILL.md" | grep -qF '[<ticket|url>...]' && echo yes || echo no)"
    assert_eq "list-input: argument-hint lists the ticket operand" "yes" \
        "$(sed -n '4p' "$s/SKILL.md" | grep -qF '[<ticket|url>...]' && echo yes || echo no)"
    assert_eq "list-input: step 2 routes to input.md before the unattended entry" "yes" \
        "$(grep -E '^2\. \*\*Saved plan' "$s/SKILL.md" | grep -qE 'steps/input\.md.*If `--unattended`' && echo yes || echo no)"
    assert_eq "list-input: SKILL.md no longer reads the default tag" "no" "$(hasF 'n1_queue_val tag' "$s/SKILL.md")"
    assert_eq "list-input: input.md never reads the default tag" "no" "$(hasF 'n1_queue_val tag' "$in")"
    assert_eq "list-input: URLs go through n1_extract_ticket_from_url" "yes" "$(hasF 'n1_extract_ticket_from_url' "$in")"
    assert_eq "list-input: list keys are validated" "yes" "$(hasF '^[A-Z][A-Z0-9_]*-[0-9]+$' "$in")"
    assert_eq "list-input: tag/story ids are validated" "yes" "$(hasF '^[A-Za-z0-9][A-Za-z0-9._-]*$' "$in")"
    assert_eq "list-input: unattended with no input stops" "yes" \
        "$(hasF 'No input: pass ticket IDs, --tag <tag> or --story <ID>.' "$in")"
    assert_eq "list-input: mixed input stops" "yes" "$(hasF 'Pass one input: a ticket list, --tag or --story.' "$in")"
    assert_eq "list-input: --tag with --story is mixed input" "yes" "$(hasF 'includes `--tag` with `--story`' "$in")"
    assert_eq "list-input: no valid key stops" "yes" "$(hasF 'No valid ticket keys in the list.' "$in")"
    assert_eq "list-input: missing-input prompt is free text, not an option list" "no" "$(has '^   > [0-9]\. ' "$in")"
    assert_eq "list-input: intake has List mode" "yes" "$(has '^## List mode$' "$s/steps/intake.md")"
    assert_eq "list-input: list mode skips the already-run check" "yes" \
        "$(sed -n '/^## List mode$/,/^## /p' "$s/steps/intake.md" | grep -qF 'no already-run check' && echo yes || echo no)"
    assert_eq "list-input: list mode excludes invalid items" "yes" \
        "$(sed -n '/^## List mode$/,/^## /p' "$s/steps/intake.md" | grep -qF 'invalid ticket key' && echo yes || echo no)"
    assert_eq "list-input: list mode excludes unreadable keys" "yes" \
        "$(sed -n '/^## List mode$/,/^## /p' "$s/steps/intake.md" | grep -qF 'reason `not found`' && echo yes || echo no)"
    assert_eq "list-input: Story check covers list mode" "yes" "$(has '^## Story check \(tag and list mode\)$' "$s/steps/intake.md")"
    assert_eq "list-input: plan header allows mode list" "yes" "$(hasF 'mode: tag|story|list' "$s/steps/run.md")"
    assert_eq "list-input: revalidation covers list mode" "yes" "$(hasF 'story and list mode: done-class per intake.md § Story mode' "$s/steps/run.md")"
    local line a b c
    line=$(grep -m1 'list-%08x' "$in")
    a=$(KEYS=" N1-2 N1-10 N1-2"; eval "$line"; printf '%s' "$QUEUE_ID")
    b=$(KEYS=" N1-10 N1-2"; eval "$line"; printf '%s' "$QUEUE_ID")
    c=$(KEYS=" N1-3"; eval "$line"; printf '%s' "$QUEUE_ID")
    assert_eq "list-input: QUEUE_ID ignores order and duplicates" "$a" "$b"
    assert_eq "list-input: QUEUE_ID is list-<8 hex>" "yes" "$([[ "$a" =~ ^list-[0-9a-f]{8}$ ]] && echo yes || echo no)"
    assert_eq "list-input: different keys give a different QUEUE_ID" "yes" "$([ "$a" != "$c" ] && echo yes || echo no)"
    # Run the item-1 resolve loop from input.md with real items and a stubbed URL extractor.
    local raw blk out
    raw=$(awk '/^```bash$/{b="";f=1;next} /^```$/{if(f&&b~/for ITEM in/){printf "%s",b;exit}f=0} f{b=b $0 "\n"}' "$in" | grep -v '^source ')
    blk=${raw/"for ITEM in '<ITEM_1>' '<ITEM_2>'"/"for ITEM in 'N1-2' 'N1-2' 'N1-12' 'N1-1' 'notakey' 'https://x/browse/N1-7' 'https://x/bad' 'n1-5' 'a|PWN-1|x' 'but' 'maxConcurrent'"}
    out=$(n1_extract_ticket_from_url() { case "$1" in */browse/*) echo "${1##*/}" ;; *) return 1 ;; esac; }
        N1_HOME=/nonexistent; eval "$blk")
    assert_eq "list-input: loop keeps order, dedupes, resolves URLs" "KEYS= N1-2 N1-12 N1-1 N1-7" "$(grep '^KEYS=' <<<"$out")"
    assert_eq "list-input: key-shaped typos and failed URLs go to BAD (N1-440)" "BAD= https:__x_bad n1-5" "$(grep '^BAD=' <<<"$out")"
    assert_eq "list-input: other words go to PROSE, sanitized (N1-440)" "PROSE= notakey a_PWN-1_x but maxConcurrent" "$(grep '^PROSE=' <<<"$out")"
    blk=${raw/"for ITEM in '<ITEM_1>' '<ITEM_2>'"/"for ITEM in 'but' 'change' 'maxConcurrent' 'to' '1' 'in' 'n1' 'config'"}
    out=$(N1_HOME=/nonexistent; eval "$blk")
    assert_eq "list-input: prose-only args yield no keys (N1-440)" "KEYS=|BAD=" "$(grep '^KEYS=' <<<"$out")|$(grep '^BAD=' <<<"$out")"
    assert_eq "list-input: prose-only args are kept as an instruction (N1-440)" "PROSE= but change maxConcurrent to 1 in n1 config" "$(grep '^PROSE=' <<<"$out")"
    # N1-440 rule text
    assert_eq "list-input: never-infer rule (N1-440)" "yes" "$(hasF 'Never pick a tag, story or ticket list from conversation context, memory, config, a schedule or an existing queue dir, and never reuse a queue dir because it looks current.' "$in")"
    assert_eq "list-input: prose alone still asks item 3 (N1-440)" "yes" "$(hasF '(prose alone counts as no input)' "$in")"
    assert_eq "list-input: prose printed as a session instruction (N1-440)" "yes" "$(hasF 'Session instruction (not a ticket selector): ' "$in")"
    assert_eq "list-input: prose never selects input (N1-440)" "yes" "$(hasF 'Never use prose as a ticket key, tag, story ID, path or shell word' "$in")"
    assert_eq "list-input: no-valid-key needs BAD items (N1-440)" "yes" "$(hasF '`KEYS` is empty and `BAD` is not' "$in")"
    assert_eq "list-input: interactive plans get a unique id (N1-440)" "yes" "$(hasF 'QUEUE_ID=$(n1_queue_new_id "$QUEUE_ID")' "$in")"
    assert_eq "list-input: planning pointer written at intake (N1-440)" "yes" "$(hasF 'n1_queue_plan_state write "$QUEUE_ID" intake "$MODE" "$SRC"' "$in")"
    assert_eq "list-input: no bare mkdir -p for interactive ids (N1-440)" "1" "$(grep -c 'mkdir -p "$N1_HOME/queue/$QUEUE_ID"' "$in")"
}

# N1-440: per-session queue planning pointer, unique plan ids, planning-dir discard.
test_queue_plan_state() {
    local h; h=$(mktemp -d)
    type n1_session_id >/dev/null 2>&1 || source "$REPO_ROOT/lib/host.sh"
    qps() { ( export N1_HOME="$h" N1_SESSION_ID="${SID:-s1}"; n1_queue_plan_state "$@" ); }
    qnew() { ( export N1_HOME="$h" N1_SESSION_ID=s1; n1_queue_new_id "$@" ); }
    qdis() { ( export N1_HOME="$h" N1_SESSION_ID=s1; n1_queue_plan_discard "$@" ); }
    local rc out a b c
    # pointer write/read/step/clear
    qps write n1-auto-20261106T101530Z intake tag n1-auto; rc=$?
    assert_eq "plan-state: write rc 0" "0" "$rc"
    assert_eq "plan-state: keyed file written" "yes" "$([ -f "$h/queue-plan.s1.json" ] && echo yes || echo no)"
    assert_eq "plan-state: read prints id step mode source" "$(printf 'n1-auto-20261106T101530Z\tintake\ttag\tn1-auto')" "$(qps read)"
    qps step preview
    assert_eq "plan-state: step advances" "preview" "$(qps read | cut -f2)"
    qps step bogus && rc=0 || rc=$?
    assert_eq "plan-state: unknown step refused" "1" "$rc"
    assert_eq "plan-state: refused step keeps the old one" "preview" "$(qps read | cut -f2)"
    qps write '../x' intake tag x && rc=0 || rc=$?
    assert_eq "plan-state: bad queue id refused" "1" "$rc"
    qps write q1 intake epic x && rc=0 || rc=$?
    assert_eq "plan-state: bad mode refused" "1" "$rc"
    qps write q1 intake list 'N1-1 N1-2;$(id)/x'
    assert_eq "plan-state: source sanitized" "N1-1 N1-2idx" "$(qps read | cut -f4)"
    local long; long=$(printf "N1-%s," $(seq 1 100)); qps write q1 intake list "$long"
    assert_eq "plan-state: long selector kept whole" "$long" "$(qps read | cut -f4)"
    qps write q1 intake list 'N1-1 N1-2;$(id)/x'
    assert_eq "plan-state: other session reads nothing" "" "$(SID=s2 qps read)"
    SID='a/b' qps write q1 intake tag x && rc=0 || rc=$?
    assert_eq "plan-state: unsafe sid refused" "1" "$rc"
    assert_eq "plan-state: unsafe sid writes no file" "1" "$(ls "$h" | grep -c '^queue-plan\.')"
    echo '{"queueId":"../x","step":"intake","mode":"tag","source":""}' > "$h/queue-plan.s1.json"
    qps read >/dev/null && rc=0 || rc=$?
    assert_eq "plan-state: tampered id not read" "1" "$rc"
    qps clear
    assert_eq "plan-state: clear removes the file" "no" "$([ -e "$h/queue-plan.s1.json" ] && echo yes || echo no)"
    # unique ids
    mkdir -p "$h/queue/n1-auto"; echo 'old rows' > "$h/queue/n1-auto/queue.md"
    a=$(qnew n1-auto); b=$(qnew n1-auto)
    assert_eq "new-id: two plans of one tag differ" "yes" "$([ -n "$a" ] && [ "$a" != "$b" ] && echo yes || echo no)"
    assert_eq "new-id: shape <tag>-<UTC>[-n]" "yes" "$([[ "$a" =~ ^n1-auto-[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$ ]] && [[ "$b" =~ ^n1-auto-[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$ ]] && echo yes || echo no)"
    assert_eq "new-id: dir created, no inherited rows" "yes|no" "$([ -d "$h/queue/$b" ] && echo yes)|$([ -e "$h/queue/$b/queue.md" ] && echo yes || echo no)"
    c=$(qnew "$(printf 'x%.0s' {1..50})")
    assert_eq "new-id: base cut to 40" "yes" "$([[ "$c" =~ ^x{40}-[0-9]{8}T[0-9]{6}Z ]] && echo yes || echo no)"
    out=$(qnew '../x') && rc=0 || rc=$?
    assert_eq "new-id: bad base refused" "1|" "$rc|$out"
    # discard
    mkdir -p "$h/queue/$a/desc"; qps write "$a" preview tag n1-auto
    qdis "$a"
    assert_eq "discard: planning-only dir removed" "no" "$([ -e "$h/queue/$a" ] && echo yes || echo no)"
    assert_eq "discard: pointer cleared" "no" "$([ -e "$h/queue-plan.s1.json" ] && echo yes || echo no)"
    qdis n1-auto && rc=0 || rc=$?
    assert_eq "discard: dir with queue.md kept" "1|yes" "$rc|$([ -f "$h/queue/n1-auto/queue.md" ] && echo yes)"
    mkdir -p "$h/queue/claimed/.unattended-claim"
    qdis claimed && rc=0 || rc=$?
    assert_eq "discard: claimed dir kept" "1|yes" "$rc|$([ -d "$h/queue/claimed" ] && echo yes)"
    qdis '../x' && rc=0 || rc=$?
    assert_eq "discard: bad id refused" "1" "$rc"
    rm -rf "$h"
}

# N1-440: tag attribute and planning-state wiring in run.md, runner and report.
test_queue_id_wiring() {
    local s="$REPO_ROOT/skills/n1-queue/steps"
    hasF() { grep -qF -- "$1" "$2" && echo yes || echo no; }
    assert_eq "id-wiring: plan frontmatter carries tag" "yes" "$(hasF 'tag: <--tag value in tag mode, else empty>' "$s/run.md")"
    assert_eq "id-wiring: saved plan advances state" "yes" "$(hasF 'n1_queue_plan_state step saved' "$s/run.md")"
    assert_eq "id-wiring: launch clears planning state" "yes" "$(hasF 'n1_queue_plan_state clear' "$s/run.md")"
    assert_eq "id-wiring: --plan stop clears planning state" "yes" "$(hasF 'n1_queue_plan_state clear`, then print "Plan saved' "$s/run.md")"
    assert_eq "id-wiring: report reads tag attribute" "yes" "$(hasF 'TAG=$(n1_read_frontmatter "$QUEUE_FILE" tag)' "$s/report.md")"
    assert_eq "id-wiring: runner reads tag attribute" "yes" "$(hasF 'N1_QUEUE_TAG=$(n1_read_frontmatter "$QUEUE" tag)' "$REPO_ROOT/scripts/n1-queue-run.sh")"
    # --run in a new session: input.md never ran, so the Hierarchy block's SRC comes from the saved frontmatter.
    assert_eq "id-wiring: saved plan restores SRC from frontmatter" "yes" "$(hasF 'SRC=$(n1_read_frontmatter "$QUEUE_FILE" story_id 2>/dev/null)' "$s/run.md")"
}

# N1-55: ask-mode child mirrors its question and accepts a relayed answer; n1-queue exposes --answer.
test_answer_wiring() {
    local h="$REPO_ROOT/skills/n1-start/procedures/autonomy-headless-ask.md"
    local s="$REPO_ROOT/skills/n1-queue/SKILL.md" r="$REPO_ROOT/skills/n1-queue/steps/report.md"
    assert_eq "answer-wiring: child writes question file" "yes" "$(grep -qF '.question-%s.json' "$h" && echo yes || echo no)"
    assert_eq "answer-wiring: child removes question file on answer" "yes" "$(grep -qF 'rm -f "$N1_QUEUE_DIR/.question-$ID.json"' "$h" && echo yes || echo no)"
    assert_eq "answer-wiring: child accepts relayed answer" "yes" "$(grep -qF '[n1-queue answer] ' "$h" && echo yes || echo no)"
    assert_eq "answer-wiring: SKILL documents --answer" "yes" "$(grep -qF -- '--answer <ticket> <text>' "$s" && echo yes || echo no)"
    assert_eq "answer-wiring: report calls n1_queue_answer" "yes" "$(grep -qF 'n1_queue_answer "$N1_HOME"' "$r" && echo yes || echo no)"
    assert_eq "answer-wiring: question schema carries rationale (RULE-1)" "yes" "$(grep -qF '"recommended","rationale"}' "$h" && grep -qF 'No recommendation. The options are equivalent given the available evidence; select based on team preference.' "$h" && echo yes || echo no)"
    assert_eq "answer-wiring: question schema documents optional alternatives (N1-216)" "yes" "$(grep -qF '"alternatives": {"<option label>": "works when <condition>"}' "$h" && grep -qF 'references/question-format.md' "$h" && echo yes || echo no)"
    assert_eq "answer-wiring: per-ticket answer file cleared before write" "yes" "$(grep -qF 'AF="$N1_HOME/queue/.answer-<ticket>.txt"; rm -f "$AF"' "$r" && echo yes || echo no)"
    assert_eq "answer-wiring: answer written via file-write mechanism" "yes" "$(grep -qF 'file-write mechanism' "$r" && echo yes || echo no)"
}

# NP-203: queue children apply plan-time pre-decisions; release gate never consults them.
test_headless_plan_wiring() {
    local h="$REPO_ROOT/skills/n1-start/procedures/autonomy-headless-predecision.md" l="$REPO_ROOT/skills/n1-start/ledger.md"
    assert_eq "headless-plan: looks up the Decisions row" "yes" "$(grep -q 'n1_queue_decisions_row "\$N1_QUEUE_DIR/queue.md"' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: logs [plan]" "yes" "$(grep -qF '[plan]' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: release gate excluded" "yes" "$(grep -q 'release confirmation gate never consults' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: ledger documents [plan]" "yes" "$(grep -qF '`[plan]`' "$l" && echo yes || echo no)"
    assert_eq "headless-plan: verifies queue.md run_id matches N1_QUEUE_RUN_ID (SEC-L1)" "yes" \
        "$(grep -q 'run_id 2>/dev/null)" = "\$N1_QUEUE_RUN_ID"' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: recomputes the content hash before honouring a pre-decision (SEC-1)" "yes" \
        "$(grep -qF 'n1_queue_content_hash' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: falls through to escalation on hash mismatch (SEC-1)" "yes" \
        "$(grep -qF 'MISMATCH' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: title and desc are written to files, never a bare shell string (SEC-1)" "yes" \
        "$(grep -q 'n1_queue_content_hash "\$M/.guard-live.title" "\$M/.guard-live.txt"' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: MATCH needs a non-empty live hash in the trusted set (SEC-5, NP-231)" "yes" \
        "$(grep -qF 'if [ -n "$NEW_HASH" ] && n1_desc_hash_is_trusted "$ID" "$NEW_HASH"; then echo MATCH; else echo MISMATCH; fi' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: trusted set names N1's recorded writes (.desc-hashes)" "yes" \
        "$(grep -qF '.desc-hashes' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: single-value equality against OLD_HASH is gone" "no" \
        "$(grep -qF '[ "$NEW_HASH" = "$OLD_HASH" ]' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: points at the chain procedure" "yes" \
        "$(grep -qF 'references/desc-hash-chain.md' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: checks for post-plan human comments (SEC-2)" "yes" \
        "$(grep -qF 'Comment check (SEC-2)' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: a post-plan comment falls through like MISMATCH (SEC-2)" "yes" \
        "$(grep -q 'created after .planned_at.: treat this exactly like .MISMATCH' "$h" && echo yes || echo no)"
    assert_eq "headless-plan: guard re-fetch is marked for the capture hook (N1-326)" "yes" \
        "$(grep -qF 'n1_desc_mark guard "$ID"' "$h" && echo yes || echo no)"
}

# N1-268 AC3. Bug caught: a failed row whose PR merged after the runner stopped supervising it stays "failed" in --status.
test_status_reconcile_merged() {
    local tmp out; tmp=$(mktemp -d)
    mk_bg "$tmp" oq "T-A:done" "T-B:done" "T-C:done"
    mkdir -p "$tmp/n1home/memory/T-A" "$tmp/n1home/memory/T-B" "$tmp/n1home/memory/T-C"
    n1_write_frontmatter "$tmp/queue.md" run_id R1
    # finalize stamps queue_run_id on the overview; T-C's overview is left over from an earlier run (R0) whose PR merged long ago.
    printf -- '---\nstep: done\nqueue_run_id: R1\n---\n## Pending\npr_url: https://github.com/o/r/pull/1\n' > "$tmp/n1home/memory/T-A/overview.md"
    printf -- '---\nstep: done\nqueue_run_id: R1\n---\n## Pending\npr_url: https://github.com/o/r/pull/2\n' > "$tmp/n1home/memory/T-B/overview.md"
    printf -- '---\nstep: done\nqueue_run_id: R0\n---\n## Pending\npr_url: https://github.com/o/r/pull/3\n' > "$tmp/n1home/memory/T-C/overview.md"
    for n in 1 2 3; do n1_queue_row_status "$tmp/queue.md" "$n" failed subtask-timeout; done
    printf '| T-A | 2026-11-02T00:00:00Z | | failed | | orca:task-T-A/d-T-A |\n| T-B | 2026-11-02T00:00:00Z | | failed | | orca:task-T-B/d-T-B |\n| T-C | 2026-11-02T00:00:00Z | | failed | | orca:task-T-C/d-T-C |\n' >> "$tmp/queue.md"
    printf '#!/bin/sh\ncase "$*" in *pull/1*|*pull/3*) echo MERGED ;; *pull/2*) echo OPEN ;; esac\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
    : > "$tmp/events.jsonl"
    out=$(PATH="$tmp/bin:$PATH" n1_queue_reconcile "$tmp/queue.md")
    assert_eq "reconcile: merged row reported" "reconciled: T-A merged" "$out"
    assert_eq "reconcile: Runs outcome merged / open PR and stale-run PR untouched" "merged failed failed" \
        "$(_n1_queue_run_outcome "$tmp/queue.md" T-A) $(_n1_queue_run_outcome "$tmp/queue.md" T-B) $(_n1_queue_run_outcome "$tmp/queue.md" T-C)"
    assert_eq "reconcile: failed -> pr for the merged row only" "pr failed failed" \
        "$(plan_cell "$tmp/queue.md" 1 8) $(plan_cell "$tmp/queue.md" 2 8) $(plan_cell "$tmp/queue.md" 3 8)"
    assert_eq "runs-outcome: no Runs row is non-zero" "1" "$(n1_queue_runs_outcome "$tmp/queue.md" T-Z merged >/dev/null; echo $?)"
    assert_eq "reconcile: event recorded" "merged" \
        "$(jq -r 'select(.event=="ticket_finished" and .ticket=="T-A") | .outcome' "$tmp/events.jsonl")"
    assert_eq "reconcile: table shows merged" "merged" \
        "$(PATH="$tmp/bin:$PATH" n1_queue_status_table "$tmp/queue.md" "$tmp/events.jsonl" | awk -F'\t' '$1 == "T-A" { print $2 }')"
    assert_eq "reconcile: idempotent" "" "$(PATH="$tmp/bin:$PATH" n1_queue_reconcile "$tmp/queue.md")"
    assert_eq "reconcile: one event only" "1" "$(grep -c '"ticket_finished"' "$tmp/events.jsonl")"
    rm -rf "$tmp"
}

# N1-298: --story <Epic> expands each child into its Sub-tasks; --story <Story> is unchanged.
test_story_epic_wiring() {
    local s="$REPO_ROOT/skills/n1-queue/steps"
    hasF() { grep -qF -- "$1" "$2" && echo yes || echo no; }
    hasX() { grep -qxF -- "$1" "$2" && echo yes || echo no; }
    # Epic branch
    assert_eq "epic-wiring: intake has the Jira-only Epic expansion paragraph" "yes" "$(hasF '**Epic expansion (Jira only).**' "$s/intake.md")"
    assert_eq "epic-wiring: Epic branch keys on root issue type Epic" "yes" "$(hasF 'returned issue type `Epic` for the story ID' "$s/intake.md")"
    assert_eq "epic-wiring: per-child search copies the story JQL form" "yes" "$(hasF 'JQL `parent = <STORY_KEY> ORDER BY created ASC`' "$s/intake.md")"
    assert_eq "epic-wiring: child keys are key-validated before the search" "yes" "$(hasF 'Apply § Key validation to `<STORY_KEY>` before the search' "$s/intake.md")"
    assert_eq "epic-wiring: any child search error stops the whole intake" "yes" "$(hasF '**STOP** the whole intake (no partial plan)' "$s/intake.md")"
    assert_eq "epic-wiring: childless child stays one row" "yes" "$(hasF 'Reason `epic child`' "$s/intake.md")"
    assert_eq "epic-wiring: expanded Sub-tasks carry their Story key" "yes" "$(hasF 'Reason `epic subtask of <STORY_KEY>`' "$s/intake.md")"
    assert_eq "epic-wiring: all-Done child is excluded" "yes" "$(hasF 'done-before-run (all subtasks done)' "$s/intake.md")"
    assert_eq "epic-wiring: depth fixed, Sub-tasks never searched" "yes" "$(hasF 'never search a Sub-task for children' "$s/intake.md")"
    assert_eq "epic-wiring: YouTrack story mode unchanged" "yes" "$(hasF 'YouTrack has no Epic path here' "$s/intake.md")"
    assert_eq "epic-wiring: Output lists the Epic Reason values" "yes" "$(hasF '`epic subtask of <STORY_KEY>` and `epic child` for Epic-mode candidates' "$s/intake.md")"
    # Unchanged Story path (byte-identical lines)
    assert_eq "epic-wiring: story JQL line unchanged" "yes" "$(hasX '- **Jira:** call `mcp__<TRACKER_MCP>__<SEARCH_OP>` with JQL `parent = <STORY_ID> ORDER BY created ASC`. Include `cloudId`.' "$s/intake.md")"
    assert_eq "epic-wiring: zero-subtask STOP line unchanged" "yes" "$(hasX '- **Zero subtasks** (parsed empty result, any status): print "no subtasks — run /n1:n1-start <STORY_ID>" and **STOP** (no queue is built).' "$s/intake.md")"
    assert_eq "epic-wiring: story subtask Reason kept" "yes" "$(hasF '`story subtask` for story-mode candidates found via subtask enumeration' "$s/intake.md")"
    # Preview hierarchy (display-only, schema unchanged)
    assert_eq "epic-wiring: preview prints Hierarchy only for epic Reasons (contains, not starts-with)" "yes" "$(hasF 'When any candidate'"'"'s Reason contains `epic subtask of ` or `epic child`' "$s/preview.md")"
    assert_eq "epic-wiring: preview Hierarchy line format" "yes" "$(hasX 'Epic <SRC> > Story <STORY_KEY> <CHILD_TITLE>: #3, #4, #5' "$s/preview.md")"
    assert_eq "epic-wiring: Hierarchy uses post-reorder numbers and is display-only" "yes" "$(hasF 'Grouping is display-only' "$s/preview.md")"
    assert_eq "epic-wiring: Prompt re-print includes the Hierarchy block" "yes" "$(hasF 'Print the plan table again (Reason now carries Order notes) and the Hierarchy block when it applies' "$s/preview.md")"
}


test_parse_service
test_find_repo
test_pick_model
test_plan_wiring
test_list_input_wiring
test_queue_plan_state
test_queue_id_wiring
test_story_epic_wiring
test_child_status
test_child_status_deploy
test_held_helpers
test_held_user_merge
test_held_sweep_story_finish_skip
test_sync_default
test_story_branch_helpers
test_queue_branch_ensure
test_story_base
test_story_bg_settings
test_story_base_wiring
test_story_branch_wiring
test_row_status
test_queue_retry
test_write_plan_cells
test_pending_rows
test_decisions_and_stale
test_desc_hash_chain
test_refined_intake_check
test_title_vague
test_desc_chain_wiring
test_brief_wiring
test_retry_wiring
test_form_repair_wiring
test_overlap_order
test_schedule_helpers
test_eligible_rows
test_schedule_cycle_and_merge_final
test_obsolete_release
test_release_wiring
test_already_run
test_release_rows
test_release_cmd
test_bg_helpers
test_decision_counts
test_queue_digest
test_fmt_elapsed
test_status_table_pre_np197_fixture
test_status_table_claude_code
test_status_table_running_step
test_queue_answer
test_escalated_step_fallback
test_queue_event
test_escalation_text
test_desktop_notify
test_desktop_notify_stdin
test_notify_backends
test_answer_wiring
test_headless_plan_wiring
test_status_reconcile_merged

test_n1_339_cleanup_helpers() {
    local tmp339 cmd339; tmp339=$(mktemp -d)
    printf '## Finish\n- **Cleanup:** worktree:removed, branch:deleted (/x)\n' > "$tmp339/a.md"
    printf '## Finish\n- **Cleanup:** worktree:kept (dirty), branch:kept (checked out in /x)\n' > "$tmp339/b.md"
    assert_eq "N1-339 cleanup_needed: branch deleted -> no" no "$(n1_queue_cleanup_needed "$tmp339/a.md" && echo yes || echo no)"
    assert_eq "N1-339 cleanup_needed: kept -> yes" yes "$(n1_queue_cleanup_needed "$tmp339/b.md" && echo yes || echo no)"
    assert_eq "N1-339 cleanup_needed: no line -> yes" yes "$(n1_queue_cleanup_needed "$tmp339/none.md" && echo yes || echo no)"
    cmd339=$(n1_queue_clean_cmd /repo T-B sonnet run-1 n1-q-T-B-2-clean)
    assert_eq "N1-339 clean_cmd: n1-clean --ticket T-B" yes "$([[ "$cmd339" == *n1-clean*--ticket*T-B* ]] && echo yes || echo no)"
    assert_eq "N1-339 clean_cmd: unattended queue settings" yes "$([[ "$cmd339" == *N1_QUEUE_RUN_ID*run-1* ]] && echo yes || echo no)"
    printf '%s\n' '{"event":"ticket_cleanup","ticket":"T-A","outcome":"skipped","reason":"worktree:kept (dirty); /a"}' \
        '{"event":"ticket_cleanup","ticket":"T-B","outcome":"failed","reason":"x"}' \
        '{"event":"ticket_cleanup","ticket":"T-B","outcome":"success","reason":"y"}' 'garbage' > "$tmp339/e.jsonl"
    assert_eq "N1-339 cleanup_left: last per ticket, non-success only" "T-A: worktree:kept (dirty); /a" "$(n1_queue_cleanup_left "$tmp339/e.jsonl")"
    assert_eq "N1-339 cleanup_left: missing file prints nothing" "" "$(n1_queue_cleanup_left "$tmp339/nope.jsonl")"
    assert_eq "N1-339 report: header has Cleanup" yes "$(grep -qF 'PR\tAttach\tCleanup' "$REPO_ROOT/skills/n1-queue/steps/report.md" && echo yes || echo no)"
    assert_eq "N1-339 report: lists worktrees not removed" yes "$(grep -qF 'n1_queue_cleanup_left' "$REPO_ROOT/skills/n1-queue/steps/report.md" && echo yes || echo no)"
    rm -rf "$tmp339"
}

# N1-292: one PR read for state, base and head; nothing on a non-GitHub URL or a persistent gh error.
test_pr_view() {
    local tmp u=https://github.com/o/r/pull/1; tmp=$(mktemp -d); mk_bg "$tmp" pv "T-A:done"
    printf 'OPEN\tstory/S-1\tabc\n' > "$tmp/fake/gh-view.1"
    assert_eq "pr_view: state base head" "OPEN|story/S-1|abc" \
        "$(PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp/fake" n1_queue_pr_view "$u" | tr '\t' '|')"
    rm -f "$tmp/fake/gh-view.1"
    assert_eq "pr_view: gh error -> empty" "" "$(PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp/fake" n1_queue_pr_view "$u")"
    assert_eq "pr_view: non-GitHub URL -> empty, no gh call" "" "$(PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp/fake" n1_queue_pr_view https://x/pr/1)"
    rm -rf "$tmp"
}

# N1-292: one gh pr checks read classified; stdout parsed whatever the exit code (gh exits 8 while pending).
test_checks_class() {
    local tmp u=https://github.com/o/r/pull/1; tmp=$(mktemp -d); mk_bg "$tmp" cc "T-A:done"
    ck() {
        printf '%s' "$1" > "$tmp/fake/gh-checks"; printf '%s' "$2" > "$tmp/fake/gh-checks-rc"; printf '%s' "$3" > "$tmp/fake/gh-checks-err"
        PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp/fake" n1_queue_checks_class "$u"
    }
    assert_eq "checks: pass + skipping -> green" green "$(ck '[{"bucket":"pass"},{"bucket":"skipping"}]' 0 '')"
    assert_eq "checks: fail -> red" red "$(ck '[{"bucket":"pass"},{"bucket":"fail"}]' 1 '')"
    assert_eq "checks: cancel -> red" red "$(ck '[{"bucket":"cancel"}]' 1 '')"
    assert_eq "checks: fail beats pending -> red" red "$(ck '[{"bucket":"fail"},{"bucket":"pending"}]' 8 '')"
    assert_eq "checks: pending (exit 8) -> pending" pending "$(ck '[{"bucket":"pending"}]' 8 '')"
    assert_eq "checks: zero checks -> none" none "$(ck '' 1 "no checks reported on the 'feat' branch")"
    assert_eq "checks: other gh error -> error" error "$(ck '' 1 'HTTP 502: Bad Gateway')"
    assert_eq "checks: non-JSON -> error" error "$(ck 'oops' 0 '')"
    assert_eq "checks: non-GitHub URL -> error" error "$(PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp/fake" n1_queue_checks_class https://x/pr/1)"
    rm -rf "$tmp"
}

# N1-292: best-effort fast-forward of the local story branch; never forced, refuses non-story names.
test_sync_story() {
    local tmp rc; tmp=$(mktemp -d)
    git init -q -b main "$tmp/origin"
    git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m init
    git -C "$tmp/origin" branch story/S-1
    git clone -q "$tmp/origin" "$tmp/repo" 2>/dev/null
    git -C "$tmp/repo" fetch -q origin story/S-1:story/S-1
    git -C "$tmp/origin" checkout -q story/S-1
    git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m child
    rc=0; n1_queue_sync_story "$tmp/repo" story/S-1 2>/dev/null || rc=$?
    assert_eq "sync_story: rc 0" 0 "$rc"
    assert_eq "sync_story: local story branch at origin tip" "$(git -C "$tmp/origin" rev-parse story/S-1)" "$(git -C "$tmp/repo" rev-parse story/S-1)"
    rc=0; n1_queue_sync_story "$tmp/repo" main 2>/dev/null || rc=$?
    assert_eq "sync_story: non-story branch refused" 1 "$rc"
    rm -rf "$tmp"
}

# N1-446: the local queue branch is fast-forwarded after a runner merge like a story branch; other prefixes are refused.
test_sync_queue_branch() {
    local tmp rc; tmp=$(mktemp -d)
    git init -q -b main "$tmp/origin"
    git -C "$tmp/origin" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m init
    git -C "$tmp/origin" branch queue/sq-20261106T000000Z
    git clone -q "$tmp/origin" "$tmp/repo" 2>/dev/null
    rc=0; n1_queue_sync_story "$tmp/repo" queue/sq-20261106T000000Z 2>/dev/null || rc=$?
    assert_eq "sync-queue: queue branch fetched" "0|$(git -C "$tmp/origin" rev-parse queue/sq-20261106T000000Z)" \
        "$rc|$(git -C "$tmp/repo" rev-parse queue/sq-20261106T000000Z 2>/dev/null)"
    rc=0; n1_queue_sync_story "$tmp/repo" release/x 2>/dev/null || rc=$?
    assert_eq "sync-queue: other prefix refused" 1 "$rc"
    rm -rf "$tmp"
}

# N1-292: the Done session is a bg n1-run with a fixed prompt ending in the ticket id, queue settings env.
test_done_cmd() {
    local cmd; cmd=$(n1_queue_done_cmd /r T-A sonnet RUN1 n1-q-T-A-1-done)
    assert_eq "done_cmd: n1-run skill" yes "$(grep -qF '/n1:n1-run' <<< "$cmd" && echo yes || echo no)"
    assert_eq "done_cmd: session name" yes "$(grep -qF 'n1-q-T-A-1-done' <<< "$cmd" && echo yes || echo no)"
    assert_eq "done_cmd: prompt forbids merging" yes "$(grep -qF 'no\ merge' <<< "$cmd" && echo yes || echo no)"
    assert_eq "done_cmd: unattended queue settings" yes "$(grep -qF 'N1_QUEUE_RUN_ID' <<< "$cmd" && echo yes || echo no)"
}

# N1-293: ## Final PRs upsert keyed by Repo, inserted before ## Runs (stays last); fails closed on a bad PR cell or two headings.
test_final_pr_table() {
    local tmp q rc; tmp=$(mktemp -d); q="$tmp/queue.md"
    printf -- '---\nqueue_id: q\n---\n## Plan\n| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |\n|---|---|---|---|---|---|---|---|\n| 1 | T-A | a | /r1 | /h | sonnet | pr | merged |\n| 2 | T-B | b | /r2 | /h | sonnet | pr | merged |\n\n## Runs\n| Ticket |\n' > "$q"
    n1_queue_final_pr_set "$q" /r1 https://github.com/o/r/pull/9 draft "MERGEABLE (CLEAN)" ""
    n1_queue_final_pr_set "$q" /r2 - - - no-merged-children
    n1_queue_final_pr_set "$q" /r1 https://github.com/o/r/pull/9 ready "CONFLICTING (DIRTY)" 'x|y'
    assert_eq "final table: rows by repo, upserted, cells sanitized" \
        $'/r1\thttps://github.com/o/r/pull/9\tready\tCONFLICTING (DIRTY)\txy\n/r2\t-\t-\t-\tno-merged-children' \
        "$(n1_queue_final_prs "$q")"
    assert_eq "final table: ## Runs stays last" "## Runs" "$(grep '^## ' "$q" | tail -1)"
    assert_eq "final table: one heading" 1 "$(grep -c '^## Final PRs$' "$q")"
    rc=0; n1_queue_final_pr_set "$q" /r3 'https://evil.example/pull/1' ready x "" || rc=$?
    assert_eq "final table: non-GitHub PR cell refused" 1 "$rc"
    printf '## Final PRs\n' >> "$q"; rc=0
    n1_queue_final_pr_set "$q" /r3 - - - x || rc=$?
    assert_eq "final table: duplicate heading fails closed" 1 "$rc"
    assert_eq "final reader: duplicate heading prints nothing" "" "$(n1_queue_final_prs "$q")"
    sed -i '$d' "$q"
    sed -i '/^| \/r2 /a | /r4 | https://github.com/o/r/pull/5 | ready | x | |\n| /r2 | https://evil.example/pull/1 | ready | x | |\n| /r2 | [x](https://evil.example) | ready | x | |' "$q"
    assert_eq "final reader: rows outside the Plan or with a non-GitHub PR cell dropped" \
        $'/r1\thttps://github.com/o/r/pull/9\tready\tCONFLICTING (DIRTY)\txy\n/r2\t-\t-\t-\tno-merged-children' "$(n1_queue_final_prs "$q")"
    printf '{"event":"final_pr_opened","run_id":"R1","pr":"https://github.com/o/r/pull/9"}\n{"event":"final_pr_opened","run_id":"R0","pr":"https://github.com/o/r/pull/5"}\n' > "$tmp/ev.jsonl"
    sed -i '/^| \/r4 /d;/evil/d;/^| \/r2 .*\[x\]/d' "$q"
    sed -i '/^| \/r2 /a | /r2 | https://github.com/o/r/pull/5 | ready | x | |' "$q"
    assert_eq "final reader: URL row needs a final_pr_opened event of this run with the same pr" \
        $'/r1\thttps://github.com/o/r/pull/9\tready\tCONFLICTING (DIRTY)\txy\n/r2\t-\t-\t-\tno-merged-children' "$(n1_queue_final_prs "$q" "$tmp/ev.jsonl" R1)"
    assert_eq "final reader: no matching event drops URL rows" $'/r2\t-\t-\t-\tno-merged-children' "$(n1_queue_final_prs "$q" "$tmp/ev.jsonl" R2)"
    printf '\n## Final PRs\n| /r1 | https://github.com/o/r/pull/9 | ready | x | |\n' >> "$q"
    assert_eq "final reader: two headings print nothing" "" "$(n1_queue_final_prs "$q" "$tmp/ev.jsonl" R1)"
    assert_eq "final reader: no file prints nothing" "" "$(n1_queue_final_prs "$tmp/none.md")"
    rm -rf "$tmp"
}

# N1-293 (D4): body for one repo: Landed (Runs Outcome merged) and Not landed (Status, sanitized Reason cut to 120).
test_final_body() {
    local tmp q out long; tmp=$(mktemp -d); q="$tmp/queue.md"
    long=$(printf 'r%.0s' $(seq 1 200))
    {
        printf -- '---\nqueue_id: q\n---\n## Plan\n| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |\n|---|---|---|---|---|---|---|---|\n'
        printf '| 1 | T-A | a | /r1 | /h | sonnet | pr | merged |\n'
        printf '| 2 | T-B | b | /r1 | /h | sonnet | pr | finish:ci-red |\n'
        printf '| 3 | T-C | c | /r2 | /h | sonnet | pr | merged |\n'
        printf '| 4 | T-D | d | /r1 | /h | sonnet | failed | %s |\n' "$long"
        printf '\n## Runs\n| Ticket | Started | Exit | Outcome | PR | Session |\n|---|---|---|---|---|---|\n'
        printf '| T-A | t | | merged | https://github.com/o/r/pull/1 | s |\n'
        printf '| T-B | t | | pr | javascript:x | s |\n'
        printf '| T-C | t | | merged | https://github.com/o/r2/pull/3 | s |\n'
    } > "$q"
    out=$(n1_queue_final_body "$q" /r1 S-1 "$tmp/body.md")
    assert_eq "final body: counts for the repo" "1 2" "$out"
    assert_eq "final body: landed line" yes \
        "$(grep -qxF -- '- T-A: https://github.com/o/r/pull/1 (merged)' "$tmp/body.md" && echo yes || echo no)"
    assert_eq "final body: not-landed line, non-GitHub PR shown as -" yes \
        "$(grep -qxF -- '- T-B: pr, PR - (finish:ci-red)' "$tmp/body.md" && echo yes || echo no)"
    assert_eq "final body: other repo's row absent" 0 "$(grep -c 'T-C' "$tmp/body.md" || true)"
    assert_eq "final body: reason cut to 120 chars" 1 \
        "$(grep -c "^- T-D: failed, PR - ($(printf 'r%.0s' $(seq 1 120)))\$" "$tmp/body.md" || true)"
    assert_eq "final body: draft note" yes "$(grep -qF 'Draft: 2 of 3 children did not land' "$tmp/body.md" && echo yes || echo no)"
    assert_eq "final body: unreviewed disclosure" yes "$(grep -qF 'Not Codex-reviewed; the per-branch convention commit is unreviewed' "$tmp/body.md" && echo yes || echo no)"
    assert_eq "final body: human merge note" yes "$(grep -qF 'a human reviews and merges this PR' "$tmp/body.md" && echo yes || echo no)"
    out=$(n1_queue_final_body "$q" /r2 S-1 "$tmp/body2.md")
    assert_eq "final body: all landed" "1 0" "$out"
    assert_eq "final body: ready note" yes "$(grep -qF 'Ready for review: All 1 children landed.' "$tmp/body2.md" && echo yes || echo no)"
    # N1-446: queue kind — same counts, queue heading/branch/finish wording; the default kind stays story.
    out=$(n1_queue_final_body "$q" /r1 sq-20261106T000000Z "$tmp/qbody.md" queue)
    assert_eq "final-body queue: same counts as story" "$(n1_queue_final_body "$q" /r1 S-1 "$tmp/sbody.md")" "$out"
    assert_eq "final-body queue: heading" "## Queue sq-20261106T000000Z: final PR" "$(head -n1 "$tmp/qbody.md")"
    assert_eq "final-body queue: opened from the queue branch" yes \
        "$(grep -qF 'from queue/sq-20261106T000000Z (N1-293)' "$tmp/qbody.md" && echo yes || echo no)"
    assert_eq "final-body queue: finish closes no ticket" yes \
        "$(grep -qF 'After the merge, run /n1:n1-finish with this PR number; it closes no ticket and deletes the local queue branch; the remote branch follows' "$tmp/qbody.md" && echo yes || echo no)"
    n1_queue_final_body "$q" /r1 S-1 "$tmp/sbody2.md" story >/dev/null
    assert_eq "final-body: explicit story kind equals the default" "" "$(cmp "$tmp/sbody.md" "$tmp/sbody2.md" 2>&1)"
    assert_eq "final-body: unknown kind -> 1" 1 "$(n1_queue_final_body "$q" /r1 S-1 "$tmp/x.md" release >/dev/null 2>&1; echo $?)"
    rm -rf "$tmp"
}

# N1-293 (D7): final session is a bg n1-run in the worktree; queue settings + N1_HOME, no story env even when the
# caller has it; the prompt names --draft only for a draft and forbids merging.
test_final_cmd() {
    local tmp cmd s=n1-q-S-1-final-1; tmp=$(mktemp -d)
    mk_bg "$tmp" q "T-A:done"; mkdir -p "$tmp/wt"
    cmd=$(N1_STORY_ID=S-1 N1_STORY_BRANCH=story/S-1 n1_queue_final_cmd "$tmp/wt" /h RUN1 "$s" S-1 develop /q/final-1.body.md 1)
    FAKE_DIR="$tmp/fake" FAKE_N1H="$tmp/n1home" PATH="$tmp/bin:$PATH" bash -c "$cmd" >/dev/null 2>&1
    assert_eq "final_cmd: cwd is the worktree" "$tmp/wt" "$(cat "$tmp/fake/cwd.$s")"
    assert_eq "final_cmd: settings N1_HOME, run id, headless" "/h,RUN1,1" \
        "$(jq -r '[.env.N1_HOME,.env.N1_QUEUE_RUN_ID,.env.N1_HEADLESS]|join(",")' "$tmp/fake/settings.$s")"
    assert_eq "final_cmd: no story env" 0 "$(jq '[.env|keys[]|select(startswith("N1_STORY"))]|length' "$tmp/fake/settings.$s")"
    assert_eq "final_cmd: n1-run, ends with the story id" "yes,yes" \
        "$(grep -q '^/n1:n1-run ' "$tmp/fake/prompt.$s" && echo yes || echo no),$(grep -q 'Story: S-1$' "$tmp/fake/prompt.$s" && echo yes || echo no)"
    assert_eq "final_cmd: exact push and create" yes \
        "$(grep -qF 'git push origin HEAD:refs/heads/story/S-1' "$tmp/fake/prompt.$s" \
            && grep -qF 'gh pr create --head story/S-1 --base develop' "$tmp/fake/prompt.$s" \
            && grep -qF -- '--body-file /q/final-1.body.md --draft' "$tmp/fake/prompt.$s" && echo yes || echo no)"
    assert_eq "final_cmd: forbids merging" yes "$(grep -qF 'no merge' "$tmp/fake/prompt.$s" && echo yes || echo no)"
    # The PostToolUse/Stop hooks (pr-review-observe.sh, pr-review-stop.sh) ask a session that ran gh pr create for one
    # n1-pr step 3 continuation; the prompt tells the final session to decline it instead of running a Codex review.
    assert_eq "final_cmd: declines the Codex-review continuation" yes "$(grep -qF 'not Codex-reviewed by design' "$tmp/fake/prompt.$s" && echo yes || echo no)"
    cmd=$(n1_queue_final_cmd "$tmp/wt" /h RUN1 n1-q-S-1-final-2 S-1 main /q/b.md 0)
    FAKE_DIR="$tmp/fake" FAKE_N1H="$tmp/n1home" PATH="$tmp/bin:$PATH" bash -c "$cmd" >/dev/null 2>&1
    assert_eq "final_cmd: ready PR has no --draft" 0 "$(grep -cF -- '--draft' "$tmp/fake/prompt.n1-q-S-1-final-2" || true)"
    # N1-446: the default kind is story (identical command); an unknown kind is refused. Queue prompt wording is
    # asserted on the decoded prompt in test_queue_final_pr (tests/test_queue_runner_bg_chain.sh).
    assert_eq "final-cmd: explicit story kind equals the default" yes \
        "$([ "$(n1_queue_final_cmd "$tmp/wt" /h RUN1 n1-q-S-1-final-2 S-1 main /q/b.md 0)" = "$(n1_queue_final_cmd "$tmp/wt" /h RUN1 n1-q-S-1-final-2 S-1 main /q/b.md 0 story)" ] && echo yes || echo no)"
    assert_eq "final-cmd: unknown kind -> 1" 1 "$(n1_queue_final_cmd "$tmp/wt" /h RUN1 s S-1 main /q/b.md 0 release >/dev/null 2>&1; echo $?)"
    rm -rf "$tmp"
}

# N1-293 (D6): the final PR is re-derived from gh (one OPEN PR, head/base/repo checked); mergeable retries UNKNOWN, bounded.
test_final_gh_readers() {
    local tmp u=https://github.com/o/r/pull/9; tmp=$(mktemp -d)
    mk_bg "$tmp" q "T-A:done"
    fgh() { FAKE_DIR="$tmp/fake" PATH="$tmp/bin:$PATH" "$@"; }
    assert_eq "final find: no PR -> nothing" "" "$(fgh n1_queue_final_pr_find o/r story/S-1 main)"
    echo '[{"url":"https://github.com/o/r/pull/9","isDraft":true,"headRefName":"story/S-1","baseRefName":"main","isCrossRepository":false,"headRepositoryOwner":{"login":"o"}}]' > "$tmp/fake/gh-final-list.main"
    assert_eq "final find: one open PR" $'https://github.com/o/r/pull/9\ttrue' "$(fgh n1_queue_final_pr_find o/r story/S-1 main)"
    assert_eq "final find: query names repo, head, base, open" yes \
        "$(grep -qF 'pr list --repo o/r --head story/S-1 --base main --state open' "$tmp/fake/gh-final-calls" && echo yes || echo no)"
    assert_eq "final find: URL of another repo rejected" "" "$(fgh n1_queue_final_pr_find o/x story/S-1 main)"
    assert_eq "final find: invalid repo slug" "" "$(fgh n1_queue_final_pr_find 'o/r --x' story/S-1 main)"
    echo '[{"url":"https://github.com/o/r/pull/9","isDraft":false,"headRefName":"story/S-2","baseRefName":"main","isCrossRepository":false,"headRepositoryOwner":{"login":"o"}}]' > "$tmp/fake/gh-final-list.main"
    assert_eq "final find: other head rejected" "" "$(fgh n1_queue_final_pr_find o/r story/S-1 main)"
    echo '[{"url":"https://github.com/o/r/pull/9","isDraft":false,"headRefName":"story/S-1","baseRefName":"main","isCrossRepository":false,"headRepositoryOwner":{"login":"o"}},{"url":"https://github.com/o/r/pull/10","isDraft":false,"headRefName":"story/S-1","baseRefName":"main","isCrossRepository":false,"headRepositoryOwner":{"login":"o"}}]' > "$tmp/fake/gh-final-list.main"
    assert_eq "final find: two PRs rejected" "" "$(fgh n1_queue_final_pr_find o/r story/S-1 main)"
    echo '[{"url":"https://github.com/o/r/pull/9","isDraft":false,"headRefName":"story/S-1","baseRefName":"main","isCrossRepository":true,"headRepositoryOwner":{"login":"evil"}}]' > "$tmp/fake/gh-final-list.main"
    assert_eq "final find: fork PR rejected" "" "$(fgh n1_queue_final_pr_find o/r story/S-1 main)"
    echo '[{"url":"https://github.com/o/r/pull/8","isDraft":false,"headRefName":"story/S-1","baseRefName":"main","isCrossRepository":true,"headRepositoryOwner":{"login":"evil"}},{"url":"https://github.com/o/r/pull/9","isDraft":true,"headRefName":"story/S-1","baseRefName":"main","isCrossRepository":false,"headRepositoryOwner":{"login":"o"}}]' > "$tmp/fake/gh-final-list.main"
    assert_eq "final find: a fork PR does not hide the real one" $'https://github.com/o/r/pull/9\ttrue' "$(fgh n1_queue_final_pr_find o/r story/S-1 main)"
    echo '[{"url":"https://github.com/o/r/pull/9","isDraft":false,"headRefName":"story/S-1","baseRefName":"main","isCrossRepository":false,"headRepositoryOwner":{"login":"o"}}]' > "$tmp/fake/gh-final-list.main"
    assert_eq "valid_branch: plain names" "0,0" "$(_n1_queue_valid_branch main; echo -n $?),$(_n1_queue_valid_branch release/1.2; echo $?)"
    assert_eq "valid_branch: injection, option, dotdot, empty rejected" "1,1,1,1,1" \
        "$(_n1_queue_valid_branch 'main; curl x|sh'; echo -n $?),$(_n1_queue_valid_branch -x; echo -n $?),$(_n1_queue_valid_branch 'a..b'; echo -n $?),$(_n1_queue_valid_branch ''; echo -n $?),$(_n1_queue_valid_branch 'a b'; echo $?)"
    assert_eq "final find: invalid default branch" "" "$(fgh n1_queue_final_pr_find o/r story/S-1 'main; x')"
    printf 'UNKNOWN\t\nUNKNOWN\t\nMERGEABLE\tCLEAN\n' > "$tmp/fake/gh-mergeable-seq"
    assert_eq "mergeable: UNKNOWN retried until computed" $'MERGEABLE\tCLEAN' "$(fgh n1_queue_pr_mergeable "$u")"
    printf 'UNKNOWN\t\n' > "$tmp/fake/gh-mergeable-seq"; : > "$tmp/fake/gh-mergeable-calls"
    assert_eq "mergeable: bounded, last UNKNOWN kept" $'UNKNOWN\t' "$(fgh n1_queue_pr_mergeable "$u")"
    assert_eq "mergeable: 4 reads at most" 4 "$(nlines "$tmp/fake/gh-mergeable-calls")"
    rm -f "$tmp/fake/gh-mergeable-seq"
    assert_eq "mergeable: unreadable prints nothing" "" "$(fgh n1_queue_pr_mergeable "$u")"
    assert_eq "mergeable: non-PR URL prints nothing" "" "$(fgh n1_queue_pr_mergeable https://evil.example/x)"
    rm -rf "$tmp"
}

# N1-293: --status and the story summary read ## Final PRs; docs name the human-merge policy and both events.
test_final_pr_wiring() {
    local r="$REPO_ROOT/skills/n1-queue/steps/report.md" a="$REPO_ROOT/references/architecture.md" u="$REPO_ROOT/skills/n1-queue/steps/run.md"
    assert_eq "final wiring: --status prints Final PRs" yes "$(grep -qF 'Final PRs (repo, PR, draft, mergeable, note):' "$r" && echo yes || echo no)"
    assert_eq "final wiring: summary reads Final PRs" yes "$(grep -qF 'FINAL=$(n1_queue_final_prs "$QUEUE_FILE" "$(dirname "$QUEUE_FILE")/events.jsonl" "$RUN_ID")' "$r" && echo yes || echo no)"
    assert_eq "final wiring: final lines above per-child lines" yes "$(grep -qF 'above the per-child lines' "$r" && echo yes || echo no)"
    assert_eq "final wiring: halted summary lists merged children" yes "$(grep -qF 'merged into `story/<STORY_ID>`' "$r" && echo yes || echo no)"
    assert_eq "final wiring: events documented" yes "$(grep -qF '`final_pr_opened`' "$a" && grep -qF '`final_pr_failed`' "$a" && echo yes || echo no)"
    assert_eq "final wiring: gated merge policy in run step" yes "$(grep -qF 'The runner merges the final PR only when' "$u" && echo yes || echo no)"
    assert_eq "final wiring: gated merge policy in architecture" yes "$(grep -qF 'The runner merges the final PR only when' "$a" && echo yes || echo no)"
    assert_eq "final wiring: no never-merge text left" no "$(grep -qF 'never merges the final PR' "$u" "$a" && echo yes || echo no)"
    assert_eq "final wiring: merge event documented" yes "$(grep -qF '`final_pr_merge`' "$a" && echo yes || echo no)"
    assert_eq "final wiring: summary says merged or waits" yes \
        "$(grep -qF 'waits for a human (<reason>)' "$r" && grep -qF 'Final PR merge: by the runner' "$r" && echo yes || echo no)"
}

# N1-446: every integration-branch gate in the runner keys on a non-empty RUN_MODE; none is story-only any more
# (story_env, branch block, Orca CR-2 record, Orca MERGE wait, Orca resume re-evaluation, final_prs tail).
test_queue_integration_wiring() {
    local r="$REPO_ROOT/scripts/n1-queue-run.sh"
    assert_eq "queue-wiring: no story-only RUN_MODE gate" 0 "$(grep -c '\[ "\$RUN_MODE" = story \]' "$r" || true)"
    assert_eq "queue-wiring: six RUN_MODE integration gates" 6 "$(grep -c '\[ -n "\$RUN_MODE" \]' "$r" || true)"
    assert_eq "queue-wiring: final_pr passes the kind to body and cmd" 2 "$(grep -c '"\$body" "\$draft" "\$RUN_MODE")\|"\$SBID" "\$body" "\$RUN_MODE")' "$r" || true)"
    assert_eq "queue-wiring: n1-finish close step skips queue/ heads" yes \
        "$(grep -qF 'starts with `queue/`' "$REPO_ROOT/skills/n1-finish/steps/04-close-ticket.md" && echo yes || echo no)"
    assert_eq "queue-wiring: n1-pr bump skip names queue children" yes \
        "$(grep -qF 'Story child or queue child' "$REPO_ROOT/skills/n1-pr/steps/01-prepare.md" && echo yes || echo no)"
    assert_eq "queue-wiring: run.md documents the queue integration branch" yes \
        "$(grep -qF '**Queue integration branch (N1-446).**' "$REPO_ROOT/skills/n1-queue/steps/run.md" && echo yes || echo no)"
    assert_eq "queue-wiring: architecture documents it" yes \
        "$(grep -qF 'Queue integration branch (N1-446)' "$REPO_ROOT/references/architecture.md" && echo yes || echo no)"
}

test_n1_339_cleanup_helpers
test_pr_view
test_checks_class
test_sync_story
test_sync_queue_branch
test_done_cmd
test_final_pr_table
test_final_body
test_final_cmd
test_final_gh_readers
test_final_pr_wiring
test_queue_integration_wiring

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

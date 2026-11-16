#!/usr/bin/env bash
# Tests for scripts/n1-queue-run.sh: story and queue final PR (open, reuse, draft/predecessor, gates, merge) on the bg backend.
# Shared setup and fixtures: tests/queue_runner_lib.sh (N1-304 split; moved out of _bg_chain.sh in N1-621).
set -euo pipefail
source "$(dirname "$0")/queue_runner_lib.sh"

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

# N1-447 Codex: corrupt predecessor metadata (a row with an invalid cell) is not "no predecessor": the final PR stays a draft.
test_queue_final_invalid_predecessor() {
    local tmp s="n1-sq-${QB#queue/}-final-1"; tmp=$(mktemp -d)
    queue_merge_fixture "$tmp" "T-A:working done"
    touch "$tmp/fake/final-create"; printf 'UNKNOWN\t\nMERGEABLE\tCLEAN\n' > "$tmp/fake/gh-mergeable-seq"
    n1_queue_pred_set "$tmp/queue.md" "$tmp/repo" "$QC_ID" "$QC_P" https://github.com/o/r/pull/5 "$SM_PIN" "$SM_PIN" waiting
    sed -i "s/| waiting |/| not-a-status |/" "$tmp/queue.md"
    run_bg_queue "$tmp" >/dev/null
    assert_eq "pred-invalid: final PR opened as a draft" yes "$(grep -qF -- '--draft' "$tmp/fake/prompt.$s" && echo yes || echo no)"
    assert_eq "pred-invalid: Note says why" 1 "$(fin_row "$tmp" "$tmp/repo" | grep -cF 'predecessor metadata invalid')"
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
    assert_eq "final-merge: no n1-finish session for a story final PR (N1-462)" 0 "$(count_x "$tmp/fake/events" 'launch n1-sq-final-9-fin')"
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

# N1-462 AC: with fullAuto + mergeOnFinish the runner merges a queue final PR, then launches `n1-finish <PR#> chained`
# for it and waits; the Note carries the finish outcome after the merged prefix.
test_queue_final_merge_launches_finish() {
    local tmp url=https://github.com/o/r/pull/9; tmp=$(mktemp -d)
    queue_final_merge_fixture "$tmp" "T-A:working done"
    printf 'MERGED\t%s\t%s\n' "$QB" "$SM_PIN" > "$tmp/fake/gh-view.1"   # the child landed in the queue branch
    assert_eq "queue-final-finish: exit 0" 0 "$(run_fm "$tmp")"
    assert_eq "queue-final-finish: merged" 1 "$(fm_merges "$tmp" 9)"
    assert_eq "queue-final-finish: one finish session" 1 "$(count_x "$tmp/fake/events" 'launch n1-sq-final-9-fin')"
    assert_eq "queue-final-finish: finish runs for the PR number, chained" yes \
        "$(grep -qF '9 chained' "$tmp/fake/prompt.n1-sq-final-9-fin" && echo yes || echo no)"
    assert_eq "queue-final-finish: landed child not yet closed" "merged; finish: closed 0/1" "$(fin_note "$tmp")"
    rm -rf "$tmp"
    # the finish session closes the child: its overview ## Finish names the final PR
    tmp=$(mktemp -d); queue_final_merge_fixture "$tmp" "T-A:working done"
    printf 'MERGED\t%s\t%s\n' "$QB" "$SM_PIN" > "$tmp/fake/gh-view.1"; echo "$url" > "$tmp/fake/fin-closes.9.T-A"
    run_fm "$tmp" >/dev/null
    assert_eq "queue-final-finish: finish closed the child" "merged; finish: closed 1/1" "$(fin_note "$tmp")"
    rm -rf "$tmp"
    # a refused launch is recorded with the resume hint; the merge still counts
    tmp=$(mktemp -d); queue_final_merge_fixture "$tmp" "T-A:working done"; touch "$tmp/fake/refuse-fin"
    run_fm "$tmp" >/dev/null
    assert_eq "queue-final-finish: launch failure keeps the merge and names the resume" "1,merged; finish: launch-failed (run /n1:n1-finish 9)" \
        "$(fm_merges "$tmp" 9),$(fin_note "$tmp")"
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

n1_only_filter
test_queue_final_pr
test_queue_final_waits_predecessor
test_queue_final_invalid_predecessor
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
test_queue_final_merge_launches_finish
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

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

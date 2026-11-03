#!/usr/bin/env bash
# Tests for lib/queue.sh and scripts/n1-queue-run.sh: parsing, plan/status/report, decisions, desc-hash chain, wiring greps, notify, held helpers.
# Shared setup and fixtures: tests/queue_runner_lib.sh (N1-304 split).
set -euo pipefail
source "$(dirname "$0")/queue_runner_lib.sh"

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

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
EOF
    assert_eq "release-rows: pr/escalated/failed not yet released, deduped" \
        "$(printf 'T-1\t%s/h,T-3\t%s/h' "$tmp" "$tmp")" \
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
    local rc=0; ( PATH="$tmp/bin"; n1_desktop_notify "Title" "Body" ) || rc=$?
    assert_eq "desktop: falls through broken backend" "0" "$rc"
    assert_eq "desktop: osascript used" "yes" "$([ -f "$tmp/osa" ] && echo yes || echo no)"
    rm -f "$tmp/bin/notify-send" "$tmp/bin/osascript"
    rc=0; ( PATH="$tmp/bin"; n1_desktop_notify "Title" "Body" ) || rc=$?
    assert_eq "desktop: none available -> 1" "1" "$rc"
    printf '#!/bin/sh\necho "$N1_NT|$N1_NB" > "%s/ps"\n' "$tmp" > "$tmp/ps.exe"; chmod +x "$tmp/ps.exe"
    rc=0; ( PATH="$tmp/bin"; N1_WSL_POWERSHELL="$tmp/ps.exe" n1_desktop_notify "Title" "Body" ) || rc=$?
    assert_eq "desktop: WSL powershell off PATH used" "0|Title|Body" "$rc|$(cat "$tmp/ps" 2>/dev/null)"
}

test_desktop_notify_stdin() {   # N1-265: no desktop backend may consume the caller's stdin (WSL powershell.exe drains it)
    local tmp b out; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/bin"; ln -s "$(command -v timeout)" "$tmp/bin/timeout"
    printf '#!/bin/sh\nwhile read -r _; do :; done\nexit 0\n' > "$tmp/drain"; chmod +x "$tmp/drain"
    for b in notify-send osascript; do
        rm -f "$tmp/bin/notify-send" "$tmp/bin/osascript"; cp "$tmp/drain" "$tmp/bin/$b"
        out=$(printf 'a\nb\nc\n' | { read -r _; ( PATH="$tmp/bin"; n1_desktop_notify T B ); cat; } | paste -sd, -)
        assert_eq "desktop-stdin: $b leaves caller stdin alone" "b,c" "$out"
    done
    rm -f "$tmp/bin/notify-send" "$tmp/bin/osascript"
    out=$(printf 'a\nb\nc\n' | { read -r _; ( PATH="$tmp/bin"; N1_WSL_POWERSHELL="$tmp/drain" n1_desktop_notify T B ); cat; } | paste -sd, -)
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
    rc=0; ( PATH="$tmp/bin"; n1_notify needs-you "T-2 needs you" ) 2> "$tmp/err" || rc=$?
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
    assert_eq "status: cost always em dash" "4" "$(echo "$out" | awk -F'\t' '$5=="\xe2\x80\x94"' | wc -l | tr -d ' ')"
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

    git -C "$tmp/repo" remote set-url origin "$tmp/no-such-origin"; mkq
    assert_eq "user-merge: sync failure -> both still wait" "2" "$(PATH="$P" n1_queue_held_sweep "$tmp/q.md" 2>/dev/null)"
    assert_eq "user-merge: sync failure -> T-2 held" "held" "$(plan_cell "$tmp/q.md" 2 8)"
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
    local recipe; recipe=$(awk 'index($0,"## Intake check")==1{f=1;next} f&&/^```bash/{b=1;next} b&&/^```/{exit} b' "$REPO_ROOT/references/desc-hash-chain.md" | { grep -v '^source ' || true; } | sed 's/<ID>/T-7/g')
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

    local h="$REPO_ROOT/skills/n1-start/procedures/autonomy-headless.md" guard_clear_before guard_hash guard_clear_after
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
    assert_eq "plan-wiring: queue steps never write overview.md" "no" \
        "$(cat "$s/steps/intake.md" "$s/steps/preview.md" "$s/steps/run.md" | grep -qE 'n1_write_frontmatter[^|]*overview' && echo yes || echo no)"
    assert_eq "plan-wiring: staleness re-plan re-orders every pending row (CR-1)" "yes" "$(has 'Re-run overlap order globally' "$s/steps/run.md")"
    assert_eq "plan-wiring: staleness recheck uses the sha256 hash helper, not cksum" "yes" "$(has 'n1_queue_content_hash' "$s/steps/run.md")"
    assert_eq "plan-wiring: run.md no longer pipes through cksum" "no" "$(has 'cksum <' "$s/steps/run.md")"
    assert_eq "plan-wiring: preview snapshot uses the sha256 hash helper, not cksum" "yes" "$(has 'n1_queue_content_hash' "$s/steps/preview.md")"
    assert_eq "plan-wiring: preview.md no longer pipes through cksum" "no" "$(has 'cksum <' "$s/steps/preview.md")"
    assert_eq "plan-wiring: intake validates ticket keys before path use (SEC-L4)" "yes" "$(has '\^\[A-Z\]\[A-Z0-9_\]\*-\[0-9\]\+\$' "$s/steps/intake.md")"

    # SEC-1: a ticket title is written to a file, never interpolated into a shell string.
    assert_eq "plan-wiring: preview writes the title to a file before hashing" "yes" "$(has '\.title.*file-write mechanism|file-write mechanism.*\.title' "$s/steps/preview.md")"
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

# N1-55: ask-mode child mirrors its question and accepts a relayed answer; n1-queue exposes --answer.
test_answer_wiring() {
    local h="$REPO_ROOT/skills/n1-start/procedures/autonomy-headless.md"
    local s="$REPO_ROOT/skills/n1-queue/SKILL.md" r="$REPO_ROOT/skills/n1-queue/steps/report.md"
    assert_eq "answer-wiring: child writes question file" "yes" "$(grep -qF '.question-%s.json' "$h" && echo yes || echo no)"
    assert_eq "answer-wiring: child removes question file on answer" "yes" "$(grep -qF 'rm -f "$N1_QUEUE_DIR/.question-$ID.json"' "$h" && echo yes || echo no)"
    assert_eq "answer-wiring: child accepts relayed answer" "yes" "$(grep -qF '[n1-queue answer] ' "$h" && echo yes || echo no)"
    assert_eq "answer-wiring: SKILL documents --answer" "yes" "$(grep -qF -- '--answer <ticket> <text>' "$s" && echo yes || echo no)"
    assert_eq "answer-wiring: report calls n1_queue_answer" "yes" "$(grep -qF 'n1_queue_answer "$N1_HOME"' "$r" && echo yes || echo no)"
    assert_eq "answer-wiring: question schema carries rationale (RULE-1)" "yes" "$(grep -qF '"recommended","rationale"}' "$h" && grep -qF 'No recommendation. The options are equivalent given the available evidence; select based on team preference.' "$h" && echo yes || echo no)"
    assert_eq "answer-wiring: per-ticket answer file cleared before write" "yes" "$(grep -qF 'AF="$N1_HOME/queue/.answer-<ticket>.txt"; rm -f "$AF"' "$r" && echo yes || echo no)"
    assert_eq "answer-wiring: answer written via file-write mechanism" "yes" "$(grep -qF 'file-write mechanism' "$r" && echo yes || echo no)"
}

# NP-203: queue children apply plan-time pre-decisions; release gate never consults them.
test_headless_plan_wiring() {
    local h="$REPO_ROOT/skills/n1-start/procedures/autonomy-headless.md" l="$REPO_ROOT/skills/n1-start/ledger.md"
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
}

test_parse_service
test_find_repo
test_pick_model
test_plan_wiring
test_child_status
test_child_status_deploy
test_held_helpers
test_held_user_merge
test_sync_default
test_row_status
test_write_plan_cells
test_pending_rows
test_decisions_and_stale
test_desc_hash_chain
test_refined_intake_check
test_title_vague
test_desc_chain_wiring
test_brief_wiring
test_form_repair_wiring
test_overlap_order
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
test_queue_answer
test_escalated_step_fallback
test_queue_event
test_escalation_text
test_desktop_notify
test_desktop_notify_stdin
test_notify_backends
test_answer_wiring
test_headless_plan_wiring

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

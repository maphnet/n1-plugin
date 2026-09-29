#!/usr/bin/env bash
# Tests for lib/queue.sh and scripts/n1-queue-run.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $label"; PASS=$((PASS+1))
    else
        echo "FAIL: $label (expected=[$expected] actual=[$actual])"; FAIL=$((FAIL+1))
    fi
}

plan_cell() { # <queue.md> <row#> <col: 8=Status 9=Reason>
    awk -F'|' -v n="$2" -v c="$3" '{ for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) } $2 == n && NF >= 9 { print $c }' "$1"
}

export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
: "${N1_HOME:=}"; : "${ID:=}"; export N1_HOME ID
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/lib/frontmatter.sh"
source "${REPO_ROOT}/lib/queue.sh"
source "${REPO_ROOT}/lib/validation.sh"

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
    out=$(unset N1_QUEUE_RELEASE_STUB; N1_HOST=codex n1_queue_release_cmd n1-auto /r /tmp/log)
    assert_eq "release_cmd: codex real command shape" "yes" \
        "$(case "$out" in *"codex exec"*'--status'*'n1-auto'*) echo yes ;; *) echo "no: $out" ;; esac)"
}

# --- n1_queue_child_status ---------------------------------------------------
test_child_status() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

    printf -- '---\nstep: pr\n---\n# T\n' > "$tmp/pr.md"
    printf -- '---\nstep: ci\n---\n# T\n' > "$tmp/ci.md"
    printf -- '---\nstep: done\n---\n# T\n' > "$tmp/done.md"
    printf -- '---\nstep: escalated\n---\n# T\n\n## Escalations\n- blocked\n' > "$tmp/esc.md"
    printf -- '---\nstep: qa\n---\n# T\n\n## Escalations\n- QA fail\n' > "$tmp/esc2.md"
    printf -- '---\nstep: implementation\n---\n# T\n' > "$tmp/mid.md"
    printf -- '---\nstep: done\n---\n# T\n\n## Escalations\n- [asked] resolved, continuing\n\npr_url: https://example.com/pr/1\n' > "$tmp/asked-done.md"

    assert_eq "qstatus: step pr -> pr" "pr" "$(n1_queue_child_status "$tmp/pr.md" 0)"
    assert_eq "qstatus: step ci -> pr" "pr" "$(n1_queue_child_status "$tmp/ci.md" 0)"
    assert_eq "qstatus: step done -> pr" "pr" "$(n1_queue_child_status "$tmp/done.md" 0)"
    assert_eq "qstatus: step escalated" "escalated" "$(n1_queue_child_status "$tmp/esc.md" 0)"
    assert_eq "qstatus: escalations section" "escalated" "$(n1_queue_child_status "$tmp/esc2.md" 0)"
    assert_eq "qstatus: mid-run exit 0 -> running" "running" "$(n1_queue_child_status "$tmp/mid.md" 0)"
    assert_eq "qstatus: mid-run exit 1 -> failed" "failed" "$(n1_queue_child_status "$tmp/mid.md" 1)"
    assert_eq "qstatus: missing file exit 1 -> failed" "failed" "$(n1_queue_child_status "$tmp/none.md" 1)"
    assert_eq "qstatus: missing file exit 0 -> running" "running" "$(n1_queue_child_status "$tmp/none.md" 0)"
    assert_eq "qstatus: ask-mode answered then done -> pr, not escalated" "pr" "$(n1_queue_child_status "$tmp/asked-done.md" 0)"

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

    local cc cx
    cc=$(unset N1_QUEUE_CHILD_STUB N1_STORY_PLUGIN_DIR; N1_HOST=claude-code n1_queue_child_cmd /r T-1 sonnet RUN1 /tmp/log n1-q-T-1-1)
    assert_eq "child_cmd: claude-code bg launch" "yes" "$(case "$cc" in "cd /r && claude --bg --name n1-q-T-1-1 --model sonnet --permission-mode bypassPermissions --settings "*bgIsolation*"/n1:n1-start\ T-1"*) echo yes ;; *) echo "no: $cc" ;; esac)"
    assert_eq "child_cmd: claude-code has N1_UNATTENDED=ask" "yes" \
        "$(case "$cc" in *'N1_UNATTENDED'*'ask'*) echo yes ;; *) echo no ;; esac)"
    cx=$(unset N1_QUEUE_CHILD_STUB; N1_HOST=codex n1_queue_child_cmd /r T-1 sonnet RUN1 /tmp/log)
    assert_eq "child_cmd: codex unchanged" "yes" "$(case "$cx" in *'N1_QUEUE_RUN_ID="RUN1"'*"codex exec"*) case "$cx" in *--bg*) echo no ;; *) echo yes ;; esac ;; *) echo "no: $cx" ;; esac)"
    assert_eq "child_cmd: codex has no N1_UNATTENDED" "no" "$(case "$cx" in *N1_UNATTENDED*) echo yes ;; *) echo no ;; esac)"

    cc=$(unset N1_QUEUE_CHILD_STUB N1_STORY_PLUGIN_DIR; N1_QUEUE_TAG=n1-auto N1_HOST=claude-code n1_queue_child_cmd /r T-1 sonnet RUN1 /tmp/log n1-q-T-1-1)
    assert_eq "child_cmd: claude-code forwards N1_QUEUE_TAG" "yes" \
        "$(case "$cc" in *'N1_QUEUE_TAG'*'n1-auto'*) echo yes ;; *) echo "no: $cc" ;; esac)"
    cx=$(unset N1_QUEUE_CHILD_STUB; N1_QUEUE_TAG=n1-auto N1_HOST=codex n1_queue_child_cmd /r T-1 sonnet RUN1 /tmp/log)
    assert_eq "child_cmd: codex forwards N1_QUEUE_TAG" "yes" \
        "$(case "$cx" in *'N1_QUEUE_TAG=n1-auto '*"codex exec"*) echo yes ;; *) echo "no: $cx" ;; esac)"
    cc=$(unset N1_QUEUE_CHILD_STUB N1_STORY_PLUGIN_DIR; N1_QUEUE_DIR=/q/dir N1_HOST=claude-code n1_queue_child_cmd /r T-1 sonnet RUN1 /tmp/log n1-q-T-1-1)
    assert_eq "child_cmd: claude-code forwards N1_QUEUE_DIR" "yes" \
        "$(case "$cc" in *'N1_QUEUE_DIR'*'/q/dir'*) echo yes ;; *) echo "no: $cc" ;; esac)"
    cx=$(unset N1_QUEUE_CHILD_STUB; N1_QUEUE_DIR=/q/dir N1_HOST=codex n1_queue_child_cmd /r T-1 sonnet RUN1 /tmp/log)
    assert_eq "child_cmd: codex forwards N1_QUEUE_DIR" "yes" \
        "$(case "$cx" in *'N1_QUEUE_DIR=/q/dir '*"codex exec"*) echo yes ;; *) echo "no: $cx" ;; esac)"

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

# --- Integration: runner -----------------------------------------------------
test_runner_three_strikes() {
    local tmp; tmp=$(mktemp -d)
    # trap 'rm -rf "$tmp"' RETURN  # keep for debugging on failure

    # Stub script: T-A -> pr, T-B -> escalated, T-C -> exit 124 (timeout, no overview)
    cat > "$tmp/stub.sh" <<'STUBEOF'
#!/usr/bin/env bash
TICKET="$1"
case "$TICKET" in
    T-A)
        mkdir -p "$(dirname "$N1_QUEUE_OVERVIEW")"
        printf -- '---\nstep: pr\n---\n# T\n\n## Pending\nawaiting: merge\npr_url: https://x/pr/99\n' > "$N1_QUEUE_OVERVIEW"
        exit 0 ;;
    T-B)
        mkdir -p "$(dirname "$N1_QUEUE_OVERVIEW")"
        printf -- '---\nstep: escalated\n---\n# T\n\n## Escalations\n- blocked\n' > "$N1_QUEUE_OVERVIEW"
        exit 0 ;;
    T-C) exit 124 ;;
esac
STUBEOF
    chmod +x "$tmp/stub.sh"

    # Wrapper that sets N1_QUEUE_OVERVIEW for the stub
    cat > "$tmp/wrapper.sh" <<WEOF
#!/usr/bin/env bash
TICKET="\$1"
export N1_QUEUE_OVERVIEW="$tmp/n1home/memory/\$TICKET/overview.md"
exec "$tmp/stub.sh" "\$TICKET"
WEOF
    chmod +x "$tmp/wrapper.sh"

    mkdir -p "$tmp/n1home/memory"
    printf '{"queue":{"notify":"command","notifyCommand":"cat >> %s/notes"}}\n' "$tmp" > "$tmp/n1home/config.json"

    cat > "$tmp/queue.md" <<'EOF'
---
step: plan
queue_id: test-q
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-A | Fix A | /repo | N1HOME_PLACEHOLDER | sonnet | pending | |
| 2 | T-B | Fix B | /repo | N1HOME_PLACEHOLDER | sonnet | pending | |
| 3 | T-C | Fix C | /repo | N1HOME_PLACEHOLDER | sonnet | pending | |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
EOF
    sed -i "s|N1HOME_PLACEHOLDER|$tmp/n1home|g" "$tmp/queue.md"

    export N1_QUEUE_CHILD_STUB="$tmp/wrapper.sh"
    export N1_HOME="$tmp/n1home"

    local exit_code=0
    bash "$REPO_ROOT/scripts/n1-queue-run.sh" "$tmp/queue.md" > "$tmp/output.txt" 2>&1 || exit_code=$?

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
    assert_eq "events-3s: uniform schema" "true" "$(jq -s 'all(keys | length == 10)' "$tmp/events.jsonl")"
    assert_eq "notify-3s: needs-you (esc), info (final fail), needs-you (halt); none for pr/deferred" \
        "needs-you,info,needs-you" "$(jq -r .kind "$tmp/notes" | paste -sd, -)"
    assert_eq "notify-3s: halt text" "yes" \
        "$(jq -r 'select(.kind=="needs-you") | .text' "$tmp/notes" | grep -q '^Queue test-q halted: ' && echo yes || echo no)"

    unset N1_QUEUE_CHILD_STUB
    rm -rf "$tmp"
}

test_runner_all_pr() {
    local tmp; tmp=$(mktemp -d)

    cat > "$tmp/stub.sh" <<'STUBEOF'
#!/usr/bin/env bash
TICKET="$1"
sleep 1
mkdir -p "$(dirname "$N1_QUEUE_OVERVIEW")"
printf -- '---\nstep: pr\n---\n# T\n\n## Pending\nawaiting: merge\npr_url: https://x/pr/42\n' > "$N1_QUEUE_OVERVIEW"
exit 0
STUBEOF
    chmod +x "$tmp/stub.sh"

    cat > "$tmp/wrapper.sh" <<WEOF
#!/usr/bin/env bash
TICKET="\$1"
export N1_QUEUE_OVERVIEW="$tmp/n1home/memory/\$TICKET/overview.md"
exec "$tmp/stub.sh" "\$TICKET"
WEOF
    chmod +x "$tmp/wrapper.sh"

    mkdir -p "$tmp/n1home/memory"
    printf '{"queue":{"notify":"command","notifyCommand":"cat >> %s/notes"}}\n' "$tmp" > "$tmp/n1home/config.json"

    cat > "$tmp/queue.md" <<'EOF'
---
step: plan
queue_id: test-q2
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-X | Do X | /repo | N1HOME_PLACEHOLDER | sonnet | pending | |
| 2 | T-Y | Do Y | /repo | N1HOME_PLACEHOLDER | sonnet | pending | |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
EOF
    sed -i "s|N1HOME_PLACEHOLDER|$tmp/n1home|g" "$tmp/queue.md"

    export N1_QUEUE_CHILD_STUB="$tmp/wrapper.sh"
    export N1_HOME="$tmp/n1home"

    local exit_code=0
    bash "$REPO_ROOT/scripts/n1-queue-run.sh" "$tmp/queue.md" > "$tmp/output.txt" 2>&1 || exit_code=$?

    assert_eq "runner-allpr: exit 0" "0" "$exit_code"

    local step; step=$(n1_read_frontmatter "$tmp/queue.md" step)
    assert_eq "runner-allpr: step done" "done" "$step"

    # pid should be removed
    local pid; pid=$(n1_read_frontmatter "$tmp/queue.md" pid)
    assert_eq "runner-allpr: pid removed" "" "$pid"

    assert_eq "events-allpr: sequence" "queue_started,ticket_started,ticket_finished,ticket_started,ticket_finished,queue_done" \
        "$(jq -r .event "$tmp/events.jsonl" | paste -sd, -)"
    assert_eq "events-allpr: pr url" "https://x/pr/42" \
        "$(jq -r 'select(.event=="ticket_finished") | .pr' "$tmp/events.jsonl" | head -1)"
    assert_eq "events-allpr: runner wall-clock duration >= 1s" "true" \
        "$(jq -s '[.[] | select(.event=="ticket_finished") | .duration_s >= 1] | all' "$tmp/events.jsonl")"
    assert_eq "events-allpr: queue_done digest" "2 PR / 0 awaiting / 0 failed" \
        "$(jq -r 'select(.event=="queue_done") | .reason' "$tmp/events.jsonl")"
    assert_eq "notify-allpr: exactly one done, no per-PR notify" "done|Queue test-q2: 2 PR / 0 awaiting / 0 failed" \
        "$(jq -r '.kind + "|" + .text' "$tmp/notes" | paste -sd, -)"

    unset N1_QUEUE_CHILD_STUB
    rm -rf "$tmp"
}

# NP-199: tag mode forwards N1_QUEUE_TAG, a re-queued ticket's release flag is reset at
# launch, and finalize stamps queue_run_id into overview.md.
test_runner_tag_release() {
    local tmp; tmp=$(mktemp -d)

    cat > "$tmp/stub.sh" <<'STUBEOF'
#!/usr/bin/env bash
TICKET="$1"
printf '%s\n' "${N1_QUEUE_TAG:-}" > "$N1_QUEUE_SEEN.tag.$TICKET"
printf '%s\n' "${N1_QUEUE_DIR:-}" > "$N1_QUEUE_SEEN.dir.$TICKET"
grep '^queue_tag_removed:' "$N1_QUEUE_OVERVIEW" > "$N1_QUEUE_SEEN.flag.$TICKET" 2>/dev/null || true
mkdir -p "$(dirname "$N1_QUEUE_OVERVIEW")"
printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/7\n' > "$N1_QUEUE_OVERVIEW"
exit 0
STUBEOF
    chmod +x "$tmp/stub.sh"

    cat > "$tmp/wrapper.sh" <<WEOF
#!/usr/bin/env bash
TICKET="\$1"
export N1_QUEUE_OVERVIEW="$tmp/n1home/memory/\$TICKET/overview.md"
export N1_QUEUE_SEEN="$tmp/seen"
exec "$tmp/stub.sh" "\$TICKET"
WEOF
    chmod +x "$tmp/wrapper.sh"

    mkdir -p "$tmp/n1home/memory/T-R"
    printf -- '---\nstep: pr\nqueue_run_id: OLD\nqueue_tag_removed: true\n---\n' > "$tmp/n1home/memory/T-R/overview.md"
    printf '{"queue":{"notify":"command","notifyCommand":"cat >> %s/notes"}}\n' "$tmp" > "$tmp/n1home/config.json"

    cat > "$tmp/queue.md" <<EOF
---
step: plan
queue_id: n1-auto
mode: tag
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-R | Re-queued | /repo | $tmp/n1home | sonnet | pending | |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
EOF

    export N1_QUEUE_CHILD_STUB="$tmp/wrapper.sh"
    export N1_HOME="$tmp/n1home"
    # CCR fix: this fixture's stub leaves queue_tag_removed unset (it isn't testing
    # release wiring), so the T-R "pr" row would otherwise trip the real automatic
    # tag-release backstop added below. Stub it to a no-op, same as N1_QUEUE_CHILD_STUB.
    export N1_QUEUE_RELEASE_STUB=/bin/true
    local exit_code=0
    bash "$REPO_ROOT/scripts/n1-queue-run.sh" "$tmp/queue.md" > "$tmp/output.txt" 2>&1 || exit_code=$?

    assert_eq "tag-release: exit 0" "0" "$exit_code"
    assert_eq "tag-release: child sees N1_QUEUE_TAG" "n1-auto" "$(cat "$tmp/seen.tag.T-R")"
    assert_eq "queue-dir: child sees absolute N1_QUEUE_DIR" "$(cd "$tmp" && pwd)" "$(cat "$tmp/seen.dir.T-R")"
    assert_eq "tag-release: flag reset before child starts" "queue_tag_removed: false" "$(cat "$tmp/seen.flag.T-R")"
    assert_eq "tag-release: finalize stamps queue_run_id" \
        "$(n1_read_frontmatter "$tmp/queue.md" run_id)" \
        "$(n1_read_frontmatter "$tmp/n1home/memory/T-R/overview.md" queue_run_id)"

    unset N1_QUEUE_CHILD_STUB N1_QUEUE_RELEASE_STUB
    rm -rf "$tmp"
}

# NP-199 (CCR fix): report.md's release wiring only runs on --status/--watch. Without
# an automatic backstop, a failed tag-mode ticket's tag would stay attached until a
# human happens to check. The runner must fire the backstop itself when the run ends.
test_runner_auto_release_backstop() {
    local tmp; tmp=$(mktemp -d)
    cat > "$tmp/stub.sh" <<'STUBEOF'
#!/usr/bin/env bash
mkdir -p "$(dirname "$N1_QUEUE_OVERVIEW")"
printf -- '---\nstep: implement\n---\n# T\n' > "$N1_QUEUE_OVERVIEW"
exit 1
STUBEOF
    chmod +x "$tmp/stub.sh"
    cat > "$tmp/wrapper.sh" <<WEOF
#!/usr/bin/env bash
TICKET="\$1"
export N1_QUEUE_OVERVIEW="$tmp/n1home/memory/\$TICKET/overview.md"
exec "$tmp/stub.sh" "\$TICKET"
WEOF
    chmod +x "$tmp/wrapper.sh"
    mkdir -p "$tmp/n1home/memory/T-F"
    cat > "$tmp/queue.md" <<EOF
---
step: plan
queue_id: n1-auto
mode: tag
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-F | Fails | /repo | $tmp/n1home | sonnet | pending | |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
EOF
    cat > "$tmp/release-seen.sh" <<WEOF2
#!/usr/bin/env bash
printf '%s\n' "\$1" > "$tmp/release-called"
WEOF2
    chmod +x "$tmp/release-seen.sh"
    export N1_QUEUE_CHILD_STUB="$tmp/wrapper.sh"
    export N1_QUEUE_RELEASE_STUB="$tmp/release-seen.sh"
    export N1_HOME="$tmp/n1home"
    bash "$REPO_ROOT/scripts/n1-queue-run.sh" "$tmp/queue.md" >/dev/null 2>&1 || true

    assert_eq "auto-release: backstop fired for a failed tag-mode row" "n1-auto" \
        "$(cat "$tmp/release-called" 2>/dev/null || echo "not called")"

    unset N1_QUEUE_CHILD_STUB N1_QUEUE_RELEASE_STUB
    rm -rf "$tmp"
}

# NP-199 (CCR fix): halt() exits the process directly (exit 2), bypassing the normal
# "Done" tail — the backstop must also fire from inside halt() or a halted run's
# tickets never get released either.
test_runner_release_backstop_on_halt() {
    local tmp; tmp=$(mktemp -d)
    cat > "$tmp/stub.sh" <<'STUBEOF'
#!/usr/bin/env bash
mkdir -p "$(dirname "$N1_QUEUE_OVERVIEW")"
printf -- '---\nstep: escalated\n---\n# T\n\n## Escalations\n- blocked\n' > "$N1_QUEUE_OVERVIEW"
exit 0
STUBEOF
    chmod +x "$tmp/stub.sh"
    cat > "$tmp/wrapper.sh" <<WEOF
#!/usr/bin/env bash
TICKET="\$1"
export N1_QUEUE_OVERVIEW="$tmp/n1home/memory/\$TICKET/overview.md"
exec "$tmp/stub.sh"
WEOF
    chmod +x "$tmp/wrapper.sh"
    mkdir -p "$tmp/n1home/memory"
    printf '{"queue":{"notify":"none"}}\n' > "$tmp/n1home/config.json"
    cat > "$tmp/queue.md" <<EOF
---
step: plan
queue_id: n1-auto
mode: tag
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-1 | A | /repo | $tmp/n1home | sonnet | pending | |
| 2 | T-2 | B | /repo | $tmp/n1home | sonnet | pending | |
| 3 | T-3 | C | /repo | $tmp/n1home | sonnet | pending | |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
EOF
    cat > "$tmp/release-seen.sh" <<WEOF2
#!/usr/bin/env bash
printf '%s\n' "\$1" > "$tmp/release-called"
WEOF2
    chmod +x "$tmp/release-seen.sh"
    export N1_QUEUE_CHILD_STUB="$tmp/wrapper.sh"
    export N1_QUEUE_RELEASE_STUB="$tmp/release-seen.sh"
    export N1_HOME="$tmp/n1home"
    local exit_code=0
    bash "$REPO_ROOT/scripts/n1-queue-run.sh" "$tmp/queue.md" >/dev/null 2>&1 || exit_code=$?

    assert_eq "auto-release-halt: runner halted" "2" "$exit_code"
    assert_eq "auto-release-halt: backstop still fired" "n1-auto" \
        "$(cat "$tmp/release-called" 2>/dev/null || echo "not called")"

    unset N1_QUEUE_CHILD_STUB N1_QUEUE_RELEASE_STUB
    rm -rf "$tmp"
}

# Real (unstubbed) Codex path: host comes from queue.md frontmatter even though
# CLAUDE_PLUGIN_ROOT is exported (the runner forces it for path resolution).
test_runner_codex_host() {
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/bin" "$tmp/n1home/memory"
    echo '{"queue":{"notify":"none"}}' > "$tmp/n1home/config.json"
    cat > "$tmp/bin/codex" <<'EOF'
#!/usr/bin/env bash
for a; do last="$a"; done
t="${last##* }"
mkdir -p "$FAKE_N1H/memory/$t"
printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/7\n' > "$FAKE_N1H/memory/$t/overview.md"
EOF
    printf '#!/bin/sh\necho called >> "$FAKE_N1H/claude-called"\n' > "$tmp/bin/claude"
    chmod +x "$tmp/bin/codex" "$tmp/bin/claude"
    cat > "$tmp/queue.md" <<EOF
---
step: plan
queue_id: test-cx
host: codex
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-X | Do X | $tmp | $tmp/n1home | sonnet | pending | |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
EOF
    local rc=0
    env -u N1_QUEUE_CHILD_STUB FAKE_N1H="$tmp/n1home" N1_HOME="$tmp/n1home" PATH="$tmp/bin:$PATH" \
        bash "$REPO_ROOT/scripts/n1-queue-run.sh" "$tmp/queue.md" > "$tmp/output.txt" 2>&1 || rc=$?
    assert_eq "codex-host: exit 0" "0" "$rc"
    assert_eq "codex-host: T-X pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "codex-host: claude never called" "no" "$([ -f "$tmp/n1home/claude-called" ] && echo yes || echo no)"
    assert_eq "codex-host: Runs row exit/outcome/pr" "0|pr|https://x/pr/7" \
        "$(awk -F'|' '/^## Runs/{f=1;next} f && $2 ~ /T-X/ { for (i=4;i<=6;i++) gsub(/ /,"",$i); print $4 "|" $5 "|" $6 }' "$tmp/queue.md")"
    rm -rf "$tmp"
}

# --- Background-session (claude-code) runner path ----------------------------
# mk_bg <tmp> <queue-id> <ticket:states>... — queue.md (host: claude-code) plus a fake
# claude and a no-op sleep in <tmp>/bin. States are space-separated, one per poll of
# that session; the last state repeats. Timeout 1 min, poll 30 s -> 2 polls.
mk_bg() {
    local tmp="$1" qid="$2" n=0 spec t; shift 2
    mkdir -p "$tmp/bin" "$tmp/fake" "$tmp/n1home/memory"
    cat > "$tmp/bin/claude" <<'FAKEEOF'
#!/usr/bin/env bash
# Fake claude CLI for background-session tests. State lives in $FAKE_DIR.
D="$FAKE_DIR"
case "$1" in
    --bg)
        all="$*"; name=""; settings=""; prompt=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --name) name="$2"; shift ;;
                --settings) settings="$2"; shift ;;
                --model|--permission-mode|--plugin-dir) shift ;;
                --bg) ;;
                *) prompt="$1" ;;
            esac
            shift
        done
        echo "launch $name" >> "$D/events"
        printf '%s\n' "$all" > "$D/args.$name"
        printf '%s\n' "$settings" > "$D/settings.$name"
        if [ -f "$D/refuse" ]; then
            echo "Bypass Permissions mode requires accepting the disclaimer first. Run claude --dangerously-skip-permissions once."
            exit 1
        fi
        printf '%s\n' "$prompt" > "$D/prompt.$name"
        n=$(( $(cat "$D/seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$D/seq"
        printf '%08x' "$n" > "$D/id.$name"
        printf 'backgrounded \xc2\xb7 %08x \xc2\xb7 %s\n' "$n" "$name"
        ;;
    agents)
        out=""
        for f in "$D"/prompt.*; do
            [ -f "$f" ] || continue
            name="${f##*/prompt.}"; t=$(cat "$f"); t="${t##* }"
            c=$(( $(cat "$D/poll.$name" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$D/poll.$name"
            read -r -a seq < "$D/states.$t"
            i=$(( c < ${#seq[@]} ? c - 1 : ${#seq[@]} - 1 ))
            st="${seq[$i]}"
            echo "state $name $st" >> "$D/events"
            if [ "$st" = done ]; then
                mkdir -p "$FAKE_N1H/memory/$t"
                dp=""; [ -f "$D/deploy.$t" ] && dp=$'deploy_pending: true\n'
                # clear.<t>: an interactive n1-finish clears the flag after the first done poll.
                if [ -f "$D/clear.$t" ]; then
                    [ -f "$D/cleared.$t" ] && dp=$'deploy_pending: false\n'
                    touch "$D/cleared.$t"
                fi
                # finish-step.<ticket>: overrides the terminal step (default pr) so a test
                # can simulate a bg session reporting done while overview never reached a
                # terminal step (NP-216).
                step="pr"; [ -f "$D/finish-step.$t" ] && step=$(cat "$D/finish-step.$t")
                printf -- '---\nstep: %s\n%s---\n# T\n\n## Pending\npr_url: https://x/pr/1\n' "$step" "$dp" > "$FAKE_N1H/memory/$t/overview.md"
            fi
            sid=$(cat "$D/id.$name" 2>/dev/null || echo "00000000")
            out="$out${out:+,}{\"kind\":\"background\",\"id\":\"$sid\",\"sessionId\":\"$sid-0000-0000-0000-000000000000\",\"name\":\"$name\",\"state\":\"$st\",\"waitingFor\":null,\"pid\":1,\"cwd\":\"/r\"}"
        done
        echo "[$out]"
        ;;
    stop) echo "$2" >> "$D/stopped" ;;
esac
FAKEEOF
    printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/sleep"
    chmod +x "$tmp/bin/claude" "$tmp/bin/sleep"
    printf '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":1,"notify":"command","notifyCommand":"cat >> %s/notes"}}\n' "$tmp" > "$tmp/n1home/config.json"
    {
        printf -- '---\nstep: plan\nqueue_id: %s\nhost: claude-code\n---\n## Plan\n' "$qid"
        printf '| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |\n|---|--------|-------|------|---------|-------|--------|--------|\n'
        for spec in "$@"; do
            n=$((n + 1)); t="${spec%%:*}"
            printf '%s\n' "${spec#*:}" > "$tmp/fake/states.$t"
            printf '| %s | %s | Fix %s | %s | %s | sonnet | pending | |\n' "$n" "$t" "$t" "$tmp" "$tmp/n1home"
        done
        printf '\n## Runs\n| Ticket | Started | Exit | Outcome | PR | Session |\n|--------|---------|------|---------|----|---------|\n'
    } > "$tmp/queue.md"
}

run_bg_queue() { # <tmp> — runs the runner with the fakes first on PATH; prints its exit code
    local rc=0
    env -u N1_QUEUE_CHILD_STUB FAKE_DIR="$1/fake" FAKE_N1H="$1/n1home" N1_HOME="$1/n1home" PATH="$1/bin:$PATH" \
        bash "$REPO_ROOT/scripts/n1-queue-run.sh" "$1/queue.md" > "$1/output.txt" 2>&1 || rc=$?
    echo "$rc"
}

line_of() { grep -n -F -- "$2" "$1" | head -1 | cut -d: -f1; }

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
    assert_eq "bg-seq: settings env + isolation" "1,autonomous,claude-code,ask,none" \
        "$(jq -r '[.env.N1_HEADLESS,.env.N1_AUTONOMY_PRESET,.env.N1_HOST,.env.N1_UNATTENDED,.worktree.bgIsolation]|join(",")' "$tmp/fake/settings.n1-bgq-T-A-1")"
    assert_eq "bg-seq: run id in settings" "$(n1_read_frontmatter "$tmp/queue.md" run_id)" \
        "$(jq -r .env.N1_QUEUE_RUN_ID "$tmp/fake/settings.n1-bgq-T-A-1")"
    assert_eq "bg-seq: session id stored" "00000001" "$(n1_queue_session_id "$tmp/queue.md" T-A)"
    assert_eq "bg-seq: PR url recorded" "https://x/pr/1" \
        "$(awk -F'|' '/^## Runs/{f=1;next} f && $2 ~ /T-A/ { gsub(/ /,"",$6); print $6 }' "$tmp/queue.md")"
    local bad; bad=$(awk '/^## Runs/{f=1;next} f && /^\| T-/{ if (gsub(/\|/,"|") != 7) print }' "$tmp/queue.md")
    assert_eq "bg-seq: Runs rows have 7 cells" "" "$bad"
    rm -rf "$tmp"
}

test_bg_awaiting() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:blocked blocked working done" "T-B:working done"
    assert_eq "bg-await: exit 0" "0" "$(run_bg_queue "$tmp")"
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
host: claude-code
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
    mk_bg "$tmp" bgq "T-A:working working working"
    echo '{"queue":{"pollSeconds":30,"subtaskTimeoutMinutes":0,"notify":"none"}}' > "$tmp/n1home/config.json"
    mkdir -p "$tmp/n1home/memory/T-A"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/9\n' > "$tmp/n1home/memory/T-A/overview.md"
    assert_eq "bg-recw: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-recw: row 1 pr" "pr" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-recw: PR url recorded" "https://x/pr/9" \
        "$(awk -F'|' '/^## Runs/{f=1;next} f && $2 ~ /T-A/ { gsub(/ /,"",$6); print $6 }' "$tmp/queue.md")"
    assert_eq "bg-recw: no deferred-retry row" "" "$(plan_cell "$tmp/queue.md" 2 8)"
    assert_eq "bg-recw: session never stopped" "" "$(cat "$tmp/fake/stopped" 2>/dev/null || true)"
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

test_run_sync_reason_default() {
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/n1home/memory/T-X"
    cat > "$tmp/queue.md" <<EOF
---
step: plan
queue_id: syncq
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-X | Fix X | $tmp | $tmp/n1home | sonnet | pending | |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
EOF
    local stub; stub=$(mktemp)
    printf '#!/bin/sh\nexit 1\n' > "$stub"; chmod +x "$stub"
    env N1_QUEUE_CHILD_STUB="$stub" N1_HOME="$tmp/n1home" \
        bash "$REPO_ROOT/scripts/n1-queue-run.sh" "$tmp/queue.md" >/dev/null 2>&1 || true
    assert_eq "sync-reason: row 1 deferred" "deferred" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "sync-reason: row 1 reason" "child-exit-1" "$(plan_cell "$tmp/queue.md" 1 9)"
    rm -rf "$tmp" "$stub"
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

test_busy_guard() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

    cat > "$tmp/queue.md" <<EOF
---
step: run
pid: $$
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

# --- n1_queue_status_table ----------------------------------------------------
mk_status_queue() { # <tmp> <host> — a 3-row queue.md + events.jsonl + overview.md fixture
    local tmp="$1" host="$2"
    mkdir -p "$tmp/h/memory/T-2" "$tmp/h/memory/T-4"
    printf -- '---\nstep: review\n---\n' > "$tmp/h/memory/T-2/overview.md"
    printf -- '---\nstep: escalated\n---\n\n## Escalations\n\n- [headless] qa: first blocker\n- [headless] implementation: second blocker\n' > "$tmp/h/memory/T-4/overview.md"
    {
        printf -- '---\nhost: %s\n---\n' "$host"
        printf '## Plan\n| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |\n|---|--------|-------|------|---------|-------|--------|--------|\n'
        printf '| 1 | T-1 | A | /r | %s/h | sonnet | pr | |\n' "$tmp"
        printf '| 2 | T-2 | B | /r | %s/h | sonnet | in-progress | |\n' "$tmp"
        printf '| 3 | T-3 | C | /r | %s/h | sonnet | awaiting-human | |\n' "$tmp"
        printf '| 4 | T-4 | D | /r | %s/h | sonnet | escalated | |\n' "$tmp"
        printf '\n## Runs\n| Ticket | Started | Exit | Outcome | PR | Session |\n|--------|---------|------|---------|----|---------|\n'
        printf '| T-1 | 2020-01-01T00:00:00Z | | pr | https://x/pr/1 | 00000001 |\n'
        printf '| T-2 | %s | | | | 0000abcd |\n' "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)"
        printf '| T-3 | %s | | | | 11112222 |\n' "$(date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)"
        printf '| T-4 | 2020-01-01T00:00:00Z | | escalated | | |\n'
    } > "$tmp/q.md"
    printf '{"ts":"2020-01-01T00:01:00Z","queue":"q","run_id":"r","event":"ticket_finished","ticket":"T-1","outcome":"pr","pr":"https://x/pr/1","session":"00000001","duration_s":60,"reason":""}\n' \
        > "$tmp/events.jsonl"
}

test_status_table_claude_code() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    mk_status_queue "$tmp" claude-code
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

test_status_table_codex() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    mk_status_queue "$tmp" codex
    # a `claude` that fails the test if invoked on the codex path
    mkdir -p "$tmp/bin"
    cat > "$tmp/bin/claude" <<'FAKEEOF'
#!/usr/bin/env bash
echo "claude should not be called on codex host" >&2
exit 1
FAKEEOF
    chmod +x "$tmp/bin/claude"
    local out; out=$(PATH="$tmp/bin:$PATH" n1_queue_status_table "$tmp/q.md" "$tmp/events.jsonl")
    assert_eq "status(codex): T-2 uses Plan status, no agents call" "in-progress" \
        "$(echo "$out" | awk -F'\t' '$1=="T-2"{print $2}')"
    assert_eq "status(codex): T-3 no attach (no bg sessions)" "" "$(echo "$out" | awk -F'\t' '$1=="T-3"{print $7}')"
    assert_eq "status(codex): T-1 pr elapsed" "1m" "$(echo "$out" | awk -F'\t' '$1=="T-1"{print $4}')"
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
    local out rc=0
    out=$(N1_HOST=codex n1_queue_status_table "$tmp/queue.md" "$tmp/nonexistent-events.jsonl") || rc=$?
    assert_eq "pre-NP-197 fixture: exits 0" "0" "$rc"
    assert_eq "pre-NP-197 fixture: TP-6 status from Plan" "pr" \
        "$(echo "$out" | awk -F'\t' '$1=="TP-6"{print $2}')"
    assert_eq "pre-NP-197 fixture: TP-6 PR from Runs" "https://github.com/maphnet/test-project/pull/3" \
        "$(echo "$out" | awk -F'\t' '$1=="TP-6"{print $6}')"
}

# --- NP-219: pending deploy -----------------------------------------------------
test_child_status_deploy() {
    local tmp; tmp=$(mktemp -d)
    printf -- '---\nstep: pr\ndeploy_pending: true\n---\n' > "$tmp/ov.md"
    assert_eq "child-status: deploy pending" "awaiting-deploy" "$(n1_queue_child_status "$tmp/ov.md" 0)"
    printf -- '---\nstep: pr\ndeploy_pending: false\n---\n' > "$tmp/ov.md"
    assert_eq "child-status: deploy done -> pr" "pr" "$(n1_queue_child_status "$tmp/ov.md" 0)"
    printf -- '---\nstep: pr\n---\n' > "$tmp/ov.md"
    assert_eq "child-status: no delivery -> pr (unchanged)" "pr" "$(n1_queue_child_status "$tmp/ov.md" 0)"
    printf -- '---\nstep: escalated\n---\n' > "$tmp/ov.md"
    assert_eq "child-status: no delivery -> escalated (unchanged)" "escalated" "$(n1_queue_child_status "$tmp/ov.md" 1)"
    rm -rf "$tmp"
}

test_runner_deploy_pending() {
    local tmp; tmp=$(mktemp -d)
    cat > "$tmp/stub.sh" <<'STUBEOF'
#!/usr/bin/env bash
TICKET="$1"
mkdir -p "$(dirname "$N1_QUEUE_OVERVIEW")"
if [ "$TICKET" = T-D ]; then
    printf -- '---\nstep: pr\ndeploy_pending: true\n---\n# T\n' > "$N1_QUEUE_OVERVIEW"
else
    sed -i.bak 's/^step: .*/step: pr/' "$N1_QUEUE_OVERVIEW"
fi
exit 0
STUBEOF
    chmod +x "$tmp/stub.sh"
    cat > "$tmp/wrapper.sh" <<WEOF
#!/usr/bin/env bash
TICKET="\$1"
export N1_QUEUE_OVERVIEW="$tmp/n1home/memory/\$TICKET/overview.md"
exec "$tmp/stub.sh" "\$TICKET"
WEOF
    chmod +x "$tmp/wrapper.sh"
    mkdir -p "$tmp/n1home/memory/T-P"
    # Stale flag from an earlier run: the runner must reset it at launch.
    printf -- '---\nstep: implement\ndeploy_pending: true\n---\n# T\n' > "$tmp/n1home/memory/T-P/overview.md"
    printf '{"queue":{"notify":"command","notifyCommand":"cat >> %s/notes"}}\n' "$tmp" > "$tmp/n1home/config.json"
    cat > "$tmp/queue.md" <<EOF
---
step: plan
queue_id: test-dep
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|--------|-------|------|---------|-------|--------|--------|
| 1 | T-D | Deploy me | /repo | $tmp/n1home | sonnet | pending | |
| 2 | T-P | Plain | /repo | $tmp/n1home | sonnet | pending | |

## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|--------|---------|------|---------|----|---------|
EOF
    export N1_QUEUE_CHILD_STUB="$tmp/wrapper.sh"
    export N1_HOME="$tmp/n1home"
    local rc=0
    bash "$REPO_ROOT/scripts/n1-queue-run.sh" "$tmp/queue.md" > "$tmp/output.txt" 2>&1 || rc=$?
    assert_eq "runner-deploy: exit 0" "0" "$rc"
    assert_eq "runner-deploy: T-D awaiting-human" "awaiting-human" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "runner-deploy: T-D reason" "awaiting-deploy" "$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "runner-deploy: queue continued, T-P pr (stale flag reset)" "pr" "$(plan_cell "$tmp/queue.md" 2 8)"
    assert_eq "runner-deploy: no retry row" "" "$(plan_cell "$tmp/queue.md" 3 8)"
    assert_eq "runner-deploy: step done" "done" "$(n1_read_frontmatter "$tmp/queue.md" step)"
    assert_eq "runner-deploy: event outcome" "awaiting-deploy" \
        "$(jq -r 'select(.event=="ticket_finished" and .ticket=="T-D") | .outcome' "$tmp/events.jsonl")"
    assert_eq "runner-deploy: digest" "1 PR / 1 awaiting / 0 failed" \
        "$(jq -r 'select(.event=="queue_done") | .reason' "$tmp/events.jsonl")"
    assert_eq "runner-deploy: needs-you notify with resume hint" "yes" \
        "$(jq -r 'select(.kind=="needs-you") | .text' "$tmp/notes" | grep -qF 'n1-finish T-D' && echo yes || echo no)"
    assert_eq "runner-deploy: hint" "T-D: n1-finish T-D (deploy pending)" "$(n1_queue_awaiting_hints "$tmp/queue.md")"
    unset N1_QUEUE_CHILD_STUB
    rm -rf "$tmp"
}

test_bg_deploy_pending() {
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgq "T-A:working done" "T-B:done"
    touch "$tmp/fake/deploy.T-A"
    assert_eq "bg-deploy: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-deploy: T-A awaiting-human" "awaiting-human" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-deploy: T-A reason" "awaiting-deploy" "$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "bg-deploy: T-B pr (queue moved on)" "pr" "$(plan_cell "$tmp/queue.md" 2 8)"
    assert_eq "bg-deploy: finalized exactly once" "1" \
        "$(jq -r 'select(.ticket=="T-A" and .event=="ticket_finished") | .event' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    assert_eq "bg-deploy: no retry row" "" "$(plan_cell "$tmp/queue.md" 3 8)"
    assert_eq "bg-deploy: step done" "done" "$(n1_read_frontmatter "$tmp/queue.md" step)"
    assert_eq "bg-deploy: no parked wait message" "0" "$(grep -c 'awaiting-human rows left' "$tmp/output.txt" || true)"
    rm -rf "$tmp"
}

test_bg_deploy_flag_cleared_mid_run() {
    # An interactive n1-finish clears deploy_pending while the queue still runs: the row
    # stays terminal (recorded Reason), no second finalize, no parked wait.
    local tmp; tmp=$(mktemp -d)
    mk_bg "$tmp" bgc "T-A:working done" "T-B:working done"
    touch "$tmp/fake/deploy.T-A" "$tmp/fake/clear.T-A"
    assert_eq "bg-deploy-cleared: exit 0" "0" "$(run_bg_queue "$tmp")"
    assert_eq "bg-deploy-cleared: flag was cleared" "false" \
        "$(n1_read_frontmatter "$tmp/n1home/memory/T-A/overview.md" deploy_pending)"
    assert_eq "bg-deploy-cleared: T-A still awaiting-human" "awaiting-human" "$(plan_cell "$tmp/queue.md" 1 8)"
    assert_eq "bg-deploy-cleared: T-A reason kept" "awaiting-deploy" "$(plan_cell "$tmp/queue.md" 1 9)"
    assert_eq "bg-deploy-cleared: finalized exactly once" "1" \
        "$(jq -r 'select(.ticket=="T-A" and .event=="ticket_finished") | .event' "$tmp/events.jsonl" | wc -l | tr -d ' ')"
    assert_eq "bg-deploy-cleared: T-B pr" "pr" "$(plan_cell "$tmp/queue.md" 2 8)"
    assert_eq "bg-deploy-cleared: no retry row" "" "$(plan_cell "$tmp/queue.md" 3 8)"
    assert_eq "bg-deploy-cleared: no parked wait message" "0" "$(grep -c 'awaiting-human rows left' "$tmp/output.txt" || true)"
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
             skills/n1-start/steps/investigation-deliverable.md skills/n1-start/steps/estimation.md; do
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

test_parse_service
test_find_repo
test_pick_model
test_plan_wiring
test_child_status
test_child_status_deploy
test_row_status
test_write_plan_cells
test_pending_rows
test_decisions_and_stale
test_desc_hash_chain
test_title_vague
test_desc_chain_wiring
test_brief_wiring
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
test_status_table_codex
test_escalated_step_fallback
test_queue_event
test_escalation_text
test_desktop_notify
test_notify_backends
test_runner_three_strikes
test_runner_all_pr
test_runner_deploy_pending
test_runner_tag_release
test_runner_auto_release_backstop
test_runner_release_backstop_on_halt
test_runner_codex_host
test_bg_sequential
test_bg_awaiting
test_bg_awaiting_timeout
test_bg_deploy_pending
test_bg_deploy_flag_cleared_mid_run
test_bg_working_timeout
test_bg_missing_grace
test_bg_reconcile_working
test_bg_reconcile_missing
test_bg_reconcile_working_stale_escalation
test_bg_blocked_first_tick_parks
test_bg_reason_child_exited_incomplete
test_bg_reason_bg_state_catchall
test_run_sync_reason_default
test_notify_check
test_bg_disclaimer
test_busy_guard

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
test_headless_plan_wiring

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

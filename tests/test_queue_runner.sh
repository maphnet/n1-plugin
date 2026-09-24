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
                printf -- '---\nstep: pr\n---\n# T\n\n## Pending\npr_url: https://x/pr/1\n' > "$FAKE_N1H/memory/$t/overview.md"
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
    assert_eq "bg-seq: settings env + isolation" "1,autonomous,ci,claude-code,ask,none" \
        "$(jq -r '[.env.N1_HEADLESS,.env.N1_AUTONOMY_PRESET,.env.N1_STOP_AT,.env.N1_HOST,.env.N1_UNATTENDED,.worktree.bgIsolation]|join(",")' "$tmp/fake/settings.n1-bgq-T-A-1")"
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

test_parse_service
test_find_repo
test_pick_model
test_child_status
test_row_status
test_pending_rows
test_bg_helpers
test_decision_counts
test_queue_digest
test_queue_event
test_escalation_text
test_desktop_notify
test_notify_backends
test_runner_three_strikes
test_runner_all_pr
test_runner_codex_host
test_bg_sequential
test_bg_awaiting
test_bg_awaiting_timeout
test_bg_working_timeout
test_bg_missing_grace
test_bg_disclaimer
test_busy_guard

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

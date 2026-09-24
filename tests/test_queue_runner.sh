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
    assert_eq "val: default fallback" "60" "$(n1_queue_val pollSeconds)"
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

    assert_eq "qstatus: step pr -> pr" "pr" "$(n1_queue_child_status "$tmp/pr.md" 0)"
    assert_eq "qstatus: step ci -> pr" "pr" "$(n1_queue_child_status "$tmp/ci.md" 0)"
    assert_eq "qstatus: step done -> pr" "pr" "$(n1_queue_child_status "$tmp/done.md" 0)"
    assert_eq "qstatus: step escalated" "escalated" "$(n1_queue_child_status "$tmp/esc.md" 0)"
    assert_eq "qstatus: escalations section" "escalated" "$(n1_queue_child_status "$tmp/esc2.md" 0)"
    assert_eq "qstatus: mid-run exit 0 -> running" "running" "$(n1_queue_child_status "$tmp/mid.md" 0)"
    assert_eq "qstatus: mid-run exit 1 -> failed" "failed" "$(n1_queue_child_status "$tmp/mid.md" 1)"
    assert_eq "qstatus: missing file exit 1 -> failed" "failed" "$(n1_queue_child_status "$tmp/none.md" 1)"
    assert_eq "qstatus: missing file exit 0 -> running" "running" "$(n1_queue_child_status "$tmp/none.md" 0)"
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

    local j='{"agents":[{"name":"a","state":"working"},{"name":"b","state":"blocked","waitingFor":"input"},{"name":"c","state":"done"},{"name":"d","state":"stopped"},{"name":"e","state":"failed"}]}'
    assert_eq "bgstate: working" "working" "$(n1_queue_bg_state "$j" a)"
    assert_eq "bgstate: blocked" "blocked" "$(n1_queue_bg_state "$j" b)"
    assert_eq "bgstate: done" "done" "$(n1_queue_bg_state "$j" c)"
    assert_eq "bgstate: stopped -> failed" "failed" "$(n1_queue_bg_state "$j" d)"
    assert_eq "bgstate: failed" "failed" "$(n1_queue_bg_state "$j" e)"
    assert_eq "bgstate: missing -> failed" "failed" "$(n1_queue_bg_state "$j" zz)"
    assert_eq "bgstate: bare array" "blocked" "$(n1_queue_bg_state '[{"name":"a","state":"blocked"}]' a)"

    local cc cx
    cc=$(unset N1_QUEUE_CHILD_STUB N1_STORY_PLUGIN_DIR; N1_HOST=claude-code n1_queue_child_cmd /r T-1 sonnet RUN1 /tmp/log n1-q-T-1-1)
    assert_eq "child_cmd: claude-code bg launch" "yes" "$(case "$cc" in "cd /r && claude --bg --name n1-q-T-1-1 --model sonnet --permission-mode bypassPermissions --settings "*bgIsolation*"/n1:n1-start\ T-1"*) echo yes ;; *) echo "no: $cc" ;; esac)"
    cx=$(unset N1_QUEUE_CHILD_STUB; N1_HOST=codex n1_queue_child_cmd /r T-1 sonnet RUN1 /tmp/log)
    assert_eq "child_cmd: codex unchanged" "yes" "$(case "$cx" in *'N1_QUEUE_RUN_ID="RUN1"'*"codex exec"*) case "$cx" in *--bg*) echo no ;; *) echo yes ;; esac ;; *) echo "no: $cx" ;; esac)"

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
    # Runs rows have exactly 6 cells incl. Session (no phantom trailing cell)
    local bad; bad=$(awk '/^## Runs/{f=1;next} f && /^\| T-/{ if (gsub(/\|/,"|") != 7) print }' "$tmp/queue.md")
    assert_eq "runner: Runs rows have 6 cells" "" "$bad"

    local halted_msg; halted_msg=$(grep -c "HALTED" "$tmp/output.txt" || true)
    assert_eq "runner: HALTED message printed" "1" "$halted_msg"

    unset N1_QUEUE_CHILD_STUB
    rm -rf "$tmp"
}

test_runner_all_pr() {
    local tmp; tmp=$(mktemp -d)

    cat > "$tmp/stub.sh" <<'STUBEOF'
#!/usr/bin/env bash
TICKET="$1"
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

    unset N1_QUEUE_CHILD_STUB
    rm -rf "$tmp"
}

# Real (unstubbed) Codex path: host comes from queue.md frontmatter even though
# CLAUDE_PLUGIN_ROOT is exported (the runner forces it for path resolution).
test_runner_codex_host() {
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/bin" "$tmp/n1home/memory"
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

test_parse_service
test_find_repo
test_pick_model
test_child_status
test_row_status
test_pending_rows
test_bg_helpers
test_decision_counts
test_runner_three_strikes
test_runner_all_pr
test_runner_codex_host
test_busy_guard

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

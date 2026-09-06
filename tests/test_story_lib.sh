#!/usr/bin/env bash
# Tests for lib/story.sh helpers (story orchestrator).
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

export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
: "${N1_HOME:=}"; : "${ID:=}"; export N1_HOME ID
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/lib/story.sh"

# --- parse_service -----------------------------------------------------------
test_parse_service() {
    assert_eq "parse: prefix present" "inference" "$(n1_story_parse_service 'inference | Add batching endpoint')"
    assert_eq "parse: odd spacing" "tailnet-acl" "$(n1_story_parse_service 'tailnet-acl |Grant SSH')"
    assert_eq "parse: no prefix" "" "$(n1_story_parse_service 'Add batching endpoint')"
    assert_eq "parse: pipe later in title only" "" "$(n1_story_parse_service 'Support a|b syntax')"
}

# --- find_repo ---------------------------------------------------------------
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

    echo '{"story":{"opusFromSize":"L"}}' > "$tmp/config.json"
    assert_eq "model: threshold L, M -> sonnet" "sonnet" "$(n1_story_pick_model M)"
    assert_eq "model: threshold L, L -> opus" "opus" "$(n1_story_pick_model L)"
    assert_eq "val: config override" "L" "$(n1_story_val opusFromSize)"
    assert_eq "val: default fallback" "60" "$(n1_story_val pollSeconds)"
    unset -f n1_config_file
}

test_toposort() {
    local out
    out=$(n1_story_toposort "A,B,C" "" | tr '\n' ',')
    assert_eq "topo: no edges keeps order" "A,B,C," "$out"
    out=$(n1_story_toposort "A,B,C" $'B>A\nC>B' | tr '\n' ',')
    assert_eq "topo: linear chain" "C,B,A," "$out"
    out=$(n1_story_toposort "A,B,C,D" $'A>B\nA>C\nB>D\nC>D' | tr '\n' ',')
    assert_eq "topo: diamond" "A,B,C,D," "$out"
    if n1_story_toposort "A,B" $'A>B\nB>A' >/dev/null 2>&1; then
        assert_eq "topo: cycle exits 2" "2" "0"
    else
        assert_eq "topo: cycle exits 2" "2" "$?"
    fi
}

test_child_status() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    printf -- '---\nstep: done\n---\n# T\n\n## Finish\nMerged PR https://x/pr/1\npr_url: https://x/pr/1\n' > "$tmp/done.md"
    printf -- '---\nstep: pr\n---\n# T\n\n## Pending\nawaiting: merge\npr: 7\npr_url: https://x/pr/7\n' > "$tmp/pending.md"
    printf -- '---\nstep: escalated\n---\n# T\n\n## Escalations\n- plan approval needed\n' > "$tmp/esc.md"
    printf -- '---\nstep: qa\n---\n# T\n\n## Escalations\n- QA exhausted\n' > "$tmp/esc2.md"
    printf -- '---\nstep: implementation\n---\n# T\n' > "$tmp/mid.md"

    assert_eq "status: done -> merged" "merged" "$(n1_story_child_status "$tmp/done.md" 0)"
    assert_eq "status: pending -> awaiting-merge" "awaiting-merge" "$(n1_story_child_status "$tmp/pending.md" 0)"
    assert_eq "status: step escalated" "escalated" "$(n1_story_child_status "$tmp/esc.md" 0)"
    assert_eq "status: escalations section" "escalated" "$(n1_story_child_status "$tmp/esc2.md" 0)"
    assert_eq "status: mid-run exit 0 -> running" "running" "$(n1_story_child_status "$tmp/mid.md" 0)"
    assert_eq "status: mid-run exit 1 -> failed" "failed" "$(n1_story_child_status "$tmp/mid.md" 1)"
    assert_eq "status: missing file exit 1 -> failed" "failed" "$(n1_story_child_status "$tmp/none.md" 1)"
    assert_eq "status: missing file exit 0 -> running" "running" "$(n1_story_child_status "$tmp/none.md" 0)"
    assert_eq "pr_url: from pending" "https://x/pr/7" "$(n1_story_child_pr_url "$tmp/pending.md")"
    assert_eq "pr_url: from finish block" "https://x/pr/1" "$(n1_story_child_pr_url "$tmp/done.md")"
    assert_eq "pr_url: absent" "" "$(n1_story_child_pr_url "$tmp/mid.md")"
}

test_child_cmd() {
    unset N1_STORY_PLUGIN_DIR
    local cmd; cmd=$(n1_story_child_cmd /repos/inf INF-12 opus STORY-1 /tmp/log.jsonl)
    case "$cmd" in
        *'cd "/repos/inf"'*'N1_HEADLESS=1'*'N1_AUTONOMY_PRESET=autonomous'*'N1_STORY_ID="STORY-1"'*'claude -p "/n1:n1-start INF-12"'*'--model opus'*'--permission-mode bypassPermissions'*'--output-format stream-json --verbose'*'> "/tmp/log.jsonl" 2>&1'*)
            assert_eq "cmd: full shape" "ok" "ok" ;;
        *) assert_eq "cmd: full shape" "ok" "$cmd" ;;
    esac
    case "$cmd" in *--plugin-dir*) assert_eq "cmd: no plugin-dir by default" "absent" "present" ;; *) assert_eq "cmd: no plugin-dir by default" "absent" "absent" ;; esac
    export N1_STORY_PLUGIN_DIR=/dev/n1-plugin
    cmd=$(n1_story_child_cmd /repos/inf INF-12 sonnet STORY-1 /tmp/log.jsonl)
    case "$cmd" in *'--plugin-dir "/dev/n1-plugin"'*) assert_eq "cmd: plugin-dir when env set" "ok" "ok" ;; *) assert_eq "cmd: plugin-dir when env set" "ok" "$cmd" ;; esac
    unset N1_STORY_PLUGIN_DIR
}

test_parse_service
test_find_repo
test_pick_model
test_toposort
test_child_status
test_child_cmd

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

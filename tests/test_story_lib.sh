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

test_parse_service
test_find_repo
test_pick_model
test_toposort

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

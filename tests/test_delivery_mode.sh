#!/usr/bin/env bash
# Tests for NP-219 delivery mode: lib/config.sh helpers, negative execution,
# merge-gate non-regression, and skill wiring.
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
unset N1_QUEUE_RUN_ID N1_HEADLESS
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/lib/frontmatter.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TEST_CONFIG="$TMP/config.json"
n1_config_file() { echo "$TEST_CONFIG"; }

action() { echo "$1" > "$TEST_CONFIG"; n1_delivery_action; }

SSH_CFG='{"delivery":{"mode":"ssh","command":"true"}}'

# --- n1_delivery_action -------------------------------------------------------
test_action() {
    assert_eq "action: empty config -> none" "none" "$(action '{}')"
    assert_eq "action: PR project (prMode ready) -> none" "none" "$(action '{"git":{"prMode":"ready"},"finishWork":{"enabled":true}}')"
    assert_eq "action: prMode skip without delivery -> none" "none" \
        "$(action '{"git":{"prMode":"skip"},"finishWork":{"enabled":true,"mergeOnFinish":true}}')"
    assert_eq "action: empty mode -> none" "none" "$(action '{"delivery":{"mode":"","command":"true"}}')"
    assert_eq "action: unknown mode -> none" "none" "$(action '{"delivery":{"mode":"rsync","command":"true"}}')"
    assert_eq "action: ssh interactive -> execute" "execute" "$(action "$SSH_CFG")"
    assert_eq "action: ssh queue child -> runbook" "runbook" "$(N1_QUEUE_RUN_ID=R1 action "$SSH_CFG")"
    assert_eq "action: ssh headless -> runbook" "runbook" "$(N1_HEADLESS=1 action "$SSH_CFG")"
    assert_eq "action: queue child without delivery -> none" "none" "$(N1_QUEUE_RUN_ID=R1 action '{}')"
}

# --- n1_delivery_runbook: writes, never executes ------------------------------
test_runbook_never_executes() {
    export N1_HOME="$TMP/home"
    local id=T-9 ov="$TMP/home/memory/T-9/overview.md" out
    mkdir -p "$TMP/home/memory/$id"
    printf -- '---\nstep: pr\n---\n# T\n' > "$ov"
    printf '{"delivery":{"mode":"ssh","command":"touch %s/DEPLOYED","verifyCommand":"touch %s/VERIFIED"}}\n' "$TMP" "$TMP" > "$TEST_CONFIG"

    out=$(N1_QUEUE_RUN_ID=R1 n1_delivery_runbook "$id" abc123)
    assert_eq "runbook: path printed" "$TMP/home/memory/$id/runbook.md" "$out"
    assert_eq "runbook: deploy command NOT executed" "no" "$([ -e "$TMP/DEPLOYED" ] && echo yes || echo no)"
    assert_eq "runbook: verify command NOT executed" "no" "$([ -e "$TMP/VERIFIED" ] && echo yes || echo no)"
    assert_eq "runbook: contains deploy command" "yes" "$(grep -qF "touch $TMP/DEPLOYED" "$out" && echo yes || echo no)"
    assert_eq "runbook: contains verify command" "yes" "$(grep -qF "touch $TMP/VERIFIED" "$out" && echo yes || echo no)"
    assert_eq "runbook: resume hint" "yes" "$(grep -qF 'n1-finish T-9' "$out" && echo yes || echo no)"
    assert_eq "runbook: merged note" "yes" "$(grep -qF 'abc123' "$out" && echo yes || echo no)"
    assert_eq "runbook: deploy_pending set" "true" "$(n1_read_frontmatter "$ov" deploy_pending)"
    assert_eq "runbook: merge sha recorded" "abc123" "$(n1_read_frontmatter "$ov" deploy_merge_sha)"
    assert_eq "runbook: other frontmatter kept" "pr" "$(n1_read_frontmatter "$ov" step)"

    # No merge yet, no overview yet, no verify command.
    printf '{"delivery":{"mode":"ssh","command":"touch %s/DEPLOYED2"}}\n' "$TMP" > "$TEST_CONFIG"
    out=$(n1_delivery_runbook T-10)
    local ov2="$TMP/home/memory/T-10/overview.md"
    assert_eq "runbook-unmerged: deploy command NOT executed" "no" "$([ -e "$TMP/DEPLOYED2" ] && echo yes || echo no)"
    assert_eq "runbook-unmerged: overview created + flag set" "true" "$(n1_read_frontmatter "$ov2" deploy_pending)"
    assert_eq "runbook-unmerged: no merge sha" "" "$(n1_read_frontmatter "$ov2" deploy_merge_sha)"
    assert_eq "runbook-unmerged: not-merged note" "yes" "$(grep -qF 'Not merged yet' "$out" && echo yes || echo no)"
    assert_eq "runbook-unmerged: no verify section" "0" "$(grep -c 'Verify command' "$out" || true)"
}

# --- Non-regression: merge/finish gates ignore the delivery block -------------
gate() {
    echo "$1" > "$TEST_CONFIG"
    local m=0 f=0
    if n1_merge_allowed; then m=1; fi
    if n1_finish_enabled; then f=1; fi
    echo "$m$f"
}

test_gates_unchanged() {
    local base with
    for base in '{}' \
        '{"finishWork":{"enabled":true,"mergeOnFinish":true}}' \
        '{"git":{"prMode":"skip"},"finishWork":{"enabled":true,"mergeOnFinish":true},"queue":{"mergeOnFinish":true}}' \
        '{"git":{"prMode":"ready"},"finishWork":{"enabled":false}}'; do
        with=$(echo "$base" | jq -c '. + {"delivery":{"mode":"ssh","command":"true"}}')
        assert_eq "gates unchanged (interactive): $base" "$(gate "$base")" "$(gate "$with")"
        assert_eq "gates unchanged (queue): $base" "$(N1_QUEUE_RUN_ID=R1 gate "$base")" "$(N1_QUEUE_RUN_ID=R1 gate "$with")"
    done
}

test_action
test_runbook_never_executes
test_gates_unchanged

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

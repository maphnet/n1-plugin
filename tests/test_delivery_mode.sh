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

# --- SEC-3: no jq -> runbook, never execute -----------------------------------
test_action_no_jq() {
    local nopath
    nopath=$(mktemp -d)
    for b in bash sh grep awk sed head tr; do
        local real; real=$(command -v "$b")
        [ -n "$real" ] && ln -s "$real" "$nopath/$b"
    done
    # Pretty-printed (one key per line), matching real config files — the non-jq
    # fallback's awk section scan only balances braces across separate lines.
    printf '{\n  "delivery": {\n    "mode": "ssh",\n    "command": "true"\n  }\n}\n' > "$TEST_CONFIG"
    assert_eq "action: ssh + no jq -> runbook (not execute)" "runbook" \
        "$(PATH="$nopath" n1_delivery_action)"
    # Compact JSON: the non-jq value parser cannot read it; must still fail closed.
    printf '{"delivery":{"mode":"ssh","command":"true"}}\n' > "$TEST_CONFIG"
    assert_eq "action: compact ssh + no jq -> runbook (not none)" "runbook" \
        "$(PATH="$nopath" n1_delivery_action)"
    printf '{"finishWork":{"enabled":true}}\n' > "$TEST_CONFIG"
    assert_eq "action: no delivery block + no jq -> none" "none" \
        "$(PATH="$nopath" n1_delivery_action)"
    rm -rf "$nopath"
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

# --- NP-240: multi-step delivery helpers ---------------------------------------
test_multi_step_helpers() {
    local cf="$TMP/step.cmd" out
    echo '{"delivery":{"mode":"ssh","command":"true"}}' > "$TEST_CONFIG"
    assert_eq "multi-step: command only -> false" "false" "$(n1_delivery_is_multi_step)"
    echo '{"delivery":{"mode":"ssh","steps":["`true`"]}}' > "$TEST_CONFIG"
    assert_eq "multi-step: steps only -> true" "true" "$(n1_delivery_is_multi_step)"
    echo '{"delivery":{"mode":"ssh","command":"true","steps":["`true`"]}}' > "$TEST_CONFIG"
    assert_eq "multi-step: command wins over steps" "false" "$(n1_delivery_is_multi_step)"
    echo '{"delivery":{"mode":"ssh","steps":[]}}' > "$TEST_CONFIG"
    assert_eq "multi-step: empty steps -> true (execute reports it empty)" "true" "$(n1_delivery_is_multi_step)"
    echo '{"delivery":{"mode":"ssh","steps":"`true`"}}' > "$TEST_CONFIG"
    assert_eq "multi-step: steps not an array -> false" "false" "$(n1_delivery_is_multi_step)"
    echo '{}' > "$TEST_CONFIG"
    assert_eq "multi-step: no delivery -> false" "false" "$(n1_delivery_is_multi_step)"

    printf '{"delivery":{"mode":"ssh","steps":["`touch %s/RAN`","Manual: chown on host","`a` and `b`","plain text",""]}}\n' "$TMP" > "$TEST_CONFIG"
    out=$(n1_delivery_step 0 "$cf")
    assert_eq "step 0: shell" "shell" "$(printf '%s\n' "$out" | sed -n 1p)"
    assert_eq "step 0: item text on line 2" "\`touch $TMP/RAN\`" "$(printf '%s\n' "$out" | sed -n 2p)"
    assert_eq "step 0: command file holds the exact command" "touch $TMP/RAN" "$(cat "$cf")"
    assert_eq "step 0: never executed" "no" "$([ -e "$TMP/RAN" ] && echo yes || echo no)"
    out=$(n1_delivery_step 1 "$cf")
    assert_eq "step 1: Manual: prefix -> manual" "manual" "$(printf '%s\n' "$out" | sed -n 1p)"
    assert_eq "step 1: manual text on line 2" "Manual: chown on host" "$(printf '%s\n' "$out" | sed -n 2p)"
    assert_eq "step 1: manual leaves no command file" "no" "$([ -e "$cf" ] && echo yes || echo no)"
    assert_eq "step 2: four backticks -> manual" "manual" "$(n1_delivery_step 2 "$cf" | sed -n 1p)"
    assert_eq "step 3: no backticks -> manual" "manual" "$(n1_delivery_step 3 "$cf" | sed -n 1p)"
    assert_eq "step 4: empty item -> manual, not end" "manual" "$(n1_delivery_step 4 "$cf" | sed -n 1p)"
    assert_eq "step 5: past the end -> end" "end" "$(n1_delivery_step 5 "$cf")"
    assert_eq "step: non-numeric index -> end" "end" "$(n1_delivery_step 'x;true' "$cf")"
    assert_eq "step: command config -> end" "end" \
        "$(echo '{"delivery":{"mode":"ssh","command":"true"}}' > "$TEST_CONFIG"; n1_delivery_step 0 "$cf")"
}

test_runbook_steps() {
    export N1_HOME="$TMP/home"
    local ov="$TMP/home/memory/T-11/overview.md" out
    printf '{"delivery":{"mode":"ssh","steps":["`touch %s/FIRST`","Manual: approve restart","`touch %s/THIRD`"],"verifyCommand":"touch %s/VERIFY3"}}\n' \
        "$TMP" "$TMP" "$TMP" > "$TEST_CONFIG"
    out=$(N1_QUEUE_RUN_ID=R1 n1_delivery_runbook T-11 abc123)
    assert_eq "runbook-steps: no step or verify executed" "no" \
        "$([ -e "$TMP/FIRST" ] || [ -e "$TMP/THIRD" ] || [ -e "$TMP/VERIFY3" ] && echo yes || echo no)"
    assert_eq "runbook-steps: shell step listed" "yes" "$(grep -qF "1. \`touch $TMP/FIRST\`" "$out" && echo yes || echo no)"
    assert_eq "runbook-steps: manual step listed" "yes" "$(grep -qF '2. Manual: approve restart' "$out" && echo yes || echo no)"
    assert_eq "runbook-steps: verify listed" "yes" "$(grep -qF "touch $TMP/VERIFY3" "$out" && echo yes || echo no)"
    assert_eq "runbook-steps: no empty deploy command block" "0" "$(grep -c 'Deploy command' "$out" || true)"
    assert_eq "runbook-steps: deploy_pending set" "true" "$(n1_read_frontmatter "$ov" deploy_pending)"
    assert_eq "runbook-steps: next step recorded" "0" "$(n1_read_frontmatter "$ov" deploy_next_step)"
    # Abort at step 2 (index 1): only the remaining steps are listed, resume point recorded.
    out=$(n1_delivery_runbook T-11 abc123 1)
    assert_eq "runbook-steps: done step dropped" "0" "$(grep -cF "$TMP/FIRST" "$out" || true)"
    assert_eq "runbook-steps: remaining steps kept" "yes" "$(grep -qF "3. \`touch $TMP/THIRD\`" "$out" && echo yes || echo no)"
    assert_eq "runbook-steps: resume index recorded" "1" "$(n1_read_frontmatter "$ov" deploy_next_step)"
    out=$(n1_delivery_runbook T-11 abc123 'x;y')
    assert_eq "runbook-steps: bad first-step falls back to 0" "0" "$(n1_read_frontmatter "$ov" deploy_next_step)"
    # Single-command runbooks never gain the key (AC3).
    assert_eq "runbook: single-command has no deploy_next_step" "" \
        "$(n1_read_frontmatter "$TMP/home/memory/T-9/overview.md" deploy_next_step)"
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

# --- Skill wiring ---------------------------------------------------------------
section() { awk -v h="$2" 'index($0, h) == 1 {f=1; next} /^## /{f=0} f' "$1"; }

test_wiring() {
    local s="$REPO_ROOT/skills" step="$REPO_ROOT/skills/n1-finish/steps/03b-ssh-deploy.md"
    assert_eq "wiring: delivery step exists" "yes" "$([ -f "$step" ] && echo yes || echo no)"
    assert_eq "wiring: step branches on n1_delivery_action" "yes" "$(grep -q 'n1_delivery_action' "$step" && echo yes || echo no)"
    assert_eq "wiring: runbook branch uses the helper" "yes" \
        "$(section "$step" '## Runbook branch' | grep -q 'n1_delivery_runbook' && echo yes || echo no)"
    assert_eq "wiring: runbook branch never runs a command" "0" \
        "$(section "$step" '## Runbook branch' | grep -c 'bash -c' || true)"
    assert_eq "wiring: execute branch runs the deploy" "yes" \
        "$(section "$step" '## Execute branch' | grep -qF 'bash -c "$DEPLOY_CMD"' && echo yes || echo no)"
    assert_eq "wiring: execute branch runs the verify" "yes" \
        "$(section "$step" '## Execute branch' | grep -qF 'bash -c "$VERIFY_CMD"' && echo yes || echo no)"
    # Both commands run from a detached checkout of the merge SHA, never the current dir.
    assert_eq "wiring: deploy checks out the merge SHA" "yes" \
        "$(section "$step" '## Execute branch' | grep -qF 'git worktree add -q --detach "$DEPLOY_DIR" "<SHA>"' && echo yes || echo no)"
    assert_eq "wiring: deploy and verify both run in the checkout" "2" \
        "$(section "$step" '## Execute branch' | grep -c 'OUT=$(cd .*n1-deploy\|OUT=$(cd "$DEPLOY_DIR"' || true)"
    assert_eq "wiring: deploy checkout is removed" "yes" \
        "$(section "$step" '## Execute branch' | grep -qF 'git worktree remove --force "${TMPDIR:-/tmp}/n1-deploy-<ID>"' && echo yes || echo no)"
    # Step 6's Finish rewrite and report carry the delivery outcome instead of dropping it.
    assert_eq "wiring: cleanup Finish template has a Delivery line" "yes" \
        "$(grep -qF -- '- **Delivery:** <pending (runbook: memory/<ID>/runbook.md)' "$s/n1-finish/steps/06-cleanup.md" && echo yes || echo no)"
    assert_eq "wiring: cleanup report has a Delivery line" "yes" \
        "$(grep -q '^Delivery: <pending' "$s/n1-finish/steps/06-cleanup.md" && echo yes || echo no)"
    assert_eq "wiring: delivery step writes the Delivery line, not Deploy" "0" \
        "$(grep -c '\*\*Deploy:\*\*' "$step" || true)"
    assert_eq "wiring: execute branch asks first" "yes" \
        "$(section "$step" '## Execute branch' | grep -q 'Ask the user' && echo yes || echo no)"
    assert_eq "wiring: Step 4 enters the delivery step first" "yes" \
        "$(sed -n '1,4p' "$s/n1-finish/steps/04-close-ticket.md" | grep -qF '03b-ssh-deploy.md' && echo yes || echo no)"
    assert_eq "wiring: resume skips merge on recorded sha" "yes" \
        "$(grep -qF 'deploy_merge_sha' "$s/n1-finish/steps/01-resolve-target.md" && echo yes || echo no)"
    assert_eq "wiring: SKILL.md documents delivery keys" "yes" \
        "$(grep -qF '.delivery.verifyCommand' "$s/n1-finish/SKILL.md" && echo yes || echo no)"
    local init="$s/n1-init/steps/09-finish-release.md"
    assert_eq "init: asks about delivery" "yes" "$(grep -qF '"mode": "ssh"' "$init" && echo yes || echo no)"
    assert_eq "init: warns there is no ssh deny hook" "yes" "$(grep -qF 'no deny hook' "$init" && echo yes || echo no)"
    assert_eq "init: warns delivery commands must not contain secrets" "yes" \
        "$(grep -qF 'must not contain secrets' "$init" && echo yes || echo no)"
    assert_eq "init: offers multi-step delivery" "yes" "$(grep -qF '"steps": [' "$init" && echo yes || echo no)"
    assert_eq "init: empty command offers steps instead of a plain skip" "yes" \
        "$(grep -qF 'No single deploy command?' "$init" && echo yes || echo no)"
    assert_eq "init: step grammar explained" "yes" "$(grep -qF 'saved as a manual step' "$init" && echo yes || echo no)"
    assert_eq "init: reconfiguration shows steps" "yes" "$(grep -qF 'steps         →' "$init" && echo yes || echo no)"
    assert_eq "init: never writes both shapes" "yes" "$(grep -qF 'Never write both' "$init" && echo yes || echo no)"
    # SEC-1/SEC-2: failure/pending tracker comments never carry command text or raw output.
    assert_eq "wiring: deploy-failed comment has no command interpolation" "0" \
        "$(section "$step" '## Execute branch' | grep -c '<command>' || true)"
    assert_eq "wiring: deploy-failed comment says output kept locally" "yes" \
        "$(section "$step" '## Execute branch' | grep -qF 'kept locally in N1 memory' && echo yes || echo no)"
    assert_eq "wiring: pending comment has no command interpolation" "yes" \
        "$(section "$step" '## Runbook branch' | grep -qF 'runbook in N1 memory' && echo yes || echo no)"
    assert_eq "wiring: runbook branch never posts runbook content" "yes" \
        "$(section "$step" '## Runbook branch' | grep -qF 'Never post the runbook content' && echo yes || echo no)"
    assert_eq "wiring: failed-deploy path also updates overview Finish line" "yes" \
        "$(section "$step" '## Execute branch' | grep -qF 'Runbook branch steps 1 and 3' && echo yes || echo no)"
    # SEC-5: resume trusts deploy_merge_sha only after regex + ancestor validation.
    assert_eq "wiring: resume validates SHA format" "yes" \
        "$(grep -qF '^[0-9a-f]{7,40}$' "$s/n1-finish/steps/01-resolve-target.md" && echo yes || echo no)"
    assert_eq "wiring: resume validates SHA is an ancestor of the default branch" "yes" \
        "$(grep -qF 'merge-base --is-ancestor' "$s/n1-finish/steps/01-resolve-target.md" && echo yes || echo no)"
    # Non-regression: the PR / local-merge / deploy-watch step files, and n1-start's finish
    # gate (nothing has merged yet when finish-gate is false, so there is nothing to deploy),
    # are not touched.
    assert_eq "non-regression: 02-merge has no delivery logic" "0" "$(grep -c 'delivery' "$s/n1-finish/steps/02-merge.md" || true)"
    assert_eq "non-regression: 03-deploy has no delivery logic" "0" "$(grep -c 'delivery\.' "$s/n1-finish/steps/03-deploy.md" || true)"
    assert_eq "non-regression: n1-start finish gate has no delivery logic" "0" "$(grep -c 'delivery' "$s/n1-start/steps/finish.md" || true)"
}

# --- NP-240: multi-step wiring ---------------------------------------------------
test_wiring_multi_step() {
    local step="$REPO_ROOT/skills/n1-finish/steps/03b-ssh-deploy.md" ms
    ms=$(section "$step" '## Multi-step execute')
    assert_eq "multi-step wiring: execute branch forks on the shape" "yes" \
        "$(section "$step" '## Execute branch' | grep -qF 'n1_delivery_is_multi_step' && echo yes || echo no)"
    assert_eq "multi-step wiring: section exists" "yes" "$([ -n "$ms" ] && echo yes || echo no)"
    assert_eq "multi-step wiring: classifies with the helper" "yes" \
        "$(printf '%s' "$ms" | grep -qF 'n1_delivery_step <K>' && echo yes || echo no)"
    assert_eq "multi-step wiring: runs the extracted file, never re-typed text" "yes" \
        "$(printf '%s' "$ms" | grep -qF 'bash "$CMDF"' && echo yes || echo no)"
    assert_eq "multi-step wiring: shows the command with cat" "yes" \
        "$(printf '%s' "$ms" | grep -qF 'cat "$N1_HOME/memory/<ID>/deploy-step.cmd"' && echo yes || echo no)"
    assert_eq "multi-step wiring: per-step unconditional gate" "yes" \
        "$(printf '%s' "$ms" | grep -qF 'ask the user for every step' && echo yes || echo no)"
    assert_eq "multi-step wiring: runs in the merge-SHA checkout" "yes" \
        "$(printf '%s' "$ms" | grep -qF 'git worktree add -q --detach "$DEPLOY_DIR" "<SHA>"' && echo yes || echo no)"
    assert_eq "multi-step wiring: checkout is removed" "yes" \
        "$(printf '%s' "$ms" | grep -qF 'git worktree remove --force "${TMPDIR:-/tmp}/n1-deploy-<ID>"' && echo yes || echo no)"
    assert_eq "multi-step wiring: abort writes a remaining-steps runbook" "yes" \
        "$(printf '%s' "$ms" | grep -qF 'n1_delivery_runbook "<ID>" "<SHA>" <K>' && echo yes || echo no)"
    assert_eq "multi-step wiring: resume reads deploy_next_step" "yes" \
        "$(printf '%s' "$ms" | grep -qF 'deploy_next_step' && echo yes || echo no)"
    assert_eq "multi-step wiring: verify runs once" "yes" \
        "$(printf '%s' "$ms" | grep -qF 'bash -c "$VERIFY_CMD"' && echo yes || echo no)"
    assert_eq "multi-step wiring: failure comment keeps output local" "yes" \
        "$(printf '%s' "$ms" | grep -qF 'kept locally in N1 memory' && echo yes || echo no)"
    assert_eq "multi-step wiring: no command interpolation in comments" "0" \
        "$(printf '%s' "$ms" | grep -c '<command>' || true)"
    assert_eq "multi-step wiring: runbook branch forbids steps too" "yes" \
        "$(section "$step" '## Runbook branch' | grep -qF 'delivery.steps' && echo yes || echo no)"
    assert_eq "multi-step wiring: SKILL.md documents delivery.steps" "yes" \
        "$(grep -qF '.delivery.steps' "$REPO_ROOT/skills/n1-finish/SKILL.md" && echo yes || echo no)"
}

test_wiring
test_wiring_multi_step
test_action
test_action_no_jq
test_runbook_never_executes
test_multi_step_helpers
test_runbook_steps
test_gates_unchanged

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

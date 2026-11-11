#!/usr/bin/env bash
# Tests for NP-219 delivery mode: lib/config.sh helpers, negative execution,
# and skill wiring.
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
    assert_eq "action: PR project (prMode ready) -> none" "none" "$(action '{"git":{"prMode":"ready"}}')"
    assert_eq "action: prMode skip without delivery -> none" "none" \
        "$(action '{"git":{"prMode":"skip"}}')"
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
    printf '{"git":{"prMode":"ready"}}\n' > "$TEST_CONFIG"
    assert_eq "action: no delivery block + no jq -> none" "none" \
        "$(PATH="$nopath" n1_delivery_action)"
    rm -rf "$nopath"
}

# --- N1-531: delivery.skipPaths --------------------------------------------------
skip() { echo "$1" > "$TEST_CONFIG"; printf '%s' "$2" | n1_delivery_skip; }

test_skip() {
    local c='{"delivery":{"mode":"ssh","command":"true","skipPaths":["docs/","*.md"]}}'
    assert_eq "skip: every path matches -> skip" "skip" "$(skip "$c" $'docs/a.txt\nREADME.md\ndocs/sub/b.png')"
    assert_eq "skip: one non-matching path -> deliver" "deliver" "$(skip "$c" $'docs/a.txt\nsrc/app.sh')"
    assert_eq "skip: trailing / is a directory prefix only" "deliver" "$(skip "$c" 'docsx/a.txt')"
    assert_eq "skip: * crosses / (bash case semantics)" "skip" "$(skip "$c" 'src/templates/x.md')"
    assert_eq "skip: blank lines ignored" "skip" "$(skip "$c" $'\ndocs/a.txt\n\n')"
    assert_eq "skip: empty stdin -> deliver" "deliver" "$(skip "$c" '')"
    assert_eq "skip: no skipPaths key -> deliver" "deliver" "$(skip "$SSH_CFG" 'docs/a.txt')"
    assert_eq "skip: empty list -> deliver" "deliver" \
        "$(skip '{"delivery":{"mode":"ssh","skipPaths":[]}}' 'docs/a.txt')"
    assert_eq "skip: list of empty strings -> deliver" "deliver" \
        "$(skip '{"delivery":{"mode":"ssh","skipPaths":[""]}}' 'docs/a.txt')"
    assert_eq "skip: not an array -> deliver" "deliver" \
        "$(skip '{"delivery":{"mode":"ssh","skipPaths":"docs/"}}' 'docs/a.txt')"
    assert_eq "skip: malformed config -> deliver" "deliver" "$(skip '{not json' 'docs/a.txt')"
    assert_eq "skip: non-object delivery -> deliver" "deliver" "$(skip '{"delivery":"x"}' 'docs/a.txt')"
    assert_eq "skip: leading ./ in a glob is stripped" "skip" \
        "$(skip '{"delivery":{"mode":"ssh","skipPaths":["./docs/"]}}' 'docs/a.txt')"
}

test_skip_no_jq() {
    local nopath b real
    nopath=$(mktemp -d)
    for b in bash cat; do real=$(command -v "$b"); ln -s "$real" "$nopath/$b"; done
    echo '{"delivery":{"mode":"ssh","skipPaths":["docs/"]}}' > "$TEST_CONFIG"
    assert_eq "skip: no jq -> deliver" "deliver" "$(printf 'docs/a.txt' | PATH="$nopath" n1_delivery_skip)"
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

# --- N1-528: covered deploy_pending tickets ---------------------------------------
test_covered() {
    local repo="$TMP/cov-repo" home="$TMP/cov-home" a b x side out exp before after nf_before nf_after
    export GIT_CEILING_DIRECTORIES="$TMP"
    g() { git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
    git init -q -b main "$repo"
    g commit -q --allow-empty -m 'A [T-1] [T-8] [T-9] [T-7-old] bad.id T-130 [T-6]'; a=$(g rev-parse HEAD)
    g commit -q --allow-empty -m 'B (OWN) T-2 [T-4]'; b=$(g rev-parse HEAD)
    g commit -q --allow-empty -m 'X [T-10]'; x=$(g rev-parse HEAD)
    g checkout -q -b side "$a"
    g commit -q --allow-empty -m 'S [T-3]'; side=$(g rev-parse HEAD)
    g checkout -q main
    mk() {
        mkdir -p "$home/memory/$1"
        printf -- '---\nstep: done\ndeploy_pending: %s\ndeploy_merge_sha: %s\n---\n# %s\n' "$2" "$3" "$1" > "$home/memory/$1/overview.md"
    }
    mk OWN true "$b"                 # the owner ticket: excluded
    mk T-1 true "$a"                 # ancestor -> ok
    mk T-2 true "${b:0:7}"           # short SHA, ancestor -> ok
    mk T-3 true "$side"              # not an ancestor (side branch / force-push) -> skipped
    mk T-4 true deadbeefdeadbeef     # unknown SHA (another repo in a shared N1_HOME) -> skipped
    mk T-5 true 'abc;rm'             # malformed SHA -> skipped
    mk T-6 false "$a"                # not pending -> skipped
    mk T-7-old true "$a"             # archived dir -> skipped
    mk bad.id true "$a"              # ID outside [A-Za-z0-9_-] -> skipped
    mk T-8 true "$a"                 # unticked Deployment Actions -> actions
    printf '# R\n\n## Deployment Actions\n\n### After deploy\n\n- [ ] #1 restart worker\n' > "$home/memory/T-8/runbook.md"
    mk T-9 true "$a"                 # all actions ticked -> ok
    printf '# R\n\n## Deployment Actions\n\n### After deploy\n\n- [x] #1 restart worker\n\n## Notes\n\n- [ ] unrelated todo\n' > "$home/memory/T-9/runbook.md"
    mk T-10 true "$x"                # equal to X -> ok
    mk T-12 true "$a"                # commit does not name T-12 -> skipped (identity binding)
    mk T-13 true "$a"                # only T-130 is named -> skipped (boundary)
    mkdir -p "$home/memory/T-11"     # no overview.md -> skipped

    before=$(cat "$home"/memory/*/overview.md "$home"/memory/*/runbook.md | cksum)
    nf_before=$(find "$home" | wc -l)
    out=$(cd "$repo" && N1_HOME="$home" n1_delivery_covered "$x" OWN | LC_ALL=C sort)
    exp=$(printf '%s\n' "T-1 $a ok" "T-10 $x ok" "T-2 ${b:0:7} ok" "T-8 $a actions" "T-9 $a ok" | LC_ALL=C sort)
    assert_eq "covered: exact candidate set" "$exp" "$out"
    after=$(cat "$home"/memory/*/overview.md "$home"/memory/*/runbook.md | cksum)
    nf_after=$(find "$home" | wc -l)
    assert_eq "covered: pure (memory content unchanged)" "$before" "$after"
    assert_eq "covered: pure (no files created)" "$nf_before" "$nf_after"

    assert_eq "covered: own ID is listed when not excluded" "yes" \
        "$(grep -q '^OWN ' <<<"$(cd "$repo" && N1_HOME="$home" n1_delivery_covered "$x")" && echo yes || echo no)"
    assert_eq "covered: malformed X -> nothing" "" "$(cd "$repo" && N1_HOME="$home" n1_delivery_covered "$x;rm" OWN)"
    assert_eq "covered: unknown X -> nothing" "" \
        "$(cd "$repo" && N1_HOME="$home" n1_delivery_covered 0123456789abcdef0123 OWN)"
    assert_eq "covered: empty X -> nothing" "" "$(cd "$repo" && N1_HOME="$home" n1_delivery_covered '' OWN)"
    assert_eq "covered: outside a git repo -> nothing" "" "$(cd "$home" && N1_HOME="$home" n1_delivery_covered "$x" OWN)"
    assert_eq "covered: empty N1_HOME -> nothing" "" "$(cd "$repo" && N1_HOME='' n1_delivery_covered "$x" OWN)"
    assert_eq "covered: earlier X covers fewer tickets" "T-1 $a ok" \
        "$(cd "$repo" && N1_HOME="$home" n1_delivery_covered "$a" OWN | grep -v -e '^T-8 ' -e '^T-9 ')"
    unset GIT_CEILING_DIRECTORIES
}

test_finish_line_set() {
    local ov="$TMP/fls.md"
    printf -- '---\nstep: done\n---\n# T\n\n## Finish\n- **Merged:** abc\n- **Delivery:** pending (runbook: memory/T/runbook.md)\n- **Ticket:** left open (deploy pending)\n\n## Notes\nkeep\n' > "$ov"
    n1_finish_line_set "$ov" Delivery "succeeded (covered by OWN at 1234567)"
    assert_eq "finish-line: one Delivery line" "1" "$(grep -c '^- \*\*Delivery:\*\*' "$ov" || true)"
    assert_eq "finish-line: new value inside ## Finish" "yes" \
        "$(grep -qF -- '- **Delivery:** succeeded (covered by OWN at 1234567)' <<<"$(section "$ov" '## Finish')" && echo yes || echo no)"
    assert_eq "finish-line: other Finish lines kept" "yes" \
        "$(grep -qF -- '- **Merged:** abc' <<<"$(section "$ov" '## Finish')" && grep -qF -- '- **Ticket:** left open' "$ov" && echo yes || echo no)"
    assert_eq "finish-line: other sections kept" "keep" "$(section "$ov" '## Notes')"
    assert_eq "finish-line: frontmatter kept" "done" "$(n1_read_frontmatter "$ov" step)"
    n1_finish_line_set "$ov" Delivery "succeeded (covered by OWN at 1234567)"
    assert_eq "finish-line: idempotent re-run" "1" "$(grep -c '^- \*\*Delivery:\*\*' "$ov" || true)"
    printf -- '---\n---\n# T\n' > "$ov"
    n1_finish_line_set "$ov" Ticket "moved to Done"
    assert_eq "finish-line: appends ## Finish when absent" "- **Ticket:** moved to Done" "$(section "$ov" '## Finish')"
    assert_eq "finish-line: missing file -> rc 1" "1" \
        "$(n1_finish_line_set "$TMP/nope.md" Ticket x && echo 0 || echo 1)"
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

# --- Skill wiring ---------------------------------------------------------------
section() { awk -v h="$2" 'index($0, h) == 1 {f=1; next} /^## /{f=0} f' "$1"; }

test_wiring() {
    local s="$REPO_ROOT/skills" step="$REPO_ROOT/skills/n1-finish/steps/03b-ssh-deploy.md"
    local rb xb head4
    rb=$(section "$step" '## Runbook branch')
    xb=$(section "$step" '## Execute branch')
    assert_eq "wiring: delivery step exists" "yes" "$([ -f "$step" ] && echo yes || echo no)"
    assert_eq "wiring: step branches on n1_delivery_action" "yes" "$(grep -q 'n1_delivery_action' "$step" && echo yes || echo no)"
    assert_eq "wiring: runbook branch uses the helper" "yes" \
        "$(grep -q 'n1_delivery_runbook' <<<"$rb" && echo yes || echo no)"
    assert_eq "wiring: runbook branch never runs a command" "0" \
        "$(grep -c 'bash -c' <<<"$rb" || true)"
    assert_eq "wiring: execute branch runs the deploy" "yes" \
        "$(grep -qF 'bash -c "$DEPLOY_CMD"' <<<"$xb" && echo yes || echo no)"
    assert_eq "wiring: execute branch runs the verify" "yes" \
        "$(grep -qF 'bash -c "$VERIFY_CMD"' <<<"$xb" && echo yes || echo no)"
    # Both commands run from a detached checkout of the merge SHA, never the current dir.
    assert_eq "wiring: deploy checks out the merge SHA" "yes" \
        "$(grep -qF 'git worktree add -q --detach "$DEPLOY_DIR" "<SHA>"' <<<"$xb" && echo yes || echo no)"
    assert_eq "wiring: deploy and verify both run in the checkout" "2" \
        "$(grep -c 'OUT=$(cd .*n1-deploy\|OUT=$(cd "$DEPLOY_DIR"' <<<"$xb" || true)"
    assert_eq "wiring: deploy checkout is removed" "yes" \
        "$(grep -qF 'git worktree remove --force "${TMPDIR:-/tmp}/n1-deploy-<ID>"' <<<"$xb" && echo yes || echo no)"
    # Step 6's Finish rewrite and report carry the delivery outcome instead of dropping it.
    assert_eq "wiring: cleanup Finish template has a Delivery line" "yes" \
        "$(grep -qF -- '- **Delivery:** <pending (runbook: memory/<ID>/runbook.md)' "$s/n1-finish/steps/06-cleanup.md" && echo yes || echo no)"
    assert_eq "wiring: cleanup report has a Delivery line" "yes" \
        "$(grep -q '^Delivery: <pending' "$s/n1-finish/steps/06-cleanup.md" && echo yes || echo no)"
    assert_eq "wiring: delivery step writes the Delivery line, not Deploy" "0" \
        "$(grep -c '\*\*Deploy:\*\*' "$step" || true)"
    assert_eq "wiring: execute branch asks first" "yes" \
        "$(grep -q 'Ask the user' <<<"$xb" && echo yes || echo no)"
    head4=$(sed -n '1,6p' "$s/n1-finish/steps/04-close-ticket.md")
    assert_eq "wiring: Step 4 enters the delivery step first" "yes" \
        "$(grep -qF '03b-ssh-deploy.md' <<<"$head4" && echo yes || echo no)"
    local succ
    succ=$(grep -F -- '- **Delivery:** succeeded (' "$step")
    assert_eq "wiring: delivery step has two success exits" "2" "$(grep -c . <<<"$succ")"
    assert_eq "wiring: each success exit continues through Step 6" "2" \
        "$(grep -F 'continue with its After-deploy actions and ticket close, then Step 5 and Step 6' <<<"$succ" | grep -cF 'incomplete until Step 6 runs' || true)"
    assert_eq "wiring: Step 4 gate says delivery success continues in the same run" "yes" \
        "$(grep -qF 'a successful delivery continues with the rest of Step 4' <<<"$head4" && echo yes || echo no)"
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
    assert_eq "init: asks for repo-only skipPaths" "yes" "$(grep -qF '"skipPaths": [' "$init" && echo yes || echo no)"
    assert_eq "init: reconfiguration shows skipPaths" "yes" "$(grep -qF 'skipPaths     →' "$init" && echo yes || echo no)"
    assert_eq "docs: architecture documents skipPaths" "yes" \
        "$(grep -qF 'delivery.skipPaths' "$REPO_ROOT/references/architecture.md" && echo yes || echo no)"
    # SEC-1/SEC-2: failure/pending tracker comments never carry command text or raw output.
    assert_eq "wiring: deploy-failed comment has no command interpolation" "0" \
        "$(grep -c '<command>' <<<"$xb" || true)"
    assert_eq "wiring: deploy-failed comment says output kept locally" "yes" \
        "$(grep -qF 'kept locally in N1 memory' <<<"$xb" && echo yes || echo no)"
    assert_eq "wiring: pending comment has no command interpolation" "yes" \
        "$(grep -qF 'runbook in N1 memory' <<<"$rb" && echo yes || echo no)"
    assert_eq "wiring: runbook branch never posts runbook content" "yes" \
        "$(grep -qF 'Never post the runbook content' <<<"$rb" && echo yes || echo no)"
    assert_eq "wiring: failed-deploy path also updates overview Finish line" "yes" \
        "$(grep -qF 'Runbook branch steps 1 and 3' <<<"$xb" && echo yes || echo no)"
    # SEC-5: resume trusts deploy_merge_sha only after regex + ancestor validation.
    assert_eq "wiring: resume validates SHA format" "yes" \
        "$(grep -qF '^[0-9a-f]{7,40}$' "$s/n1-finish/steps/01-resolve-target.md" && echo yes || echo no)"
    assert_eq "wiring: resume validates SHA is an ancestor of the default branch" "yes" \
        "$(grep -qF 'merge-base --is-ancestor' "$s/n1-finish/steps/01-resolve-target.md" && echo yes || echo no)"
    # N1-531: repo-only skip gate.
    local sk
    sk=$(section "$step" '## Repo-only skip')
    assert_eq "skip wiring: gate calls n1_delivery_skip" "yes" \
        "$(grep -qF 'n1_delivery_skip' "$step" && echo yes || echo no)"
    assert_eq "skip wiring: file list is the paginated PR files API" "yes" \
        "$(grep -qF 'pulls/$PR/files" --paginate' "$step" && echo yes || echo no)"
    assert_eq "skip wiring: completeness check against changed_files (3000 cap)" "yes" \
        "$(grep -qF '.changed_files' "$step" && grep -qF -- '-ge 3000' "$step" && grep -qF -- '-ne "$TOTAL"' "$step" && echo yes || echo no)"
    assert_eq "skip wiring: renamed files also check the previous path" "yes" \
        "$(grep -qF 'previous_filename' "$step" && echo yes || echo no)"
    assert_eq "skip wiring: section exists" "yes" "$([ -n "$sk" ] && echo yes || echo no)"
    assert_eq "skip wiring: writes the not-needed Delivery line" "yes" \
        "$(grep -qF -- '- **Delivery:** not needed (repo-only paths)' <<<"$sk" && echo yes || echo no)"
    assert_eq "skip wiring: never writes a runbook" "0" \
        "$(grep -c 'n1_delivery_runbook "' <<<"$sk" || true)"
    assert_eq "skip wiring: clears a stale deploy_pending" "yes" \
        "$(grep -qF 'deploy_pending false' <<<"$sk" && echo yes || echo no)"
    assert_eq "skip wiring: returns to Step 4 to close the ticket" "yes" \
        "$(grep -qF 'Return to Step 4 and continue with its After-deploy actions and ticket close' <<<"$sk" && echo yes || echo no)"
    assert_eq "skip wiring: both Step 6 Delivery grammars list not needed" "2" \
        "$(grep -cF 'not needed (repo-only paths)' "$s/n1-finish/steps/06-cleanup.md" || true)"

    # Non-regression: the PR / local-merge / deploy-watch step files and n1-start's finish step are not touched.
    assert_eq "non-regression: 02-merge has no delivery logic" "0" "$(grep -c 'delivery' "$s/n1-finish/steps/02-merge.md" || true)"
    assert_eq "non-regression: 03-deploy has no delivery logic" "0" "$(grep -c 'delivery\.' "$s/n1-finish/steps/03-deploy.md" || true)"
    assert_eq "non-regression: n1-start finish gate has no delivery logic" "0" "$(grep -c 'delivery' "$s/n1-start/steps/finish.md" || true)"
}

# --- N1-528: covered-close wiring ------------------------------------------------
test_wiring_covered() {
    local s="$REPO_ROOT/skills" cc="$REPO_ROOT/skills/n1-finish/references/covered-close.md"
    local c4="$REPO_ROOT/skills/n1-finish/steps/04-close-ticket.md" c6="$REPO_ROOT/skills/n1-finish/steps/06-cleanup.md"
    local lr lt
    assert_eq "covered wiring: reference exists" "yes" "$([ -f "$cc" ] && echo yes || echo no)"
    assert_eq "covered wiring: Step 4 points at covered-close.md" "yes" \
        "$(grep -qF 'skills/n1-finish/references/covered-close.md' "$c4" && echo yes || echo no)"
    assert_eq "covered wiring: Step 4 runs it only after a succeeded delivery" "yes" \
        "$(grep -qF 'recorded `- **Delivery:** succeeded (`' "$c4" && echo yes || echo no)"
    assert_eq "covered wiring: scan uses the helper with own ID excluded" "yes" \
        "$(grep -qF 'n1_delivery_covered "$X" "$ID"' "$cc" && echo yes || echo no)"
    assert_eq "covered wiring: batch prompt skipped only under fullAuto" "yes" \
        "$(grep -qF 'n1_fullauto_enabled' "$cc" && echo yes || echo no)"
    assert_eq "covered wiring: skipped delivery steps disable the auto close" "yes" \
        "$(grep -qF 'skipped steps' "$cc" && echo yes || echo no)"
    assert_eq "covered wiring: unticked actions are never closed" "yes" \
        "$(grep -qF 'never closed' "$cc" && echo yes || echo no)"
    assert_eq "covered wiring: records the covered Delivery value" "yes" \
        "$(grep -qF 'n1_finish_line_set "$OV" Delivery "succeeded (covered by $ID at $X)"' "$cc" && echo yes || echo no)"
    assert_eq "covered wiring: clears deploy_pending and the pending marker" "yes" \
        "$(grep -qF 'deploy_pending false' "$cc" && grep -qF 'n1_pending_clear "$OV"' "$cc" && echo yes || echo no)"
    lr=$(grep -n -m1 -F 'n1_finish_line_set "$OV" Delivery' "$cc" | cut -d: -f1 || true)
    lt=$(grep -n -m1 -F 'moveStatus' "$cc" | cut -d: -f1 || true)
    assert_eq "covered wiring: local record precedes the tracker close" "yes" \
        "$([ -n "$lr" ] && [ -n "$lt" ] && [ "$lr" -lt "$lt" ] && echo yes || echo no)"
    assert_eq "covered wiring: tracker failure never blocks" "yes" \
        "$(grep -qF 'warn, never block' "$cc" && echo yes || echo no)"
    assert_eq "covered wiring: never deploys or runs Step 5/6 for covered tickets" "yes" \
        "$(grep -qF 'Never run a deploy, Step 5 or Step 6 for a covered ticket' "$cc" && echo yes || echo no)"
    assert_eq "covered wiring: both Step 6 Delivery grammars list covered" "2" \
        "$(grep -cF 'succeeded (covered by <owner ID> at <sha>)' "$c6" || true)"
    assert_eq "covered wiring: mode:runbook exit runs the covered close" "yes" \
        "$(grep -qF 'including the `mode:runbook` exit' "$c4" && grep -qF 'covered-tickets paragraph' "$c4" && echo yes || echo no)"
    assert_eq "covered wiring: Step 6 Report has a Covered line" "yes" \
        "$(grep -q '^Covered: <' "$c6" && echo yes || echo no)"
    assert_eq "covered wiring: 03b untouched (no covered text)" "0" \
        "$(grep -c 'covered by' "$s/n1-finish/steps/03b-ssh-deploy.md" || true)"
    assert_eq "docs: architecture documents the covered close" "yes" \
        "$(grep -qF 'n1_delivery_covered' "$REPO_ROOT/references/architecture.md" && echo yes || echo no)"
}

# --- NP-240: multi-step wiring ---------------------------------------------------
test_wiring_multi_step() {
    local step="$REPO_ROOT/skills/n1-finish/steps/03b-ssh-deploy.md" ms xb rb
    ms=$(section "$step" '## Multi-step execute')
    xb=$(section "$step" '## Execute branch')
    rb=$(section "$step" '## Runbook branch')
    assert_eq "multi-step wiring: execute branch forks on the shape" "yes" \
        "$(grep -qF 'n1_delivery_is_multi_step' <<<"$xb" && echo yes || echo no)"
    assert_eq "multi-step wiring: section exists" "yes" "$([ -n "$ms" ] && echo yes || echo no)"
    assert_eq "multi-step wiring: classifies with the helper" "yes" \
        "$(grep -qF 'n1_delivery_step <K>' <<<"$ms" && echo yes || echo no)"
    assert_eq "multi-step wiring: runs the extracted file, never re-typed text" "yes" \
        "$(grep -qF 'bash "$CMDF"' <<<"$ms" && echo yes || echo no)"
    assert_eq "multi-step wiring: shows the command with cat" "yes" \
        "$(grep -qF 'cat "$N1_HOME/memory/<ID>/deploy-step.cmd"' <<<"$ms" && echo yes || echo no)"
    assert_eq "multi-step wiring: per-step unconditional gate" "yes" \
        "$(grep -qF 'ask the user for every step' <<<"$ms" && echo yes || echo no)"
    assert_eq "multi-step wiring: runs in the merge-SHA checkout" "yes" \
        "$(grep -qF 'git worktree add -q --detach "$DEPLOY_DIR" "<SHA>"' <<<"$ms" && echo yes || echo no)"
    assert_eq "multi-step wiring: checkout is removed" "yes" \
        "$(grep -qF 'git worktree remove --force "${TMPDIR:-/tmp}/n1-deploy-<ID>"' <<<"$ms" && echo yes || echo no)"
    assert_eq "multi-step wiring: abort writes a remaining-steps runbook" "yes" \
        "$(grep -qF 'n1_delivery_runbook "<ID>" "<SHA>" <K>' <<<"$ms" && echo yes || echo no)"
    assert_eq "multi-step wiring: resume reads deploy_next_step" "yes" \
        "$(grep -qF 'deploy_next_step' <<<"$ms" && echo yes || echo no)"
    assert_eq "multi-step wiring: verify runs once" "yes" \
        "$(grep -qF 'bash -c "$VERIFY_CMD"' <<<"$ms" && echo yes || echo no)"
    assert_eq "multi-step wiring: failure comment keeps output local" "yes" \
        "$(grep -qF 'kept locally in N1 memory' <<<"$ms" && echo yes || echo no)"
    assert_eq "multi-step wiring: no command interpolation in comments" "0" \
        "$(grep -c '<command>' <<<"$ms" || true)"
    assert_eq "multi-step wiring: runbook branch forbids steps too" "yes" \
        "$(grep -qF 'delivery.steps' <<<"$rb" && echo yes || echo no)"
    assert_eq "multi-step wiring: SKILL.md documents delivery.steps" "yes" \
        "$(grep -qF '.delivery.steps' "$REPO_ROOT/skills/n1-finish/SKILL.md" && echo yes || echo no)"
}

test_wiring
test_wiring_multi_step
test_wiring_covered
test_action
test_action_no_jq
test_skip
test_skip_no_jq
test_runbook_never_executes
test_multi_step_helpers
test_runbook_steps
test_covered
test_finish_line_set

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

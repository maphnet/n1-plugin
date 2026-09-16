#!/usr/bin/env bash
# Tests for n1_resolve_model and the models prune snippet.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label (expected=$expected actual=$actual)"
        FAIL=$((FAIL+1))
    fi
}

# ---------------------------------------------------------------------------
# Shared setup: export CLAUDE_PLUGIN_ROOT so agents/*.md and pipeline.json
# are found by n1_resolve_model.
# ---------------------------------------------------------------------------
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
# Ensure N1_HOME and ID are always bound (set -u safety).
: "${N1_HOME:=}"
: "${ID:=}"
export N1_HOME ID

# Source config.sh (which may lazily source signals.sh as needed).
# shellcheck source=../lib/config.sh
source "${REPO_ROOT}/lib/config.sh"

# ---------------------------------------------------------------------------
# Test (a): resolver returns sonnet with empty models block
# ---------------------------------------------------------------------------
test_a() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    # Write a config with an empty models object.
    cat > "${tmpdir}/config.json" <<'JSON'
{
  "models": {}
}
JSON

    # Override n1_config_file to point at our temp config.
    # N1_HOME and ID must be unset so no signal-memory path is constructed.
    local saved_n1_home="${N1_HOME:-}"
    local saved_id="${ID:-}"
    # Set to empty (not unset) — avoids set -u errors in n1_resolve_model.
    export N1_HOME=""
    export ID=""

    local TEST_CONFIG="${tmpdir}/config.json"
    n1_config_file() { echo "$TEST_CONFIG"; }

    local result
    result=$(n1_resolve_model developer implementation) || true

    # Restore
    n1_config_file() { echo "$(n1_home)/config.json"; }
    [ -n "$saved_n1_home" ] && export N1_HOME="$saved_n1_home" || export N1_HOME=""
    [ -n "$saved_id"      ] && export ID="$saved_id"      || export ID=""

    assert_eq "resolver returns sonnet with empty models" "sonnet" "$result"
}

# ---------------------------------------------------------------------------
# Test (b): resolver returns opus when blast_radius=high signal present
# ---------------------------------------------------------------------------
test_b() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    # Config with empty models.
    cat > "${tmpdir}/config.json" <<'JSON'
{
  "models": {}
}
JSON

    # Memory directory for ticket TEST-1
    local mem_dir="${tmpdir}/memory/TEST-1"
    mkdir -p "$mem_dir"

    # analysis.md with blast_radius=high in the n1:signals block.
    cat > "${mem_dir}/analysis.md" <<'MD'
# Analysis

<!-- n1:signals
blast_radius: high
-->
MD

    local saved_n1_home="${N1_HOME:-}"
    local saved_id="${ID:-}"
    export N1_HOME="$tmpdir"
    export ID="TEST-1"

    local TEST_CONFIG="${tmpdir}/config.json"
    n1_config_file() { echo "$TEST_CONFIG"; }

    local result
    result=$(n1_resolve_model developer implementation) || true

    # Restore
    n1_config_file() { echo "$(n1_home)/config.json"; }
    [ -n "$saved_n1_home" ] && export N1_HOME="$saved_n1_home" || export N1_HOME=""
    [ -n "$saved_id"      ] && export ID="$saved_id"      || export ID=""

    assert_eq "resolver returns opus on escalation signal" "opus" "$result"
}

# ---------------------------------------------------------------------------
# Test (c): prune snippet removes only equal-to-default entries
# ---------------------------------------------------------------------------
test_c() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local CFG="${tmpdir}/config.json"
    cat > "$CFG" <<'JSON'
{
  "models": {
    "developer": "sonnet",
    "code-reviewer": "opus",
    "solution-architect": "haiku"
  }
}
JSON

    # Run the prune snippet (from task-1 spec) against the real repo agents.
    local pruned_output
    pruned_output=$(
        for f in "${CLAUDE_PLUGIN_ROOT}"/agents/*.md; do
            a=$(basename "$f" .md)
            def=$(awk 'NR==1&&/^---$/{x=1;next} x&&/^---$/{exit} x&&/^model:/{sub(/^model:[ \t]*/,"");gsub(/\r/,"");print;exit}' "$f")
            cur=$(jq -r ".models[\"$a\"] // empty" "$CFG")
            if [ -n "$cur" ] && [ "$cur" = "$def" ]; then
                jq "del(.models[\"$a\"])" "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
                echo "pruned models.$a=$cur (equals frontmatter default)"
            fi
        done
    )

    # developer (sonnet) and code-reviewer (opus) match defaults → pruned.
    # solution-architect (haiku) differs from default opus → kept.
    local dev_val reviewer_val architect_val
    dev_val=$(jq -r '.models.developer // empty' "$CFG")
    reviewer_val=$(jq -r '."models"["code-reviewer"] // empty' "$CFG")
    architect_val=$(jq -r '."models"["solution-architect"] // empty' "$CFG")

    assert_eq "prune removes developer=sonnet (matches default)" "" "$dev_val"
    assert_eq "prune removes code-reviewer=opus (matches default)" "" "$reviewer_val"
    assert_eq "prune keeps solution-architect=haiku (differs from default opus)" "haiku" "$architect_val"

    # Confirm prune lines appeared in output.
    local pruned_dev pruned_reviewer
    pruned_dev=$(echo "$pruned_output" | grep -c "pruned models.developer=sonnet" || true)
    pruned_reviewer=$(echo "$pruned_output" | grep -c "pruned models.code-reviewer=opus" || true)
    assert_eq "prune emitted log for developer" "1" "$pruned_dev"
    assert_eq "prune emitted log for code-reviewer" "1" "$pruned_reviewer"
}

test_autonomy_preset() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
    cat > "${tmpdir}/config.json" <<'JSON'
{ "autonomy": { "brainstorm": "interactive", "qualityEscalations": "block", "tailChain": "suggest", "acceptanceGate": "ask" },
  "planReview": { "requirePlanApproval": true } }
JSON
    local TEST_CONFIG="${tmpdir}/config.json"
    n1_config_file() { echo "$TEST_CONFIG"; }

    unset N1_AUTONOMY_PRESET
    assert_eq "preset off: brainstorm from config" "interactive" "$(n1_autonomy_val brainstorm)"
    assert_eq "preset off: plan approval from config" "true" "$(n1_plan_approval_required)"

    export N1_AUTONOMY_PRESET=autonomous
    assert_eq "preset: brainstorm" "auto" "$(n1_autonomy_val brainstorm)"
    assert_eq "preset: mechanicalPrompts" "auto" "$(n1_autonomy_val mechanicalPrompts)"
    assert_eq "preset: qualityEscalations" "auto-accept" "$(n1_autonomy_val qualityEscalations)"
    assert_eq "preset: tailChain" "suggest" "$(n1_autonomy_val tailChain)"
    assert_eq "preset: acceptanceGate" "auto" "$(n1_autonomy_val acceptanceGate)"
    assert_eq "preset: escalationMargin" "0.05" "$(n1_autonomy_val escalationMargin)"
    assert_eq "preset: plan approval forced false" "false" "$(n1_plan_approval_required)"
    unset N1_AUTONOMY_PRESET
    unset -f n1_config_file
}

# ---------------------------------------------------------------------------
# Test (d): analysis downgrade covers every ticket the lite-analysis gate
# accepts. The gate fires on tier=simple + quality in {adequate,weak} +
# type in {task,chore}, and its design assumes the architect is downgraded on
# all of them. `chore` is downgraded by types.chore.step_overrides and
# `adequate` by the downgrade trigger, which left simple+task+weak running at
# the frontier base model with the narrowest scope directive.
# ---------------------------------------------------------------------------
test_d() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    cat > "${tmpdir}/config.json" <<'JSON'
{
  "models": {}
}
JSON

    local saved_n1_home="${N1_HOME:-}"
    local saved_id="${ID:-}"
    local TEST_CONFIG="${tmpdir}/config.json"
    n1_config_file() { echo "$TEST_CONFIG"; }

    # $1=label $2=tier $3=type $4=description_quality $5=expected model
    _case() {
        local mem_dir="${tmpdir}/memory/$1"
        mkdir -p "$mem_dir"
        printf -- '---\ntier: %s\ntype: %s\n---\n' "$2" "$3" > "${mem_dir}/overview.md"
        printf '<!-- n1:signals description_quality=%s -->\n' "$4" > "${mem_dir}/ticket.md"
        export N1_HOME="$tmpdir"
        export ID="$1"
        local result
        result=$(n1_resolve_model solution-architect analysis) || true
        assert_eq "analysis model: tier=$2 type=$3 quality=$4" "$5" "$result"
    }

    _case LITE-1 simple   task  adequate sonnet
    _case LITE-2 simple   chore weak     sonnet
    _case LITE-3 simple   task  weak     sonnet

    # Guardrails: the widened trigger must not downgrade tickets the gate
    # rejects. A weak description on a non-simple ticket, or on an
    # investigation, still needs the frontier architect.
    _case KEEP-1 complex  task  weak     opus
    _case KEEP-2 standard task  weak     opus

    unset -f _case
    n1_config_file() { echo "$(n1_home)/config.json"; }
    [ -n "$saved_n1_home" ] && export N1_HOME="$saved_n1_home" || export N1_HOME=""
    [ -n "$saved_id"      ] && export ID="$saved_id"      || export ID=""
}

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------
test_a
test_b
test_c
test_d
test_autonomy_preset

# ---------------------------------------------------------------------------
# Host-keyed models object (3.0.0)
# ---------------------------------------------------------------------------
test_host_models() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    export N1_HOME="$tmpdir/home"; mkdir -p "$N1_HOME"
    export CODEX_HOME="$tmpdir/codex"; mkdir -p "$CODEX_HOME"
    printf '[agents]\ndefault_subagent_model = "gpt-5.6-terra"\ndefault_subagent_reasoning_effort = "medium"\n' > "$CODEX_HOME/config.toml"
    cat > "$N1_HOME/config.json" <<'CFG'
{"models": {
  "code-reviewer": {"claude-code": "opus", "codex": "gpt-5.6"},
  "developer": "sonnet",
  "qa-engineer": {"codex": {"model": "gpt-5.6-sol", "reasoning_effort": "high"}}
}}
CFG
    assert_eq "object form: claude value" "opus" "$(N1_HOST=claude-code n1_model_for code-reviewer)"
    assert_eq "object form: codex value" "gpt-5.6" "$(N1_HOST=codex n1_model_for code-reviewer)"
    assert_eq "object form: resolve_model returns codex value not JSON" "gpt-5.6" "$(N1_HOST=codex n1_resolve_model code-reviewer)"
    assert_eq "legacy string applies on claude" "sonnet" "$(N1_HOST=claude-code n1_model_for developer)"
    assert_eq "legacy string ignored on codex -> codex default" "gpt-5.6-terra" "$(N1_HOST=codex n1_model_for developer)"
    assert_eq "no entry on claude -> frontmatter" "opus" "$(N1_HOST=claude-code n1_model_for security-reviewer)"
    assert_eq "no entry on codex -> translated known role" "gpt-5.6-sol" "$(N1_HOST=codex n1_model_for security-reviewer)"
    assert_eq "nested codex model" "gpt-5.6-sol" "$(N1_HOST=codex n1_model_for qa-engineer)"
    assert_eq "nested codex effort" "high" "$(N1_HOST=codex n1_reasoning_effort_for qa-engineer)"
    assert_eq "default codex effort" "medium" "$(N1_HOST=codex n1_reasoning_effort_for developer)"
    assert_eq "effort empty on claude" "" "$(N1_HOST=claude-code n1_reasoning_effort_for qa-engineer)"
    unset CODEX_HOME
}
# Restore n1_config_file that test_autonomy_preset unset.
n1_config_file() { printf '%s' "$(n1_home)/config.json"; }
test_host_models

# ---------------------------------------------------------------------------
# Tier-aware Codex routing. These cases exercise the real resolver in isolated
# N1/Codex homes so host defaults cannot leak between cases.
# ---------------------------------------------------------------------------
codex_case() {
    # $1 label, $2 config JSON, $3 TOML, $4 persona, $5 context, $6 Astra context,
    # $7 expected model, $8 expected effort, $9 expected stderr substring
    local label="$1" config="$2" toml="$3" persona="$4" context="$5" astra="$6"
    local expected_model="$7" expected_effort="$8" expected_err="$9" tmp result err
    tmp=$(mktemp -d)
    mkdir -p "$tmp/home" "$tmp/codex"
    printf '%s\n' "$config" > "$tmp/home/config.json"
    printf '%b\n' "$toml" > "$tmp/codex/config.toml"
    result=$(N1_HOST=codex N1_HOME="$tmp/home" ID=CASE CODEX_HOME="$tmp/codex" \
        n1_resolve_agent "$persona" "$context" "$astra" 2>"$tmp/err") || true
    err=$(<"$tmp/err")
    rm -rf "$tmp"
    assert_eq "$label combined record" "$expected_model"$'\t'"$expected_effort" "$result"
    assert_eq "$label model" "$expected_model" "${result%%$'\t'*}"
    assert_eq "$label effort" "$expected_effort" "${result#*$'\t'}"
    if [ -n "$expected_err" ]; then
        case "$err" in *"$expected_err"*) assert_eq "$label warning" "$expected_err" "$expected_err";; *) assert_eq "$label warning" "$expected_err" "$err";; esac
    else
        assert_eq "$label has no warning" "" "$err"
    fi
}

codex_runtime_case() {
    # $1 label $2 config $3 TOML $4 persona $5 context $6 overview $7 analysis
    # $8 implementation $9 expected model ${10} expected effort
    local label="$1" config="$2" toml="$3" persona="$4" context="$5" overview="$6" analysis="$7" implementation="$8"
    local expected_model="$9" expected_effort="${10}" tmp record err
    tmp=$(mktemp -d)
    mkdir -p "$tmp/home/memory/CASE" "$tmp/codex"
    printf '%s\n' "$config" > "$tmp/home/config.json"
    printf '%b\n' "$toml" > "$tmp/codex/config.toml"
    printf '%b\n' "$overview" > "$tmp/home/memory/CASE/overview.md"
    [ -z "$analysis" ] || printf '%b\n' "$analysis" > "$tmp/home/memory/CASE/analysis.md"
    [ -z "$implementation" ] || printf '%b\n' "$implementation" > "$tmp/home/memory/CASE/implementation.md"
    record=$(N1_HOST=codex N1_HOME="$tmp/home" ID=CASE CODEX_HOME="$tmp/codex" n1_resolve_agent "$persona" "$context" 2>"$tmp/err") || true
    err=$(<"$tmp/err")
    rm -rf "$tmp"
    assert_eq "$label combined record" "$expected_model"$'\t'"$expected_effort" "$record"
    assert_eq "$label has no warning" "" "$err"
}

test_codex_runtime_precedence() {
    local empty='{"models":{}}' defaults='[agents]\ndefault_subagent_model = "flat-default"\ndefault_subagent_reasoning_effort = "medium"'
    assert_eq "Opus downgrade translates to Terra" gpt-5.6-terra "$(N1_HOST=codex n1_translate_model codex "$(n1_resolve_tier downgrade opus)")"
    assert_eq "Sonnet downgrade translates to Luna" gpt-5.6-luna "$(N1_HOST=codex n1_translate_model codex "$(n1_resolve_tier downgrade sonnet)")"
    codex_runtime_case "high blast escalation" "$empty" "$defaults" developer implementation '---\ntype: task\n---' '<!-- n1:signals\nblast_radius: high\n-->' '' gpt-5.6-sol medium
    codex_runtime_case "escalation beats downgrade" "$empty" "$defaults" code-reviewer review '---\ntype: chore\n---' '<!-- n1:signals\nsecurity_relevant: true\nblast_radius: low\n-->' '<!-- n1:signals\nlines_changed: 1\n-->' gpt-5.6-sol medium
    codex_runtime_case "type override runs without signal" "$empty" "$defaults" code-reviewer review '---\ntype: chore\n---' '' '' gpt-5.6-terra medium
}

test_n1_model_for_astra_policy() {
    local tmp model err
    tmp=$(mktemp -d)
    mkdir -p "$tmp/home" "$tmp/codex"
    printf '%s\n' '{"models":{"developer":{"codex":"gpt-6-astra"}}}' > "$tmp/home/config.json"
    model=$(N1_HOST=codex N1_HOME="$tmp/home" ID=CASE CODEX_HOME="$tmp/codex" n1_model_for developer 2>"$tmp/err") || true
    err=$(<"$tmp/err")
    rm -rf "$tmp"
    assert_eq "n1_model_for rejects context-free Astra" "gpt-5.6-terra" "$model"
    case "$err" in *"ineligible gpt-6-astra override"*) assert_eq "n1_model_for warns on rejected Astra" present present;; *) assert_eq "n1_model_for warns on rejected Astra" present "$err";; esac
}

test_astra_cycles_and_missing_defaults() {
    local tmp record err cycle model
    tmp=$(mktemp -d)
    mkdir -p "$tmp/home/memory/CASE" "$tmp/codex"
    record=$(N1_HOST=codex N1_HOME="$tmp/home" ID=CASE CODEX_HOME="$tmp/codex" n1_resolve_agent planner 2>"$tmp/err") || true
    assert_eq "missing config and defaults use known mapping" $'gpt-5.6-sol\tmedium' "$record"
    assert_eq "missing config and defaults have no warning" "" "$(<"$tmp/err")"
    printf '%s\n' '{"models":{"developer":{"codex":"gpt-6-astra"}}}' > "$tmp/home/config.json"
    for cycle in 0 1 2; do
        printf -- '---\nreview_fix_cycle: %s\n---\n' "$cycle" > "$tmp/home/memory/CASE/overview.md"
        model=$(N1_HOST=codex N1_HOME="$tmp/home" ID=CASE CODEX_HOME="$tmp/codex" n1_resolve_model developer fix failed-fix-escalation 2>"$tmp/err") || true
        err=$(<"$tmp/err")
        if [ "$cycle" -lt 2 ]; then
            assert_eq "failed-fix cycle $cycle falls back" gpt-5.6-terra "$model"
            case "$err" in *"ineligible gpt-6-astra override"*) assert_eq "failed-fix cycle $cycle warns" present present;; *) assert_eq "failed-fix cycle $cycle warns" present "$err";; esac
        else
            assert_eq "failed-fix cycle 2 accepts Astra" gpt-6-astra "$model"
            assert_eq "failed-fix cycle 2 has no warning" "" "$err"
        fi
    done
    printf '%s\n' '{"models":{}}' > "$tmp/home/config.json"
    model=$(N1_HOST=codex N1_HOME="$tmp/home" ID=CASE CODEX_HOME="$tmp/codex" n1_resolve_model developer review final-whole-branch-review 2>"$tmp/err") || true
    assert_eq "eligibility alone does not select Astra" gpt-5.6-terra "$model"
    assert_eq "eligibility alone has no warning" "" "$(<"$tmp/err")"
    rm -rf "$tmp"
}

test_tier_aware_codex() {
    local empty='{"models":{}}' defaults='[agents]\ndefault_subagent_model = "gpt-5.6-terra"\ndefault_subagent_reasoning_effort = "medium"'
    codex_case "Opus baseline" "$empty" "$defaults" planner "" "" gpt-5.6-sol medium ""
    codex_case "architect Opus baseline" "$empty" "$defaults" solution-architect "" "" gpt-5.6-sol medium ""
    codex_case "reviewer Opus baseline" "$empty" "$defaults" code-reviewer "" "" gpt-5.6-sol medium ""
    codex_case "Sonnet baseline" "$empty" "$defaults" developer "" "" gpt-5.6-terra medium ""
    codex_case "QA Sonnet baseline" "$empty" "$defaults" qa-engineer "" "" gpt-5.6-terra medium ""
    codex_case "Sonnet low frontmatter clamps" "$empty" '[agents]\ndefault_subagent_model = "gpt-5.6-terra"' product-analyst "" "" gpt-5.6-terra medium "below policy floor 'medium'"
    assert_eq "minimal tier translates to Luna" "gpt-5.6-luna" "$(N1_HOST=codex n1_translate_model codex "$(n1_resolve_tier minimal sonnet)")"
    codex_case "non-Astra override" '{"models":{"developer":{"codex":{"model":"custom-model","reasoning_effort":"high"}}}}' "$defaults" developer implementation "" custom-model high ""
    codex_case "explicit low clamps" '{"models":{"developer":{"codex":{"reasoning_effort":"low"}}}}' "$defaults" developer "" "" gpt-5.6-terra medium "below policy floor 'medium'"
    codex_case "global low clamps" "$empty" '[agents]\ndefault_subagent_model = "flat-default"\ndefault_subagent_reasoning_effort = "low"' developer "" "" gpt-5.6-terra medium "below policy floor 'medium'"
    codex_case "global high remains high" "$empty" '[agents]\ndefault_subagent_model = "flat-default"\ndefault_subagent_reasoning_effort = "high"' developer "" "" gpt-5.6-terra high ""
    codex_case "unknown effort clamps" '{"models":{"developer":{"codex":{"reasoning_effort":"odd"}}}}' "$defaults" developer "" "" gpt-5.6-terra medium "unsupported Codex effort 'odd'"
    codex_case "ineligible Astra falls back" '{"models":{"developer":{"codex":"gpt-6-astra"}}}' "$defaults" developer "" "" gpt-5.6-terra medium "ineligible gpt-6-astra override"
    codex_case "unknown Astra context falls back" '{"models":{"developer":{"codex":"gpt-6-astra"}}}' "$defaults" developer review unknown-context gpt-5.6-terra medium "ineligible gpt-6-astra override"
    codex_case "eligible final review retains Astra" '{"models":{"developer":{"codex":"gpt-6-astra"}}}' "$defaults" developer review final-whole-branch-review gpt-6-astra medium ""
    codex_case "eligible architecture retains Astra" '{"models":{"developer":{"codex":"gpt-6-astra"}}}' "$defaults" developer brainstorm architecture-adjudication gpt-6-astra medium ""
    codex_case "unknown role uses CLI default" "$empty" "$defaults" no-such-persona "" "" gpt-5.6-terra medium ""
}
test_tier_aware_codex
test_codex_runtime_precedence
test_n1_model_for_astra_policy
test_astra_cycles_and_missing_defaults

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

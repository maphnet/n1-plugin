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
    "code-reviewer": "sonnet",
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

    # developer (sonnet) and code-reviewer (sonnet) match defaults → pruned.
    # solution-architect (haiku) differs from default sonnet → kept.
    local dev_val reviewer_val architect_val
    dev_val=$(jq -r '.models.developer // empty' "$CFG")
    reviewer_val=$(jq -r '."models"["code-reviewer"] // empty' "$CFG")
    architect_val=$(jq -r '."models"["solution-architect"] // empty' "$CFG")

    assert_eq "prune removes developer=sonnet (matches default)" "" "$dev_val"
    assert_eq "prune removes code-reviewer=sonnet (matches default)" "" "$reviewer_val"
    assert_eq "prune keeps solution-architect=haiku (differs from default sonnet)" "haiku" "$architect_val"

    # Confirm prune lines appeared in output.
    local pruned_dev pruned_reviewer
    pruned_dev=$(echo "$pruned_output" | grep -c "pruned models.developer=sonnet" || true)
    pruned_reviewer=$(echo "$pruned_output" | grep -c "pruned models.code-reviewer=sonnet" || true)
    assert_eq "prune emitted log for developer" "1" "$pruned_dev"
    assert_eq "prune emitted log for code-reviewer" "1" "$pruned_reviewer"
}

test_plan_approval_headless() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
    echo '{ "planReview": { "requirePlanApproval": true } }' > "${tmpdir}/config.json"
    local TEST_CONFIG="${tmpdir}/config.json" rc saved="${N1_HEADLESS-__unset__}"
    n1_config_file() { echo "$TEST_CONFIG"; }

    unset N1_HEADLESS
    assert_eq "attended: plan approval from config" "true" "$(n1_plan_approval_required)"
    if n1_plan_approval_required >/dev/null; then rc=0; else rc=1; fi
    assert_eq "attended: plan approval true exits 0" "0" "$rc"
    echo '{ "planReview": { "requirePlanApproval": false } }' > "${tmpdir}/off.json"
    TEST_CONFIG="${tmpdir}/off.json"
    if n1_plan_approval_required >/dev/null; then rc=0; else rc=1; fi
    assert_eq "plan approval false exits nonzero" "1" "$rc"
    TEST_CONFIG="${tmpdir}/config.json"

    export N1_HEADLESS=1
    assert_eq "headless: plan approval forced false" "false" "$(n1_plan_approval_required)"
    if n1_plan_approval_required >/dev/null; then rc=0; else rc=1; fi
    assert_eq "headless: plan approval exits nonzero" "1" "$rc"

    if [ "$saved" = "__unset__" ]; then unset N1_HEADLESS; else export N1_HEADLESS="$saved"; fi
    unset -f n1_config_file
}

# ---------------------------------------------------------------------------
# Test (d): SA baseline is sonnet — all analysis cases resolve to sonnet.
# Downgrade triggers for SA were removed (sonnet is already the target tier).
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
    _case KEEP-1 complex  task  weak     sonnet
    _case KEEP-2 standard task  weak     sonnet

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
test_plan_approval_headless

# Restore n1_config_file that test_plan_approval_headless unset.
n1_config_file() { printf '%s' "$(n1_home)/config.json"; }

# ---------------------------------------------------------------------------
# Test (e): legacy host-keyed object back-compat — reads the "claude-code" key.
# ---------------------------------------------------------------------------
test_e() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    cat > "${tmpdir}/config.json" <<'JSON'
{"models":{"developer":{"claude-code":"opus","codex":"gpt-5.6-sol"}}}
JSON

    local saved_n1_home="${N1_HOME:-}" saved_id="${ID:-}"
    export N1_HOME="" ID=""
    local TEST_CONFIG="${tmpdir}/config.json"
    n1_config_file() { echo "$TEST_CONFIG"; }

    local result
    result=$(n1_resolve_model developer) || true

    n1_config_file() { echo "$(n1_home)/config.json"; }
    [ -n "$saved_n1_home" ] && export N1_HOME="$saved_n1_home" || export N1_HOME=""
    [ -n "$saved_id"      ] && export ID="$saved_id"      || export ID=""

    assert_eq "legacy host-keyed object reads claude-code key" "opus" "$result"
}
test_e

# ---------------------------------------------------------------------------
# Test (f): n1_resolve_agent always prints "<model>\t" (empty effort column).
# ---------------------------------------------------------------------------
test_f() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    cat > "${tmpdir}/config.json" <<'JSON'
{"models":{}}
JSON

    local saved_n1_home="${N1_HOME:-}" saved_id="${ID:-}"
    export N1_HOME="" ID=""
    local TEST_CONFIG="${tmpdir}/config.json"
    n1_config_file() { echo "$TEST_CONFIG"; }

    local out
    out=$(n1_resolve_agent developer implementation)

    n1_config_file() { echo "$(n1_home)/config.json"; }
    [ -n "$saved_n1_home" ] && export N1_HOME="$saved_n1_home" || export N1_HOME=""
    [ -n "$saved_id"      ] && export ID="$saved_id"      || export ID=""

    assert_eq "resolve_agent model+tab matches resolve_model+tab" "$(n1_resolve_model developer implementation)"$'\t' "$out"
    assert_eq "resolve_agent output has two tab-separated fields" "2" "$(printf '%s' "$out" | awk -F'\t' '{print NF}')"
    assert_eq "resolve_agent effort column is empty" "" "$(printf '%s' "$out" | cut -f2)"
}
test_f

# ---------------------------------------------------------------------------
# Test (g): N1-469 — no planner:plan downgrade trigger; planner routing ignores design_clarity.
# ---------------------------------------------------------------------------
test_g() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    echo '{"models":{}}' > "${tmpdir}/config.json"
    local saved_n1_home="${N1_HOME:-}" saved_id="${ID:-}"
    local TEST_CONFIG="${tmpdir}/config.json"
    n1_config_file() { echo "$TEST_CONFIG"; }

    assert_eq "pipeline.json has no planner:plan downgrade trigger" "" \
        "$(jq -r '.downgrade_triggers["planner:plan"] // empty' "${REPO_ROOT}/pipeline.json")"

    export N1_HOME="" ID=""
    local base
    base=$(n1_resolve_model planner plan) || true

    local mem_dir="${tmpdir}/memory/PLAN-1"
    mkdir -p "$mem_dir"
    cat > "${mem_dir}/brainstorm.md" <<'MD'
# Design

<!-- n1:signals
design_clarity: high
files_changed: 2
-->
MD
    export N1_HOME="$tmpdir" ID="PLAN-1"
    local with_signals
    with_signals=$(n1_resolve_model planner plan) || true

    n1_config_file() { echo "$(n1_home)/config.json"; }
    [ -n "$saved_n1_home" ] && export N1_HOME="$saved_n1_home" || export N1_HOME=""
    [ -n "$saved_id"      ] && export ID="$saved_id"      || export ID=""

    assert_eq "planner:plan baseline is the persona model" "opus" "$base"
    assert_eq "planner:plan with design_clarity=high equals baseline" "$base" "$with_signals"
}
test_g

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

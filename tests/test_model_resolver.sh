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
    result=$(n1_resolve_model developer implementation)

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
    result=$(n1_resolve_model developer implementation)

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

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------
test_a
test_b
test_c

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

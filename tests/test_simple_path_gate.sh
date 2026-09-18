#!/usr/bin/env bash
# tests/test_simple_path_gate.sh
# Verifies the simple-path gate added in NP-111:
#   1. The condition JSON embedded in analysis.md is valid JSON
#   2. Truth table via n1_eval_signal_gate (condition-based)
#   3. The bash predicate in analysis.md matches the same truth table
#   4. n1_record_decision records simple-path events with correct signals
#   5. context.sh persists and restores SIMPLE_PATH
#   6. SKILL.md contains the simple-path routing row
#   7. output-gates.md documents the simple-path Pipeline: line
#   8. telemetry.md documents the simple-path decision id
#   9. pipeline.json signal_routing entry is valid
#
# Run: bash tests/test_simple_path_gate.sh
# Expected: all tests PASS; exit 0.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANALYSIS="$REPO_ROOT/skills/n1-start/steps/analysis.md"
SKILL="$REPO_ROOT/skills/n1-start/SKILL.md"
GATES="$REPO_ROOT/skills/n1-start/procedures/output-gates.md"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected=[$2] actual=[$3])"; fi
}
assert_contains() {
    if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (missing in $2: $3)"; fi
}

source "$REPO_ROOT/lib/signals.sh"
source "$REPO_ROOT/lib/telemetry.sh"
source "$REPO_ROOT/lib/context.sh"

# ---------------------------------------------------------------------------
# T1: extract condition JSON from analysis.md
# ---------------------------------------------------------------------------
COND=$(grep -m1 'n1_record_decision simple-path' "$ANALYSIS" | sed "s/.*'\({.*}\)'.*/\1/")

if [ -n "$COND" ] && echo "$COND" | jq -e . >/dev/null 2>&1; then
    pass "T1: condition JSON extracted from analysis.md and is valid JSON"
else
    fail "T1: could not extract a single-line condition JSON from $ANALYSIS"
    echo; echo "Passed: $PASS  Failed: $FAIL"; exit 1
fi

# ---------------------------------------------------------------------------
# T2-T14: truth table via n1_eval_signal_gate
# ---------------------------------------------------------------------------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export N1_HOME="$T/home"
export ID="SP-1"
MEM="$N1_HOME/memory/$ID"
mkdir -p "$MEM/telemetry"

fixture() {
    local tier="$1" type="$2" blast="$3" files="$4" security="$5" root_cause="$6"
    printf -- '---\ntier: %s\ntype: %s\n---\n' "$tier" "$type" > "$MEM/overview.md"
    local sigs="blast_radius=$blast files_changed=$files security_relevant=$security"
    [ -n "$root_cause" ] && sigs="$sigs has_bug_root_cause=$root_cause"
    printf '<!-- n1:signals %s -->\n' "$sigs" > "$MEM/analysis.md"
}

check() {
    local label="$1" tier="$2" type="$3" blast="$4" files="$5" security="$6" root_cause="$7" expected="$8" actual
    fixture "$tier" "$type" "$blast" "$files" "$security" "$root_cause"
    if n1_eval_signal_gate "$MEM" "$MEM/overview.md" "$COND"; then actual=true; else actual=false; fi
    assert_eq "$label" "$expected" "$actual"
}

check "T2: simple task low 2 false fires"             simple  task  low  2 false ""     true
check "T3: simple chore low 1 false fires"            simple  chore low  1 false ""     true
check "T4: simple bug low 2 false true fires"         simple  bug   low  2 false true   true
check "T5: simple bug low 2 false no-root never fires" simple bug   low  2 false ""    false
check "T6: simple bug low 2 false false never fires"  simple  bug   low  2 false false  false
check "T7: security_relevant=true blocks"             simple  task  low  2 true  ""     false
check "T8: blast_radius=medium blocks"                simple  task  medium 2 false ""   false
check "T9: files_changed=3 blocks (not <3)"           simple  task  low  3 false ""     false
check "T10: standard tier never fires"                standard task low  2 false ""     false
check "T11: complex tier never fires"                 complex task  low  2 false ""     false
check "T12: investigation never fires"                simple  investigation low 1 false "" false
check "T13: files_changed=2 is within limit"          simple  task  low  2 false ""     true
check "T14: files_changed=0 fires"                    simple  task  low  0 false ""     true

# ---------------------------------------------------------------------------
# T15-T17: telemetry recording
# ---------------------------------------------------------------------------
fixture simple task low 2 false ""
export N1_HOST=claude-code N1_SESSION_ID=test-session
echo '{"run_id":"run-sp","n1_version":"3.4.0","host":"claude-code","session_id":"test-session"}' > "$MEM/telemetry/telemetry.lock"
n1_record_decision simple-path true "$COND" "tier=simple" "type=task" "blast=low" "files_changed=2" "security_relevant=false" "has_bug_root_cause="

LINE=$(tail -1 "$MEM/telemetry/raw/steps/run-sp.jsonl" 2>/dev/null)
assert_eq "T15: event type"    "decision"    "$(echo "$LINE" | jq -r .event)"
assert_eq "T16: decision id"   "simple-path" "$(echo "$LINE" | jq -r .id)"
assert_eq "T17: result true"   "true"        "$(echo "$LINE" | jq -r .result)"

# ---------------------------------------------------------------------------
# T18-T21: context.sh persists and restores SIMPLE_PATH
# ---------------------------------------------------------------------------
export N1_HOME="$T/ctx"
export ID="CTX-1"
mkdir -p "$T/ctx/memory/CTX-1"

TIER="simple" TYPE="task" DESC_QUALITY="adequate" LITE_MODE=false SIMPLE_PATH=true
n1_write_context
CTX_FILE="$T/ctx/memory/CTX-1/ticket-context.sh"

assert_contains "T18: context file has SIMPLE_PATH" "$CTX_FILE" 'SIMPLE_PATH='

# Reset and read back
SIMPLE_PATH=false
n1_read_context
assert_eq "T19: n1_read_context restores SIMPLE_PATH=true" "true" "$SIMPLE_PATH"

TIER="" TYPE="" DESC_QUALITY="" LITE_MODE=false SIMPLE_PATH=false
n1_write_context
n1_read_context
assert_eq "T20: n1_read_context restores SIMPLE_PATH=false" "false" "$SIMPLE_PATH"

# Absent context file is a no-op
export ID="CTX-MISSING"
mkdir -p "$T/ctx/memory/CTX-MISSING"
SIMPLE_PATH=sentinel
n1_read_context
assert_eq "T21: missing context file leaves SIMPLE_PATH unchanged" "sentinel" "$SIMPLE_PATH"

# ---------------------------------------------------------------------------
# T22: bash predicate is present in analysis.md
# ---------------------------------------------------------------------------
PRED=$(grep -m1 'SIMPLE_PATH=true' "$ANALYSIS")
if [ -n "$PRED" ]; then
    pass "T22: SIMPLE_PATH=true assignment is present in analysis.md"
else
    fail "T22: SIMPLE_PATH=true assignment missing from analysis.md"
fi

# ---------------------------------------------------------------------------
# T23-T25: bash predicate truth table (inline execution)
# ---------------------------------------------------------------------------
INIT_LINE=$(grep -m1 'SIMPLE_PATH=false' "$ANALYSIS")
COND_LINES=$(grep -A7 'SIMPLE_PATH=false' "$ANALYSIS" | grep -v '^--$' | head -8)

run_pred() {
    local tier="$1" type="$2" blast="$3" files="$4" security="$5" root_cause="$6"
    (
        TIER="$tier" TYPE="$type" BLAST="$blast" FILES_CHANGED_A="$files"
        SECURITY="$security" HAS_ROOT_CAUSE="$root_cause"
        SIMPLE_PATH=false
        if [ "$TIER" = "simple" ] && [ "$BLAST" = "low" ] && [ "${FILES_CHANGED_A:-999}" -lt 3 ] && [ "$SECURITY" != "true" ]; then
            if [ "$TYPE" = "task" ] || [ "$TYPE" = "chore" ] || { [ "$TYPE" = "bug" ] && [ "$HAS_ROOT_CAUSE" = "true" ]; }; then
                SIMPLE_PATH=true
            fi
        fi
        echo "$SIMPLE_PATH"
    )
}

assert_eq "T23: predicate simple task low 2 false"    "true"  "$(run_pred simple task  low 2 false "")"
assert_eq "T24: predicate simple bug low 2 false true" "true" "$(run_pred simple bug   low 2 false true)"
assert_eq "T25: predicate security blocks"            "false" "$(run_pred simple task  low 2 true  "")"
assert_eq "T26: predicate blast=medium blocks"        "false" "$(run_pred simple task  medium 2 false "")"
assert_eq "T27: predicate files=3 blocks"             "false" "$(run_pred simple task  low 3 false "")"
assert_eq "T28: predicate standard tier blocks"       "false" "$(run_pred standard task low 2 false "")"
assert_eq "T29: predicate chore fires"                "true"  "$(run_pred simple chore low 1 false "")"

# ---------------------------------------------------------------------------
# T30: SKILL.md has simple-path routing row
# ---------------------------------------------------------------------------
assert_contains "T30: SKILL.md has simple-path routing row" "$SKILL" "Simple-Path Routing"
assert_contains "T31: SKILL.md notes brainstorm is skipped on simple-path" "$SKILL" "skipped on simple-path"

# ---------------------------------------------------------------------------
# T32: output-gates.md documents simple-path pipeline
# ---------------------------------------------------------------------------
assert_contains "T32: output-gates.md documents simple-path pipeline" "$GATES" "simple-path"

# ---------------------------------------------------------------------------
# T33: telemetry.md documents the simple-path decision id
# ---------------------------------------------------------------------------
assert_contains "T33: telemetry.md documents simple-path decision id" \
    "$REPO_ROOT/references/telemetry.md" "simple-path"

# ---------------------------------------------------------------------------
# T34: pipeline.json signal_routing entry is valid JSON and has correct fields
# ---------------------------------------------------------------------------
SP_ENTRY=$(jq -r '.signal_routing[] | select(.name == "simple_path")' "$REPO_ROOT/pipeline.json" 2>/dev/null)
if [ -n "$SP_ENTRY" ]; then
    pass "T34: pipeline.json has signal_routing entry for simple_path"
else
    fail "T34: pipeline.json missing signal_routing entry for simple_path"
fi

SKIPS=$(echo "$SP_ENTRY" | jq -r '.skips | sort | join(",")' 2>/dev/null)
assert_eq "T35: simple_path skips brainstorm,plan,plan-review" "brainstorm,plan,plan-review" "$SKIPS"

DID=$(echo "$SP_ENTRY" | jq -r '.decision_id' 2>/dev/null)
assert_eq "T36: decision_id is simple-path" "simple-path" "$DID"

# ---------------------------------------------------------------------------
# T37: analysis.md calls n1_write_context after SIMPLE_PATH assignment
# ---------------------------------------------------------------------------
assert_contains "T37: analysis.md calls n1_write_context after gate" "$ANALYSIS" "n1_write_context"

# ---------------------------------------------------------------------------
# T38: analysis.md surfaces simple-path in Gate 1 prose
# ---------------------------------------------------------------------------
assert_contains "T38: analysis.md surfaces simple-path in Gate 1 prose" "$ANALYSIS" "Simple-path: skipping brainstorm and plan"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]

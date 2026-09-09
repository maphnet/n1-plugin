#!/usr/bin/env bash
# tests/test_lite_analysis_gate.sh
# Verifies the Lite-Analysis Gate in skills/n1-start/steps/analysis.md:
#   1. the telemetry condition JSON embedded in the skill evaluates to the
#      documented truth table under n1_eval_signal_gate
#   2. n1_record_decision snapshots the referenced signal
#   3. the skill contains the suppression sentinels the gate depends on
#   4. the executable Bash predicate that assigns LITE_MODE (all three copies)
#      is drift-free and matches the same truth table
#
# Run: bash tests/test_lite_analysis_gate.sh
# Expected: all tests PASS; exit 0.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/skills/n1-start/steps/analysis.md"
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

# ---------------------------------------------------------------------------
# Extract the condition JSON from the skill file. It must be on one line,
# matching the simplicity-gate precedent in implementation.md.
# ---------------------------------------------------------------------------
COND=$(grep -A1 -F 'n1_record_decision lite-analysis-gate' "$SKILL" | grep -o '{.*}' | head -1)

if [ -n "$COND" ] && echo "$COND" | jq -e . >/dev/null 2>&1; then
    pass "T1: condition JSON extracted from skill and is valid JSON"
else
    fail "T1: could not extract a single-line condition JSON from $SKILL"
    echo; echo "Passed: $PASS  Failed: $FAIL"; exit 1
fi

# ---------------------------------------------------------------------------
# Truth table. Fixture memory dir with overview.md frontmatter + ticket.md signals.
# ---------------------------------------------------------------------------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export N1_HOME="$T/home"
export ID="T-1"
MEM="$N1_HOME/memory/$ID"
mkdir -p "$MEM/telemetry"

fixture() {
    printf -- '---\ntier: %s\ntype: %s\n---\n' "$1" "$2" > "$MEM/overview.md"
    if [ "$3" = "__none__" ]; then
        printf 'no signal block here\n' > "$MEM/ticket.md"
    else
        printf '<!-- n1:signals description_quality=%s -->\n' "$3" > "$MEM/ticket.md"
    fi
}

check() {
    local label="$1" tier="$2" type="$3" quality="$4" expected="$5" actual
    fixture "$tier" "$type" "$quality"
    if n1_eval_signal_gate "$MEM" "$MEM/overview.md" "$COND"; then actual=true; else actual=false; fi
    assert_eq "$label (tier=$tier type=$type quality=$quality)" "$expected" "$actual"
}

check "T2: simple task adequate fires"        simple  task          adequate  true
check "T3: simple chore weak fires"           simple  chore         weak      true
check "T4: simple chore adequate fires"       simple  chore         adequate  true
check "T5: bug never fires"                   simple  bug           adequate  false
check "T6: investigation never fires"         simple  investigation adequate  false
check "T7: skeletal never fires"              simple  task          skeletal  false
check "T8: empty never fires"                 simple  task          empty     false
check "T9: standard tier never fires"         standard task         adequate  false
check "T10: complex tier never fires"         complex task          adequate  false
check "T11: absent quality signal never fires" simple task          __none__  false

# Missing ticket.md entirely must also be false, not a crash.
fixture simple task adequate
rm -f "$MEM/ticket.md"
if n1_eval_signal_gate "$MEM" "$MEM/overview.md" "$COND"; then r=true; else r=false; fi
assert_eq "T12: missing ticket.md never fires" "false" "$r"

# ---------------------------------------------------------------------------
# Telemetry: the condition's signal reference is snapshotted into the event.
# ---------------------------------------------------------------------------
fixture simple task adequate
echo '{"run_id":"run-lite","n1_version":"2.100.0"}' > "$MEM/telemetry/telemetry.lock"
n1_record_decision lite-analysis-gate true "$COND" "tier=simple" "type=task" "quality=adequate"

LINE=$(tail -1 "$MEM/telemetry/raw/steps/run-lite.jsonl" 2>/dev/null)
assert_eq "T13: event type"        "decision"           "$(echo "$LINE" | jq -r .event)"
assert_eq "T14: decision id"       "lite-analysis-gate" "$(echo "$LINE" | jq -r .id)"
assert_eq "T15: result"            "true"               "$(echo "$LINE" | jq -r .result)"
assert_eq "T16: signal snapshotted" "adequate"          "$(echo "$LINE" | jq -r '.signals["ticket.description_quality"]')"
assert_eq "T17: tier kv separate"  "simple"             "$(echo "$LINE" | jq -r '.signals.tier')"
assert_eq "T18: type kv separate"  "task"               "$(echo "$LINE" | jq -r '.signals.type')"
assert_eq "T19: quality kv separate" "adequate"         "$(echo "$LINE" | jq -r '.signals.quality')"

# ---------------------------------------------------------------------------
# Sentinels: the gate's suppression points must exist in the skill.
# ---------------------------------------------------------------------------
assert_contains "T20: gate heading" "$SKILL" "**Lite-Analysis Gate:**"

# The string `if [ "$RELATED_ENABLED" = "true" ]; then` occurs TWICE in the skill:
# once in the related-projects block (must become lite-aware) and once in the
# cross-repo telemetry block at the end (must stay as-is). Pin both counts so a
# patch applied to the wrong occurrence fails loudly.
GUARDED=$(grep -cF 'if [ "$RELATED_ENABLED" = "true" ] && [ "$LITE_MODE" != "true" ]; then' "$SKILL")
UNGUARDED=$(grep -cF 'if [ "$RELATED_ENABLED" = "true" ]; then' "$SKILL")
assert_eq "T21: related-projects guard is lite-aware (exactly 1)" "1" "$GUARDED"
assert_eq "T22: cross-repo telemetry guard untouched (exactly 1)" "1" "$UNGUARDED"
assert_contains "T23: lite scope directive exists" "$SKILL" \
    "**Lite scope directive (when \`LITE_MODE\` is \`true\`):**"
assert_contains "T24: lite escape-hatch directive exists" "$SKILL" \
    "**Lite escape-hatch directive (when \`LITE_MODE\` is \`true\`):**"
assert_contains "T25: standards research gated off in lite" "$SKILL" \
    "**When \`LITE_MODE\` is \`false\`:** Directive: \"Research relevant industry standards"
assert_contains "T26: snapshot persistence gated off in lite" "$SKILL" \
    "When \`CACHE_ENABLED\` is \`true\` AND \`LITE_MODE\` is \`false\`"
assert_contains "T27: project map gated off in lite" "$SKILL" \
    "AND \`CACHE_ENABLED\` is \`true\` AND \`LITE_MODE\` is \`false\`"
assert_contains "T28: observability skipped in lite" "$SKILL" \
    "Skip this entire block when \`LITE_MODE\` is \`true\`"
assert_contains "T29: LITE_ESCALATED parsed" "$SKILL" \
    "grep -m1 '^LITE_ESCALATED:'"
assert_contains "T30: no re-run on escalation" "$SKILL" \
    "Do NOT re-run analysis."
assert_contains "T31: output contract preserved in lite" "$SKILL" \
    "Your Output Contract is UNCHANGED"
assert_contains "T32: project-map verification skipped in lite" "$SKILL" \
    'if [ "$CACHE_STATE" != "fresh" ] && [ "$CACHE_ENABLED" = "true" ] && [ "$LITE_MODE" != "true" ]; then'
assert_contains "T33: LITE_MODE re-derived in project-map verification block" "$SKILL" \
    "# Re-derived for project-map verification: LITE_MODE was set in a different Bash invocation."
assert_contains "T34: fresh path applies the lite directives" "$SKILL" \
    "**When \`LITE_MODE\` is \`true\`, also apply the lite scope directive and the lite escape-hatch directive from shared spawn directives.**"
assert_contains "T35: fresh-path web-research bullet omitted in lite" "$SKILL" \
    "(Omit this bullet from the prompt entirely when \`LITE_MODE\` is \`true\`"
assert_contains "T36: lite ban is proactive-only, unknown resolution keeps WebSearch" "$SKILL" \
    "You MAY still use WebSearch to resolve a specific unknown before escalating it to the user"
assert_contains "T37: snapshot post-return verification is lite-aware" "$SKILL" \
    "AND \`\$CACHE_ENABLED\` is \`true\` AND \`LITE_MODE\` is \`false\`"
assert_contains "T38: Tier Assessment section is never optional in lite" "$SKILL" \
    "The \`### Tier Assessment\` section is never optional"

# ---------------------------------------------------------------------------
# The executable predicate itself. T2-T12 above exercise the *descriptive*
# telemetry condition JSON; the Bash `if` that actually assigns LITE_MODE is a
# separate artifact, duplicated three times in the skill. Extract every copy,
# prove they have not drifted apart, and run each against the same truth table.
# ---------------------------------------------------------------------------
PRED_DIR="$T/preds"
mkdir -p "$PRED_DIR"
awk -v dir="$PRED_DIR" '
    /^LITE_MODE=false$/ { n++; collecting = 1 }
    collecting { print > (dir "/pred" n ".sh") }
    collecting && /^fi$/ { collecting = 0 }
' "$SKILL"

PRED_COUNT=$(ls "$PRED_DIR" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T39: three LITE_MODE predicate copies extracted from skill" "3" "$PRED_COUNT"

if [ "$PRED_COUNT" != "3" ]; then
    echo; echo "Passed: $PASS  Failed: $FAIL"; exit 1
fi

# (a) The three copies must be byte-identical -- they must never drift.
for i in 2 3; do
    if cmp -s "$PRED_DIR/pred1.sh" "$PRED_DIR/pred$i.sh"; then
        pass "T40.$i: predicate copy $i is byte-identical to copy 1"
    else
        fail "T40.$i: predicate copy $i drifted from copy 1"
        diff "$PRED_DIR/pred1.sh" "$PRED_DIR/pred$i.sh" || true
    fi
done

# (b) Evaluate each extracted predicate against the truth table.
run_pred() {
    local pred
    pred=$(cat "$1")
    (
        TIER="$2"; TYPE="$3"; DESC_QUALITY="$4"
        eval "$pred"
        echo "$LITE_MODE"
    )
}

check_pred() {
    local file="$1" idx="$2" tier="$3" type="$4" quality="$5" expected="$6" actual
    actual=$(run_pred "$file" "$tier" "$type" "$quality")
    assert_eq "T41.$idx: predicate copy $idx (tier=$tier type=$type quality=${quality:-<empty>})" \
        "$expected" "$actual"
}

for i in 1 2 3; do
    P="$PRED_DIR/pred$i.sh"
    check_pred "$P" "$i" simple   task  adequate true
    check_pred "$P" "$i" simple   chore weak     true
    check_pred "$P" "$i" simple   task  weak     true
    check_pred "$P" "$i" simple   bug   adequate false
    check_pred "$P" "$i" simple   task  skeletal false
    check_pred "$P" "$i" standard task  adequate false
    check_pred "$P" "$i" simple   task  ""       false
done

# ---------------------------------------------------------------------------
# T42: the decision id must be discoverable in the telemetry reference, which
# enumerates the ids step files record explicitly.
# ---------------------------------------------------------------------------
assert_contains "T42: telemetry.md documents the lite-analysis-gate decision id" \
    "$REPO_ROOT/references/telemetry.md" "lite-analysis-gate"

# ---------------------------------------------------------------------------
# Post-return verification blocks execute in their own Bash invocation, so
# every variable they branch on must be re-derived inside the block. A block
# that reads an unset CACHE_ENABLED / CACHE_STATE / PROJECT_MAP_PATH /
# SNAPSHOT_PATH silently takes the wrong branch -- either suppressing a real
# failure report or emitting a false one. Extract each block and RUN it
# against a real fixture rather than grepping for the variable names.
# ---------------------------------------------------------------------------
extract_block() {
    awk -v marker="$1" '
        index($0, marker) { found = 1 }
        found && !collecting && /^```bash$/ { collecting = 1; next }
        collecting && /^```$/ { exit }
        collecting { print }
    ' "$SKILL"
}

# Fixture: a populated N1_HOME with the cache enabled and a non-lite ticket.
PR_HOME="$T/postreturn"
PR_MEM="$PR_HOME/memory/PR-1"
mkdir -p "$PR_MEM" "$PR_HOME/cache"
printf '{"analysisCache":{"enabled":true}}\n' > "$PR_HOME/config.json"
printf -- '---\ntier: standard\ntype: task\n---\n' > "$PR_MEM/overview.md"
printf '<!-- n1:signals description_quality=adequate -->\n' > "$PR_MEM/ticket.md"

run_block() {
    # $1 = extracted block, $2 = ID to run under
    local block="$1"
    (
        # The orchestrator runs these blocks in a plain shell, not under
        # `set -u`. Emulate that: an unset variable must expand to empty and
        # take a branch, not abort -- that is the failure mode under test.
        set +u
        export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
        export N1_HOME="$PR_HOME"
        export ID="$2"
        eval "$block"
    ) 2>&1
}

MAP_BLOCK=$(extract_block 'Post-return verification — project map')
SNAP_BLOCK=$(extract_block 'Post-return verification — snapshot')

# (a) Cold cache, non-lite, project map absent -> the failure must be reported.
#     Before re-derivation this printed nothing, because an unset CACHE_ENABLED
#     made the guard false and silently skipped the check.
rm -f "$PR_HOME/cache/project-map.md"
OUT=$(run_block "$MAP_BLOCK" "PR-1")
case "$OUT" in
    *"Project map persistence failed"*) pass "T43: project-map check fires on a non-lite cold run" ;;
    *) fail "T43: project-map check did not fire on a non-lite cold run (output=[$OUT])" ;;
esac

# (b) Same fixture but a lite ticket -> must stay silent.
PR_LITE="$PR_HOME/memory/PR-2"
mkdir -p "$PR_LITE"
printf -- '---\ntier: simple\ntype: task\n---\n' > "$PR_LITE/overview.md"
printf '<!-- n1:signals description_quality=adequate -->\n' > "$PR_LITE/ticket.md"
OUT=$(run_block "$MAP_BLOCK" "PR-2")
case "$OUT" in
    *"Project map persistence failed"*) fail "T44: project-map check fired on a lite run (output=[$OUT])" ;;
    *) pass "T44: project-map check stays silent on a lite run" ;;
esac

# (c) Snapshot present and non-empty -> no failure may be reported. Before
#     re-derivation SNAPSHOT_PATH was empty, so [ ! -f "" ] was always true and
#     every run logged a phantom persistence failure into ## Key Decisions.
printf '# snapshot\ncontent\n' > "$PR_HOME/cache/project-snapshot.md"
OUT=$(run_block "$SNAP_BLOCK" "PR-1")
case "$OUT" in
    *"Snapshot persistence failed"*) fail "T45: phantom snapshot failure reported although the snapshot exists (output=[$OUT])" ;;
    *) pass "T45: no snapshot failure reported when the snapshot exists" ;;
esac

# (d) Snapshot genuinely missing -> the failure must still be reported.
rm -f "$PR_HOME/cache/project-snapshot.md"
OUT=$(run_block "$SNAP_BLOCK" "PR-1")
case "$OUT" in
    *"Snapshot persistence failed"*) pass "T46: snapshot check still fires when the snapshot is missing" ;;
    *) fail "T46: snapshot check did not fire on a missing snapshot (output=[$OUT])" ;;
esac

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]

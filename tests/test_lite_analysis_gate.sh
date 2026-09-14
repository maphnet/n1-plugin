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
# After NP-110 compression the verbose directive headings were condensed into
# inline prose; each assertion now checks the compressed form.
# ---------------------------------------------------------------------------
# T20: gate result is acknowledged in prose (replaces verbose heading)
assert_contains "T20: gate result logged in prose" "$SKILL" '`LITE_MODE=true`: log'

# The string `if [ "$RELATED_ENABLED" = "true" ]; then` occurs TWICE in the skill:
# once in the related-projects block (must become lite-aware) and once in the
# cross-repo telemetry block at the end (must stay as-is). Pin both counts so a
# patch applied to the wrong occurrence fails loudly.
GUARDED=$(grep -cF 'if [ "$RELATED_ENABLED" = "true" ] && [ "$LITE_MODE" != "true" ]; then' "$SKILL")
UNGUARDED=$(grep -cF 'if [ "$RELATED_ENABLED" = "true" ]; then' "$SKILL")
assert_eq "T21: related-projects guard is lite-aware (exactly 1)" "1" "$GUARDED"
assert_eq "T22: cross-repo telemetry guard untouched (exactly 1)" "1" "$UNGUARDED"
# T23: lite scope directive in compressed spawn SA prose
assert_contains "T23: lite scope directive exists" "$SKILL" \
    "lite→touched files+callers"
# T24: lite escape-hatch in compressed spawn SA prose
assert_contains "T24: lite escape-hatch directive exists" "$SKILL" \
    '`LITE_ESCALATED:<reason>` if'
# T25: non-lite path gates research-standards access
assert_contains "T25: standards research gated off in lite" "$SKILL" \
    "Cold/stale+cache+non-lite"
# T26: LITE_MODE guard present in bash project-map one-liner
assert_contains "T26: project map one-liner is lite-aware" "$SKILL" \
    '[ "$LITE_MODE" != "true" ] && { [ ! -f "$PROJECT_MAP_PATH" ]'
# T27 removed: covered by T26 and T32 (same guard, same line)
assert_contains "T28: observability skipped in lite" "$SKILL" \
    "skip if LITE"
assert_contains "T29: LITE_ESCALATED parsed" "$SKILL" \
    "grep -m1 '^LITE_ESCALATED:'"
# T30/T31/T34/T35/T36/T37/T38 removed: verbose directive headings were
# intentionally compressed in NP-110; behavioral correctness is covered by
# T2-T12 (condition JSON truth table), T26, T32, and T43-T46 (execution).
# T32: project-map one-liner skips when LITE_MODE=true (compressed form)
assert_contains "T32: project-map verification skipped in lite" "$SKILL" \
    '[ "$CACHE_STATE" != "fresh" ] && [ "$CACHE_ENABLED" = "true" ] && [ "$LITE_MODE" != "true" ]'
# T33: downstream bash blocks re-read context via n1_read_context (replaces
# the old multi-line re-derivation block with comment)
assert_contains "T33: downstream blocks use n1_read_context to restore LITE_MODE" "$SKILL" \
    "n1_read_context"

# ---------------------------------------------------------------------------
# The executable predicate itself. T2-T12 exercise the *descriptive* telemetry
# condition JSON. After NP-110 compression the predicate is a one-liner; the
# two downstream re-derivation copies were replaced with n1_read_context().
# T39: verify the one-liner predicate is present in the skill.
# T41: evaluate it against the truth table (same checks as T2-T12 but via Bash).
# T40.2/T40.3 removed: no longer applicable (copies replaced by n1_read_context).
# ---------------------------------------------------------------------------
# After NP-110 compression LITE_MODE=false is the tail of a multi-statement
# line (line 14) and the conditional is a separate line (line 15). Extract
# the conditional line which contains the predicate logic.
PRED_COND=$(grep -m1 'LITE_MODE=true$' "$SKILL")
if [ -n "$PRED_COND" ]; then
    pass "T39: LITE_MODE predicate conditional is present in skill"
else
    fail "T39: LITE_MODE predicate conditional missing from skill"
fi

# Evaluate the predicate (init + conditional) against the truth table.
run_pred_inline() {
    (
        TIER="$2"; TYPE="$3"; DESC_QUALITY="$4"
        LITE_MODE=false
        eval "$1"
        echo "$LITE_MODE"
    )
}

check_pred_inline() {
    local tier="$1" type="$2" quality="$3" expected="$4" actual
    actual=$(run_pred_inline "$PRED_COND" "$tier" "$type" "$quality")
    assert_eq "T41: predicate (tier=$tier type=$type quality=${quality:-<empty>})" \
        "$expected" "$actual"
}

check_pred_inline simple   task  adequate true
check_pred_inline simple   chore weak     true
check_pred_inline simple   task  weak     true
check_pred_inline simple   bug   adequate false
check_pred_inline simple   task  skeletal false
check_pred_inline standard task  adequate false
check_pred_inline simple   task  ""       false

# ---------------------------------------------------------------------------
# T42: the decision id must be discoverable in the telemetry reference, which
# enumerates the ids step files record explicitly.
# ---------------------------------------------------------------------------
assert_contains "T42: telemetry.md documents the lite-analysis-gate decision id" \
    "$REPO_ROOT/references/telemetry.md" "lite-analysis-gate"

# ---------------------------------------------------------------------------
# Post-return persistence checks. After NP-110 compression the separate
# labeled verification blocks were condensed into two one-liners inside the
# main post-return bash block. Extract the one-liners and run them directly
# against a real fixture so the logic (not just the grep pattern) is tested.
# ---------------------------------------------------------------------------

# Extract the one-liner that checks project-map persistence.
MAP_LINE=$(grep -m1 'echo "Project map persistence failed' "$SKILL")
# Extract the one-liner that checks snapshot persistence.
SNAP_LINE=$(grep -m1 'echo "Snapshot persistence failed' "$SKILL")

run_oneliner() {
    # $1=line $2=CACHE_STATE $3=CACHE_ENABLED $4=LITE_MODE $5=PROJECT_MAP_PATH $6=SNAPSHOT_PATH
    local line="$1"
    (
        set +u
        CACHE_STATE="$2" CACHE_ENABLED="$3" LITE_MODE="$4"
        PROJECT_MAP_PATH="$5" SNAPSHOT_PATH="$6"
        eval "$line"
    ) 2>&1
}

PR_HOME="$T/postreturn"
mkdir -p "$PR_HOME/cache"

# (a) Cold cache, non-lite, project map absent -> must report the failure.
#     Without the LITE_MODE guard an unset LITE_MODE would make the guard false
#     and silently skip the check (the original regression this test caught).
rm -f "$PR_HOME/cache/project-map.md"
OUT=$(run_oneliner "$MAP_LINE" cold true false "$PR_HOME/cache/project-map.md" "")
case "$OUT" in
    *"Project map persistence failed"*) pass "T43: project-map check fires on a non-lite cold run" ;;
    *) fail "T43: project-map check did not fire on a non-lite cold run (output=[$OUT])" ;;
esac

# (b) Same but lite=true -> must stay silent.
OUT=$(run_oneliner "$MAP_LINE" cold true true "$PR_HOME/cache/project-map.md" "")
case "$OUT" in
    *"Project map persistence failed"*) fail "T44: project-map check fired on a lite run (output=[$OUT])" ;;
    *) pass "T44: project-map check stays silent on a lite run" ;;
esac

# (c) Snapshot present and non-empty -> no failure reported.
printf '# snapshot\ncontent\n' > "$PR_HOME/cache/project-snapshot.md"
OUT=$(run_oneliner "$SNAP_LINE" cold true false "" "$PR_HOME/cache/project-snapshot.md")
case "$OUT" in
    *"Snapshot persistence failed"*) fail "T45: phantom snapshot failure when snapshot exists (output=[$OUT])" ;;
    *) pass "T45: no snapshot failure reported when the snapshot exists" ;;
esac

# (d) Snapshot genuinely missing -> failure must be reported.
rm -f "$PR_HOME/cache/project-snapshot.md"
OUT=$(run_oneliner "$SNAP_LINE" cold true false "" "$PR_HOME/cache/project-snapshot.md")
case "$OUT" in
    *"Snapshot persistence failed"*) pass "T46: snapshot check still fires when the snapshot is missing" ;;
    *) fail "T46: snapshot check did not fire on a missing snapshot (output=[$OUT])" ;;
esac

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]

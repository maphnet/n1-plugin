#!/usr/bin/env bash
# tests/test_decisions.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export N1_HOME="$T/home"; export ID="T-1"
MEM="$N1_HOME/memory/$ID"; mkdir -p "$MEM/telemetry"
echo '{"run_id":"run-abc","n1_version":"2.84.0"}' > "$MEM/telemetry/telemetry.lock"
printf -- '---\nstep: qa\n---\n' > "$MEM/overview.md"
printf '<!-- n1:signals blast_radius=low files_changed=2 -->\n' > "$MEM/analysis.md"
source "$REPO_ROOT/lib/telemetry.sh"

n1_record_decision simplicity-gate true '{"all":[{"signal":"analysis.blast_radius","eq":"low"}]}' tier=simple
LINE=$(tail -1 "$MEM/telemetry/raw/steps/run-abc.jsonl")
assert_eq "event type" "decision" "$(echo "$LINE" | jq -r .event)"
assert_eq "decision id" "simplicity-gate" "$(echo "$LINE" | jq -r .id)"
assert_eq "result" "true" "$(echo "$LINE" | jq -r .result)"
assert_eq "signal captured from condition" "low" "$(echo "$LINE" | jq -r '.signals["analysis.blast_radius"]')"
assert_eq "extra kv captured" "simple" "$(echo "$LINE" | jq -r '.signals.tier')"
assert_eq "run id from lock" "run-abc" "$(echo "$LINE" | jq -r .run_id)"

# No lock → no write
rm "$MEM/telemetry/telemetry.lock"; rm -f "$MEM/telemetry/raw/steps/run-abc.jsonl"
n1_record_decision skip-brainstorm false
[ ! -f "$MEM/telemetry/raw/steps/run-abc.jsonl" ] && { echo "PASS: no lock no write"; PASS=$((PASS+1)); } || { echo "FAIL: no lock no write"; FAIL=$((FAIL+1)); }

# n1_resolve_model emits decisions for pipeline triggers
echo '{"run_id":"run-abc","n1_version":"2.84.0"}' > "$MEM/telemetry/telemetry.lock"
printf '<!-- n1:signals security_relevant=true blast_radius=low -->\n' > "$MEM/analysis.md"
source "$REPO_ROOT/lib/config.sh"
n1_resolve_model developer implementation >/dev/null
DEC=$(grep '"event":"decision"' "$MEM/telemetry/raw/steps/run-abc.jsonl" | jq -r 'select(.id=="escalation:developer:implementation") | .result' | head -1)
assert_eq "escalation trigger recorded true" "true" "$DEC"

echo; echo "Passed: $PASS  Failed: $FAIL"; [ "$FAIL" -eq 0 ]

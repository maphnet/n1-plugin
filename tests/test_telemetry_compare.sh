#!/usr/bin/env bash
# Test: telemetry_analyzer.py compare produces valid differential report
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/telemetry_analyzer.py"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Create two run records in different projects
mkdir -p "$TEST_DIR/proj-a/memory/T-1/telemetry/runs"
mkdir -p "$TEST_DIR/proj-b/memory/T-2/telemetry/runs"

cat > "$TEST_DIR/proj-a/memory/T-1/telemetry/runs/run-aaa.jsonl" << 'EOF'
{"schema_version":1,"run_id":"run-aaa","started_at":"2026-09-01T10:00:00Z","completed_at":"2026-09-01T10:10:00Z","estimated_tier":"simple","final_outcome":"pr_created","n1_version":"3.18.0","steps":[{"step":"ticket","step_number":1,"duration_s":30,"outcome":"success"}],"orchestrator":{"steps":[{"step":"ticket","input_tokens":5000,"output_tokens":500,"tools_used":{"Bash":2}}],"unattributed":{"tools_used":{}}},"summary":{"total_input_tokens":5000,"total_output_tokens":500,"total_cache_read_tokens":3000,"cache_efficiency":0.6,"orchestrator_tool_calls":2},"agents":[]}
EOF

cat > "$TEST_DIR/proj-b/memory/T-2/telemetry/runs/run-bbb.jsonl" << 'EOF'
{"schema_version":1,"run_id":"run-bbb","started_at":"2026-09-02T10:00:00Z","completed_at":"2026-09-02T10:20:00Z","estimated_tier":"standard","final_outcome":"pr_created","n1_version":"3.18.0","steps":[{"step":"ticket","step_number":1,"duration_s":60,"outcome":"success"}],"orchestrator":{"steps":[{"step":"ticket","input_tokens":10000,"output_tokens":1000,"tools_used":{"Bash":4}}],"unattributed":{"tools_used":{}}},"summary":{"total_input_tokens":10000,"total_output_tokens":1000,"total_cache_read_tokens":8000,"cache_efficiency":0.8,"orchestrator_tool_calls":4},"agents":[]}
EOF

OUTPUT=$(python3 "$SCRIPT" compare --n1-root "$TEST_DIR" --run1 run-aaa --run2 run-bbb 2>/dev/null)

echo "$OUTPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
comp = data['comparison']
assert comp['run_a']['run_id'] == 'run-aaa', 'wrong run_a'
assert comp['run_b']['run_id'] == 'run-bbb', 'wrong run_b'
assert comp['totals']['input_tokens']['diff'] == 5000, f\"input diff wrong: {comp['totals']['input_tokens']}\"
assert comp['totals']['input_tokens']['diff_pct'] == 100.0, 'input pct wrong'
assert comp['duration']['diff'] == 600.0, f\"duration diff wrong: {comp['duration']}\"
assert 'ticket' in comp['by_step'], 'missing ticket step diff'
assert comp['by_step']['ticket']['present_in'] == 'both', 'ticket should be in both'
print('PASS: compare output valid')
"

# Test missing run ID
python3 "$SCRIPT" compare --n1-root "$TEST_DIR" --run1 run-aaa --run2 nonexistent 2>/dev/null && { echo "FAIL: should exit non-zero for missing run"; exit 1; } || echo "PASS: missing run exits non-zero"

echo "All compare tests passed"

#!/usr/bin/env bash
# Test: telemetry_analyzer.py --attribution produces valid attribution output
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/telemetry_analyzer.py"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Create a minimal run record
mkdir -p "$TEST_DIR/test-project/memory/TEST-1/telemetry/runs"
cat > "$TEST_DIR/test-project/memory/TEST-1/telemetry/runs/run-001.jsonl" << 'EOF'
{"schema_version":1,"run_id":"run-001","started_at":"2026-09-01T10:00:00Z","completed_at":"2026-09-01T10:30:00Z","estimated_tier":"simple","final_outcome":"pr_created","n1_version":"3.18.0","steps":[{"step":"ticket","step_number":1,"duration_s":30,"outcome":"success"},{"step":"analysis","step_number":2,"duration_s":120,"outcome":"success"}],"orchestrator":{"steps":[{"step":"ticket","input_tokens":5000,"output_tokens":500,"tools_used":{"Bash":2,"Read":1}},{"step":"analysis","input_tokens":15000,"output_tokens":1500,"tools_used":{"Bash":4,"Read":3,"Agent":1}}],"unattributed":{"tools_used":{}}},"summary":{"total_input_tokens":20000,"total_output_tokens":2000,"total_cache_read_tokens":15000,"cache_efficiency":0.75,"orchestrator_tool_calls":11},"agents":[]}
EOF

OUTPUT=$(python3 "$SCRIPT" collect --n1-root "$TEST_DIR" --last 1 --attribution 2>/dev/null)

# Verify attribution key exists
echo "$OUTPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
run = data['runs'][0]
assert 'attribution' in run, 'missing attribution key'
attr = run['attribution']
assert 'by_step' in attr, 'missing by_step'
assert 'ticket' in attr['by_step'], 'missing ticket step'
assert 'analysis' in attr['by_step'], 'missing analysis step'
assert attr['by_step']['ticket']['input_share_pct'] == 25.0, f\"ticket share wrong: {attr['by_step']['ticket']['input_share_pct']}\"
assert attr['by_step']['analysis']['input_share_pct'] == 75.0, f\"analysis share wrong: {attr['by_step']['analysis']['input_share_pct']}\"
assert attr['by_step']['analysis']['agent_dispatches'] == 1, 'analysis dispatch count wrong'
assert attr['orchestrator_overhead']['unattributed_input_tokens'] == 0, 'unexpected unattributed tokens'
assert data.get('attribution_mode') is True, 'attribution_mode flag missing'
print('PASS: attribution output valid')
"

# Verify attribution absent when flag not set
OUTPUT_NO_ATTR=$(python3 "$SCRIPT" collect --n1-root "$TEST_DIR" --last 1 2>/dev/null)
echo "$OUTPUT_NO_ATTR" | python3 -c "
import json, sys
data = json.load(sys.stdin)
run = data['runs'][0]
assert 'attribution' not in run, 'attribution should not be present without --attribution'
print('PASS: attribution absent without flag')
"

echo "All attribution tests passed"

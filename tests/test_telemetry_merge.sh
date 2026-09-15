#!/usr/bin/env bash
# tests/test_telemetry_merge.sh — verify telemetry-merge.sh gap fixes
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# Mock N1_HOME so config.sh resolves
export N1_HOME="$T/home"; mkdir -p "$N1_HOME"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

RUN_ID="test-run-001"
TELEM_DIR="$T/home/memory/TEST-1/telemetry"
mkdir -p "$TELEM_DIR/raw/steps" "$TELEM_DIR/raw/agents"

# Create a minimal lock file
echo "{\"run_id\":\"$RUN_ID\",\"n1_version\":\"3.8.0\"}" > "$TELEM_DIR/telemetry.lock"

# Create a fake transcript for agent-1 (subagent path)
SESS_DIR="$T/sessions/sess-001"
mkdir -p "$SESS_DIR/subagents"
cat > "$SESS_DIR/subagents/agent-agent-1.jsonl" <<'TRANSCRIPT'
{"type":"assistant","timestamp":"2026-09-01T10:01:00Z","message":{"model":"claude-sonnet-4-20250514","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":200,"cache_creation_input_tokens":300},"content":[{"type":"text","text":"done"}]}}
{"type":"assistant","timestamp":"2026-09-01T10:02:00Z","message":{"model":"claude-sonnet-4-20250514","usage":{"input_tokens":800,"output_tokens":400,"cache_read_input_tokens":100,"cache_creation_input_tokens":150},"content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]}}
TRANSCRIPT

# Create a parent session transcript for orchestrator derivation test
cat > "$SESS_DIR.jsonl" <<'TRANSCRIPT'
{"type":"assistant","timestamp":"2026-09-01T10:00:30Z","message":{"model":"claude-sonnet-4-20250514","usage":{"input_tokens":500,"output_tokens":250,"cache_read_input_tokens":50,"cache_creation_input_tokens":75},"content":[{"type":"text","text":"orchestrating"}]}}
TRANSCRIPT

# Write step events (minimal envelope)
cat > "$TELEM_DIR/raw/steps/$RUN_ID.jsonl" <<STEPS
{"layer":"envelope","started_at":"2026-09-01T10:00:00Z","ticket_id":"TEST-1","session_id":"sess-001"}
{"layer":"step","step":"analysis","step_number":1,"started_at":"2026-09-01T10:00:00Z"}
{"layer":"step","step":"analysis","step_number":1,"completed_at":"2026-09-01T10:05:00Z","outcome":"pass"}
{"layer":"envelope_close","completed_at":"2026-09-01T10:10:00Z","final_outcome":"pr_created"}
STEPS

# Write agent events:
# agent-1: completed with subagent transcript (normal case)
# agent-2: completed but transcript_path points to nonexistent file (transcript_not_found)
# agent-3: never completed — no stop event (agent_never_finished)
# Note: NO session_transcript_path on any record — forces orchestrator derivation fallback
cat > "$TELEM_DIR/raw/agents/$RUN_ID.jsonl" <<AGENTS
{"event":"start","agent_id":"agent-1","agent_type":"n1:developer","started_at":"2026-09-01T10:00:30Z"}
{"event":"stop","agent_id":"agent-1","agent_type":"n1:developer","completed_at":"2026-09-01T10:03:00Z","transcript_path":"$SESS_DIR/subagents/agent-agent-1.jsonl"}
{"event":"start","agent_id":"agent-2","agent_type":"n1:code-reviewer","started_at":"2026-09-01T10:03:30Z"}
{"event":"stop","agent_id":"agent-2","agent_type":"n1:code-reviewer","completed_at":"2026-09-01T10:05:00Z","transcript_path":"$T/nonexistent/agent-agent-2.jsonl"}
{"event":"start","agent_id":"agent-3","agent_type":"n1:qa-engineer","started_at":"2026-09-01T10:05:30Z"}
AGENTS

# --- Run the merge ---
bash "$REPO_ROOT/hooks/telemetry-merge.sh" "$RUN_ID" "$TELEM_DIR"

OUT="$TELEM_DIR/runs/$RUN_ID.jsonl"

# --- Gap 1: total_cache_creation_tokens present and correct ---
CACHE_CREATION=$(jq '.summary.total_cache_creation_tokens' "$OUT")
assert_eq "Gap1: total_cache_creation_tokens present" "450" "$CACHE_CREATION"
# 300 + 150 = 450 from the two transcript entries

TOTAL_INPUT=$(jq '.summary.total_input_tokens' "$OUT")
assert_eq "Gap1: total_input_tokens still works" "1800" "$TOTAL_INPUT"

# --- Gap 2: orchestrator resolved via subagent path derivation ---
ORCH_ERROR=$(jq -r '.orchestrator.parse_error // "null"' "$OUT")
assert_eq "Gap2: orchestrator parse_error is null" "null" "$ORCH_ERROR"

ORCH_INPUT=$(jq '.orchestrator.totals.input_tokens' "$OUT")
assert_eq "Gap2: orchestrator input_tokens from derived transcript" "500" "$ORCH_INPUT"

ORCH_CACHE_CREATION=$(jq '.orchestrator.totals.cache_creation_tokens' "$OUT")
assert_eq "Gap2: orchestrator cache_creation_tokens" "75" "$ORCH_CACHE_CREATION"

# Summary orchestrator fields should now be non-null
ORCH_SUMMARY_IN=$(jq '.summary.orchestrator_input_tokens' "$OUT")
assert_eq "Gap2: summary orchestrator_input_tokens non-null" "500" "$ORCH_SUMMARY_IN"

# --- Gap 3b: agent_never_finished label ---
AGENT3_ERROR=$(jq -r '.agents[2].parse_error' "$OUT")
assert_eq "Gap3b: agent-3 parse_error is agent_never_finished" "agent_never_finished" "$AGENT3_ERROR"

# agent-2 should still be transcript_not_found (not agent_never_finished)
AGENT2_ERROR=$(jq -r '.agents[1].parse_error' "$OUT")
assert_eq "Gap3b: agent-2 parse_error is transcript_not_found" "transcript_not_found" "$AGENT2_ERROR"

# agent-1 should have no error
AGENT1_ERROR=$(jq -r '.agents[0].parse_error // "null"' "$OUT")
assert_eq "Gap3b: agent-1 parse_error is null" "null" "$AGENT1_ERROR"

# --- Backward compat: session_transcript_path in output ---
SESS_PATH=$(jq -r '.session_transcript_path' "$OUT")
assert_eq "session_transcript_path populated from derivation" "$SESS_DIR.jsonl" "$SESS_PATH"

echo "---"
echo "$((PASS+FAIL)) tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

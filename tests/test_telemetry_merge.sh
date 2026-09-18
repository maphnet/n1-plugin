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
{"layer":"envelope","started_at":"2026-09-01T10:00:00Z","ticket_id":"TEST-1","session_id":"sess-001","host":"claude-code"}
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
export N1_HOST="claude-code"
bash "$REPO_ROOT/hooks/telemetry-merge.sh" "$RUN_ID" "$TELEM_DIR"
unset N1_HOST

OUT="$TELEM_DIR/runs/$RUN_ID.jsonl"

# --- Gap 1: total_cache_creation_tokens present and correct ---
CACHE_CREATION=$(jq '.summary.total_cache_creation_tokens' "$OUT")
assert_eq "Gap1: missing agents leave cache total unknown" "null" "$CACHE_CREATION"
# 300 + 150 = 450 from the two transcript entries

TOTAL_INPUT=$(jq '.summary.total_input_tokens' "$OUT")
assert_eq "Gap1: missing agents leave input total unknown" "null" "$TOTAL_INPUT"

ELAPSED=$(jq '.summary.total_duration_s' "$OUT")
assert_eq "Duration: envelope elapsed time is used" "600" "$ELAPSED"

STEP_DURATION=$(jq '.summary.total_step_duration_s' "$OUT")
assert_eq "Duration: summed steps remain separately visible" "300" "$STEP_DURATION"

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

# ==== Test 2: Codex run — v4 fields, session-total usage, missing as unknown ====
RUN_ID2="test-run-002"
TELEM_DIR2="$T/home/memory/TEST-2/telemetry"
mkdir -p "$TELEM_DIR2/raw/steps" "$TELEM_DIR2/raw/agents"

echo "{\"run_id\":\"$RUN_ID2\",\"n1_version\":\"3.12.0\"}" > "$TELEM_DIR2/telemetry.lock"

# Create a Codex rollout transcript
CODEX_SESS="$T/codex-sessions/rollout-test.jsonl"
mkdir -p "$(dirname "$CODEX_SESS")"
cat > "$CODEX_SESS" <<'CODEX_TRANSCRIPT'
{"timestamp":"2026-09-01T10:00:00Z","ordinal":0,"type":"session_meta","payload":{"session_id":"codex-s1","cwd":"/x","cli_version":"0.154.0","parent_id":"parent-abc"}}
{"timestamp":"2026-09-01T10:01:00Z","ordinal":1,"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"working"}]}}
{"timestamp":"2026-09-01T10:02:00Z","ordinal":2,"type":"token_usage_record","payload":{"usage":{"input_tokens":1000,"output_tokens":100,"cached_input_tokens":500}}}
{"timestamp":"2026-09-01T10:05:00Z","ordinal":3,"type":"token_usage_record","payload":{"usage":{"input_tokens":5000,"output_tokens":300,"cached_input_tokens":3000,"reasoning_tokens":50}}}
CODEX_TRANSCRIPT

# Write step events
cat > "$TELEM_DIR2/raw/steps/$RUN_ID2.jsonl" <<STEPS2
{"layer":"envelope","started_at":"2026-09-01T10:00:00Z","ticket_id":"TEST-2","session_id":"codex-s1","host":"codex","session_transcript_path":"$CODEX_SESS"}
{"layer":"step","step":"analysis","step_number":1,"started_at":"2026-09-01T10:00:00Z"}
{"layer":"step","step":"analysis","step_number":1,"completed_at":"2026-09-01T10:05:00Z","outcome":"pass"}
{"layer":"envelope_close","completed_at":"2026-09-01T10:10:00Z","final_outcome":"pr_created"}
STEPS2

# Write agent events with session_transcript_path pointing to Codex rollout
cat > "$TELEM_DIR2/raw/agents/$RUN_ID2.jsonl" <<AGENTS2
{"event":"start","agent_id":"agent-c1","agent_type":"n1-developer","started_at":"2026-09-01T10:00:30Z","session_transcript_path":"$CODEX_SESS"}
{"event":"stop","agent_id":"agent-c1","agent_type":"n1-developer","completed_at":"2026-09-01T10:03:00Z","transcript_path":"$CODEX_SESS","session_transcript_path":"$CODEX_SESS"}
AGENTS2

# A later process may identify as Claude; immutable run identity still wins.
export N1_HOST="claude-code"
bash "$REPO_ROOT/hooks/telemetry-merge.sh" "$RUN_ID2" "$TELEM_DIR2"
unset N1_HOST

OUT2="$TELEM_DIR2/runs/$RUN_ID2.jsonl"

# Schema v4
SCHEMA_V=$(jq '.schema_version' "$OUT2")
assert_eq "Codex: schema_version is 5" "5" "$SCHEMA_V"

# Host field
HOST_V=$(jq -r '.host' "$OUT2")
assert_eq "Codex: host is codex" "codex" "$HOST_V"

# Usage scope
SCOPE_V=$(jq -r '.usage_scope' "$OUT2")
assert_eq "Codex: usage_scope is session-total" "session-total" "$SCOPE_V"

# Usage status
STATUS_V=$(jq -r '.usage_status' "$OUT2")
assert_eq "Codex: missing usage fields make status partial" "partial" "$STATUS_V"

# Session-total usage (last record wins: 5000/300/3000/50)
CODEX_INPUT=$(jq '.summary.total_input_tokens' "$OUT2")
assert_eq "Codex: total_input_tokens from last usage record" "5000" "$CODEX_INPUT"

CODEX_OUTPUT=$(jq '.summary.total_output_tokens' "$OUT2")
assert_eq "Codex: total_output_tokens from last usage record" "300" "$CODEX_OUTPUT"

CODEX_CACHED=$(jq '.summary.total_cache_read_tokens' "$OUT2")
assert_eq "Codex: total_cache_read_tokens from last usage record" "3000" "$CODEX_CACHED"

# Session linkage
LINKAGE_PARENT=$(jq -r '.session_linkage.parent_id' "$OUT2")
assert_eq "Codex: session_linkage.parent_id" "parent-abc" "$LINKAGE_PARENT"

LINKAGE_SESSION=$(jq -r '.session_linkage.session_id' "$OUT2")
assert_eq "Codex: session_linkage.session_id" "codex-s1" "$LINKAGE_SESSION"

# CLI version
CLI_V=$(jq -r '.cli_version' "$OUT2")
assert_eq "Codex: cli_version from session_meta" "0.154.0" "$CLI_V"

# ==== Test 3: Claude run still produces v4 with host=claude-code ====
# Re-run test 1 data with forced Claude host to verify v4 backward compat
export N1_HOST="claude-code"
bash "$REPO_ROOT/hooks/telemetry-merge.sh" "$RUN_ID" "$TELEM_DIR"
unset N1_HOST

SCHEMA_V3=$(jq '.schema_version' "$OUT")
assert_eq "Claude: schema_version is 5" "5" "$SCHEMA_V3"

HOST_V3=$(jq -r '.host' "$OUT")
assert_eq "Claude v4: host is claude-code" "claude-code" "$HOST_V3"

SCOPE_V3=$(jq -r '.usage_scope' "$OUT")
assert_eq "Claude v4: usage_scope includes parent" "session-tree" "$SCOPE_V3"

# Existing Claude token values still correct
TOTAL_INPUT_V4=$(jq '.summary.total_input_tokens' "$OUT")
assert_eq "Claude v4: total_input_tokens unknown with missing agents" "null" "$TOTAL_INPUT_V4"

# ==== Test 4: Missing Codex usage — null not zero ====
RUN_ID4="test-run-004"
TELEM_DIR4="$T/home/memory/TEST-4/telemetry"
mkdir -p "$TELEM_DIR4/raw/steps" "$TELEM_DIR4/raw/agents"

echo "{\"run_id\":\"$RUN_ID4\",\"n1_version\":\"3.12.0\"}" > "$TELEM_DIR4/telemetry.lock"

# Codex transcript with NO token_usage_record
CODEX_EMPTY="$T/codex-sessions/rollout-empty.jsonl"
cat > "$CODEX_EMPTY" <<'EMPTY_TRANSCRIPT'
{"timestamp":"2026-09-01T10:00:00Z","ordinal":0,"type":"session_meta","payload":{"session_id":"empty-s1","cwd":"/x"}}
{"timestamp":"2026-09-01T10:01:00Z","ordinal":1,"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}
EMPTY_TRANSCRIPT

cat > "$TELEM_DIR4/raw/steps/$RUN_ID4.jsonl" <<STEPS4
{"layer":"envelope","started_at":"2026-09-01T10:00:00Z","ticket_id":"TEST-4","session_id":"empty-s1","host":"codex","session_transcript_path":"$CODEX_EMPTY"}
{"layer":"envelope_close","completed_at":"2026-09-01T10:10:00Z","final_outcome":"pr_created"}
STEPS4

cat > "$TELEM_DIR4/raw/agents/$RUN_ID4.jsonl" <<AGENTS4
{"event":"start","agent_id":"agent-e1","agent_type":"n1-developer","started_at":"2026-09-01T10:00:30Z","session_transcript_path":"$CODEX_EMPTY"}
{"event":"stop","agent_id":"agent-e1","agent_type":"n1-developer","completed_at":"2026-09-01T10:03:00Z","transcript_path":"$CODEX_EMPTY","session_transcript_path":"$CODEX_EMPTY"}
AGENTS4

export N1_HOST="codex"
bash "$REPO_ROOT/hooks/telemetry-merge.sh" "$RUN_ID4" "$TELEM_DIR4"
unset N1_HOST

OUT4="$TELEM_DIR4/runs/$RUN_ID4.jsonl"

MISSING_STATUS=$(jq -r '.usage_status' "$OUT4")
assert_eq "Missing usage: usage_status is unknown" "unknown" "$MISSING_STATUS"

MISSING_INPUT=$(jq '.summary.total_input_tokens' "$OUT4")
assert_eq "Missing usage: total_input_tokens is null" "null" "$MISSING_INPUT"

echo "---"
echo "$((PASS+FAIL)) tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

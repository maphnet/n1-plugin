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
{"event":"question","run_id":"$RUN_ID","n1_version":"3.8.0","ticket_id":"TEST-1","layer":"question","step":"brainstorm","question_category":"design","resolution":"asked","rungs_tried":"codebase,web","timestamp":"2026-09-01T10:06:00Z"}
{"event":"question","run_id":"$RUN_ID","n1_version":"3.8.0","ticket_id":"TEST-1","layer":"question","step":"plan","question_category":"scope","resolution":"auto","rungs_tried":"","timestamp":"2026-09-01T10:07:00Z"}
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

# --- N1-101: question events reach the merged record ---
assert_eq "N1-101: questions[] has both events" "2" "$(jq '.questions | length' "$OUT")"
assert_eq "N1-101: question fields preserved" "brainstorm|design|asked|codebase,web|2026-09-01T10:06:00Z" \
  "$(jq -r '.questions[0] | [.step,.question_category,.resolution,.rungs_tried,.timestamp] | join("|")' "$OUT")"
assert_eq "N1-101: question lines do not become steps" "1" "$(jq '.steps | length' "$OUT")"
assert_eq "N1-101: benchmark counts merged questions" "2.0" \
  "$(cd "$REPO_ROOT/scripts" && python3 -c "import json,sys,benchmark; print(benchmark.QuestionMetric('q').compute(json.load(open(sys.argv[1])), []))" "$OUT")"

# --- Backward compat: session_transcript_path in output ---
SESS_PATH=$(jq -r '.session_transcript_path' "$OUT")
assert_eq "session_transcript_path populated from derivation" "$SESS_DIR.jsonl" "$SESS_PATH"

# ==== Test 3: Claude run still produces v4 with host=claude-code ====
# Re-run test 1 data with forced Claude host to verify v4 backward compat
bash "$REPO_ROOT/hooks/telemetry-merge.sh" "$RUN_ID" "$TELEM_DIR"

SCHEMA_V3=$(jq '.schema_version' "$OUT")
assert_eq "Claude: schema_version is 6" "6" "$SCHEMA_V3"

HOST_V3=$(jq -r '.host' "$OUT")
assert_eq "Claude v4: host is claude-code" "claude-code" "$HOST_V3"

SCOPE_V3=$(jq -r '.usage_scope' "$OUT")
assert_eq "Claude v4: usage_scope includes parent" "session-tree" "$SCOPE_V3"

# Existing Claude token values still correct
TOTAL_INPUT_V4=$(jq '.summary.total_input_tokens' "$OUT")
assert_eq "Claude v4: total_input_tokens unknown with missing agents" "null" "$TOTAL_INPUT_V4"

# ==== Test 5: NP-236 — last envelope_close wins, not first ====
RUN_ID5="test-run-005"
TELEM_DIR5="$T/home/memory/TEST-5/telemetry"
mkdir -p "$TELEM_DIR5/raw/steps" "$TELEM_DIR5/raw/agents"

echo "{\"run_id\":\"$RUN_ID5\",\"n1_version\":\"3.12.0\"}" > "$TELEM_DIR5/telemetry.lock"

# A stray/incorrect earlier "abandoned" close (e.g. session-stop firing mid-pause)
# followed by the genuine later outcome — the later one must win.
cat > "$TELEM_DIR5/raw/steps/$RUN_ID5.jsonl" <<STEPS5
{"layer":"envelope","started_at":"2026-09-01T10:00:00Z","ticket_id":"TEST-5","session_id":"sess-005","host":"claude-code"}
{"event":"compaction","run_id":"$RUN_ID5","timestamp":"2026-09-01T10:03:00Z"}
{"layer":"envelope_close","completed_at":"2026-09-01T10:05:00Z","final_outcome":"abandoned"}
{"layer":"envelope_close","completed_at":"2026-09-01T10:10:00Z","final_outcome":"pr_created"}
STEPS5

: > "$TELEM_DIR5/raw/agents/$RUN_ID5.jsonl"

bash "$REPO_ROOT/hooks/telemetry-merge.sh" "$RUN_ID5" "$TELEM_DIR5"

OUT5="$TELEM_DIR5/runs/$RUN_ID5.jsonl"
FINAL_OUTCOME5=$(jq -r '.final_outcome' "$OUT5")
assert_eq "NP-236: last envelope_close wins over first" "pr_created" "$FINAL_OUTCOME5"
assert_eq "N1-106: no transcript -> compaction_count null, not 0" "null" "$(jq '.summary.compaction_count' "$OUT5")"
assert_eq "N1-106: no transcript -> compaction_timestamps null" "null" "$(jq '.summary.compaction_timestamps' "$OUT5")"

# ==== Test 6: N1-106 transcript compactions and per-step context ====
RUN_ID6="test-run-006"
TELEM_DIR6="$T/home/memory/TEST-6/telemetry"
mkdir -p "$TELEM_DIR6/raw/steps" "$TELEM_DIR6/raw/agents"
TRANSCRIPT6="$T/sess-006.jsonl"
# Contexts (input+cache_read+cache_creation): m1=1000 m2=5000 m3=6000 s1(sidechain)=99999 m4=2000.
# Boundaries: 10:13 manual (in review), 10:25 auto (in run, no step), 10:26 no metadata (unknown),
# 10:27 sidechain (ignored), 10:40 manual (after run end, ignored).
cat > "$TRANSCRIPT6" <<'TRANSCRIPT'
{"type":"assistant","timestamp":"2026-09-02T10:01:00Z","message":{"id":"m1","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":800,"cache_creation_input_tokens":100},"content":[]}}
{"type":"assistant","timestamp":"2026-09-02T10:05:00Z","message":{"id":"m2","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":4800,"cache_creation_input_tokens":100},"content":[]}}
{"type":"assistant","timestamp":"2026-09-02T10:11:00Z","message":{"id":"m3","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":5800,"cache_creation_input_tokens":100},"content":[]}}
{"type":"assistant","isSidechain":true,"timestamp":"2026-09-02T10:12:00Z","message":{"id":"s1","usage":{"input_tokens":99000,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":999},"content":[]}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-09-02T10:13:00.000Z","compactMetadata":{"trigger":"manual","preTokens":6000,"postTokens":1500}}
{"type":"assistant","timestamp":"2026-09-02T10:15:00Z","message":{"id":"m4","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":1800,"cache_creation_input_tokens":100},"content":[]}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-09-02T10:25:00.000Z","compactMetadata":{"trigger":"auto","preTokens":160000,"postTokens":20000}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-09-02T10:26:00.000Z"}
{"type":"system","subtype":"compact_boundary","isSidechain":true,"timestamp":"2026-09-02T10:27:00.000Z","compactMetadata":{"trigger":"auto","preTokens":170000,"postTokens":20000}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-09-02T10:40:00.000Z","compactMetadata":{"trigger":"manual","preTokens":9000,"postTokens":2000}}
TRANSCRIPT
cat > "$TELEM_DIR6/raw/steps/$RUN_ID6.jsonl" <<STEPS6
{"layer":"envelope","started_at":"2026-09-02T10:00:00Z","ticket_id":"TEST-6","session_id":"sess-006","host":"claude-code","session_transcript_path":"$TRANSCRIPT6"}
{"layer":"step","step":"analysis","step_number":1,"started_at":"2026-09-02T10:00:00Z"}
{"layer":"step","step":"analysis","step_number":1,"completed_at":"2026-09-02T10:10:00Z","outcome":"pass"}
{"layer":"step","step":"review","step_number":2,"started_at":"2026-09-02T10:10:00Z"}
{"layer":"step","step":"review","step_number":2,"completed_at":"2026-09-02T10:20:00Z","outcome":"pass"}
{"event":"compaction","run_id":"$RUN_ID6","timestamp":"2026-09-02T10:14:00Z"}
{"layer":"envelope_close","completed_at":"2026-09-02T10:30:00Z","final_outcome":"pr_created"}
STEPS6
: > "$TELEM_DIR6/raw/agents/$RUN_ID6.jsonl"

bash "$REPO_ROOT/hooks/telemetry-merge.sh" "$RUN_ID6" "$TELEM_DIR6"
OUT6="$TELEM_DIR6/runs/$RUN_ID6.jsonl"

assert_eq "N1-106: in-run counts total|auto|manual (hook event ignored)" "3|1|1" \
  "$(jq -r '.summary | [.compaction_count,.compaction_auto_count,.compaction_manual_count] | map(tostring) | join("|")' "$OUT6")"
assert_eq "N1-106: in-run timestamps only" "2026-09-02T10:13:00.000Z,2026-09-02T10:25:00.000Z,2026-09-02T10:26:00.000Z" \
  "$(jq -r '.summary.compaction_timestamps | join(",")' "$OUT6")"
assert_eq "N1-106: boundary tokens kept" "manual|6000|1500" \
  "$(jq -r '.orchestrator.compactions[0] | [.trigger,.pre_tokens,.post_tokens] | map(tostring) | join("|")' "$OUT6")"
assert_eq "N1-106: missing metadata -> unknown trigger, null tokens" "unknown|null" \
  "$(jq -r '.orchestrator.compactions[2] | [.trigger,.pre_tokens] | map(tostring) | join("|")' "$OUT6")"
assert_eq "N1-106: analysis context start|end|peak|compactions" "1000|5000|5000|0" \
  "$(jq -r '.orchestrator.steps[] | select(.step=="analysis") | [.context_start_tokens,.context_end_tokens,.context_peak_tokens,.compactions] | map(tostring) | join("|")' "$OUT6")"
assert_eq "N1-106: review context skips sidechain, start = last before step" "5000|2000|6000|1" \
  "$(jq -r '.orchestrator.steps[] | select(.step=="review") | [.context_start_tokens,.context_end_tokens,.context_peak_tokens,.compactions] | map(tostring) | join("|")' "$OUT6")"
assert_eq "N1-106: existing step sums still include sidechain" "3" \
  "$(jq '.orchestrator.steps[] | select(.step=="review") | .api_calls' "$OUT6")"

# ==== Test 7: N1-106 open run (no completed_at) has no upper window bound ====
RUN_ID7="test-run-007"
TELEM_DIR7="$T/home/memory/TEST-7/telemetry"
mkdir -p "$TELEM_DIR7/raw/steps" "$TELEM_DIR7/raw/agents"
cat > "$TELEM_DIR7/raw/steps/$RUN_ID7.jsonl" <<STEPS7
{"layer":"envelope","started_at":"2026-09-02T10:00:00Z","ticket_id":"TEST-7","session_id":"sess-007","host":"claude-code","session_transcript_path":"$TRANSCRIPT6"}
{"layer":"step","step":"analysis","step_number":1,"started_at":"2026-09-02T10:00:00Z"}
STEPS7
: > "$TELEM_DIR7/raw/agents/$RUN_ID7.jsonl"
bash "$REPO_ROOT/hooks/telemetry-merge.sh" "$RUN_ID7" "$TELEM_DIR7"
OUT7="$TELEM_DIR7/runs/$RUN_ID7.jsonl"
assert_eq "N1-106: open run keeps the late boundary (total|manual)" "4|2" \
  "$(jq -r '.summary | [.compaction_count,.compaction_manual_count] | map(tostring) | join("|")' "$OUT7")"

# ==== Test 8: N1-106 transcript without usage fields -> compaction fields null, not 0 ====
RUN_ID8="test-run-008"
TELEM_DIR8="$T/home/memory/TEST-8/telemetry"
mkdir -p "$TELEM_DIR8/raw/steps" "$TELEM_DIR8/raw/agents"
TRANSCRIPT8="$T/sess-008.jsonl"
cat > "$TRANSCRIPT8" <<'TRANSCRIPT'
{"type":"assistant","timestamp":"2026-09-02T10:01:00Z","message":{"id":"n1","content":[]}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-09-02T10:13:00.000Z","compactMetadata":{"trigger":"manual","preTokens":6000,"postTokens":1500}}
TRANSCRIPT
cat > "$TELEM_DIR8/raw/steps/$RUN_ID8.jsonl" <<STEPS8
{"layer":"envelope","started_at":"2026-09-02T10:00:00Z","ticket_id":"TEST-8","session_id":"sess-008","host":"claude-code","session_transcript_path":"$TRANSCRIPT8"}
{"layer":"envelope_close","completed_at":"2026-09-02T10:30:00Z","final_outcome":"pr_created"}
STEPS8
: > "$TELEM_DIR8/raw/agents/$RUN_ID8.jsonl"
bash "$REPO_ROOT/hooks/telemetry-merge.sh" "$RUN_ID8" "$TELEM_DIR8"
OUT8="$TELEM_DIR8/runs/$RUN_ID8.jsonl"
assert_eq "N1-106: unusable usage -> compaction_count null" "null" "$(jq '.summary.compaction_count' "$OUT8")"
assert_eq "N1-106: unusable usage -> compaction_auto_count null" "null" "$(jq '.summary.compaction_auto_count' "$OUT8")"

# ==== Test 9: N1-106 [:19] truncation - ms boundaries in the same second as run start / step bounds ====
# Without truncation "...:00.500Z" < "...:00Z" ('.' < 'Z'), so a boundary in the run-start second
# is dropped from the window and one in the step-start second is left unattributed. The start-second
# boundary is the discriminating case; the end-second one pins 1-second resolution (up to 999 ms after
# completed_at still counts).
RUN_ID9="test-run-009"
TELEM_DIR9="$T/home/memory/TEST-9/telemetry"
mkdir -p "$TELEM_DIR9/raw/steps" "$TELEM_DIR9/raw/agents"
TRANSCRIPT9="$T/sess-009.jsonl"
cat > "$TRANSCRIPT9" <<'TRANSCRIPT'
{"type":"assistant","timestamp":"2026-09-02T10:15:00Z","message":{"id":"p1","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[]}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-09-02T10:10:00.500Z","compactMetadata":{"trigger":"manual","preTokens":6000,"postTokens":1500}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-09-02T10:20:00.500Z","compactMetadata":{"trigger":"auto","preTokens":7000,"postTokens":1500}}
TRANSCRIPT
cat > "$TELEM_DIR9/raw/steps/$RUN_ID9.jsonl" <<STEPS9
{"layer":"envelope","started_at":"2026-09-02T10:10:00Z","ticket_id":"TEST-9","session_id":"sess-009","host":"claude-code","session_transcript_path":"$TRANSCRIPT9"}
{"layer":"step","step":"review","step_number":1,"started_at":"2026-09-02T10:10:00Z"}
{"layer":"step","step":"review","step_number":1,"completed_at":"2026-09-02T10:20:00Z","outcome":"pass"}
{"layer":"envelope_close","completed_at":"2026-09-02T10:20:00Z","final_outcome":"pr_created"}
STEPS9
: > "$TELEM_DIR9/raw/agents/$RUN_ID9.jsonl"
bash "$REPO_ROOT/hooks/telemetry-merge.sh" "$RUN_ID9" "$TELEM_DIR9"
OUT9="$TELEM_DIR9/runs/$RUN_ID9.jsonl"
assert_eq "N1-106: ms boundaries in run-start/run-end/step seconds counted in window" "2" "$(jq '.summary.compaction_count' "$OUT9")"
assert_eq "N1-106: ms boundaries attributed to the step" "2" \
  "$(jq '.orchestrator.steps[] | select(.step=="review") | .compactions' "$OUT9")"

# ==== Test 10: N1-106 malformed compact_boundary records (non-string timestamp, non-dict metadata) ====
RUN_ID10="test-run-010"
TELEM_DIR10="$T/home/memory/TEST-10/telemetry"
mkdir -p "$TELEM_DIR10/raw/steps" "$TELEM_DIR10/raw/agents"
TRANSCRIPT10="$T/sess-010.jsonl"
cat > "$TRANSCRIPT10" <<'TRANSCRIPT'
{"type":"assistant","timestamp":"2026-09-02T10:01:00Z","message":{"id":"q1","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[]}}
{"type":"system","subtype":"compact_boundary","timestamp":123,"compactMetadata":{"trigger":"auto"}}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-09-02T10:05:00.000Z","compactMetadata":"x"}
{"type":"system","subtype":"compact_boundary","timestamp":"2026-09-02T10:06:00.000Z","compactMetadata":{"trigger":"manual","preTokens":6000,"postTokens":1500}}
TRANSCRIPT
cat > "$TELEM_DIR10/raw/steps/$RUN_ID10.jsonl" <<STEPS10
{"layer":"envelope","started_at":"2026-09-02T10:00:00Z","ticket_id":"TEST-10","session_id":"sess-010","host":"claude-code","session_transcript_path":"$TRANSCRIPT10"}
{"layer":"envelope_close","completed_at":"2026-09-02T10:30:00Z","final_outcome":"pr_created"}
STEPS10
: > "$TELEM_DIR10/raw/agents/$RUN_ID10.jsonl"
bash "$REPO_ROOT/hooks/telemetry-merge.sh" "$RUN_ID10" "$TELEM_DIR10"
OUT10="$TELEM_DIR10/runs/$RUN_ID10.jsonl"
# Non-string timestamp is skipped; non-dict metadata degrades to unknown trigger; valid one counted.
assert_eq "N1-106: malformed boundaries do not crash merge; timestamp-123 skipped (count|manual|unknown-trigger)" "2|1|unknown" \
  "$(jq -r '[.summary.compaction_count, .summary.compaction_manual_count, .orchestrator.compactions[0].trigger] | map(tostring) | join("|")' "$OUT10")"

# ==== Test N1-198: fix cycles from outcome events (string values); project from TELEM_DIR ====
mk_fc() { # id outcome-json-or-empty
    local d="$T/fchome/memory/$1/telemetry"
    mkdir -p "$d/raw/steps" "$d/raw/agents"
    echo "{\"run_id\":\"r-$1\",\"n1_version\":\"5.0.0\"}" > "$d/telemetry.lock"
    { echo '{"layer":"envelope","started_at":"2026-09-01T10:00:00Z","ticket_id":"'"$1"'","session_id":"s","host":"claude-code"}'
      [ -z "$2" ] || echo "{\"event\":\"outcome\",\"run_id\":\"r-$1\",\"outcomes\":$2}"
      echo '{"layer":"envelope_close","completed_at":"2026-09-01T10:10:00Z","final_outcome":"pr_created"}'
    } > "$d/raw/steps/r-$1.jsonl"
    : > "$d/raw/agents/r-$1.jsonl"
    env -u N1_HOME bash "$REPO_ROOT/hooks/telemetry-merge.sh" "r-$1" "$d"
    FC_OUT="$d/runs/r-$1.jsonl"
}
fc_pair() { jq -r '"\(.summary.review_fix_cycles)|\(.summary.qa_fix_cycles)"' "$FC_OUT"; }
for pair in "0 0" "1 0" "0 3" "3 1"; do
    set -- $pair; r=$1; q=$2
    mk_fc "FC-$r-$q" "{\"review_fix_cycles\":\"$r\",\"qa_fix_cycles\":\"$q\"}"
    assert_eq "N1-198: fix cycles from string outcome values ($r|$q)" "$r|$q" "$(fc_pair)"
done
assert_eq "N1-198: project derived from TELEM_DIR without N1_HOME" "fchome" "$(jq -r '.project' "$FC_OUT")"
# N1_HOME pointing elsewhere must not override the path-derived project
FCD="$T/fchome/memory/FC-HOME/telemetry"
mkdir -p "$FCD/raw/steps" "$FCD/raw/agents"
echo '{"run_id":"r-FC-HOME","n1_version":"5.0.0"}' > "$FCD/telemetry.lock"
echo '{"layer":"envelope","started_at":"2026-09-01T10:00:00Z","ticket_id":"FC-HOME","session_id":"s","host":"claude-code"}' > "$FCD/raw/steps/r-FC-HOME.jsonl"
: > "$FCD/raw/agents/r-FC-HOME.jsonl"
N1_HOME="$T/otherproj" bash "$REPO_ROOT/hooks/telemetry-merge.sh" "r-FC-HOME" "$FCD"
assert_eq "N1-198: TELEM_DIR path wins over N1_HOME for project" "fchome" "$(jq -r '.project' "$FCD/runs/r-FC-HOME.jsonl")"
# max across multiple outcome events
mk_fc "FC-MAX" '{"review_fix_cycles":"1","qa_fix_cycles":"1"}}
{"event":"outcome","run_id":"r-FC-MAX","outcomes":{"review_fix_cycles":"3","qa_fix_cycles":"0"}'
assert_eq "N1-198: fix cycles use max across outcome events" "3|1" "$(fc_pair)"
# non-numeric values degrade to null without crashing the merge
for bad in '"abc"' '""' '"1.5"' '"²"' '"-1"'; do
    mk_fc "FC-BAD" "{\"review_fix_cycles\":$bad,\"qa_fix_cycles\":$bad}"
    assert_eq "N1-198: non-numeric outcome value $bad -> null" "null|null" "$(fc_pair)"
done
mk_fc "FC-LIST" '["x"]'
assert_eq "N1-198: non-dict outcomes -> null" "null|null" "$(fc_pair)"
mk_fc "FC-NONE" ""
assert_eq "N1-198: no outcome event -> fix cycles null" "null|null" \
    "$(jq -r '"\(.summary.review_fix_cycles)|\(.summary.qa_fix_cycles)"' "$FC_OUT")"

echo "---"
echo "$((PASS+FAIL)) tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

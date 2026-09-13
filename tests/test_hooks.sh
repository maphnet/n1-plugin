#!/usr/bin/env bash
# tests/test_hooks.sh — behavioral tests for enforce-agent-model warning, session-start throttle.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export N1_HOME="$T/home"; export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
mkdir -p "$N1_HOME"
cat > "$N1_HOME/config.json" <<'EOF'
{"planReview":{"requirePlanApproval":true},"autonomy":{"brainstorm":"auto","acceptanceGate":"auto"}}
EOF

# enforce-agent-model: no python → systemMessage once
FAKEBIN="$T/bin"; mkdir -p "$FAKEBIN"
for c in bash jq grep sed cat dirname basename printf head tr awk mv rm mkdir date; do p=$(command -v $c) && ln -sf "$p" "$FAKEBIN/$c"; done
INPUT='{"session_id":"s1","tool_name":"Agent","tool_input":{"subagent_type":"n1:developer"}}'
OUT1=$(echo "$INPUT" | PATH="$FAKEBIN" bash "$REPO_ROOT/hooks/enforce-agent-policy.sh")
OUT2=$(echo "$INPUT" | PATH="$FAKEBIN" bash "$REPO_ROOT/hooks/enforce-agent-policy.sh")
assert_eq "warns once when python missing" "N1: agent model enforcement skipped (no Python interpreter)" "$(echo "$OUT1" | jq -r .systemMessage)"
assert_eq "second call silent" "" "$OUT2"

# session-start throttle: last_checked untouched when gh fails
mkdir -p "$T/ghbin"; printf '#!/usr/bin/env bash\nexit 1\n' > "$T/ghbin/gh"; chmod +x "$T/ghbin/gh"
MEM2="$N1_HOME/memory/T-10"; mkdir -p "$MEM2"
printf -- '---\nstep: pr\nawaiting: merge\npr: 42\ncreated: 2026-09-01T00:00:00Z\nlast_checked: 2026-01-01T00:00:00Z\n---\n' > "$MEM2/overview.md"
echo '{"source":"startup"}' | PATH="$T/ghbin:$PATH" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "last_checked unchanged on gh failure" "last_checked: 2026-01-01T00:00:00Z" "$(grep '^last_checked:' "$MEM2/overview.md")"
printf '#!/usr/bin/env bash\necho MERGED\n' > "$T/ghbin/gh"
echo '{"source":"startup"}' | PATH="$T/ghbin:$PATH" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
[ "$(grep '^last_checked:' "$MEM2/overview.md")" != "last_checked: 2026-01-01T00:00:00Z" ] && { echo "PASS: last_checked advanced on success"; PASS=$((PASS+1)); } || { echo "FAIL: last_checked advanced on success"; FAIL=$((FAIL+1)); }

# --- enforce-agent-policy (both hosts) -------------------------------------
FX="$REPO_ROOT/tests/fixtures/hooks"
cat > "$N1_HOME/config.json" <<'EOF'
{"models":{"developer":{"claude-code":"opus","codex":"gpt-5.6"}}}
EOF
POLICY="$REPO_ROOT/hooks/enforce-agent-policy.sh"
OUT=$(N1_HOST=claude-code bash "$POLICY" < "$FX/claude/pretooluse-spawn.json")
assert_eq "claude spawn override model" "opus" "$(echo "$OUT" | jq -r .hookSpecificOutput.updatedInput.model)"
OUT=$(N1_HOST=codex bash "$POLICY" < "$FX/codex/pretooluse-spawn.json")
assert_eq "codex spawn override model" "gpt-5.6" "$(echo "$OUT" | jq -r .hookSpecificOutput.updatedInput.model)"
assert_eq "codex spawn override keeps task_name" "fix-1" "$(echo "$OUT" | jq -r .hookSpecificOutput.updatedInput.task_name)"
set +e
N1_HOST=claude-code bash "$POLICY" < "$FX/claude/pretooluse-persona-denied.json" 2>"$T/err"; RC=$?
set -e
assert_eq "claude persona denial exit 2" "2" "$RC"
assert_eq "claude persona denial reason" "N1: persona code-reviewer may not use tool Edit (allowed: Glob, Grep, Read)" "$(cat "$T/err")"
set +e
N1_HOST=codex bash "$POLICY" < "$FX/codex/pretooluse-persona-denied.json" 2>"$T/err"; RC=$?
set -e
assert_eq "codex persona denial exit 2" "2" "$RC"
assert_eq "codex apply_patch denied for read-only persona" "N1: persona code-reviewer may not use tool apply_patch (allowed: Glob, Grep, Read)" "$(cat "$T/err")"
OUT=$(N1_HOST=codex bash "$POLICY" < "$FX/codex/pretooluse-persona-allowed.json"); RC=$?
assert_eq "codex exec_command allowed for read-only persona" "0:" "$RC:$OUT"
OUT=$(N1_HOST=claude-code bash "$POLICY" < "$FX/claude/pretooluse-persona-allowed.json"); RC=$?
assert_eq "claude Grep allowed for read-only persona" "0:" "$RC:$OUT"
OUT=$(echo '{"tool_name":"Read","agent_type":"general-purpose","tool_input":{}}' | N1_HOST=claude-code bash "$POLICY"); RC=$?
assert_eq "foreign agent passthrough" "0:" "$RC:$OUT"

# --- telemetry hooks accept the Codex persona prefix -----------------------
MEM3="$N1_HOME/memory/T-20/telemetry"; mkdir -p "$MEM3"
echo '{"run_id":"n1-run-x","n1_version":"3.0.0"}' > "$MEM3/telemetry.lock"
N1_HOST=codex bash "$REPO_ROOT/hooks/telemetry-agent-start.sh" < "$FX/codex/subagent-start.json"
assert_eq "codex agent start recorded" "n1-developer" "$(jq -r .agent_type "$MEM3/raw/agents/n1-run-x.jsonl")"
N1_HOST=claude-code bash "$REPO_ROOT/hooks/telemetry-agent-start.sh" < "$FX/claude/subagent-start.json"
assert_eq "claude agent start recorded" "2" "$(wc -l < "$MEM3/raw/agents/n1-run-x.jsonl")"

echo; echo "Passed: $PASS  Failed: $FAIL"; [ "$FAIL" -eq 0 ]

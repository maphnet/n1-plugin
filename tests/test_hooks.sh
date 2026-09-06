#!/usr/bin/env bash
# tests/test_hooks.sh — behavioral tests for pipeline-continue, enforce-agent-model warning, session-start throttle.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export N1_HOME="$T/home"; export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
MEM="$N1_HOME/memory/T-9"; mkdir -p "$MEM"
echo '{"ticketId":"T-9"}' > "$N1_HOME/active-run.json"
cat > "$N1_HOME/config.json" <<'EOF'
{"planReview":{"requirePlanApproval":true},"autonomy":{"brainstorm":"auto","acceptanceGate":"auto"}}
EOF
run_stop() { echo '{"stop_hook_active":false}' | bash "$REPO_ROOT/hooks/pipeline-continue.sh" >/dev/null 2>&1; echo $?; }

printf -- '---\nstep: plan\n---\n' > "$MEM/overview.md"
assert_eq "plan approval pending allows stop" "0" "$(run_stop)"
printf -- '---\nstep: plan\nplan_approved: true\n---\n' > "$MEM/overview.md"
assert_eq "plan approved blocks stop" "2" "$(run_stop)"
printf -- '---\nstep: implementation\npending_prompt: dirty tree — commit or discard?\n---\n' > "$MEM/overview.md"
assert_eq "pending prompt allows stop" "0" "$(run_stop)"
printf -- '---\nstep: implementation\npending_prompt: \n---\n' > "$MEM/overview.md"
assert_eq "cleared prompt blocks stop" "2" "$(run_stop)"

# enforce-agent-model: no python → systemMessage once
FAKEBIN="$T/bin"; mkdir -p "$FAKEBIN"
for c in bash jq grep sed cat dirname basename printf head tr awk mv rm mkdir date; do p=$(command -v $c) && ln -sf "$p" "$FAKEBIN/$c"; done
INPUT='{"session_id":"s1","tool_input":{"subagent_type":"n1:developer"}}'
OUT1=$(echo "$INPUT" | PATH="$FAKEBIN" bash "$REPO_ROOT/hooks/enforce-agent-model.sh")
OUT2=$(echo "$INPUT" | PATH="$FAKEBIN" bash "$REPO_ROOT/hooks/enforce-agent-model.sh")
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

echo; echo "Passed: $PASS  Failed: $FAIL"; [ "$FAIL" -eq 0 ]

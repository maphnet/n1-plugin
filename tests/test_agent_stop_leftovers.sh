#!/usr/bin/env bash
# tests/test_agent_stop_leftovers.sh -- N1-317: telemetry-agent-stop.sh reports (never kills) `bash -c` shells a
# persona left running in the run's worktree, once per shell, with pid and age.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
[ -r /proc/self/cwd ] || { echo "SKIP: no /proc (leftover scan is Linux-only)"; exit 0; }
T=$(mktemp -d); PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done; rm -rf "$T"; }
trap cleanup EXIT
unset N1_RUN_ID N1_SESSION_ID CLAUDE_CODE_SESSION_ID ORCA_CLI_COMMAND N1_QUEUE_RUN_ID N1_HEADLESS
export N1_HOME="$T/home" N1_STATE_DIR="$T/state"
WT="$T/wt"; ELSEWHERE="$T/elsewhere"; mkdir -p "$WT/sub" "$ELSEWHERE"
TEL="$N1_HOME/memory/T-1/telemetry"; mkdir -p "$TEL/locks"
echo '{"run_id":"r1","n1_version":"9.9.9","host":"claude-code","session_id":"s1"}' > "$TEL/locks/r1.json"
jq -n --arg w "$WT" '{ticketId:"T-1",worktreePath:$w}' > "$N1_HOME/active-run.s1.json"
RAW="$TEL/raw/agents/r1.jsonl"

spawn() {  # spawn <dir>: background `bash -c` with cwd <dir>; sets SPAWNED once its argv is `bash -c`
    (cd "$1" && exec bash -c 'sleep 60; :') &
    SPAWNED=$!; PIDS+=("$SPAWNED")
    local i=0
    until [ "$(head -c 7 "/proc/$SPAWNED/cmdline" 2>/dev/null | tr '\0' ' ')" = "bash -c" ] || [ $i -ge 50 ]; do sleep 0.1; i=$((i+1)); done
}
stop() {  # stop <agent_id>: run the stop hook as a developer persona; stdout+stderr -> $T/err; prints the exit code
    local rc=0
    jq -cn --arg a "$1" --arg c "$WT" '{session_id:"s1",cwd:$c,hook_event_name:"SubagentStop",agent_type:"n1:developer",agent_id:$a}' \
        | bash "$REPO_ROOT/hooks/telemetry-agent-stop.sh" >"$T/err" 2>&1 || rc=$?
    echo "$rc"
}
last_has_field() { tail -n 1 "$RAW" | jq -r 'has("leftover_shells")'; }

# (d) no leftover: the stop line has no leftover_shells field and nothing is printed
assert_eq "no leftover: hook exits 0" 0 "$(stop a0)"
assert_eq "no leftover: no field" false "$(last_has_field)"
assert_eq "no leftover: silent" "" "$(cat "$T/err")"

# (a) a shell left in a worktree subdir is reported with pid and age, and kept alive
spawn "$WT/sub"; P1=$SPAWNED
assert_eq "leftover: hook exits 0" 0 "$(stop a1)"
assert_eq "leftover: warning names pid and age" yes "$(grep -qE "pid $P1 age [0-9]+s" "$T/err" && echo yes || echo no)"
assert_eq "leftover: warning says not killed" yes "$(grep -qF 'reported, not killed' "$T/err" && echo yes || echo no)"
assert_eq "leftover: stop line is valid JSON" ok "$(tail -n 1 "$RAW" | jq -e . >/dev/null && echo ok || echo bad)"
assert_eq "leftover: field carries the pid" "$P1" "$(tail -n 1 "$RAW" | jq -r '.leftover_shells[0].pid')"
assert_eq "leftover: field carries a numeric age" number "$(tail -n 1 "$RAW" | jq -r '.leftover_shells[0].age_s | type')"
assert_eq "leftover: shell not killed" alive "$(kill -0 "$P1" 2>/dev/null && echo alive || echo dead)"

# the warning only reaches the user from a synchronous hook with a systemMessage on stdout
assert_eq "leftover: output is a systemMessage" ok "$(jq -e '.systemMessage|test("pid [0-9]+ age")' "$T/err" >/dev/null 2>&1 && echo ok || echo bad)"
assert_eq "hooks.json: agent-stop hook is synchronous" false "$(jq '[.hooks.SubagentStop[].hooks[] | select(.command | contains("telemetry-agent-stop.sh")) | .async // false] | any' "$REPO_ROOT/hooks/hooks.json")"

# (b)+(c) a second stop is silent for the already-reported shell; a shell outside the worktree is never reported
spawn "$ELSEWHERE"; P2=$SPAWNED
assert_eq "second stop: hook exits 0" 0 "$(stop a2)"
assert_eq "second stop: reported once (silent)" "" "$(cat "$T/err")"
assert_eq "second stop: no field" false "$(last_has_field)"

# (e) a shell that started before this agent's start event is not attributed to it (and not marked as reported)
spawn "$WT"; P3=$SPAWNED
printf '{"run_id":"r1","layer":"agent","event":"start","agent_id":"a4","agent_type":"n1:developer","started_at":"%s"}\n' \
    "$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)" >> "$RAW"
assert_eq "older shell: hook exits 0" 0 "$(stop a4)"
assert_eq "older shell: not reported" "" "$(cat "$T/err")"
assert_eq "older shell: reported to an agent without a start event" yes "$(stop a5 >/dev/null; grep -qE "pid $P3 age [0-9]+s" "$T/err" && echo yes || echo no)"
assert_eq "outside worktree: never reported" no "$(grep -qE "pid $P2 " "$T/err" && echo yes || echo no)"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

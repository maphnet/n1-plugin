#!/usr/bin/env bash
# N1-342: hooks/stuck-detector.sh nudges on the 3rd identical failing Bash call, denies the next identical
# call after 5, resets on any success/edit or a different failure, exempts polls, and records telemetry.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_SESSION_ID CLAUDE_CODE_SESSION_ID N1_RUN_ID
export N1_HOME="$T/home" CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
mkdir -p "$N1_HOME"
H="$REPO_ROOT/hooks/stuck-detector.sh"
SD="$N1_HOME/scratch/stuck"
ERR=$'Exit code 1\nboom: no such file'

hookr() { # <event> <command> [error]; env SID (default s1), AID (default none), TOOL (default Bash), DESC; prints "<rc>|<stdout>"
    local out rc
    out=$(jq -nc --arg e "$1" --arg c "$2" --arg err "${3-}" --arg cwd "$T" --arg sid "${SID-s1}" \
        --arg aid "${AID-}" --arg t "${TOOL-Bash}" --arg d "${DESC-run it}" \
        '{session_id:$sid,cwd:$cwd,hook_event_name:$e,tool_name:$t,tool_input:{command:$c,description:$d}}
         + (if $aid == "" then {} else {agent_id:$aid} end)
         + (if $e == "PostToolUseFailure" then {error:$err} else {} end)' | bash "$H" 2>"$T/stderr"); rc=$?
    printf '%s|%s' "$rc" "$out"
}
fail() { hookr PostToolUseFailure "$1" "${2-$ERR}"; }
pre() { hookr PreToolUse "$1"; }
ok() { hookr PostToolUse "$1"; }
ctx() { jq -r '.hookSpecificOutput | select(.hookEventName == "PostToolUseFailure") | .additionalContext' <<<"${1#*|}" 2>/dev/null; }
nudges() { grep -c 'additionalContext' "$1" 2>/dev/null || true; }
reset() { rm -rf "$SD"; }

# AC1: the 3rd identical failure nudges exactly once; 1st, 2nd, 4th, 5th are silent
reset; : > "$T/out"
for i in 1 2 3 4 5; do printf '%s\n' "$(fail "make test")" >> "$T/out"; done
assert_eq "five identical failures: exactly one nudge" "1" "$(nudges "$T/out")"
assert_eq "nudge is on the 3rd failure" "yes" "$(sed -n 3p "$T/out" | grep -q 'failed 3 times' && echo yes || echo no)"
assert_eq "failures 1 and 2 are silent" "0|
0|" "$(sed -n 1,2p "$T/out")"

# AC2: after 5 identical failures the next identical call is denied with a reason; before that it is allowed
reset; for i in 1 2 3 4; do fail "make test" >/dev/null; done
assert_eq "after 4 failures: identical call allowed" "0|" "$(pre "make test")"
fail "make test" >/dev/null
assert_eq "after 5 failures: identical call denied (rc 2)" "2|" "$(pre "make test")"
assert_eq "deny reason on stderr" "yes" "$(grep -q 'failed 5 times' "$T/stderr" && echo yes || echo no)"
assert_eq "deny persists for a repeated identical call" "2|" "$(pre "make test")"
assert_eq "different call is not denied" "0|" "$(pre "make lint")"
ok "make lint" >/dev/null
assert_eq "a success clears the deny" "0|" "$(pre "make test")"

# AC2 reset: a different failing call in between resets the count
reset; fail "make test" >/dev/null; fail "make test" >/dev/null; fail "make lint" >/dev/null
: > "$T/out"; fail "make test" >> "$T/out"; fail "make test" >> "$T/out"
assert_eq "different failure in between: no nudge" "0" "$(nudges "$T/out")"
reset; fail "make test" >/dev/null; fail "make test" >/dev/null; ok "make test" >/dev/null
: > "$T/out"; fail "make test" >> "$T/out"; fail "make test" >> "$T/out"
assert_eq "success of the same call resets" "0" "$(nudges "$T/out")"
reset; fail "make test" >/dev/null; fail "make test" >/dev/null; TOOL=Edit ok "" >/dev/null
: > "$T/out"; fail "make test" >> "$T/out"; fail "make test" >> "$T/out"
assert_eq "an Edit resets" "0" "$(nudges "$T/out")"
reset; fail "make test" $'Exit code 1\nerr A' >/dev/null; fail "make test" $'Exit code 1\nerr A' >/dev/null
: > "$T/out"; fail "make test" $'Exit code 1\nerr B' >> "$T/out"; fail "make test" $'Exit code 1\nerr B' >> "$T/out"
assert_eq "same command, different error text: new streak" "0" "$(nudges "$T/out")"
reset; : > "$T/out"
for e in $'Exit code 1\nat 12:00:01 pid 123' $'Exit code 1\nat 12:00:07 pid 456' $'Exit code 1\nat 13:10:59 pid 9'; do
    fail "make test" "$e" >> "$T/out"
done
assert_eq "digit-only error variance is one streak" "1" "$(nudges "$T/out")"
reset; : > "$T/out"
for d in one two three; do DESC="$d" fail "make test" >> "$T/out"; done
assert_eq "description variance is one streak" "1" "$(nudges "$T/out")"

# AC3: calls that repeat by design never trigger the ladder
reset; : > "$T/out"
for i in 1 2 3 4 5 6; do ok "n1_wait_ci_checks 12" >> "$T/out"; done
assert_eq "six identical successful polls: silent" "0" "$(nudges "$T/out")"
for i in 1 2 3 4 5 6; do fail "gh pr checks 12" $'Exit code 8\nsome checks are still pending' >> "$T/out"; done
assert_eq "six identical failing gh pr checks: no nudge" "0" "$(nudges "$T/out")"
assert_eq "failing polls: identical call never denied" "0|" "$(pre "gh pr checks 12")"
assert_eq "failing polls: no state written" "0" "$(find "$SD" -type f 2>/dev/null | wc -l | tr -d ' ')"

# Keying: per agent; invalid ids write nothing
reset; AID=a1 fail "make test" >/dev/null; AID=a1 fail "make test" >/dev/null
AID=a2 fail "make test" >/dev/null; AID=a2 fail "make test" >/dev/null
assert_eq "agent a1 3rd failure nudges" "1" "$(AID=a1 fail "make test" > "$T/out"; nudges "$T/out")"
assert_eq "agent a2 streak independent (2 so far)" "2" "$(cut -d' ' -f3 "$SD/s1.a2")"
assert_eq "one state file per agent" "s1.a1 s1.a2" "$(cd "$SD" && ls | tr '\n' ' ' | sed 's/ $//')"
reset
for s in '../x' '' 's 1' 'a/b'; do
    assert_eq "invalid session [$s]: rc 0, silent" "0|" "$(SID="$s" fail "make test")"
done
assert_eq "invalid agent id: rc 0, silent" "0|" "$(AID='../a' fail "make test")"
assert_eq "invalid ids: no state written" "0" "$(find "$SD" -type f 2>/dev/null | wc -l | tr -d ' ')"
out=$(printf 'not json' | bash "$H"); rc=$?
assert_eq "garbage stdin: rc 0, silent" "0|" "$rc|$out"

# State: hashes only, under scratch/stuck; a symlinked state file is never followed
reset; for i in 1 2; do fail "make test SECRET_TOKEN" $'Exit code 1\nboom LEAKME' >/dev/null; done
assert_eq "state is one line of hashes + counters" "1" "$(grep -Ec '^[0-9a-f]+ [0-9a-f]+ 2 0$' "$SD/s1.main")"
assert_eq "state holds no command or error text" "0" "$(grep -Ec 'SECRET_TOKEN|LEAKME|make' "$SD/s1.main")"
reset; mkdir -p "$SD"; printf 'keep' > "$T/victim"; ln -s "$T/victim" "$SD/s1.main"
for i in 1 2 3; do fail "make test" >/dev/null; done
assert_eq "symlinked state: target untouched" "keep" "$(cat "$T/victim")"
reset
assert_eq "no lock yet: no telemetry written" "0" "$(find "$N1_HOME/memory" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"

# AC4: telemetry records the nudge and the stop (once each per streak); no lock for the session -> nothing
TD="$N1_HOME/memory/T-1/telemetry"; RAW="$TD/raw/steps/r1.jsonl"
mkdir -p "$TD/locks" "$TD/raw/steps"
printf '{"run_id":"r1","n1_version":"9.9.9","session_id":"s1","host":"claude-code"}\n' > "$TD/locks/r1.json"
printf '{"layer":"envelope_open","run_id":"r1","ticket_id":"T-1"}\n' > "$RAW"
reset; for i in 1 2 3 4 5; do fail "make test" >/dev/null; done; pre "make test" >/dev/null; pre "make test" >/dev/null
assert_eq "telemetry: nudge at 3, stop at 5" '[["nudge",3,"T-1","main","s1","Bash"],["stop",5,"T-1","main","s1","Bash"]]' \
    "$(jq -sc '[.[] | select(.event == "stuck") | [.kind, .count, .ticket_id, .agent_id, .session_id, .tool]]' "$RAW")"
assert_eq "telemetry: hash is 12 hex chars" "true" "$(jq -s '[.[] | select(.event == "stuck") | .hash | test("^[0-9a-f]{12}$")] | all' "$RAW")"
for i in 1 2 3; do SID=s9 fail "make test" >/dev/null; done
assert_eq "session without a lock: no telemetry line" "2" "$(jq -s '[.[] | select(.event == "stuck")] | length' "$RAW")"
bash "$REPO_ROOT/hooks/telemetry-merge.sh" r1 "$TD" >/dev/null 2>&1; rc=$?
assert_eq "telemetry-merge accepts stuck events" "0" "$rc"
assert_eq "merged run is valid JSON" "ok" "$(jq -e . "$TD/runs/r1.jsonl" >/dev/null 2>&1 && echo ok || echo bad)"

# Registration: three synchronous entries; existing entries untouched
HJ="$REPO_ROOT/hooks/hooks.json"
reg() { jq -r --arg e "$1" '[.hooks[$e][] | select(any(.hooks[]; .command | contains("stuck-detector.sh"))) | .matcher // ""] | join(",")' "$HJ"; }
assert_eq "hooks.json: PreToolUse matcher" "Bash" "$(reg PreToolUse)"
assert_eq "hooks.json: PostToolUseFailure matcher" "Bash" "$(reg PostToolUseFailure)"
PM='^(Bash|Edit|Write|MultiEdit|NotebookEdit)$'
assert_eq "hooks.json: PostToolUse reset matcher" "$PM" "$(reg PostToolUse)"
assert_eq "hooks.json: stuck detector is synchronous" "false" \
    "$(jq '[.hooks[][] .hooks[] | select(.command | contains("stuck-detector.sh")) | .async // false] | any' "$HJ")"
assert_eq "hooks.json: three stuck-detector commands" "3" \
    "$(jq '[.hooks[][] .hooks[] | select(.command | contains("stuck-detector.sh"))] | length' "$HJ")"
assert_eq "hooks.json: pr-review-observe still on PostToolUseFailure Bash" "1" \
    "$(jq '[.hooks.PostToolUseFailure[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("pr-review-observe.sh"))] | length' "$HJ")"
assert_eq "hooks.json: enforce-agent-policy stays the first, matcher-less PreToolUse entry" "true|" \
    "$(jq -r '.hooks.PreToolUse[0] | "\(.hooks[0].command | contains("enforce-agent-policy.sh"))|\(.matcher // "")"' "$HJ")"
for t in Bash Edit Write MultiEdit NotebookEdit; do
    assert_eq "reset matcher selects $t" "yes" "$([[ "$t" =~ $PM ]] && echo yes || echo no)"
done
for t in Read Grep Glob mcp__x__Bash BashOutput; do
    assert_eq "reset matcher skips $t" "no" "$([[ "$t" =~ $PM ]] && echo yes || echo no)"
done

# Stale sweep at session start: state older than a day is removed, fresh state kept (behavioral; session-start.sh
# exits early for an unconfigured project, so the fixture needs a config.json; precedent: tests/test_hooks.sh:695)
echo '{}' > "$N1_HOME/config.json"
reset
mkdir -p "$SD"; printf 'a b 3 1\n' > "$SD/old"; printf 'a b 3 1\n' > "$SD/fresh"; touch -d '3 days ago' "$SD/old"
echo '{"session_id":"s-sweep","source":"resume"}' | N1_STATE_DIR="$T/state" N1_HOST_FILE="$T/host.json" \
    bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
assert_eq "session-start sweeps stale stuck state, keeps fresh" "fresh" "$(ls "$SD" | tr '\n' ' ' | sed 's/ $//')"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

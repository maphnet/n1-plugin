#!/usr/bin/env bash
# tests/test_orca_beacon.sh
# N1-315: hook-sent progress beacons (n1_orca_beacon in lib/orca-queue.sh and its hook call sites).
# Fake Orca CLI only. Sends are backgrounded, so assertions wait for the call log to settle.
# Run: bash tests/test_orca_beacon.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1 ($2)"; FAIL=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi; }
has() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "'$2' not in '$3'";; esac; }

T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
export FAKE="$T/fake"; mkdir -p "$FAKE/bin"; : > "$FAKE/calls"
# Fake Orca CLI: logs argv. FAKE_ORCA_FAIL: rc 1. FAKE_ORCA_HANG: sleeps past n1_orca's 5 s timeout (no log line).
cat > "$FAKE/bin/fake-orca" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_ORCA_HANG:-}" ] && sleep 10
printf '%s\n' "$*" >> "$FAKE/calls"
[ -n "${FAKE_ORCA_FAIL:-}" ] && { printf '{"id":"1","ok":false,"error":{"code":"x","message":"down"}}\n'; exit 1; }
printf '{"id":"1","ok":true,"result":{}}\n'
EOF
chmod +x "$FAKE/bin/fake-orca"
export PATH="$FAKE/bin:$PATH" ORCA_CLI_COMMAND="$FAKE/bin/fake-orca"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_HOME="$T/home"; mkdir -p "$N1_HOME/memory/T-1"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME="$T/hh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset N1_HEADLESS N1_QUEUE_RUN_ID N1_UNATTENDED N1_QUEUE_DIR N1_QUEUE_TAG N1_SESSION_ID CLAUDE_CODE_SESSION_ID N1_RUN_ID ORCA_TERMINAL_HANDLE CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR
source "$REPO_ROOT/lib/config.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/queue.sh"
source "$REPO_ROOT/lib/orca-queue.sh"

# Queue child T-1: worktree folder named after the ticket, identity file for run R1, dispatch d-1.
M="$T/main"; git init -q -b main "$M"; git -C "$M" commit -q --allow-empty -m init
mkdir -p "$T/wts"; WT="$T/wts/T-1"; git -C "$M" worktree add -q -b t1 "$WT" main
Q="$N1_HOME/queue/q1"; mkdir -p "$Q"
printf -- '---\nqueue_id: q1\nrun_id: R1\norca_run_id: run-1\nstep: run\n---\n' > "$Q/queue.md"
N1_QUEUE_DIR="$Q" n1_orca_sentinel_write "$N1_HOME" T-1 "$M" R1 run-1 task-1
n1_orca_sentinel_set "$N1_HOME" T-1 N1_ORCA_DISPATCH d-1
OV="$N1_HOME/memory/T-1/overview.md"; STAMP="$N1_HOME/queue/sentinels/T-1.beacon"

setstep() { printf -- '---\nstep: %s\ncurrent_step: %s\n---\n' "$1" "${2:-}" > "$OV"; }   # <step> [current_step]
hbs() { grep -c 'send --type heartbeat' "$FAKE/calls" 2>/dev/null || true; }
# settle <n>: wait up to 5 s for n heartbeat sends, then 0.3 s more so an unexpected extra send is counted too.
settle() { local i; for i in $(seq 50); do [ "$(hbs)" -ge "$1" ] && break; sleep 0.1; done; sleep 0.3; hbs; }
lasthb() { grep 'send --type heartbeat' "$FAKE/calls" | tail -1; }
beacon() { (cd "$WT" && n1_orca_child_env "$WT" && n1_orca_beacon "$@"); }

# --- Task 1: helper ---
setstep plan implement
beacon start n1:developer
eq "beacon: persona start sends one heartbeat" 1 "$(settle 1)"
has "beacon: start phase is step/persona, bound to task and dispatch" \
    "send --type heartbeat --phase implement/developer --subject alive --task-id task-1 --dispatch-id d-1" "$(lasthb)"
beacon start n1:developer
eq "beacon: unchanged phase sends nothing" 1 "$(settle 1)"
beacon tick
eq "beacon: tick inside a persona (same step) sends nothing" 1 "$(settle 1)"
beacon stop n1:developer
eq "beacon: persona finish sends one heartbeat" 2 "$(settle 2)"
has "beacon: stop phase is the step alone" "--phase implement --subject" "$(lasthb)"
setstep implement review
beacon tick
eq "beacon: step change sends one heartbeat" 3 "$(settle 3)"
has "beacon: current_step wins over step" "--phase review --subject" "$(lasthb)"
beacon tick
eq "beacon: same step again sends nothing" 3 "$(settle 3)"
touch -d '11 minutes ago' "$STAMP"
beacon tick
eq "beacon: 10-minute floor resends the unchanged phase" 4 "$(settle 4)"
setstep 'impl;$(x)' ''
beacon tick
eq "beacon: sanitised phase still sends" 5 "$(settle 5)"
has "beacon: phase limited to [A-Za-z0-9_.-]" "--phase implx --subject" "$(lasthb)"
setstep '' ''
beacon tick
eq "beacon: empty step sends nothing" 5 "$(settle 5)"
eq "beacon: no identity -> rc 0, no send" "0|5" "$( (unset N1_ORCA_TASK N1_ORCA_DISPATCH N1_ORCA_SENTINEL; n1_orca_beacon tick; echo "$?|$(settle 5)") )"
setstep fail ''
eq "beacon: failing send still returns 0" 0 "$( (export FAKE_ORCA_FAIL=1; beacon tick; echo $?) )"
eq "beacon: failing send was attempted" 6 "$(settle 6)"
setstep hang ''
s=$SECONDS; (export FAKE_ORCA_HANG=1; beacon tick); took=$((SECONDS - s))
eq "beacon: a hung send never blocks the caller" yes "$([ "$took" -lt 2 ] && echo yes || echo no)"

# --- Task 2: hook call sites (each hook loads the identity itself, before any early exit) ---
# hook <script> <payload> — runs a hook as a child session in $WT; prints its exit code.
hook() { printf '%s' "$2" | (cd "$WT" && CLAUDE_PROJECT_DIR="$WT" bash "$REPO_ROOT/hooks/$1" >/dev/null 2>&1); echo $?; }
AGENT='{"session_id":"s1","agent_type":"n1:developer","agent_id":"a1"}'
: > "$FAKE/calls"; rm -f "$STAMP"; setstep plan implement
eq "hook start: exit 0 with no telemetry lock" 0 "$(hook telemetry-agent-start.sh "$AGENT")"
eq "hook start: one heartbeat" 1 "$(settle 1)"
has "hook start: step/persona phase" "--phase implement/developer --subject" "$(lasthb)"
eq "hook stop: exit 0" 0 "$(hook telemetry-agent-stop.sh "$AGENT")"
eq "hook stop: one heartbeat" 2 "$(settle 2)"
has "hook stop: step phase" "--phase implement --subject" "$(lasthb)"
setstep implement review
eq "hook PostToolUse Bash: exit 0" 0 "$(hook pr-review-observe.sh '{"session_id":"s1","tool_input":{"command":"ls"}}')"
eq "hook PostToolUse Bash: step change beacons" 3 "$(settle 3)"
has "hook PostToolUse Bash: phase" "--phase review --subject" "$(lasthb)"
eq "hook Stop: exit 0" 0 "$(hook session-stop.sh '{"session_id":"s1"}')"
eq "hook Stop: same step sends nothing" 3 "$(settle 3)"
setstep review qa
hook session-stop.sh '{"session_id":"s1"}' >/dev/null
eq "hook Stop: step change beacons" 4 "$(settle 4)"
eq "hook Stop: mid-pipeline turn end still sends no worker_done" 0 "$(grep -c 'type worker_done' "$FAKE/calls" || true)"
setstep qa ci
printf '{"session_id":"s1"}' | (cd "$M" && CLAUDE_PROJECT_DIR="$M" bash "$REPO_ROOT/hooks/session-stop.sh" >/dev/null 2>&1)
eq "hook: non-queue checkout sends nothing" 4 "$(settle 4)"
eq "hook: failing send never fails the hook" 0 "$( (export FAKE_ORCA_FAIL=1; hook pr-review-observe.sh '{"session_id":"s1","tool_input":{"command":"ls"}}') )"

# Keep this last: it rewrites, then removes, the identity.
: > "$STAMP"; N1_QUEUE_DIR="$Q" n1_orca_sentinel_write "$N1_HOME" T-1 "$M" R1 run-1 task-1
eq "sentinel_write: a retry does not inherit the previous attempt's beacon stamp" no "$([ -e "$STAMP" ] && echo yes || echo no)"
: > "$STAMP"; n1_orca_sentinel_rm "$N1_HOME" T-1
eq "sentinel_rm: beacon stamp goes with the identity" no "$([ -e "$STAMP" ] && echo yes || echo no)"

echo "---"; [ "$FAIL" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
[ "$FAIL" -eq 0 ]

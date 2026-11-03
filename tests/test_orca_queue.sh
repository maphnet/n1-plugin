#!/usr/bin/env bash
# tests/test_orca_queue.sh
# N1-225: Orca orchestration backend for n1-queue (lib/orca-queue.sh): backend choice, orchestration wrappers,
# identity sentinel + loader, hook wiring, child ask, --answer reply. Fake Orca CLI only (no live Orca).
# Every helper that may consult n1_orca_active runs inside $( ) so its per-process cache never leaks.
# Run: bash tests/test_orca_queue.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1 -- $2"; FAIL=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi; }
has() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "'$2' not in '$3'";; esac; }
hasnt() { case "$3" in *"$2"*) no "$1" "'$2' unexpectedly in '$3'";; *) ok "$1";; esac; }
rc() { "$@" >/dev/null 2>&1; echo $?; }

T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
export FAKE="$T/fake"; mkdir -p "$FAKE/bin"; : > "$FAKE/calls"

# Fake Orca CLI: logs argv, FAKE_* env toggles failures. n1_orca appends --json last.
cat > "$FAKE/bin/fake-orca" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/calls"
ok() { printf '{"id":"1","ok":true,"result":%s}\n' "$1"; }
err() { printf '{"id":"1","ok":false,"error":{"code":"x","message":"%s","data":{"failedStage":"%s"}}}\n' "$1" "${2:-}"; exit 1; }
has() { local k="$1"; shift; for a; do [ "$a" = "$k" ] && return 0; done; return 1; }
# Real 1.4.247 CLI: concise receipts unless --full; --full is an unknown flag outside orchestration.
if has --full "$@" && [ "$1" != orchestration ]; then err "Unknown flag --full" invalid_argument; fi
case "$1 $2" in
  "status --json") [ -n "${FAKE_ORCA_DOWN:-}" ] && err "runtime down"; ok '{"runtime":{"reachable":true}}' ;;
  "orchestration run-create") [ -n "${FAKE_ORCA_RUN_FAIL:-}" ] && err "unknown command"; 
      if has --full "$@"; then ok "{\"run\":{\"id\":\"${FAKE_ORCA_RUN_ID:-run-1}\"}}"; else ok "{\"runId\":\"${FAKE_ORCA_RUN_ID:-run-1}\",\"objective\":\"x\"}"; fi ;;
  "orchestration task-create") if has --full "$@"; then ok '{"task":{"id":"task-1"}}'; else ok '{"taskId":"task-1","status":"ready"}'; fi ;;
  "orchestration worker-start")
      has --model "$@" && [ -n "${FAKE_ORCA_MODEL_REJECT:-}" ] && err "unsupported model" validate
      [ -n "${FAKE_ORCA_START_FAIL:-}" ] && err "setup failed" worktree-setup
      [ -n "${FAKE_ORCA_START_RC1:-}" ] && { ok '{"dispatch":{"id":"d-1"}}'; exit 1; }   # ok:true receipt, exit 1
      ok '{"dispatch":{"id":"d-1"}}' ;;
  "orchestration send"|"orchestration reply") [ -n "${FAKE_ORCA_REPLY_FAIL:-}" ] && err "reply failed"
      [ -n "${FAKE_COORD_DEAD:-}" ] && has --from "$@" && err "terminal not found"; ok '{}' ;;
  "orchestration ask")
      case "${FAKE_ASK:-answer}" in
        answer) ok '{"answer":"Use B"}' ;;
        pending) ok '{"messageId":"m-7","status":"timeout"}' ;;
        *) err "runtime down" ;;
      esac ;;
  "orchestration check") if has --all "$@"; then
          [ -n "${FAKE_COORD_DEAD:-}" ] && has --terminal "$@" && err "terminal not found"
          ok "{\"messages\":[${FAKE_INBOX:-}]}"
      else ok '{}'; fi ;;
  "terminal create") [ -n "${FAKE_TERM_FAIL:-}" ] && err "no terminal"; j='{"terminal":{"handle":"term-9"}}'; ok "${FAKE_TERM_JSON:-$j}" ;;
  "terminal close") ok '{}' ;;
  "worktree list") case "${FAKE_WT:-fail}" in fail) err "boom" ;; none) ok '{"worktrees":[]}' ;; *) ok '{"worktrees":[{"path":"/w/T-1"}]}' ;; esac ;;
  "orchestration worker-list") [ -n "${FAKE_WL_EMPTY:-}" ] && ok '{}' && exit 0
      # Real Orca 1.4.243 rows: released, running, finished (reclaimable), failed, unknown state with no projection.
      ok '{"workers":[
        {"dispatchId":"d-1","taskId":"task-1","workerState":"succeeded","dispatchStatus":"completed","terminalState":"released","projection":{"outcome":"succeeded","liveness":{"verdict":"exited","source":"resource_release"},"nextAction":{"kind":"none","argv":[]}}},
        {"dispatchId":"d-2","taskId":"task-2","workerState":"ready","dispatchStatus":"dispatched","terminalState":"active","projection":{"outcome":"in_progress","liveness":{"verdict":"live"},"nextAction":{"kind":"none","argv":[]}}},
        {"dispatchId":"d-3","taskId":"task-3","workerState":"succeeded","dispatchStatus":"completed","terminalState":"reclaimable","projection":{"outcome":"succeeded","liveness":{"verdict":"unverifiable","reason":"missing_status"},"nextAction":{"kind":"release","argv":[]}}},
        {"dispatchId":"d-4","taskId":"task-4","workerState":"failed","dispatchStatus":"failed","terminalState":"reclaimable","projection":{"outcome":"failed","liveness":{"verdict":"unverifiable","reason":"missing_status"},"nextAction":{"kind":"release","argv":[]}}},
        {"dispatchId":"d-5","taskId":"task-5","workerState":"stopping","dispatchStatus":"dispatched","terminalState":"active","projection":{}},
        {"dispatchId":"d-6","taskId":"task-6","workerState":"running","dispatchStatus":"completed","projection":{"liveness":{"verdict":"live"},"nextAction":{"kind":"none"}}},
        {"dispatchId":"d-7","taskId":"task-7","workerState":"ready","dispatchStatus":"dispatched","projection":{"liveness":{"verdict":"live"},"nextAction":{"kind":"release"}}},
        {"dispatchId":"d-8","taskId":"task-8","workerState":"running","dispatchStatus":"dispatched","projection":{"liveness":{"verdict":"live"},"nextAction":"release"}},
        {"dispatchId":"d-9","taskId":"task-9","workerState":"running","dispatchStatus":"dispatched","projection":{"liveness":"exited"}},
        {"dispatchId":"d-10","taskId":"task-10","workerState":"running","dispatchStatus":"dispatched","projection":{"liveness":{"verdict":{"x":1}}}}]}' ;;
  *) err "unknown command" ;;
esac
EOF
# A bare `orca` on PATH records any call: helpers must only ever use $ORCA_CLI_COMMAND.
printf '#!/bin/sh\necho "$*" >> "$FAKE/bare"\nexit 1\n' > "$FAKE/bin/orca"
chmod +x "$FAKE/bin/fake-orca" "$FAKE/bin/orca"
export PATH="$FAKE/bin:$PATH" ORCA_CLI_COMMAND="$FAKE/bin/fake-orca"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_HOME="$T/home"; mkdir -p "$N1_HOME/memory"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME="$T/hh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset N1_HEADLESS N1_QUEUE_RUN_ID N1_UNATTENDED N1_QUEUE_DIR N1_QUEUE_TAG N1_SESSION_ID CLAUDE_CODE_SESSION_ID N1_RUN_ID ORCA_TERMINAL_HANDLE CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR
source "$REPO_ROOT/lib/config.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/queue.sh"
source "$REPO_ROOT/lib/orca-queue.sh"
calls() { cat "$FAKE/calls"; }
reset() { : > "$FAKE/calls"; }

# --- Task 1: backend choice and orchestration wrappers ---
eq "defaults: backend auto" auto "$(n1_queue_val backend)"
eq "defaults: maxConcurrent 3" 3 "$(n1_queue_val maxConcurrent)"
eq "backend: no ORCA_CLI_COMMAND -> bg" bg "$(ORCA_CLI_COMMAND= n1_queue_backend)"
eq "backend: reachable Orca, auto -> orca" orca "$(n1_queue_backend)"
eq "backend: Orca down -> bg" bg "$(FAKE_ORCA_DOWN=1 n1_queue_backend)"
printf '{"queue":{"backend":"bg"}}\n' > "$N1_HOME/config.json"
eq "backend: queue.backend=bg -> bg" bg "$(n1_queue_backend)"
rm -f "$N1_HOME/config.json"

# N1-303: plan-time max_concurrent; the bg backend runs one ticket at a time whatever maxConcurrent says.
eq "max_concurrent: no ORCA_CLI_COMMAND (bg) -> 1" 1 "$(ORCA_CLI_COMMAND= n1_queue_max_concurrent)"
eq "max_concurrent: Orca down (bg) -> 1" 1 "$(FAKE_ORCA_DOWN=1 n1_queue_max_concurrent)"
eq "max_concurrent: Orca, default -> 3" 3 "$(n1_queue_max_concurrent)"
printf '{"queue":{"backend":"bg","maxConcurrent":3}}\n' > "$N1_HOME/config.json"
eq "max_concurrent: queue.backend=bg forces 1 over maxConcurrent=3" 1 "$(n1_queue_max_concurrent)"
printf '{"queue":{"maxConcurrent":5}}\n' > "$N1_HOME/config.json"
eq "max_concurrent: Orca uses queue.maxConcurrent" 5 "$(n1_queue_max_concurrent)"
printf '{"queue":{"maxConcurrent":"x"}}\n' > "$N1_HOME/config.json"
eq "max_concurrent: invalid value falls back to 3" 3 "$(n1_queue_max_concurrent)"
rm -f "$N1_HOME/config.json"

eq "run-create: id" run-1 "$(n1_orca_run_create q1)"
eq "run-create: unavailable -> rc 1" 1 "$(FAKE_ORCA_RUN_FAIL=1 rc n1_orca_run_create q1)"
eq "run-create: unsafe id rejected" 1 "$(FAKE_ORCA_RUN_ID='a|b' rc n1_orca_run_create q1)"
reset
eq "task-create: id" task-1 "$(n1_orca_task_create run-1 T-1)"
has "full: task-create argv ends --full --json" "--full --json" "$(calls)"
n1_orca status >/dev/null; n1_orca worktree list >/dev/null
eq "full: status and worktree list never get --full" 0 "$(calls | grep -E '^(status|worktree list)' | grep -c -- --full)"
has "worker-start: ok:true receipt with exit 1 still returns the dispatch id" d-1 "$(FAKE_ORCA_START_RC1=1 n1_orca_worker_start run-1 task-1 T-1 /r '')"
has "task-create: empty deps (held rows stay merge-gated)" "--deps []" "$(calls)"
has "task-create: spec invokes n1-start" "Invoke the n1-start skill for ticket T-1" "$(calls)"
has "task-create: spec forbids heartbeats" "Do not send heartbeat messages" "$(calls)"
has "task-create: spec names worker_done and ask" "send only worker_done and ask when needed" "$(calls)"
reset
eq "worker-start: dispatch" d-1 "$(n1_orca_worker_start run-1 task-1 T-1 /r sonnet)"
has "worker-start: flags" "orchestration worker-start --run run-1 --task task-1 --worktree new-top-level --name T-1 --repo path:/r --agent claude --model sonnet" "$(calls)"
reset
eq "worker-start: model rejected -> retried without --model" d-1 "$(FAKE_ORCA_MODEL_REJECT=1 n1_orca_worker_start run-1 task-1 T-1 /r opus 2>/dev/null)"
eq "worker-start: exactly one retry" 2 "$(grep -c worker-start "$FAKE/calls")"
eq "worker-start: failure reason" "orca-launch:worktree-setup" "$(FAKE_ORCA_START_FAIL=1 n1_orca_worker_start run-1 task-1 T-1 /r '')"

# Orca 1.4.243: taskId/dispatchId live only inside "payload", a JSON string.
J='{"ok":true,"result":{"deliveryId":"del-1","messages":[{"id":"m-1","type":"worker_done","payload":"{\"taskId\":\"task-1\",\"dispatchId\":\"d-1\",\"outcome\":\"succeeded\"}"},{"id":"m-2","type":"question","payload":"{\"taskId\":\"task-2\",\"dispatchId\":\"d-2\"}"}]}}'
eq "events: task id and dispatch id from the payload string" "$(printf 'worker_done\ttask-1\tm-1\td-1\nquestion\ttask-2\tm-2\td-2')" "$(n1_orca_events "$J")"
eq "events: top-level taskId/dispatchId fallback" "$(printf 'escalation\ttask-3\tm-3\td-3')" \
    "$(n1_orca_events '{"ok":true,"result":{"messages":[{"id":"m-3","type":"escalation","taskId":"task-3","dispatchId":"d-3"}]}}')"
eq "events: no dispatch id reads as placeholder" "$(printf 'escalation\ttask-3\tm-3\t-')" \
    "$(n1_orca_events '{"ok":true,"result":{"messages":[{"id":"m-3","type":"escalation","taskId":"task-3"}]}}')"
eq "events: malformed payload falls back, batch kept, taskless message dropped" "$(printf 'worker_done\ttask-4\tm-4\t-\nworker_done\ttask-5\tm-5\t-\nworker_done\ttask-7\tm-7\t-')" \
    "$(n1_orca_events '{"ok":true,"result":{"messages":[{"id":"m-4","type":"worker_done","payload":"{not json","taskId":"task-4"},{"id":"m-5","type":"worker_done","payload":"{\"taskId\":\"task-5\"}"},{"id":"m-6","type":"worker_done","payload":"{\"taskId\":{\"a\":1}}"},{"id":"m-7","type":"worker_done","payload":"{\"taskId\":\"task-7\"}"}]}}')"
eq "events: empty message id keeps the dispatch column" "$(printf 'escalation\ttask-8\t-\td-8')" \
    "$(n1_orca_events '{"ok":true,"result":{"messages":[{"type":"escalation","payload":"{\"taskId\":\"task-8\",\"dispatchId\":\"d-8\"}"}]}}')"
reset
n1_orca_check run-1 5 >/dev/null
has "check: requests heartbeat" "--types worker_done,escalation,question,heartbeat" "$(calls)"
eq "events: empty batch" "" "$(n1_orca_events '{"ok":true,"result":{"messages":[]}}')"
eq "liveness: verdict + durable settled state" \
    "$(printf 'd-1\ttask-1\texited\tdone\nd-2\ttask-2\tlive\t\nd-3\ttask-3\tunverifiable\tdone\nd-4\ttask-4\tunverifiable\tdone\nd-5\ttask-5\tunverifiable\t\nd-6\ttask-6\tlive\tdone\nd-7\ttask-7\tlive\tdone\nd-8\ttask-8\tlive\t\nd-9\ttask-9\texited\t\nd-10\ttask-10\tunverifiable\t')" \
    "$(n1_orca_liveness run-1)"
n1_orca_liveness run-1 >/dev/null; eq "liveness: real Orca payload is readable (rc 0)" 0 "$?"
FAKE_WL_EMPTY=1 n1_orca_liveness run-1 >/dev/null; rc=$?; eq "liveness: receipt without a worker array is unreadable" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
reset; n1_orca_ack run-1 "$J"
has "ack: delivery id" "orchestration check --run run-1 --ack del-1" "$(calls)"

eq "worktree_taken: unreadable list reads taken (fail closed)" 0 "$(rc n1_orca_worktree_taken T-1)"
eq "worktree_taken: readable, no clash" 1 "$(FAKE_WT=none rc n1_orca_worktree_taken T-1)"
eq "worktree_taken: readable, clash" 0 "$(FAKE_WT=hit rc n1_orca_worktree_taken T-1)"
# N1-267: usage-limit stall from the newest transcript of the ticket's worktree (FAKE_WT=hit lists /w/T-1).
# Bugs caught: a worker idle on the usage limit read as working (charged into subtask-timeout); a worker that resumed
# after the reset still read as stalled (never times out); one malformed transcript line disabling detection; an older
# session's transcript deciding the verdict; an unreadable worktree list reading "stalled" (fail open).
CC="$T/cc"; TD="$CC/projects/-w-T-1"; mkdir -p "$TD"
MARK='{"type":"system","subtype":"informational","level":"notice","content":"Usage limit reached · continuing automatically at 7:30pm · esc to cancel"}'
ASST='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}'
printf '%s\n%s\n' "$ASST" "$MARK" > "$TD/s1.jsonl"
eq "stalled: marker after last assistant entry" 0 "$(FAKE_WT=hit CLAUDE_CONFIG_DIR="$CC" rc n1_orca_usage_stalled T-1)"
eq "stalled: prints nothing" "" "$(FAKE_WT=hit CLAUDE_CONFIG_DIR="$CC" n1_orca_usage_stalled T-1 2>&1)"
printf '{not json\n%s\n%s\n' "$ASST" "$MARK" > "$TD/s1.jsonl"
eq "stalled: malformed line tolerated" 0 "$(FAKE_WT=hit CLAUDE_CONFIG_DIR="$CC" rc n1_orca_usage_stalled T-1)"
eq "stalled: unreadable worktree list -> not stalled" 1 "$(FAKE_WT=fail CLAUDE_CONFIG_DIR="$CC" rc n1_orca_usage_stalled T-1)"
printf '%s\n%s\n' "$MARK" "$ASST" > "$TD/s1.jsonl"
eq "stalled: assistant entry after marker (reset) -> not stalled" 1 "$(FAKE_WT=hit CLAUDE_CONFIG_DIR="$CC" rc n1_orca_usage_stalled T-1)"
printf '%s\n%s\n' "$ASST" "$MARK" > "$TD/s0.jsonl"; touch -d '1 hour ago' "$TD/s0.jsonl"
eq "stalled: only the newest transcript counts" 1 "$(FAKE_WT=hit CLAUDE_CONFIG_DIR="$CC" rc n1_orca_usage_stalled T-1)"

# --- Task 2: identity sentinel ---
M="$T/main"; git init -q -b main "$M"; git -C "$M" commit -q --allow-empty -m init
mkdir -p "$T/wts"; WT="$T/wts/T-1"; git -C "$M" worktree add -q -b t1 "$WT" main
O="$T/other"; git init -q -b main "$O"; git -C "$O" commit -q --allow-empty -m init
Q="$N1_HOME/queue/q1"; mkdir -p "$Q"
printf -- '---\nqueue_id: q1\nrun_id: R1\norca_run_id: run-1\nstep: run\n---\n' > "$Q/queue.md"
N1_QUEUE_DIR="$Q" n1_orca_sentinel_write "$N1_HOME" T-1 "$M" R1 run-1 task-1
S="$N1_HOME/queue/sentinels/T-1.env"
eq "sentinel: mode 600" 600 "$(stat -c %a "$S")"
load() { (cd "$1" && n1_orca_child_env && echo "$N1_HEADLESS|$N1_QUEUE_RUN_ID|$N1_UNATTENDED|$N1_QUEUE_DIR|$N1_ORCA_TASK|$N1_ORCA_TICKET") || echo none; }
eq "loader: Orca child loads identity" "1|R1|ask|$Q|task-1|T-1" "$(load "$WT")"
mkdir -p "$WT/sub"
eq "loader: from a subdirectory" "1|R1|ask|$Q|task-1|T-1" "$(load "$WT/sub")"
eq "loader: outside Orca (no ORCA_CLI_COMMAND)" none "$(ORCA_CLI_COMMAND= load "$WT")"
eq "loader: checkout without a sentinel" none "$(load "$M")"
sed -i "s|^N1_ORCA_REPO=.*|N1_ORCA_REPO=$O|" "$S"
eq "loader: sentinel for another repo" none "$(load "$WT")"
sed -i "s|^N1_ORCA_REPO=.*|N1_ORCA_REPO=$M|" "$S"
n1_write_frontmatter "$Q/queue.md" run_id R2
eq "loader: queue moved to another run" none "$(load "$WT")"
n1_write_frontmatter "$Q/queue.md" run_id R1
touch -d '2 days ago' "$S"
eq "loader: old sentinel of a still-current run keeps the identity (no mtime TTL)" "1|R1|ask|$Q|task-1|T-1" "$(load "$WT")"
touch "$S"
printf 'N1_QUEUE_TAG=$(touch %s/pwned)\nPATH=/evil\n' "$T" >> "$S"
eq "loader: values are data, never executed" '$(touch '"$T"'/pwned)' "$(cd "$WT" && n1_orca_child_env && printf '%s' "$N1_QUEUE_TAG")"
eq "loader: no command ran" no "$([ -e "$T/pwned" ] && echo yes || echo no)"
eq "loader: non-whitelisted key ignored" "$PATH" "$(cd "$WT" && n1_orca_child_env && printf '%s' "$PATH")"
eq "sentinel_set: whitelist enforced" 1 "$(rc n1_orca_sentinel_set "$N1_HOME" T-1 PATH /evil)"
n1_orca_sentinel_set "$N1_HOME" T-1 N1_ORCA_DISPATCH d-1
eq "sentinel_set: dispatch appended" d-1 "$(cd "$WT" && n1_orca_child_env && printf '%s' "$N1_ORCA_DISPATCH")"
has "exports: export lines" "export N1_HEADLESS=1" "$(cd "$WT" && n1_orca_child_env && n1_orca_child_env_exports)"
n1_orca_sentinel_rm "$N1_HOME" T-1 task-other
eq "sentinel_rm: another attempt's task keeps the file" yes "$([ -f "$S" ] && echo yes || echo no)"

# --- Task 3: hooks ---
EF="$T/envfile"; : > "$EF"
hook_start() { printf '{"source":"startup","cwd":"%s","session_id":"s1"}' "$1" \
    | (cd "$1" && CLAUDE_ENV_FILE="$EF" N1_STATE_DIR="$T/state" N1_HOST_FILE="$T/state/host.json" bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1); }
hook_start "$WT"
has "session-start: identity persisted for Bash commands" "export N1_HEADLESS=1" "$(cat "$EF")"
has "session-start: queue run id persisted" "export N1_QUEUE_RUN_ID=R1" "$(cat "$EF")"
: > "$EF"; hook_start "$M"
eq "session-start: no sentinel, nothing persisted" "" "$(cat "$EF")"

eq "session-start: sentinel pinned per session" yes "$([ -f "$N1_HOME/queue/sessions/T-1.s1" ] && echo yes || echo no)"
PAY=$(jq -cn --arg c "$WT" '{session_id:"s1",cwd:$c,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"gh pr merge 1 --squash"}}')
eq "merge-deny: Orca queue child denied" 2 "$(cd "$WT" && printf '%s' "$PAY" | bash "$REPO_ROOT/hooks/enforce-agent-policy.sh" >/dev/null 2>&1; echo $?)"
eq "merge-deny: session without a sentinel unaffected" 0 "$(cd "$M" && printf '%s' "$PAY" | bash "$REPO_ROOT/hooks/enforce-agent-policy.sh" >/dev/null 2>&1; echo $?)"
# Hooks run in Claude's current directory, which follows a child's `cd`; CLAUDE_PROJECT_DIR stays the session root.
eq "merge-deny: child that cd'd out of its worktree is still denied" 2 "$(cd "$M" && printf '%s' "$PAY" | CLAUDE_PROJECT_DIR="$WT" bash "$REPO_ROOT/hooks/enforce-agent-policy.sh" >/dev/null 2>&1; echo $?)"
# SEC-2: a child that deletes its sentinel or rewrites the queue run_id keeps its (pinned) identity.
cp "$S" "$T/S.bak"; rm -f "$S"
eq "merge-deny: sentinel deleted mid-session, still denied" 2 "$(cd "$WT" && printf '%s' "$PAY" | bash "$REPO_ROOT/hooks/enforce-agent-policy.sh" >/dev/null 2>&1; echo $?)"
cp "$T/S.bak" "$S"; n1_write_frontmatter "$Q/queue.md" run_id R9
eq "merge-deny: queue run_id rewritten, still denied" 2 "$(cd "$WT" && printf '%s' "$PAY" | bash "$REPO_ROOT/hooks/enforce-agent-policy.sh" >/dev/null 2>&1; echo $?)"
n1_write_frontmatter "$Q/queue.md" run_id R1
PAY2=$(jq -cn --arg c "$WT" '{session_id:"s2",cwd:$c,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"gh pr merge 1 --squash"}}')
rm -f "$S"
eq "merge-deny: another session without sentinel or pin unaffected" 0 "$(cd "$WT" && printf '%s' "$PAY2" | bash "$REPO_ROOT/hooks/enforce-agent-policy.sh" >/dev/null 2>&1; echo $?)"
cp "$T/S.bak" "$S"
PAY3=$(jq -cn --arg c "$WT" '{session_id:"s1",cwd:$c,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"rm -f $HOME/.n1/x/queue/sentinels/T-1.env"}}')
eq "sentinel-deny: child touching queue/sentinels denied" 2 "$(cd "$WT" && printf '%s' "$PAY3" | bash "$REPO_ROOT/hooks/enforce-agent-policy.sh" >/dev/null 2>&1; echo $?)"
hookrc() { (cd "$WT" && printf '%s' "$1" | env "${@:2}" bash "$REPO_ROOT/hooks/enforce-agent-policy.sh" >/dev/null 2>&1; echo $?); }
BPAY2() { jq -cn --arg c "$WT" --arg m "$1" '{session_id:"s1",cwd:$c,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$m}}'; }
wpay() { jq -cn --arg c "$WT" --arg t "$1" --arg p "$2" '{session_id:"s1",cwd:$c,hook_event_name:"PreToolUse",tool_name:$t,tool_input:{file_path:$p}}'; }
eq "sentinel-deny: Write to a session pin denied" 2 "$(hookrc "$(wpay Write "$N1_HOME/queue/sessions/T-1.s1")")"
eq "sentinel-deny: Edit to the sentinel denied" 2 "$(hookrc "$(wpay Edit "$S")")"
eq "sentinel-deny: ../ path into sentinels denied" 2 "$(hookrc "$(wpay Write "$N1_HOME/queue/q1/../sentinels/T-1.env")")"
ln -s "$N1_HOME/queue" "$T/qlink"
eq "sentinel-deny: symlinked path denied" 2 "$(hookrc "$(wpay MultiEdit "$T/qlink/sessions/T-1.s1")")"
eq "sentinel-deny: Write elsewhere unaffected" 0 "$(hookrc "$(wpay Write "$WT/a.txt")")"
# N1-268 SEC-2: a child must not forge the user-confirmed stop marker.
eq "stop-marker-deny: Bash via N1_QUEUE_DIR denied" 2 "$(hookrc "$(BPAY2 ': > "$N1_QUEUE_DIR/.stop"')")"
eq "stop-marker-deny: Bash via N1 home path denied" 2 "$(hookrc "$(BPAY2 "touch $N1_HOME/queue/q1/.stop")")"
eq "stop-marker-deny: Write to the marker denied" 2 "$(hookrc "$(wpay Write "$N1_HOME/queue/q1/.stop")")"
eq "stop-marker-deny: ../ path to the marker denied" 2 "$(hookrc "$(wpay Write "$N1_HOME/queue/q1/x/../.stop")")"
BPAY() { jq -cn --arg c "$WT" --arg m "$1" '{session_id:"s1",cwd:$c,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$m}}'; }
eq "sentinel-deny: rm of \$N1_ORCA_SENTINEL denied" 2 "$(hookrc "$(BPAY 'rm -f "$N1_ORCA_SENTINEL"')")"
eq "sentinel-deny: globbed pins denied" 2 "$(hookrc "$(BPAY 'rm $N1_HOME/queue/sess*/*')")"
eq "sentinel-deny: plain git commit text with sessions and /queue allowed" 0 "$(hookrc "$(BPAY 'git commit -m "fix sessions handling in /queue and queue/ docs"')")"
eq "sentinel-deny: gh pr create text with sessions allowed" 0 "$(hookrc "$(BPAY 'gh pr create --body "sessions, sentinels and /queue notes"')")"
eq "sentinel-deny: mixed-case absolute rm of the sentinel dir denied" 2 "$(hookrc "$(BPAY "rm -rf $N1_HOME/Queue/SENTINELS")")"
eq "sentinel-deny: rm of a memory file under N1 home allowed" 0 "$(hookrc "$(BPAY "rm -f $N1_HOME/memory/T-1/x.md")")"
eq "sentinel-deny: N1 skill snippet (preamble + rm under \$N1_HOME) allowed" 0 "$(hookrc "$(BPAY 'source ~/.n1/preamble.sh; rm -f "$N1_HOME/memory/X/.tw-probe.json"')")"
# SEC-6: N1 home comes from the session root, not the hook cwd (child inside a nested repo).
NH="$T/nhome"; mkdir -p "$NH/.n1/t-1/queue/q1" "$WT/nested"; git init -q "$WT/nested"
printf -- '---\nqueue_id: q1\nrun_id: R1\n---\n' > "$NH/.n1/t-1/queue/q1/queue.md"
(unset N1_HOME; export HOME="$NH"; N1_QUEUE_DIR="$NH/.n1/t-1/queue/q1" n1_orca_sentinel_write "$NH/.n1/t-1" T-1 "$M" R1 run-1 task-1)
eq "loader: nested-repo cwd still finds the identity via the session root" T-1 "$(cd "$WT/nested" && unset N1_HOME && export HOME="$NH" && n1_orca_child_env "$WT" && echo "$N1_ORCA_TICKET" || echo none)"
# SEC-9: the home comes from the runner's pointer, not git config: a child that repoints origin keeps its identity.
mkdir -p "$NH/.n1/evil"; git -C "$WT" remote add origin https://example.com/o/evil.git
eq "loader: git remote set-url does not drop the identity" T-1 "$(cd "$WT" && unset N1_HOME && export HOME="$NH" && n1_orca_child_env "$WT" && echo "$N1_ORCA_TICKET" || echo none)"
git -C "$WT" remote remove origin
# CR-11: the Stop hook's own cwd-derived N1_HOME must not shadow the identity home (child inside a nested repo).
mkdir -p "$NH/.n1/nested" "$NH/.n1/t-1/memory/T-1"; n1_orca_sentinel_set "$NH/.n1/t-1" T-1 N1_ORCA_DISPATCH d-1
printf -- '---\nstep: done\n---\n## Pending\npr_url: https://github.com/o/r/pull/9\n' > "$NH/.n1/t-1/memory/T-1/overview.md"
reset; printf '{"session_id":"s9"}' | (cd "$WT/nested" && unset N1_HOME && HOME="$NH" CLAUDE_PROJECT_DIR="$WT" bash "$REPO_ROOT/hooks/session-stop.sh" >/dev/null 2>&1)
has "stop: nested-repo cwd still reports worker_done" "type worker_done --outcome succeeded" "$(calls)"
# Scope: only an Orca queue child. A plain unattended run (claude --bg child) is not denied.
eq "sentinel-deny: bg/headless run without a sentinel not denied" 0 "$(cd "$M" && printf '%s' "$(BPAY 'grep -r queue/sentinels lib')" | N1_HEADLESS=1 bash "$REPO_ROOT/hooks/enforce-agent-policy.sh" >/dev/null 2>&1; echo $?)"
# SEC-5: a re-run of the session pin (compaction) never overwrites the pin from an edited sentinel.
cp "$S" "$T/S.pre"; sed -i "s|^N1_ORCA_REPO=.*|N1_ORCA_REPO=$O|" "$S"
(cd "$WT" && n1_orca_child_env "$WT" s1 && n1_orca_session_pin s1)
eq "session-pin: tampered sentinel does not overwrite the pin" "$M" "$(sed -n 's/^N1_ORCA_REPO=//p' "$N1_HOME/queue/sessions/T-1.s1")"
eq "session-pin: identity survives the tamper plus a re-pin" 0 "$(cd "$WT" && n1_orca_child_env "$WT" s1; echo $?)"
cp "$T/S.pre" "$S"
n1_orca_sentinel_rm "$N1_HOME" T-1
eq "sentinel_rm: pinned session copies go with it" no "$([ -e "$N1_HOME/queue/sessions/T-1.s1" ] && echo yes || echo no)"
eq "sentinel_rm: home pointer goes with it" no "$([ -e "$(n1_orca_home_ptr T-1)" ] && echo yes || echo no)"
cp "$T/S.bak" "$S"; printf '%s\n' "$N1_HOME" > "$(n1_orca_home_ptr T-1)"

OV="$N1_HOME/memory/T-1/overview.md"; mkdir -p "${OV%/*}"
printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://github.com/o/r/pull/7\n' > "$OV"
stop() { printf '{"session_id":"s1"}' | (cd "$WT" && ORCA_TERMINAL_HANDLE=term-9 bash "$REPO_ROOT/hooks/session-stop.sh" >/dev/null 2>&1); }
reset; stop
eq "stop: PR open at step pr sends nothing (N1-310)" "" "$(grep worker_done "$FAKE/calls")"
printf -- '---\nstep: ci\n---\n## Pending\npr_url: https://github.com/o/r/pull/7\n' > "$OV"
reset; stop
eq "stop: step ci sends nothing without fullAuto" "" "$(grep worker_done "$FAKE/calls")"
printf -- '---\nstep: done\n---\n## Pending\npr_url: https://github.com/o/r/pull/7\n' > "$OV"
printf '{"autonomy":{"fullAuto":true}}' > "$N1_HOME/config.json"
reset; stop
eq "stop: fullAuto step done without Finish block sends nothing" "" "$(grep worker_done "$FAKE/calls")"
printf '## Finish\npr_url: https://github.com/o/r/pull/7\n' >> "$OV"
reset; stop
has "stop: fullAuto with Finish block sends succeeded" "--outcome succeeded" "$(calls)"
eq "stop: fullAuto Finish sent once" 1 "$(grep -c 'type worker_done' "$FAKE/calls")"
rm -f "$N1_HOME/config.json" "$N1_HOME/queue/sentinels/T-1.sent"
printf -- '---\nstep: done\n---\n## Pending\npr_url: https://github.com/o/r/pull/7\n' > "$OV"
reset; stop
has "stop: worker_done succeeded" "orchestration send --type worker_done --outcome succeeded --task-id task-1 --dispatch-id d-1" "$(calls)"
has "stop: PR url in body" "https://github.com/o/r/pull/7" "$(calls)"
has "stop: sent from the worker terminal" "--from term-9" "$(calls)"
stop
eq "stop: sent exactly once" 1 "$(grep -c 'type worker_done' "$FAKE/calls")"
rm -f "$N1_HOME/queue/sentinels/T-1.sent"; printf -- '---\nstep: implement\n---\n' > "$OV"
reset; stop
eq "stop: mid-pipeline turn end sends nothing" "" "$(grep worker_done "$FAKE/calls")"
printf -- '---\nstep: escalated\n---\n' > "$OV"
reset; stop
has "stop: escalated child reports failed" "--outcome failed" "$(calls)"

# --- Task 4: child ask ---
QF="$Q/.question-T-1.json"
printf '{"ticket":"T-1","step":"plan","category":"design","question":"Pick a DB?","options":["A","B, or C"],"recommended":"A","rationale":"x"}' > "$QF"
reset
eq "ask: answer" "answer:Use B" "$(n1_orca_ask "$QF")"
has "ask: self-contained question" "--question T-1 plan: Pick a DB?" "$(calls)"
has "ask: options plus stop option, commas neutralised, recommended marked" "--options A (Recommended),B; or C,Stop this ticket" "$(calls)"
has "ask: rationale carried" "Recommended: A. x" "$(calls)"
printf '{"ticket":"T-1","step":"plan","question":"Pick?","options":["A","B"]}' > "$T/q2.json"; reset; n1_orca_ask "$T/q2.json" >/dev/null
has "ask: no recommendation sentence" "No recommendation. The options are equivalent given the available evidence; select based on team preference." "$(calls)"
eq "ask: no (Recommended) without a recommendation" 0 "$(grep -c '(Recommended)' "$FAKE/calls")"
eq "ask: timeout -> pending id" "pending:m-7" "$(FAKE_ASK=pending n1_orca_ask "$QF")"
reset; FAKE_ASK=pending n1_orca_ask "$QF" m-7 >/dev/null
has "ask: resume by message id" "--resume m-7" "$(calls)"
eq "ask: CLI error -> failed" failed "$(FAKE_ASK=error n1_orca_ask "$QF")"
has "skill: ask-mode Orca branch" 'n1_orca_ask "<QUESTION_FILE>"' "$(cat "$REPO_ROOT/skills/n1-start/procedures/autonomy-headless.md")"
has "preamble: loads orca-queue.sh" 'lib/orca-queue.sh' "$(cat "$REPO_ROOT/lib/preamble.sh")"

# --- Task 7: --answer in Orca mode ---
printf -- '---\nqueue_id: q1\nrun_id: R1\norca_run_id: run-1\nstep: run\n---\n## Plan\n| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |\n|---|---|---|---|---|---|---|---|\n| 1 | T-1 | Fix | %s | %s | sonnet | awaiting-human | |\n\n## Runs\n| Ticket | Started | Exit | Outcome | PR | Session |\n|---|---|---|---|---|---|\n| T-1 | 2026-10-31T00:00:00Z | | | | orca:task-1/d-1 |\n' "$M" "$N1_HOME" > "$Q/queue.md"
printf 'm-9\n' > "$Q/.ask-T-1"; printf '{}' > "$Q/.question-T-1.json"
printf 'Use B' > "$N1_HOME/queue/.answer-T-1.txt"
reset
has "answer: delivered" "answer delivered to T-1" "$(n1_queue_answer "$N1_HOME" T-1 2>&1)"
has "answer: orchestration reply" "orchestration reply --id m-9 --body Use B --run run-1" "$(calls)"
hasnt "answer: no coordinator terminal recorded -> no --from" "--from" "$(calls)"
eq "answer: markers removed" no "$({ [ -e "$Q/.ask-T-1" ] || [ -e "$Q/.question-T-1.json" ]; } && echo yes || echo no)"
eq "answer: event" answer_delivered "$(jq -r .event "$Q/events.jsonl" | tail -1)"
printf 'm-9\n' > "$Q/.ask-T-1"; printf 'Use B' > "$N1_HOME/queue/.answer-T-1.txt"
eq "answer: reply failure -> rc 1" 1 "$(FAKE_ORCA_REPLY_FAIL=1 rc n1_queue_answer "$N1_HOME" T-1)"
eq "answer: ask marker kept for a retry" yes "$([ -e "$Q/.ask-T-1" ] && echo yes || echo no)"
eq "hints: Orca row points at --answer" "T-1: /n1:n1-queue --answer T-1 <answer>" "$(n1_queue_awaiting_hints "$Q/queue.md")"

# --- N1-270: runner-owned coordinator terminal ---
# Bugs caught: the sink handle read from the wrong receipt path; a CLI failure or an unsafe/missing handle accepted
# as a coordinator; an unsafe handle passed to terminal close.
reset
eq "coord_open: handle from terminal.handle" term-9 "$(n1_orca_coord_open q1)"
has "coord_open: sink runs cat into /dev/null" "terminal create --title n1-queue coordinator q1 --command cat >/dev/null" "$(calls)"
eq "coord_open: flat handle shape" term-8 "$(FAKE_TERM_JSON='{"handle":"term-8"}' n1_orca_coord_open q1)"
eq "coord_open: CLI failure -> rc 1" 1 "$(FAKE_TERM_FAIL=1 rc n1_orca_coord_open q1)"
eq "coord_open: unsafe handle rejected" 1 "$(FAKE_TERM_JSON='{"handle":"a|b"}' rc n1_orca_coord_open q1)"
eq "coord_open: no handle rejected" 1 "$(FAKE_TERM_JSON='{}' rc n1_orca_coord_open q1)"
reset; n1_orca_coord_close term-9
has "coord_close: closes by handle" "terminal close --terminal term-9" "$(calls)"
reset; n1_orca_coord_close 'a|b'
eq "coord_close: unsafe handle never reaches the CLI" "" "$(calls)"

# Bugs caught: a question sent after the runner died never got an .ask marker (--answer: "no pending question");
# an answered, forged-dispatch, unknown-task, finished-row or earlier-run question surfaced; a second status call
# re-alerted; the reply went out as the launching terminal instead of the Run's coordinator.
n1_write_frontmatter "$Q/queue.md" orca_queue_run R1
n1_write_frontmatter "$Q/queue.md" orca_coord_terminal term-9
n1_queue_row_status "$Q/queue.md" 1 in-progress
rm -f "$Q/.ask-T-1" "$Q/.question-T-1.json"
QM() { jq -cn --arg i "$1" --arg k "$2" --arg d "$3" '{id: $i, type: "question", payload: ({taskId: $k, dispatchId: $d} | tojson)}'; }
export FAKE_INBOX="$(QM m-9 task-1 d-1),$(QM m-10 task-1 d-1),$(QM m-11 task-1 d-other),$(QM m-12 task-x d-x)"
eq "row_of_task: ticket and dispatch" "$(printf 'T-1\td-1')" "$(n1_orca_row_of_task "$Q/queue.md" task-1)"
eq "row_of_task: unknown task" "" "$(n1_orca_row_of_task "$Q/queue.md" task-x)"
reset
eq "pending: only the unanswered question bound to the row's dispatch" "$(printf '1\tT-1\tm-10')" "$(n1_orca_pending_questions "$Q")"
has "pending: lists every message as the coordinator terminal" "orchestration check --run run-1 --all --types question --terminal term-9" "$(calls)"
n1_queue_row_status "$Q/queue.md" 1 pr
eq "pending: finished row skipped" "" "$(n1_orca_pending_questions "$Q")"
n1_queue_row_status "$Q/queue.md" 1 in-progress
n1_write_frontmatter "$Q/queue.md" orca_queue_run R0
eq "pending: Run of an earlier queue run skipped" "" "$(n1_orca_pending_questions "$Q")"
n1_write_frontmatter "$Q/queue.md" orca_queue_run R1
# Bug caught: an unanswered question from an older task parked the ticket's newer attempt.
printf '| T-1 | 2026-10-31T01:00:00Z | | | | orca:task-2/d-2 |\n' >> "$Q/queue.md"
eq "pending: question of an older task than the ticket's latest attempt skipped" "" "$(n1_orca_pending_questions "$Q")"
sed -i '$d' "$Q/queue.md"
printf '{"queue":{"notify":"command","notifyCommand":"cat >> %s/notes"}}\n' "$T" > "$N1_HOME/config.json"
OUT=$(n1_queue_interrupted_note "$Q/queue.md")
has "runner-down: resume line still printed" "resume: /n1:n1-queue --run q1" "$OUT"
eq "runner-down: .ask marker for --answer" m-10 "$(cat "$Q/.ask-T-1" 2>/dev/null)"
eq "runner-down: row parked, hint points at --answer" "T-1: /n1:n1-queue --answer T-1 <answer>" "$(n1_queue_awaiting_hints "$Q/queue.md")"
esc() { jq -R 'fromjson? | select(.event == "escalated" and .ticket == "T-1") | .event' "$Q/events.jsonl" | wc -l | tr -d ' '; }
eq "runner-down: one escalated event" 1 "$(esc)"
has "runner-down: needs-you carries the answer command" "T-1 needs you: worker question pending, runner down (answer: /n1:n1-queue --answer T-1 <text>)" "$(cat "$T/notes" 2>/dev/null)"
n1_queue_interrupted_note "$Q/queue.md" >/dev/null
eq "runner-down: second status call adds no event" 1 "$(esc)"
printf 'Use A' > "$N1_HOME/queue/.answer-T-1.txt"; reset
has "runner-down: --answer delivers" "answer delivered to T-1" "$(n1_queue_answer "$N1_HOME" T-1 2>&1)"
has "answer: reply sent as the coordinator terminal" "orchestration reply --id m-10 --body Use A --run run-1 --from term-9" "$(calls)"
n1_queue_interrupted_note "$Q/queue.md" >/dev/null
eq "runner-down: answered question not surfaced again" 1 "$(esc)"
export FAKE_INBOX="$(QM m-13 task-1 d-1)"; rm -f "$Q/.ask-T-1"
eq "pending: dead coordinator terminal -> scan retried as the caller" "$(printf '1\tT-1\tm-13')" "$(FAKE_COORD_DEAD=1 n1_orca_pending_questions "$Q")"
printf 'm-13\n' > "$Q/.ask-T-1"; printf 'Use C' > "$N1_HOME/queue/.answer-T-1.txt"; reset
has "answer: dead coordinator terminal -> still delivered" "answer delivered to T-1" "$(FAKE_COORD_DEAD=1 n1_queue_answer "$N1_HOME" T-1 2>&1)"
has "answer: the retry carries no --from" "orchestration reply --id m-13 --body Use C --run run-1 --full --json" "$(calls)"
# Bug caught: a done queue with a parked Orca row never scanned the inbox, so a second question surfaced nowhere.
n1_write_frontmatter "$Q/queue.md" step done
n1_queue_row_status "$Q/queue.md" 1 awaiting-human
export FAKE_INBOX="$(QM m-20 task-1 d-1)"; rm -f "$Q/.ask-T-1"
n1_queue_finished_scan "$Q/queue.md"
eq "finished: done queue with parked row -> .ask marker" m-20 "$(cat "$Q/.ask-T-1" 2>/dev/null)"
rm -f "$Q/.ask-T-1"; n1_write_frontmatter "$Q/queue.md" step run
n1_queue_finished_scan "$Q/queue.md"
eq "finished: running queue not scanned" no "$([ -e "$Q/.ask-T-1" ] && echo yes || echo no)"
rm -f "$N1_HOME/config.json"; unset FAKE_INBOX

# --- summary (later tasks insert their sections above this line) ---
eq "no bare orca call" "" "$(cat "$FAKE/bare" 2>/dev/null)"
[ "$FAIL" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$FAIL"

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
case "$1 $2" in
  "status --json") [ -n "${FAKE_ORCA_DOWN:-}" ] && err "runtime down"; ok '{"runtime":{"reachable":true}}' ;;
  "orchestration run-create") [ -n "${FAKE_ORCA_RUN_FAIL:-}" ] && err "unknown command"; ok "{\"run\":{\"id\":\"${FAKE_ORCA_RUN_ID:-run-1}\"}}" ;;
  "orchestration task-create") ok '{"task":{"id":"task-1"}}' ;;
  "orchestration worker-start")
      has --model "$@" && [ -n "${FAKE_ORCA_MODEL_REJECT:-}" ] && err "unsupported model" validate
      [ -n "${FAKE_ORCA_START_FAIL:-}" ] && err "setup failed" worktree-setup
      ok '{"dispatch":{"id":"d-1"}}' ;;
  "orchestration send"|"orchestration reply") [ -n "${FAKE_ORCA_REPLY_FAIL:-}" ] && err "reply failed"; ok '{}' ;;
  "orchestration ask")
      case "${FAKE_ASK:-answer}" in
        answer) ok '{"answer":"Use B"}' ;;
        pending) ok '{"messageId":"m-7","status":"timeout"}' ;;
        *) err "runtime down" ;;
      esac ;;
  "orchestration check") ok '{}' ;;
  "orchestration worker-list") ok '{"workers":[{"dispatchId":"d-1","taskId":"task-1","projection":{"liveness":"exited"}},{"dispatchId":"d-2","taskId":"task-2","projection":{}}]}' ;;
  *) err "unknown command" ;;
esac
EOF
# A bare `orca` on PATH records any call: helpers must only ever use $ORCA_CLI_COMMAND.
printf '#!/bin/sh\necho "$*" >> "$FAKE/bare"\nexit 1\n' > "$FAKE/bin/orca"
chmod +x "$FAKE/bin/fake-orca" "$FAKE/bin/orca"
export PATH="$FAKE/bin:$PATH" ORCA_CLI_COMMAND="$FAKE/bin/fake-orca"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_HOME="$T/home"; mkdir -p "$N1_HOME/memory"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
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

eq "run-create: id" run-1 "$(n1_orca_run_create q1)"
eq "run-create: unavailable -> rc 1" 1 "$(FAKE_ORCA_RUN_FAIL=1 rc n1_orca_run_create q1)"
eq "run-create: unsafe id rejected" 1 "$(FAKE_ORCA_RUN_ID='a|b' rc n1_orca_run_create q1)"
reset
eq "task-create: id" task-1 "$(n1_orca_task_create run-1 T-1)"
has "task-create: empty deps (held rows stay merge-gated)" "--deps []" "$(calls)"
has "task-create: spec invokes n1-start" "Invoke the n1-start skill for ticket T-1" "$(calls)"
reset
eq "worker-start: dispatch" d-1 "$(n1_orca_worker_start run-1 task-1 T-1 /r sonnet)"
has "worker-start: flags" "orchestration worker-start --run run-1 --task task-1 --worktree new-top-level --name T-1 --repo path:/r --agent claude --model sonnet" "$(calls)"
reset
eq "worker-start: model rejected -> retried without --model" d-1 "$(FAKE_ORCA_MODEL_REJECT=1 n1_orca_worker_start run-1 task-1 T-1 /r opus 2>/dev/null)"
eq "worker-start: exactly one retry" 2 "$(grep -c worker-start "$FAKE/calls")"
eq "worker-start: failure reason" "orca-launch:worktree-setup" "$(FAKE_ORCA_START_FAIL=1 n1_orca_worker_start run-1 task-1 T-1 /r '')"

J='{"ok":true,"result":{"deliveryId":"del-1","messages":[{"type":"worker_done","taskId":"task-1","id":"m-1"},{"type":"question","taskId":"task-2","id":"m-2"}]}}'
eq "events: TSV" "$(printf 'worker_done\ttask-1\tm-1\nquestion\ttask-2\tm-2')" "$(n1_orca_events "$J")"
eq "events: empty batch" "" "$(n1_orca_events '{"ok":true,"result":{"messages":[]}}')"
eq "liveness: missing liveness reads unverifiable" "$(printf 'd-1\ttask-1\texited\nd-2\ttask-2\tunverifiable')" "$(n1_orca_liveness run-1)"
reset; n1_orca_ack run-1 "$J"
has "ack: delivery id" "orchestration check --run run-1 --ack del-1" "$(calls)"

# --- summary (later tasks insert their sections above this line) ---
eq "no bare orca call" "" "$(cat "$FAKE/bare" 2>/dev/null)"
[ "$FAIL" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$FAIL"

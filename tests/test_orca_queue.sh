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
  "worktree list") case "${FAKE_WT:-fail}" in fail) err "boom" ;; none) ok '{"worktrees":[]}' ;; *) ok '{"worktrees":[{"path":"/w/T-1"}]}' ;; esac ;;
  "orchestration worker-list") [ -n "${FAKE_WL_EMPTY:-}" ] && ok '{}' && exit 0; ok '{"workers":[{"dispatchId":"d-1","taskId":"task-1","projection":{"liveness":"exited"}},{"dispatchId":"d-2","taskId":"task-2","projection":{}}]}' ;;
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
FAKE_WL_EMPTY=1 n1_orca_liveness run-1 >/dev/null; rc=$?; eq "liveness: receipt without a worker array is unreadable" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
reset; n1_orca_ack run-1 "$J"
has "ack: delivery id" "orchestration check --run run-1 --ack del-1" "$(calls)"

eq "worktree_taken: unreadable list reads taken (fail closed)" 0 "$(rc n1_orca_worktree_taken T-1)"
eq "worktree_taken: readable, no clash" 1 "$(FAKE_WT=none rc n1_orca_worktree_taken T-1)"
eq "worktree_taken: readable, clash" 0 "$(FAKE_WT=hit rc n1_orca_worktree_taken T-1)"

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
wpay() { jq -cn --arg c "$WT" --arg t "$1" --arg p "$2" '{session_id:"s1",cwd:$c,hook_event_name:"PreToolUse",tool_name:$t,tool_input:{file_path:$p}}'; }
eq "sentinel-deny: Write to a session pin denied" 2 "$(hookrc "$(wpay Write "$N1_HOME/queue/sessions/T-1.s1")")"
eq "sentinel-deny: Edit to the sentinel denied" 2 "$(hookrc "$(wpay Edit "$S")")"
eq "sentinel-deny: ../ path into sentinels denied" 2 "$(hookrc "$(wpay Write "$N1_HOME/queue/q1/../sentinels/T-1.env")")"
ln -s "$N1_HOME/queue" "$T/qlink"
eq "sentinel-deny: symlinked path denied" 2 "$(hookrc "$(wpay MultiEdit "$T/qlink/sessions/T-1.s1")")"
eq "sentinel-deny: Write elsewhere unaffected" 0 "$(hookrc "$(wpay Write "$WT/a.txt")")"
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
printf -- '---\nstep: pr\n---\n## Pending\npr_url: https://github.com/o/r/pull/9\n' > "$NH/.n1/t-1/memory/T-1/overview.md"
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
eq "answer: markers removed" no "$({ [ -e "$Q/.ask-T-1" ] || [ -e "$Q/.question-T-1.json" ]; } && echo yes || echo no)"
eq "answer: event" answer_delivered "$(jq -r .event "$Q/events.jsonl" | tail -1)"
printf 'm-9\n' > "$Q/.ask-T-1"; printf 'Use B' > "$N1_HOME/queue/.answer-T-1.txt"
eq "answer: reply failure -> rc 1" 1 "$(FAKE_ORCA_REPLY_FAIL=1 rc n1_queue_answer "$N1_HOME" T-1)"
eq "answer: ask marker kept for a retry" yes "$([ -e "$Q/.ask-T-1" ] && echo yes || echo no)"
eq "hints: Orca row points at --answer" "T-1: /n1:n1-queue --answer T-1 <answer>" "$(n1_queue_awaiting_hints "$Q/queue.md")"

# --- summary (later tasks insert their sections above this line) ---
eq "no bare orca call" "" "$(cat "$FAKE/bare" 2>/dev/null)"
[ "$FAIL" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$FAIL"

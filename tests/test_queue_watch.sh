#!/usr/bin/env bash
# Tests for n1_queue_watch (lib/queue.sh): run_id filtering, cursor resume, terminal exit.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $label"; PASS=$((PASS+1))
    else
        echo "FAIL: $label (expected=[$expected] actual=[$actual])"; FAIL=$((FAIL+1))
    fi
}
has()   { case "$3" in *"$2"*) assert_eq "$1" yes yes ;; *) assert_eq "$1" yes "no: $3" ;; esac; }
lacks() { case "$3" in *"$2"*) assert_eq "$1" absent "present: $3" ;; *) assert_eq "$1" absent absent ;; esac; }

HOME_DIR=$(mktemp -d); trap 'rm -rf "$HOME_DIR"' EXIT
printf '{"queue":{"pollSeconds":1}}' > "$HOME_DIR/config.json"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" REPO_ROOT N1_HOME="$HOME_DIR" N1_SESSION_ID=sessA
: "${ID:=}"; export ID
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/lib/frontmatter.sh"
source "${REPO_ROOT}/lib/queue.sh"

# watch <secs> <n1_queue_watch args...> — runs the watch under timeout; prints its output then "rc=<code>".
# rc=124 means it was still watching (no terminal state) when the timeout hit.
watch() {
    local secs="$1"; shift
    timeout "$secs" bash -c 'source "$REPO_ROOT/lib/config.sh"; source "$REPO_ROOT/lib/frontmatter.sh"; source "$REPO_ROOT/lib/queue.sh"; n1_queue_watch "$@"' _ "$@"
    echo "rc=$?"
}

newq() { local q="$HOME_DIR/queue/$1"; mkdir -p "$q"; : > "$q/events.jsonl"; printf '%s' "$q"; }
ev()   { local q="$1"; shift; n1_queue_event "$q/events.jsonl" "$(basename "$q")" "$@"; }

test_run_id_filter_and_finish() {
    local q; q=$(newq q1)
    ev "$q" R0 escalated ticket=T-OLD reason="old question"
    ev "$q" R1 escalated ticket=T-1 session=0000abcd reason="Pick A or B"
    ev "$q" R0 halted reason="old halt"
    ev "$q" R1 ticket_started ticket=T-2
    ev "$q" R1 queue_done reason="1 PR"
    local out; out=$(watch 10 "$q" R1 "$$" 0)
    has   "filter: own escalation relayed" "n1-queue q1: T-1 needs you: Pick A or B" "$out"
    has   "filter: attach hint" "(resume: claude attach 0000abcd)" "$out"
    lacks "filter: other run's escalation not relayed" "T-OLD" "$out"
    lacks "filter: other run's halt ignored" "old halt" "$out"
    lacks "filter: non-relayed event ignored" "T-2" "$out"
    has   "finish: final line" "n1-queue q1: finished: 1 PR. Watch ended." "$out"
    has   "finish: exits 0" "rc=0" "$out"
    assert_eq "finish: cursor removed" "no" "$([ -e "$q/.watch-R1.sessA" ] && echo yes || echo no)"
}

test_adopt_from_eof_and_resume() {
    local q out; q=$(newq q2)
    ev "$q" R1 escalated ticket=T-1 reason="seen in status table"
    out=$(watch 2 "$q" R1 "$$")
    assert_eq "adopt: no history replay, still watching" "rc=124" "$out"
    assert_eq "adopt: cursor at end of file" "1" "$(cat "$q/.watch-R1.sessA" 2>/dev/null)"

    ev "$q" R1 ticket_finished ticket=T-2 outcome=pr pr=https://example.test/pr/2
    out=$(watch 2 "$q" R1 "$$")
    has   "resume: new event relayed" "n1-queue q2: T-2 finished: pr https://example.test/pr/2" "$out"
    lacks "resume: consumed event not replayed" "T-1" "$out"
    has   "resume: still watching" "rc=124" "$out"

    ev "$q" R1 halted reason=boom
    out=$(watch 10 "$q" R1 "$$")
    lacks "resume: T-2 not replayed" "T-2" "$out"
    has   "halt: final line" "n1-queue q2: halted: boom. Watch ended." "$out"
    has   "halt: exits 0" "rc=0" "$out"
    assert_eq "halt: cursor removed" "no" "$([ -e "$q/.watch-R1.sessA" ] && echo yes || echo no)"
}

test_runner_dead() {
    local q p out; q=$(newq q3)
    p=$(bash -c 'echo $$')  # already-exited pid: bash's own EXIT trap fires early (and wipes
                            # $HOME_DIR) if a backgrounded `cmd &` job is killed while this
                            # script has a `trap ... EXIT` set; a synchronous dead pid avoids it
    ev "$q" R1 ticket_finished ticket=T-1 outcome=failed reason=timeout
    out=$(watch 10 "$q" R1 "$p" 0)
    has "dead: pending events relayed first" "n1-queue q3: T-1 finished: failed (timeout)" "$out"
    has "dead: runner gone line" "n1-queue q3: runner (pid $p) is gone without a finish or halt event. Watch ended." "$out"
    has "dead: exits 0" "rc=0" "$out"
    assert_eq "dead: cursor removed" "no" "$([ -e "$q/.watch-R1.sessA" ] && echo yes || echo no)"
}

test_sessions_independent() {
    local q a b; q=$(newq q4)
    ev "$q" R1 escalated ticket=T-1 reason=q
    a=$(watch 2 "$q" R1 "$$" 0)
    b=$(N1_SESSION_ID=sessB watch 2 "$q" R1 "$$" 0)
    has "sessions: A relays" "T-1 needs you" "$a"
    has "sessions: B relays independently" "T-1 needs you" "$b"
    assert_eq "sessions: separate cursors" "1 1" "$(cat "$q/.watch-R1.sessA" 2>/dev/null) $(cat "$q/.watch-R1.sessB" 2>/dev/null)"
}

test_rejects_bad_input_and_sanitizes() {
    local q out; q=$(newq q5)
    out=$(watch 2 "$q" "../R1" "$$" 0 2>&1)
    has "input: path-like run_id rejected" "bad run or session id" "$out"
    out=$(watch 2 "$q" R1 "-1" 0 2>&1)
    has "input: non-numeric pid rejected" "bad runner pid" "$out"
    ev "$q" R1 halted reason="$(printf 'a\033[31mb')"
    out=$(watch 5 "$q" R1 "$$" 0)
    has "sanitize: control chars replaced" "halted: a [31mb. Watch ended." "$out"
}

test_run_id_filter_and_finish
test_adopt_from_eof_and_resume
test_runner_dead
test_sessions_independent
test_rejects_bad_input_and_sanitizes

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# tests/test_owner_guard.sh — N1-308: n1_owner_check (lib/config.sh) detects a second live
# n1-start orchestrator on the same ticket via the active-run pointers' pid field.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); LIVE=""
trap 'kill $LIVE 2>/dev/null; rm -rf "$T"' EXIT
unset N1_SESSION_ID CLAUDE_CODE_SESSION_ID N1_HEADLESS N1_RUN_ID
export N1_HOME="$T/home"; mkdir -p "$N1_HOME"
source "$REPO_ROOT/lib/config.sh"
source "$REPO_ROOT/lib/step.sh"

# ptr <sid> <ticket> <runId> <pid|->  ("-" writes a legacy pointer without pid)
ptr() {
    if [ "$4" = - ]; then printf '{"ticketId":"%s","runId":"%s","worktreePath":null,"branch":""}\n' "$2" "$3"
    else printf '{"ticketId":"%s","runId":"%s","worktreePath":null,"branch":"","pid":%s}\n' "$2" "$3" "$4"; fi > "$N1_HOME/active-run.$1.json"
}
reset() { rm -f "$N1_HOME"/active-run.*.json; }

# Live owner whose cmdline contains "claude"; live non-claude process; dead pid.
SLEEP_BIN=$(readlink -f "$(command -v sleep)")
await_exec() { local i; for i in $(seq 50); do [ "$(readlink "/proc/$1/exe" 2>/dev/null)" = "$SLEEP_BIN" ] && return 0; sleep 0.1; done; return 1; }
ln -s "$(command -v sleep)" "$T/claude"
"$T/claude" 30 & CL=$!
sleep 30 & SL=$!
LIVE="$CL $SL"
HAVE_PROC=0; [ -r "/proc/$$/cmdline" ] && HAVE_PROC=1   # no /proc (macOS): the cmdline check is skipped, so case (e) is too
if [ "$HAVE_PROC" = 1 ]; then await_exec "$CL"; await_exec "$SL"; fi
DEAD=99999; while kill -0 "$DEAD" 2>/dev/null; do DEAD=$((DEAD-1)); done
export N1_SESSION_ID=me

# (a) second live owner -> owner:live <sid> <pid>, rc 1
reset; ptr other T-1 r1 "$CL"
OUT=$(n1_owner_check T-1); RC=$?
assert_eq "a: live token" "owner:live other $CL" "$OUT"
assert_eq "a: rc 1" 1 "$RC"

# (b) self: own-sid pointer, and own pid under a new sid
reset; ptr me T-1 r1 "$CL"
OUT=$(n1_owner_check T-1); RC=$?
assert_eq "b1: own sid is self" "owner:self" "$OUT"
assert_eq "b1: rc 0" 0 "$RC"
reset; ptr newsid T-1 r1 "$PPID"
OUT=$(n1_owner_check T-1); RC=$?
assert_eq "b2: own pid under new sid is self" "owner:self" "$OUT"
assert_eq "b2: rc 0" 0 "$RC"

# (c) n1-finish marker with a live pid is not an owner
reset; ptr fin T-1 n1-finish "$CL"
OUT=$(n1_owner_check T-1); RC=$?
assert_eq "c: finish marker free" "owner:free" "$OUT"
assert_eq "c: rc 0" 0 "$RC"

# (d) dead pid -> stale-takeover, stale file left in place
reset; ptr old T-1 r1 "$DEAD"
OUT=$(n1_owner_check T-1); RC=$?
assert_eq "d: dead pid takeover" "owner:stale-takeover" "$OUT"
assert_eq "d: rc 0" 0 "$RC"
assert_eq "d: stale file kept" "yes" "$([ -f "$N1_HOME/active-run.old.json" ] && echo yes)"

# (e) live pid whose cmdline lacks "claude" (recycled pid) -> takeover (needs /proc)
if [ "$HAVE_PROC" = 1 ]; then
    reset; ptr recycled T-1 r1 "$SL"
    OUT=$(n1_owner_check T-1); RC=$?
    assert_eq "e: non-claude pid takeover" "owner:stale-takeover" "$OUT"
    assert_eq "e: rc 0" 0 "$RC"
else echo "SKIP: e (no /proc)"; fi

# (f) legacy pointer without pid -> free; live owner of another ticket -> free
reset; ptr legacy T-1 r1 -
assert_eq "f1: legacy pointer free" "owner:free" "$(n1_owner_check T-1)"
reset; ptr other T-2 r1 "$CL"
assert_eq "f2: other ticket free" "owner:free" "$(n1_owner_check T-1)"

# (g) headless: token + HEADLESS ESCALATION; no memory dir created; escalation appended when overview.md exists
reset; ptr other T-1 r1 "$CL"
OUT=$(N1_HEADLESS=1 n1_owner_check T-1); RC=$?
assert_eq "g: rc 1" 1 "$RC"
assert_eq "g: token first" "owner:live other $CL" "$(head -1 <<<"$OUT")"
assert_eq "g: headless line" "HEADLESS ESCALATION: T-1 owned by live session other (pid $CL)" "$(sed -n 2p <<<"$OUT")"
assert_eq "g: no memory dir created" "no" "$([ -e "$N1_HOME/memory/T-1" ] && echo yes || echo no)"
mkdir -p "$N1_HOME/memory/T-1"
printf -- '---\nstep: ticket\n---\n# T-1\n\n## Escalations\n' > "$N1_HOME/memory/T-1/overview.md"
N1_HEADLESS=1 n1_owner_check T-1 >/dev/null
assert_eq "g: escalation appended" 1 "$(grep -c '^- \[headless\] owner: T-1 owned by live session other' "$N1_HOME/memory/T-1/overview.md")"
rm -rf "$N1_HOME/memory/T-1"

# (h) writer records pid = $PPID, keeps compact runId, clear_if still removes it
reset
n1_active_run_write T-1 run-h null ""
F="$N1_HOME/active-run.me.json"
assert_eq "h: pid is PPID" "$PPID" "$(jq -r .pid "$F")"
assert_eq "h: compact runId kept" 1 "$(grep -cF '"runId":"run-h"' "$F")"
n1_active_run_clear_if run-h
assert_eq "h: clear_if removes" "gone" "$([ -f "$F" ] && echo kept || echo gone)"

# (i) n1_step_begin prints the live token on stdout; silent when free
reset; ptr other T-1 r1 "$CL"
ID=T-1
assert_eq "i: step_begin live token" "owner:live other $CL" "$(n1_step_begin ticket 1 2>/dev/null)"
reset
assert_eq "i: step_begin silent when free" "" "$(n1_step_begin ticket 1 2>/dev/null)"
unset ID
echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

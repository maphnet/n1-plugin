#!/usr/bin/env bash
# tests/test_concurrent_state.sh — NP-206: per-project $N1_HOME state under concurrent sessions.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_SESSION_ID CLAUDE_CODE_SESSION_ID
export N1_HOME="$T/home"; mkdir -p "$N1_HOME"
source "$REPO_ROOT/lib/config.sh"
source "$REPO_ROOT/lib/frontmatter.sh"

# --- static guard: no fixed-name temp files in swept RMW helpers ---
SWEPT=("$REPO_ROOT/lib/frontmatter.sh" "$REPO_ROOT/lib/step.sh" "$REPO_ROOT/lib/signals.sh" \
       "$REPO_ROOT/lib/memory.sh" "$REPO_ROOT/lib/related.sh" "$REPO_ROOT/lib/queue.sh" \
       "$REPO_ROOT/scripts/n1-queue-run.sh")
FIXED=$(grep -nE '\$\{?[A-Za-z_]+\}?(\.step)?\.tmp"' "${SWEPT[@]}" || true)
assert_eq "no fixed .tmp names in swept helpers" "" "$FIXED"

# --- concurrent frontmatter writers never corrupt overview.md ---
OVD="$T/ov"; mkdir -p "$OVD"; OV="$OVD/overview.md"
printf -- '---\nstep: start\n---\n## Body\nkeep me\n' > "$OV"
for i in $(seq 1 30); do n1_write_frontmatter "$OV" step "s$i" 2>/dev/null & done
wait
assert_eq "frontmatter delimiters intact" "2" "$(grep -c '^---$' "$OV")"
assert_eq "exactly one step line" "1" "$(grep -c '^step: s[0-9]*$' "$OV")"
assert_eq "body preserved" "keep me" "$(tail -1 "$OV")"
assert_eq "no temp files left behind" "overview.md" "$(ls -A "$OVD")"

# --- active-run pointer is keyed per session ---
N1_SESSION_ID=sA n1_active_run_write T-1 run-a /wt/a T-1
N1_SESSION_ID=sB n1_active_run_write T-2 run-b /wt/b T-2
assert_eq "session A reads its own ticket" "T-1" "$(jq -r .ticketId "$(N1_SESSION_ID=sA n1_active_run_file)" 2>/dev/null)"
assert_eq "session B reads its own ticket" "T-2" "$(jq -r .ticketId "$(N1_SESSION_ID=sB n1_active_run_file)" 2>/dev/null)"
N1_SESSION_ID=sA n1_active_run_clear
assert_eq "clear removes only this session's pointer" "absent:T-2" \
  "$([ -f "$N1_HOME/active-run.sA.json" ] && echo present || echo absent):$(jq -r .ticketId "$N1_HOME/active-run.sB.json" 2>/dev/null)"
n1_active_run_write T-3 run-c null T-3
assert_eq "no session id writes the unkeyed file" "T-3" "$(jq -r .ticketId "$N1_HOME/active-run.json" 2>/dev/null)"
assert_eq "keyed reader falls back to unkeyed file" "$N1_HOME/active-run.json" "$(N1_SESSION_ID=sC n1_active_run_file 2>/dev/null)"
assert_eq "unsafe session id never becomes a filename" "$N1_HOME/active-run.json" "$(N1_SESSION_ID='../x' n1_active_run_file write 2>/dev/null)"

# --- n1_finish_mark / n1_active_run_clear_if (N1-167) ---
rm -f "$N1_HOME"/active-run*.json
assert_eq "mark without session id is unkeyed, writes nothing" "marker:unkeyed:none" \
  "$(n1_finish_mark T-9):$(ls "$N1_HOME" | grep -c '^active-run' | sed 's/^0$/none/')"
assert_eq "mark with session id is keyed" "marker:keyed:n1-finish" \
  "$(N1_SESSION_ID=sM n1_finish_mark T-9):$(jq -r .runId "$N1_HOME/active-run.sM.json")"
N1_SESSION_ID=sM n1_active_run_clear_if n1-start
assert_eq "clear_if keeps a pointer with another runId" "present" "$([ -f "$N1_HOME/active-run.sM.json" ] && echo present || echo absent)"
N1_SESSION_ID=sM n1_active_run_clear_if n1-finish
assert_eq "clear_if removes the n1-finish pointer" "absent" "$([ -f "$N1_HOME/active-run.sM.json" ] && echo present || echo absent)"
N1_SESSION_ID=sN n1_active_run_write T-8 run-x null T-8
N1_SESSION_ID=sN n1_finish_mark T-8 >/dev/null
N1_SESSION_ID=sN n1_active_run_clear_if n1-finish
assert_eq "mark keeps an existing pointer; clear_if then leaves it" "run-x" "$(jq -r .runId "$N1_HOME/active-run.sN.json")"
echo '{"runId":"n1-finish"}' > "$N1_HOME/active-run.json"
N1_SESSION_ID=sO n1_active_run_clear_if n1-finish
assert_eq "clear_if never removes the shared unkeyed file" "present" "$([ -f "$N1_HOME/active-run.json" ] && echo present || echo absent)"
touch "$T/notadir"
assert_eq "mark with unwritable home is marker:failed, rc 1" "marker:failed:1" \
  "$(N1_HOME="$T/notadir/x" N1_SESSION_ID=sF n1_finish_mark T-7 2>/dev/null || true):$(N1_HOME="$T/notadir/x" N1_SESSION_ID=sF n1_finish_mark T-7 >/dev/null 2>&1; echo $?)"

echo "---"; echo "PASS: $PASS  FAIL: $FAIL"; [ "$FAIL" -eq 0 ]

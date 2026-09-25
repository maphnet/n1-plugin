#!/usr/bin/env bash
# tests/test_concurrent_state.sh — NP-206: per-project $N1_HOME state under concurrent sessions.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_SESSION_ID CODEX_THREAD_ID CODEX_SESSION_ID CLAUDE_CODE_SESSION_ID
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

echo "---"; echo "PASS: $PASS  FAIL: $FAIL"; [ "$FAIL" -eq 0 ]

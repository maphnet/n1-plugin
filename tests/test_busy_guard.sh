#!/usr/bin/env bash
# tests/test_busy_guard.sh — NP-210: n1_busy_guard (lib/frontmatter.sh) same-ticket conflict detection.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
source "$REPO_ROOT/lib/frontmatter.sh"

OV="$T/overview.md"

# (a) no pid yet -> no warning, pid written, exit 0
printf -- '---\nstep: start\n---\n' > "$OV"
OUT=$(n1_busy_guard "$OV" T-1 2>&1); RC=$?
assert_eq "a: exit 0" 0 "$RC"
assert_eq "a: no warning" "" "$OUT"
assert_eq "a: pid written" "$$" "$(n1_read_frontmatter "$OV" pid)"

# (b) dead pid -> no warning, pid rewritten, exit 0
DEAD=99999; while kill -0 "$DEAD" 2>/dev/null; do DEAD=$((DEAD-1)); done
n1_write_frontmatter "$OV" pid "$DEAD"
OUT=$(n1_busy_guard "$OV" T-1 2>&1); RC=$?
assert_eq "b: exit 0" 0 "$RC"
assert_eq "b: no warning" "" "$OUT"
assert_eq "b: pid rewritten" "$$" "$(n1_read_frontmatter "$OV" pid)"

# (c) live, different pid, interactive -> warning, exit 0, pid untouched by guard's own write path
sleep 30 & OTHER=$!
n1_write_frontmatter "$OV" pid "$OTHER"
unset N1_HEADLESS
OUT=$(n1_busy_guard "$OV" T-1 2>&1); RC=$?
assert_eq "c: exit 0" 0 "$RC"
assert_eq "c: warns" "1" "$(echo "$OUT" | grep -c 'already running')"

# (c-headless) live, different pid, headless -> refuses, exit 3
n1_write_frontmatter "$OV" pid "$OTHER"
OUT=$(N1_HEADLESS=1 n1_busy_guard "$OV" T-1 2>&1); RC=$?
assert_eq "c-headless: exit 3" 3 "$RC"
assert_eq "c-headless: refuses" "1" "$(echo "$OUT" | grep -c 'refusing (headless)')"
kill "$OTHER" 2>/dev/null; wait "$OTHER" 2>/dev/null

# (d) live, self pid -> no warning, exit 0
n1_write_frontmatter "$OV" pid "$$"
OUT=$(n1_busy_guard "$OV" T-1 2>&1); RC=$?
assert_eq "d: exit 0" 0 "$RC"
assert_eq "d: no warning" "" "$OUT"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

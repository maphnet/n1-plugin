#!/usr/bin/env bash
# tests/test_timeout_kill_after.sh — NP-227: bounded call sites escalate to SIGKILL
# after a grace period, and the escalation reaches TERM-ignoring descendants.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
command -v timeout >/dev/null || { echo "SKIP: timeout missing"; exit 0; }

BC="$REPO_ROOT/lib/breakcheck.sh"
QR="$REPO_ROOT/scripts/n1-queue-run.sh"
XR="$REPO_ROOT/skills/n1-pr/steps/03-cross-host-review.md"

# 1. Static guard: every in-scope call site carries -k 30 ...
assert_eq "breakcheck.sh: timeout -k 30 sites"        2 "$(grep -c 'timeout -k 30 ' "$BC" || true)"
assert_eq "n1-queue-run.sh: timeout -k 30 sites"      2 "$(grep -c 'timeout -k 30 ' "$QR" || true)"
assert_eq "03-cross-host-review.md: timeout -k 30 site" 1 "$(grep -c 'timeout -k 30 ' "$XR" || true)"
# ... and no bare `timeout <duration>` invocation in command position remains.
BARE=$(grep -nE '(^|&&|[;(|])[[:space:]]*timeout[[:space:]]+[^-[:space:]]' "$BC" "$QR" "$XR" || true)
assert_eq "no bare timeout call sites" "" "$BARE"
# breakcheck must classify the SIGKILL-escalated exit (137) as a timeout too.
assert_eq "breakcheck accepts 137 as timeout" 1 "$(grep -c 'rc_rev" -eq 137' "$BC" || true)"
# SEC-1: n1-queue-run.sh must force OUTCOME=failed for exit 137, not just 124.
assert_eq "n1-queue-run.sh: 137 forces OUTCOME=failed" 1 "$(grep -c '124|137) OUTCOME="failed"' "$QR" || true)"

# 2. Behavior: -k escalates to SIGKILL for the whole process group.
PIDF=$(mktemp)
START=$SECONDS
set +e
timeout -k 1 1 bash -c 'trap "" TERM; sleep 30 & echo $! > "$1"; wait' _ "$PIDF"
RC=$?
set -e
ELAPSED=$((SECONDS - START))
assert_eq "escalated timeout exit code is 128+SIGKILL" 137 "$RC"
assert_eq "returned within grace window (<10s)" true "$([ "$ELAPSED" -lt 10 ] && echo true || echo false)"

CHILD=$(cat "$PIDF"); rm -f "$PIDF"
alive=true
if [ -n "$CHILD" ]; then
    # ponytail: kill -0 sees an unreaped zombie as alive; 2s retry covers init reaping.
    for _ in $(seq 1 20); do kill -0 "$CHILD" 2>/dev/null || { alive=false; break; }; sleep 0.1; done
    [ "$alive" = false ] || kill -9 "$CHILD" 2>/dev/null || true
fi
assert_eq "TERM-ignoring descendant killed with the group" false "$alive"

echo; echo "Passed: $PASS  Failed: $FAIL"; [ "$FAIL" -eq 0 ]

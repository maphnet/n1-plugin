#!/usr/bin/env bash
# tests/test_implement_inline_review.sh — N1-469: per-task review templates tell the reviewer to reply
# inline and write no file; review scope text is unchanged.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO_ROOT/skills/n1-implement/SKILL.md"
PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (missing: $2)"; FAIL=$((FAIL+1)); fi; }
section() { awk -v h="$1" '$0==h{p=1;next} p&&/^---$/{exit} p' "$SKILL"; }

TR=$(section "## Task Review Template")
RR=$(section "## Re-Review Template")
check "Task Review Template extractable" "Review Task N" "$TR"
check "Re-Review Template extractable" "Re-Review Task N" "$RR"
check "Task Review: inline reply" "Return findings inline in your reply; write no file." "$TR"
check "Re-Review: inline reply" "Return findings inline in your reply; write no file." "$RR"
# Scope unchanged.
check "Task Review scope unchanged" "diff from BASE to HEAD" "$TR"
check "Re-Review scope unchanged" "Scope:** verify only the fix diff (FIX_BASE to HEAD)" "$RR"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

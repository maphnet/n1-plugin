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

# N1-517: run mode n1-start caps per-task fix rounds at 2 and skips the Final Review Gate; standalone unchanged.
BODY=$(cat "$SKILL")
IMPL=$(cat "$REPO_ROOT/skills/n1-start/steps/implementation.md")
check "n1-start carries the run mode" "Run mode: n1-start (per-task fix rounds 1-2, then adjudicate; skip the Final Review Gate)" "$IMPL"
check "fix loop: n1-start stops after round 2" "Run mode: n1-start: rounds 1-2 only, then adjudicate." "$BODY"
check "fix loop: standalone keeps fresh-developer rounds" "Rounds 4-5: a fresh developer" "$BODY"
check "fix loop: adjudicate after the last round" "After the last round with open findings: adjudicate each" "$BODY"
check "final gate: skipped under n1-start" "Run mode: n1-start: skip (Step 7 reviews the full diff)." "$BODY"
check "re-review: round cap follows the run mode" "Re-Review Task N, Round R/<cap>" "$RR"
SIZE=$(wc -c < "$SKILL")
if [ "$SIZE" -le 6144 ]; then echo "PASS: SKILL.md within 6144 B ($SIZE)"; PASS=$((PASS+1)); else echo "FAIL: SKILL.md is $SIZE B > 6144"; FAIL=$((FAIL+1)); fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

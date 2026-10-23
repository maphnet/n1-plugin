#!/usr/bin/env bash
# N1-116: hands-off soft-findings policy after review PASS stays wired through review -> fix -> PR body.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
R=skills/n1-start/steps/review.md
F=skills/n1-start/steps/fix.md
S=skills/n1-start/SKILL.md

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

check "review step exposes QE to the PASS branch" 'QE=\$\(n1_autonomy_val .qualityEscalations.\)' "$R"
check "PASS + auto-accept records deferred soft findings" 'QE=auto-accept.*## Deferred Soft Findings' "$R"
check "PASS + Medium routes to Step 8 SOFT-ONLY" 'Medium.*Step 8 SOFT-ONLY' "$R"
check "PASS without Medium: no soft pass" 'none.*no soft pass' "$R"
check "PASS: security findings never soft" 'SEC-N.*never soft.*FAIL' "$R"
check "hard findings stay explicit and unchanged" 'always FAIL.*\(unchanged\)' "$R"

check "FAIL path marked unchanged" '^\*\*FAIL\*\* \(unchanged\):' "$F"
check "SOFT-ONLY paragraph exists" '^\*\*SOFT-ONLY\*\*' "$F"
check "soft pass recorded with (soft) heading" '## Fix Cycle <N> \(soft\)' "$F"
check "soft pass skips counter and re-review" 'no `review_fix_cycle` increment, no re-review' "$F"
check "soft pass deferrals still filed" 'SOFT-ONLY.*Findings deferred' "$F"

check "pipeline table names the soft pass" 'FIX \(if FAIL or soft pass\)' "$S"

exit $FAIL

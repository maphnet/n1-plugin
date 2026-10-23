#!/usr/bin/env bash
# N1-116: hands-off soft-findings policy after review PASS stays wired through review -> fix -> PR body.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
R=skills/n1-start/steps/review.md
F=skills/n1-start/steps/fix.md
S=skills/n1-start/SKILL.md
T=agents/tech-writer.md

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

check "review step exposes QE to the PASS branch" 'QE=\$\(n1_autonomy_val .qualityEscalations.\)' "$R"
check "PASS + auto-accept records deferred soft findings" 'QE=auto-accept.*## Deferred Soft Findings' "$R"
check "PASS + Medium routes to Step 8 SOFT-ONLY" 'Medium.*Step 8 SOFT-ONLY' "$R"
check "PASS without Medium: no soft pass" 'none.*no soft pass' "$R"
check "PASS: security findings never soft" 'SEC-N.*never soft.*FAIL' "$R"
check "hard findings stay explicit and unchanged" 'always FAIL.*\(unchanged\)' "$R"

check "FAIL path paragraph exists" '^\*\*FAIL\*\*: spawn' "$F"
check "SOFT-ONLY paragraph exists" '^\*\*SOFT-ONLY\*\*' "$F"
check "soft pass recorded with (soft) heading" '## Fix Cycle <N> \(soft\)' "$F"
check "soft pass skips counter and re-review" 'no `review_fix_cycle` increment, no re-review' "$F"
check "soft pass deferrals still filed" 'SOFT-ONLY.*Findings deferred' "$F"

check "pipeline table names the soft pass" 'FIX \(if FAIL or soft pass\)' "$S"
check "PR body lists deferred soft findings" '## Deferred Soft Findings.*## Review Notes' "$T"
check "review FAIL: [SEC-N] scoped to auto-accept" 'with .QE=auto-accept. also any .\[SEC-N\]' "$R"
check "fix FAIL spawn passes [SEC-N]" 'also all `\[SEC-N\]`' "$F"
check "fix increment block labeled FAIL-only" 'FAIL-only \(the next two blocks; SOFT-ONLY skips' "$F"
check "fix Return to Step 7 labeled FAIL-only" 'FAIL-only: return to Step 7' "$F"
check "tech-writer excludes [SEC-N] from bullets" 'Omit `\[SEC-N\]`' "$T"

check "soft pass adds unfixed Medium to deferred list" 'Medium it left unfixed.*Deferred Soft Findings' "$F"
check "deferred list takes only Low XREPO" 'Low `\[XREPO-N\]`' "$R"

exit $FAIL

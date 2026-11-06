#!/usr/bin/env bash
# N1-116: hands-off soft-findings policy after review PASS stays wired through review -> fix -> PR body.
# N1-209: Medium routes — (correctness) Medium -> SOFT-ONLY; other Medium -> Deferred Soft Findings, no developer; FAIL fixes every non-TQ Medium.
# N1-257: [SEC-N] Low deferred at every cycle; ` (pre-existing)` [SEC-N] never FAILs (Medium/Low filed, Critical/High escalate).
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
R=skills/n1-start/steps/review.md
RP=skills/n1-start/procedures/review-preexisting.md
F=skills/n1-start/steps/fix.md
S=skills/n1-start/SKILL.md
T=agents/tech-writer.md
C=agents/code-reviewer.md
SR=agents/security-reviewer.md

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
check_absent() { # <label> <fixed-string> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}

check "PASS records deferred soft findings" '^\*\*PASS\*\* \(hands-off soft policy, N1-116\).*## Deferred Soft Findings' "$R"
check "route 1: PASS + (correctness) Medium routes to Step 8 SOFT-ONLY" 'title ends ` \(correctness\)` → Step 8 SOFT-ONLY' "$R"
check "route 2: PASS + other Medium deferred, no developer" 'every other non-TQ Medium to `## Deferred Soft Findings` \(no developer' "$R"
check "PASS without (correctness) Medium: no soft pass" 'no `\(correctness\)` Medium → no soft pass' "$R"
check "PASS: in-diff non-Low security findings never soft" 'In-diff non-Low `\[SEC-N\]` is never soft: FAIL → Step 8' "$R"
check "hard findings stay explicit and unchanged" 'always FAIL.*\(unchanged\)' "$R"

check "FAIL path paragraph exists" '^\*\*FAIL\*\*: spawn' "$F"
check "SOFT-ONLY paragraph exists" '^\*\*SOFT-ONLY\*\*' "$F"
check "soft pass recorded with (soft) heading" '## Fix Cycle <N> \(soft\)' "$F"
check "soft pass skips counter and re-review" 'no `review_fix_cycle` increment, no re-review' "$F"
check "soft pass deferrals still filed" 'SOFT-ONLY.*Findings deferred' "$F"
check "SOFT-ONLY scope is (correctness) Medium only" 'scope: non-TQ Medium titled `\(correctness\)` only' "$F"

check "pipeline table names the soft pass" 'FIX \(if FAIL or soft pass\)' "$S"
check "PR body lists deferred soft findings" '## Deferred Soft Findings.*## Review Notes' "$T"
check "review FAIL: in-diff non-Low [SEC-N]" 'above\); also any in-diff non-Low .\[SEC-N\].' "$R"
check "fix FAIL spawn passes in-diff non-Low [SEC-N]" 'also every in-diff non-Low `\[SEC-N\]`' "$F"
check "route 3: FAIL scope fixes every non-TQ Medium except pre-existing in the same pass" 'also every in-diff non-Low `\[SEC-N\]` and every non-TQ Medium except ` \(pre-existing\)`, fixed in this same pass' "$F"
check "fix increment block labeled FAIL-only" 'FAIL-only \(the next two blocks; SOFT-ONLY skips' "$F"
check "fix Return to Step 7 labeled FAIL-only" 'FAIL-only: return to Step 7' "$F"
check "tech-writer excludes [SEC-N] from bullets" 'Omit `\[SEC-N\]`' "$T"

check "soft pass adds unfixed Medium to deferred list" 'Medium it left unfixed.*Deferred Soft Findings' "$F"
check "deferred list takes only Low XREPO" 'Low `\[XREPO-N\]`' "$R"
check "code-reviewer marks correctness Mediums" '^- \*\*Correctness marker:\*\*.*` \(correctness\)`' "$C"

# N1-261: no unreviewed soft pass after a FAIL fix cycle
check "review: SOFT-ONLY route only at review_fix_cycle 0, defer at >=1" 'Step 8 SOFT-ONLY \(one developer pass, no re-review\) only when `review_fix_cycle` is 0 or absent.*`review_fix_cycle>=1`.*defer it, no developer' "$R"
check "fix: Cap gate defers SOFT-ONLY at REVIEW_FIX_CYCLE>=1" '^\*\*Cap gate\*\*.*SOFT-ONLY with `FIX_GATE` not `allow` or `REVIEW_FIX_CYCLE>=1`.*Deferred Soft Findings' "$F"

# N1-257
check "review FAIL: SEC Low and pre-existing never FAIL" 'never a `\[SEC-N\]` Low or ` \(pre-existing\)`' "$R"
check "review FAIL: pre-existing Critical/High [SEC-N] exempt under auto-accept" 'except a ` \(pre-existing\)` `\[SEC-N\]`: \*\*Pre-existing\*\* above' "$R"
check_absent "SEC Low deferral no longer gated on fix cycle" 'Low `\[SEC-N\]` only when `review_fix_cycle>=1`' "$R"
check "SEC Low deferred at every cycle incl. 0" '`\[SEC-N\]` Low too, at every cycle incl\. 0' "$R"
check "pre-existing never listed as soft" 'Never list a ` \(pre-existing\)` finding not treated as in-diff \(filed above\); a downgraded one is an ordinary `\[SEC-N\]`' "$R"
check "pre-existing handled before routing on PASS or FAIL" '^\*\*Pre-existing\*\* \(PASS or FAIL, before routing\)' "$RP"
check "pre-existing Medium/Low filed via followup-filing" 'Medium/Low: append to `## Follow-ups` per `<N1_ROOT>/references/followup-filing\.md` § Append \(source `review`\)' "$RP"
check "pre-existing Critical/High escalates" 'Critical/High or any other or unparsed severity: § Autonomy Gate' "$RP"
check "pre-existing prompt: no recommendation" 'No recommendation\. The options are equivalent given the available evidence; select based on team preference\. 1\. File as follow-up' "$RP"
check "non-pre-existing hard findings still FAIL" 'Other Critical/High/`\[RULE-N\]` always FAIL' "$R"
check "Exhausted gate: in-diff non-Low SEC blocks auto-resolve" 'No open in-diff non-Low `\[SEC-N\]` or security-class finding' "$F"

check "security-reviewer marks pre-existing findings" '^- \*\*Pre-existing marker:\*\*.*` \(pre-existing\)`' "$SR"
check "security-reviewer Index title carries the marker" 'when the Pre-existing marker constraint applies, end `<title>` with ` \(pre-existing\)`; never otherwise' "$SR"
check "fix scope: pre-existing SEC filed by user excluded from Critical+High" 'Critical\+High \(except a ` \(pre-existing\)` `\[SEC-N\]` the user filed;' "$F"
check "fingerprints: pre-existing SEC not treated as in-diff excluded" 'except a ` \(pre-existing\)` one not treated as in-diff' "$R"
check "pre-existing marker downgraded when in a changed hunk" 'lies in a changed hunk or in a file the diff adds' "$RP"
check "pre-existing gate skips titles already in Follow-ups" 'Skip a finding whose title is already in `## Follow-ups`' "$RP"
check "pre-existing unknown severity escalates" 'any other or unparsed severity: § Autonomy Gate' "$RP"
check "pre-existing downgrade names base range" 'git diff -U0 "\$BASE_BRANCH"\.\.\.HEAD' "$RP"
check "pre-existing command has no pathspec or finding text" 'no pathspec, never put a finding path or title in a command' "$RP"
check "pre-existing unparsable file:line fails closed" 'missing or unparsable `file:line` counts as in-diff' "$RP"

exit $FAIL

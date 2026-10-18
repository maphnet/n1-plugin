#!/usr/bin/env bash
# Native skill tests: no Superpowers dependency in manifests, skill size budgets.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0

# 1. No Superpowers in any manifest
for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json; do
    if grep -qi 'superpowers' "$f" 2>/dev/null; then
        echo "FAIL: $f still references superpowers"; FAIL=1
    fi
done
[ $FAIL -eq 0 ] && echo "PASS: no superpowers in manifests"

# 2. Skill size budgets (in bytes)
check_size() { # <path-or-dir> <max-bytes> <label>
    local size
    if [ -d "$1" ]; then
        size=$(find "$1" -name '*.md' -exec cat {} + | wc -c)
    else
        size=$(wc -c < "$1")
    fi
    if [ "$size" -le "$2" ]; then
        echo "PASS: $3 is ${size}B (<= ${2}B)"
    else
        echo "FAIL: $3 is ${size}B (budget ${2}B)"; FAIL=1
    fi
}
check_size "skills/n1-brainstorm" 5120 "n1-brainstorm"
check_size "skills/n1-plan" 4096 "n1-plan"
check_size "skills/n1-implement" 8192 "n1-implement"

# 3. Codex review `codex exec` dispatch must never block on inherited stdin (NP-224)
REVIEW_RUNNER=scripts/codex-pr-review.sh
CODEX_LINE=$(grep -n 'codex exec' "$REVIEW_RUNNER" | head -1)
if echo "$CODEX_LINE" | grep -q 'timeout '; then
    echo "PASS: 03-codex-review codex exec is timeout-wrapped"
else
    echo "FAIL: 03-codex-review codex exec is missing a timeout wrapper"; FAIL=1
fi
if grep -A4 'codex exec' "$REVIEW_RUNNER" | grep -q '</dev/null'; then
    echo "PASS: 03-codex-review codex exec redirects stdin from /dev/null"
else
    echo "FAIL: 03-codex-review codex exec is missing </dev/null"; FAIL=1
fi

if grep -qE 'TIER=|tier.*complex|n1_host' skills/n1-pr/steps/03-codex-review.md; then
    echo "FAIL: 03-codex-review still gates on tier or host"; FAIL=1
else
    echo "PASS: 03-codex-review runs on every PR (no tier/host gate)"
fi

# 4. N1-70: the PR report/CHECKPOINT lives at the end of step 3, not step 2,
#    so the orchestrator never stops before the Codex review.
P2=skills/n1-pr/steps/02-push-create.md
P3=skills/n1-pr/steps/03-codex-review.md
if grep -q 'CHECKPOINT:' "$P2"; then
    echo "FAIL: 02-push-create still prints a CHECKPOINT"; FAIL=1
else
    echo "PASS: 02-push-create prints no CHECKPOINT"
fi
if grep -q '03-codex-review.md' <<<"$(grep -v '^[[:space:]]*$' "$P2" | tail -1)"; then
    echo "PASS: 02-push-create ends with continuation to step 3"
else
    echo "FAIL: 02-push-create does not end with continuation to step 3"; FAIL=1
fi
LAST_CP=$(grep -n 'CHECKPOINT: Ready for Tech Lead review.' "$P3" | tail -1 | cut -d: -f1)
TRIAGE_REPLY=$(grep -n '^### Triage Reply' "$P3" | head -1 | cut -d: -f1)
if [ -n "$LAST_CP" ] && [ -n "$TRIAGE_REPLY" ] && [ "$LAST_CP" -gt "$TRIAGE_REPLY" ]; then
    echo "PASS: 03-codex-review ends with the PR report CHECKPOINT"
else
    echo "FAIL: 03-codex-review is missing the final CHECKPOINT after Triage Reply"; FAIL=1
fi
if grep -qiE 'stop here|skip this step entirely' "$P3"; then
    echo "FAIL: 03-codex-review has an early exit that bypasses the Report"; FAIL=1
else
    echo "PASS: 03-codex-review has no early exit before the Report"
fi
if grep -qF 'n1_record_decision codex-review' lib/codex-review.sh && grep -qF 'step-not-run' hooks/pr-review-observe.sh; then
    echo "PASS: 03-codex-review records skipped codex-review decisions"
else
    echo "FAIL: 03-codex-review does not record skipped codex-review decisions"; FAIL=1
fi

# 5. N1-70: dispatch budget/effort/prompt, outcome telemetry, and codex+post in one bash fence
for pat in 'N1_CROSS_HOST_REVIEW_TIMEOUT:-900' 'codex exec -c model_reasoning_effort=medium' 'do not run tests' 'n1_review_record'; do
    if grep -qF "$pat" "$REVIEW_RUNNER"; then
        echo "PASS: 03-codex-review has '$pat'"
    else
        echo "FAIL: 03-codex-review missing '$pat'"; FAIL=1
    fi
done
CX=$(grep -n 'codex exec' "$REVIEW_RUNNER" | head -1 | cut -d: -f1)
GH=$(grep -n 'gh pr comment' "$REVIEW_RUNNER" | head -1 | cut -d: -f1)
if [ -n "$CX" ] && [ -n "$GH" ] && [ "$GH" -gt "$CX" ] && ! grep -q '^```' <<<"$(sed -n "${CX},${GH}p" "$REVIEW_RUNNER")"; then
    echo "PASS: 03-codex-review runs codex and posts the comment in one bash block"
else
    echo "FAIL: 03-codex-review splits codex dispatch and comment posting across blocks"; FAIL=1
fi

# 6. N1-94: Codex findings are validated by a read-only reviewer before developer fixes
first_line() { grep -n -m1 -E -- "$1" "$P3" | cut -d: -f1; }
SEV=$(first_line '^### Severity Parsing'); VAL=$(first_line '^### Validation')
FIX=$(first_line '^### Fix Cycle'); TR=$(first_line '^### Triage Reply')
CRV=$(first_line 'n1_resolve_agent code-reviewer review')
if [ -n "$SEV" ] && [ -n "$VAL" ] && [ -n "$FIX" ] && [ "$SEV" -lt "$VAL" ] && [ "$VAL" -lt "$FIX" ]; then
    echo "PASS: 03-codex-review has Validation between Severity Parsing and Fix Cycle"
else
    echo "FAIL: 03-codex-review Validation section missing or misplaced"; FAIL=1
fi
if [ -n "$CRV" ] && [ -n "$VAL" ] && [ -n "$FIX" ] && [ "$CRV" -gt "$VAL" ] && [ "$CRV" -lt "$FIX" ]; then
    echo "PASS: 03-codex-review Validation dispatches code-reviewer"
else
    echo "FAIL: 03-codex-review Validation does not resolve code-reviewer"; FAIL=1
fi
for pat in 'Critical, High, or Medium' 'CONFIRMED | INVALID' '<CONFIRMED_FINDINGS>' 'on by default' 'gh pr diff' 'nothing to triage'; do
    if grep -qF -- "$pat" "$P3"; then
        echo "PASS: 03-codex-review has '$pat'"
    else
        echo "FAIL: 03-codex-review missing '$pat'"; FAIL=1
    fi
done
if grep -qF 'HIGH_PLUS' "$P3"; then
    echo "FAIL: 03-codex-review developer still receives unvalidated High+ findings"; FAIL=1
else
    echo "PASS: 03-codex-review developer receives only confirmed findings"
fi
if grep -qiE 'ask the user|wait for (the )?user' "$P3"; then
    echo "FAIL: 03-codex-review triage prompts the user"; FAIL=1
else
    echo "PASS: 03-codex-review triage never prompts the user"
fi
if [ -n "$TR" ] && sed -n "${TR},\$p" "$P3" | grep -qF 'Dismissed by validator'; then
    echo "PASS: 03-codex-review Triage Reply lists validator dismissals"
else
    echo "FAIL: 03-codex-review Triage Reply lacks validator dismissals"; FAIL=1
fi

# 7. N1-94 SEC-1: untrusted triage text reaches the PR only through a file
if grep -qF -- '--body-file "$TRIAGE_FILE"' "$P3" && ! grep -qE 'TRIAGE_BODY=|printf .*\$TRIAGE_BODY' "$P3"; then
    echo "PASS: 03-codex-review posts triage via --body-file, never via shell variable"
else
    echo "FAIL: 03-codex-review triage reply splices text into shell"; FAIL=1
fi

exit $FAIL

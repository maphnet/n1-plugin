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

if grep -qE 'TIER=|tier.*complex|n1_host' skills/n1-pr/steps/03-codex-review.md skills/n1-pr/procedures/codex-triage.md 2>/dev/null; then
    echo "FAIL: 03-codex-review still gates on tier or host"; FAIL=1
else
    echo "PASS: 03-codex-review runs on every PR (no tier/host gate)"
fi

# 4. N1-70: the PR report/CHECKPOINT lives at the end of step 3, not step 2,
#    so the orchestrator never stops before the Codex review.
P2=skills/n1-pr/steps/02-push-create.md
P3=skills/n1-pr/steps/03-codex-review.md
TRI=skills/n1-pr/procedures/codex-triage.md
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
PTR=$(grep -n 'procedures/codex-triage.md' "$P3" | head -1 | cut -d: -f1)
if [ -n "$LAST_CP" ] && [ -n "$PTR" ] && [ "$LAST_CP" -gt "$PTR" ] && grep -q '^### Triage Reply' "$TRI" 2>/dev/null \
   && grep -q 'Step 10: Report' <<<"$(grep -v '^[[:space:]]*$' "$TRI" 2>/dev/null | tail -1)"; then
    echo "PASS: 03-codex-review ends with the PR report CHECKPOINT; triage returns to Step 10"
else
    echo "FAIL: 03-codex-review CHECKPOINT/triage return path broken"; FAIL=1
fi
if grep -qiE 'stop here|skip this step entirely' "$P3" "$TRI" 2>/dev/null; then
    echo "FAIL: 03-codex-review or codex-triage has an early exit that bypasses the Report"; FAIL=1
else
    echo "PASS: 03-codex-review and codex-triage have no early exit before the Report"
fi
if grep -qF 'n1_record_decision codex-review' lib/codex-review.sh && grep -qF 'step-not-run' hooks/pr-review-observe.sh; then
    echo "PASS: 03-codex-review records skipped codex-review decisions"
else
    echo "FAIL: 03-codex-review does not record skipped codex-review decisions"; FAIL=1
fi

# 4b. N1-127: triage text is read on demand; 03 keeps only runner, gate and report
if [ -f "$TRI" ] && grep -qF 'procedures/codex-triage.md' "$P3"; then
    echo "PASS: 03-codex-review points to the on-demand triage procedure"
else
    echo "FAIL: 03-codex-review triage procedure pointer or file missing"; FAIL=1
fi
if grep -qE '^### (Severity Parsing|Validation|Fix Cycle|Reconcile PR Body|Triage Reply)' "$P3"; then
    echo "FAIL: 03-codex-review still inlines triage sections"; FAIL=1
else
    echo "PASS: 03-codex-review keeps triage sections in the procedure"
fi
P3_BYTES=$(wc -c < "$P3")
if [ "$P3_BYTES" -le 7000 ]; then
    echo "PASS: 03-codex-review is $P3_BYTES B (<= 7000)"
else
    echo "FAIL: 03-codex-review is $P3_BYTES B (> 7000)"; FAIL=1
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
first_line() { grep -n -m1 -E -- "$1" "$TRI" 2>/dev/null | cut -d: -f1; }
SEV=$(first_line '^### Severity Parsing'); VAL=$(first_line '^### Validation')
FIX=$(first_line '^### Fix Cycle'); TR=$(first_line '^### Triage Reply')
CRV=$(first_line 'n1_resolve_agent code-reviewer review')
if [ -n "$SEV" ] && [ -n "$VAL" ] && [ -n "$FIX" ] && [ "$SEV" -lt "$VAL" ] && [ "$VAL" -lt "$FIX" ]; then
    echo "PASS: codex-triage has Validation between Severity Parsing and Fix Cycle"
else
    echo "FAIL: codex-triage Validation section missing or misplaced"; FAIL=1
fi
if [ -n "$CRV" ] && [ -n "$VAL" ] && [ -n "$FIX" ] && [ "$CRV" -gt "$VAL" ] && [ "$CRV" -lt "$FIX" ]; then
    echo "PASS: codex-triage Validation dispatches code-reviewer"
else
    echo "FAIL: codex-triage Validation does not resolve code-reviewer"; FAIL=1
fi
for pat in 'Critical, High, or Medium' 'CONFIRMED | INVALID' '<CONFIRMED_FINDINGS>' 'gh pr diff'; do
    if grep -qF -- "$pat" "$TRI" 2>/dev/null; then
        echo "PASS: codex-triage has '$pat'"
    else
        echo "FAIL: codex-triage missing '$pat'"; FAIL=1
    fi
done
for pat in 'on by default' 'nothing to triage'; do
    if grep -qF -- "$pat" "$P3"; then
        echo "PASS: 03-codex-review gate has '$pat'"
    else
        echo "FAIL: 03-codex-review gate missing '$pat'"; FAIL=1
    fi
done
if grep -qF 'HIGH_PLUS' "$P3" "$TRI" 2>/dev/null; then
    echo "FAIL: codex triage developer still receives unvalidated High+ findings"; FAIL=1
else
    echo "PASS: codex triage developer receives only confirmed findings"
fi
if grep -qiE 'ask the user|wait for (the )?user' "$P3" "$TRI" 2>/dev/null; then
    echo "FAIL: codex triage prompts the user"; FAIL=1
else
    echo "PASS: codex triage never prompts the user"
fi
if [ -n "$TR" ] && sed -n "${TR},\$p" "$TRI" | grep -qF 'Dismissed by validator'; then
    echo "PASS: codex-triage Triage Reply lists validator dismissals"
else
    echo "FAIL: codex-triage Triage Reply lacks validator dismissals"; FAIL=1
fi

# 7. N1-94 SEC-1: untrusted triage text reaches the PR only through a file
if grep -qF -- '--body-file "$TRIAGE_FILE"' "$TRI" 2>/dev/null && ! grep -qE 'TRIAGE_BODY=|printf .*\$TRIAGE_BODY' "$P3" "$TRI" 2>/dev/null; then
    echo "PASS: codex-triage posts triage via --body-file, never via shell variable"
else
    echo "FAIL: codex-triage triage reply splices text into shell"; FAIL=1
fi

# 8. N1-94 SEC-2 / CR-3: developer never pushes; orchestrator path gate; validator scope pins
if grep -qF 'Do NOT push' "$TRI" 2>/dev/null && grep -qF 'push:blocked' "$TRI" && grep -qF 'codex-push-gate.sh' "$TRI"; then
    echo "PASS: codex-triage gates the push on allowed paths"
else
    echo "FAIL: codex-triage push gate missing"; FAIL=1
fi
for pat in 'Scope override' 'do not run git' 'UNVERIFIED' 'authoritative'; do
    if grep -qF -- "$pat" "$TRI" 2>/dev/null; then
        echo "PASS: codex-triage validator has '$pat'"
    else
        echo "FAIL: codex-triage validator missing '$pat'"; FAIL=1
    fi
done

# 9. N1-123 D1: the N1-116 soft-findings policy does not apply to Codex triage
for f in "$TRI" references/architecture.md; do
    if grep -qF 'does not apply to Codex triage (N1-123)' "$f"; then
        echo "PASS: $f records the N1-123 Codex triage decision"
    else
        echo "FAIL: $f missing the N1-123 Codex triage decision"; FAIL=1
    fi
done

# 10. N1-123 SEC-4: disclose soft-pass fixes as not cross-reviewed when Codex did not run
for pat in '### Soft-Fix Notice' '^## Fix Cycle [0-9]+ \(soft\)' 'not cross-reviewed' '--body-file "$SOFTFIX_FILE"' 'softfix:comment-failed' 'softfix:reviewed' 'softfix:no-id' 'softfix:bad-pr-url' 'softfix:unreadable' 'softfix:already-posted' 'gh pr view "$PR_URL" --json comments' 'gh pr comment "$PR_URL"'; do
    if grep -qF -- "$pat" "$P3"; then
        echo "PASS: 03-codex-review soft-fix notice has '$pat'"
    else
        echo "FAIL: 03-codex-review soft-fix notice missing '$pat'"; FAIL=1
    fi
done
SF=$(grep -n '^### Soft-Fix Notice' "$P3" | head -1 | cut -d: -f1)
TG=$(grep -n '^### Triage Gate' "$P3" | head -1 | cut -d: -f1)
if [ -n "$SF" ] && [ -n "$TG" ] && [ "$SF" -lt "$TG" ]; then
    echo "PASS: 03-codex-review soft-fix notice runs before the Triage Gate"
else
    echo "FAIL: 03-codex-review soft-fix notice must precede the Triage Gate"; FAIL=1
fi
if grep -qF '## Fix Cycle <N> (soft)' skills/n1-start/steps/fix.md && grep -qF -- '^## Fix Cycle [0-9]+ \(soft\)' "$P3"; then
    echo "PASS: soft Fix Cycle heading matches between fix.md and the notice grep"
else
    echo "FAIL: soft Fix Cycle heading drifted between fix.md and 03-codex-review.md"; FAIL=1
fi
if grep -qF 'Soft-fix disclosure (SEC-4, N1-123)' references/architecture.md; then
    echo "PASS: architecture.md documents the soft-fix disclosure and residual gap"
else
    echo "FAIL: architecture.md missing the soft-fix disclosure"; FAIL=1
fi

if grep -q 'qualityEscalations' skills/n1-pr/steps/03-codex-review.md && grep -q 'auto-accept' skills/n1-pr/steps/03-codex-review.md && grep -q 'never end with an offer or question to fix Codex findings' skills/n1-pr/steps/03-codex-review.md && grep -q 'never close Gate 3 with an offer or question to fix Codex findings' skills/n1-start/procedures/output-gates.md; then
    echo "PASS: 03-codex-review fixes all findings under auto-accept and never offers"
else
    echo "FAIL: 03-codex-review missing qualityEscalations auto-accept / no-offer rule"; FAIL=1
fi

# 9. N1-127: tech-writer writes the PR body to a file; 02 creates the PR from it
P1=skills/n1-pr/steps/01-prepare.md
TWR=agents/tech-writer.md
if grep -qF 'PR_BODY_FILE=$(mktemp "$N1_HOME/scratch/pr-body-' "$P1" && grep -qF 'body_file:' "$P1"; then
    echo "PASS: 01-prepare creates the PR body file and passes body_file"
else
    echo "FAIL: 01-prepare does not create/pass the PR body file"; FAIL=1
fi
if grep -qF '`body_file`' "$TWR" && grep -qF 'pr body written: <body_file>' "$TWR"; then
    echo "PASS: tech-writer writes the PR body to body_file"
else
    echo "FAIL: tech-writer has no body_file output"; FAIL=1
fi
if grep -qF 'PR_BODY_FILE="<the path from pr:body-file=>"' "$P2" && grep -qF -- '--body-file "$PR_BODY_FILE"' "$P2"; then
    echo "PASS: 02-push-create defines and uses PR_BODY_FILE"
else
    echo "FAIL: 02-push-create PR_BODY_FILE undefined or unused"; FAIL=1
fi
if grep -qF '[ -s "$PR_BODY_FILE" ] ||' "$P2"; then
    echo "PASS: 02-push-create refuses an empty PR body"
else
    echo "FAIL: 02-push-create does not guard an empty PR body"; FAIL=1
fi
if grep -qF -- '--body "<body>"' "$P2"; then
    echo "FAIL: 02-push-create still inlines the PR body"; FAIL=1
else
    echo "PASS: 02-push-create never inlines the PR body"
fi

exit $FAIL

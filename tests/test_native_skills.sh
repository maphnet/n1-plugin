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
CODEX_LINE=$(grep -n 'codex exec' skills/n1-pr/steps/03-codex-review.md | head -1)
if echo "$CODEX_LINE" | grep -q 'timeout '; then
    echo "PASS: 03-codex-review codex exec is timeout-wrapped"
else
    echo "FAIL: 03-codex-review codex exec is missing a timeout wrapper"; FAIL=1
fi
if grep -A4 'codex exec' skills/n1-pr/steps/03-codex-review.md | grep -q '</dev/null'; then
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
if grep -qF 'n1_record_decision codex-review false' "$P3" && grep -qF '"outcome=skipped"' "$P3"; then
    echo "PASS: 03-codex-review records skipped codex-review decisions"
else
    echo "FAIL: 03-codex-review does not record skipped codex-review decisions"; FAIL=1
fi

# 5. N1-70: dispatch budget/effort/prompt, outcome telemetry, and codex+post in one bash fence
for pat in 'N1_CROSS_HOST_REVIEW_TIMEOUT:-900' 'codex exec -c model_reasoning_effort=medium' 'do not run tests' '"outcome=$OUTCOME"'; do
    if grep -qF "$pat" "$P3"; then
        echo "PASS: 03-codex-review has '$pat'"
    else
        echo "FAIL: 03-codex-review missing '$pat'"; FAIL=1
    fi
done
CX=$(grep -n 'codex exec' "$P3" | head -1 | cut -d: -f1)
GH=$(grep -n 'gh pr comment' "$P3" | head -1 | cut -d: -f1)
if [ -n "$CX" ] && [ -n "$GH" ] && [ "$GH" -gt "$CX" ] && ! grep -q '^```' <<<"$(sed -n "${CX},${GH}p" "$P3")"; then
    echo "PASS: 03-codex-review runs codex and posts the comment in one bash block"
else
    echo "FAIL: 03-codex-review splits codex dispatch and comment posting across blocks"; FAIL=1
fi

exit $FAIL

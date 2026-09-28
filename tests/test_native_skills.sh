#!/usr/bin/env bash
# Native skill tests: no Superpowers dependency in manifests, skill size budgets.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0

# 1. No Superpowers in any manifest
for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json plugin.json .agents/plugins/marketplace.json; do
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

# 3. Cross-host `codex exec` dispatch must never block on inherited stdin (NP-224)
CODEX_LINE=$(grep -n 'codex exec' skills/n1-pr/steps/03-cross-host-review.md | head -1)
if echo "$CODEX_LINE" | grep -q 'timeout '; then
    echo "PASS: 03-cross-host-review codex exec is timeout-wrapped"
else
    echo "FAIL: 03-cross-host-review codex exec is missing a timeout wrapper"; FAIL=1
fi
if grep -A4 'codex exec' skills/n1-pr/steps/03-cross-host-review.md | grep -q '</dev/null'; then
    echo "PASS: 03-cross-host-review codex exec redirects stdin from /dev/null"
else
    echo "FAIL: 03-cross-host-review codex exec is missing </dev/null"; FAIL=1
fi

exit $FAIL

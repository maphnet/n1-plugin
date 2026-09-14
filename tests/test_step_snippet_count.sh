#!/usr/bin/env bash
# Test: every skills/n1-start/steps/*.md file has at most 3 bash code blocks,
# unless it carries an exception annotation:
#   <!-- n1:step-snippet-exception: <reason> -->
# The test skips annotated files and prints the reason, keeping exceptions visible.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEPS_DIR="${REPO_ROOT}/skills/n1-start/steps"
MAX_SNIPPETS=3
FAIL=0
SKIP_COUNT=0
PASS_COUNT=0

for f in "${STEPS_DIR}"/*.md; do
    name="$(basename "$f")"

    if grep -qF 'n1:step-snippet-exception' "$f" 2>/dev/null; then
        reason=$(grep -m1 'n1:step-snippet-exception' "$f" \
            | sed 's/.*n1:step-snippet-exception:[[:space:]]*//' \
            | sed 's/[[:space:]]*-->.*//; s/[[:space:]]*$//')
        echo "SKIP: ${name} (${reason:-exception documented})"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    # Count lines that open a bash fenced block
    count=$(grep -c '^```bash' "$f" 2>/dev/null) || count=0

    if [ "$count" -gt "$MAX_SNIPPETS" ]; then
        echo "FAIL: ${name} has ${count} bash snippets (max ${MAX_SNIPPETS})"
        FAIL=1
    else
        echo "PASS: ${name} (${count} bash snippet(s))"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
done

echo ""
echo "Results: ${PASS_COUNT} passed, ${SKIP_COUNT} excepted, FAIL=${FAIL}"
exit "$FAIL"

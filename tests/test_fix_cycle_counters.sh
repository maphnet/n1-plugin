#!/usr/bin/env bash
# Test: qa_fix_cycle / tq_fix_cycle count real fixes only. Their increments must sit in
# fix-branch prose, not in an always-run bash fence; review_fix_cycle stays in fix.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEPS="${REPO_ROOT}/skills/n1-start/steps"
FAIL=0

check() { # <file> <counter>
    local f="${STEPS}/$1" c="$2" inside prose
    inside=$(awk '/^```/{b=!b; next} b' "$f" | grep -c "n1_increment_counter.*\"$c\"" || true)
    prose=$(awk '/^```/{b=!b; next} !b' "$f" | grep -c "n1_increment_counter.*\"$c\"" || true)
    if [ "$inside" -eq 0 ] && [ "$prose" -eq 1 ]; then echo "PASS: $1 $c"
    else echo "FAIL: $1 $c (in fence: $inside, in prose: $prose)"; FAIL=1; fi
}

check qa.md qa_fix_cycle
check review.md tq_fix_cycle
grep -q 'n1_increment_counter.*"review_fix_cycle"' "${STEPS}/fix.md" \
    && echo "PASS: fix.md review_fix_cycle" || { echo "FAIL: fix.md review_fix_cycle missing"; FAIL=1; }

exit "$FAIL"

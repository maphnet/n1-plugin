#!/usr/bin/env bash
# Test: lib/preamble.sh sources without error and sets expected variables
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

# Test 1: preamble.sh sources cleanly with CLAUDE_PLUGIN_ROOT set
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
# n1_home requires git and config; just verify the source chain works
(
    source "$REPO_ROOT/lib/preamble.sh" 2>/dev/null
    [ -n "$N1_ROOT" ] || { echo "FAIL: N1_ROOT not set"; exit 1; }
    [ "$N1_ROOT" = "$REPO_ROOT" ] || { echo "FAIL: N1_ROOT='$N1_ROOT' != '$REPO_ROOT'"; exit 1; }
    # step.sh functions should be available
    type n1_step_begin >/dev/null 2>&1 || { echo "FAIL: n1_step_begin not available"; exit 1; }
    type n1_verify_dependencies >/dev/null 2>&1 || { echo "FAIL: n1_verify_dependencies not available"; exit 1; }
    echo "PASS: preamble sources cleanly and provides expected functions"
) || FAIL=1

# Test 2: preamble.sh sets N1_ROOT via PLUGIN_ROOT fallback
unset CLAUDE_PLUGIN_ROOT
export PLUGIN_ROOT="$REPO_ROOT"
(
    source "$REPO_ROOT/lib/preamble.sh" 2>/dev/null
    [ "$N1_ROOT" = "$REPO_ROOT" ] || { echo "FAIL: PLUGIN_ROOT fallback N1_ROOT='$N1_ROOT'"; exit 1; }
    echo "PASS: PLUGIN_ROOT fallback works"
) || FAIL=1

# Test 3: no n1-start snippet still uses the old N1_ROOT resolution line
# (migration verification — the inline N1_ROOT="${CLAUDE_PLUGIN_ROOT..." pattern should be gone)
STEPS_DIR="${REPO_ROOT}/skills/n1-start/steps"
PROCS_DIR="${REPO_ROOT}/skills/n1-start/procedures"
OLD_PATTERN='N1_ROOT="${CLAUDE_PLUGIN_ROOT'
for f in "${STEPS_DIR}"/*.md "${PROCS_DIR}"/*.md "$REPO_ROOT/skills/n1-start/review-core.md"; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    if grep -qF "$OLD_PATTERN" "$f" 2>/dev/null; then
        echo "FAIL: ${name} still uses old N1_ROOT resolution pattern"
        FAIL=1
    fi
done
[ "$FAIL" = "0" ] && echo "PASS: no n1-start files use old preamble pattern"

echo ""
exit "$FAIL"

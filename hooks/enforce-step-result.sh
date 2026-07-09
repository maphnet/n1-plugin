#!/usr/bin/env bash
# Stop hook: corrective nudge when a step-mode session ends without emitting a
# step result (dogfood I16). Delegates to enforce-step-result.py; fail-open.
set -euo pipefail

# Fast path: only n1-loop step sessions carry N1_RUN_ID.
[ -n "${N1_RUN_ID:-}" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"

INPUT=$(cat)

N1_HOME=$(n1_home)
[ -n "$N1_HOME" ] && [ -d "$N1_HOME/memory" ] || exit 0

# Find a WORKING interpreter — `command -v python3` can resolve to a broken
# pyenv-win shim that exists on PATH but silently eats piped stdin.
PY=""
for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && \
        [ "$(printf x | "$cand" -c "import sys; print(sys.stdin.read())" 2>/dev/null)" = "x" ]; then
        PY="$cand"
        break
    fi
done
[ -n "$PY" ] || exit 0

printf '%s' "$INPUT" | "$PY" "${SCRIPT_DIR}/enforce-step-result.py" "$N1_HOME/memory" || exit 0

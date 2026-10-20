#!/usr/bin/env bash
# PreToolUse hook: N1 agent policy (persona tool restriction, config model override, queue merge deny).
# Delegates to enforce-agent-policy.py; fail-open unless the script denies (exit 2).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"

INPUT=$(cat)

# Fast path: persona payloads always go to Python. The merge deny (Case 3) applies only to
# headless queue children, so forward every payload there unfiltered (SEC-4: a substring glob
# is evaded by quote-split obfuscation; Python strips quotes first). Everything else exits here.
case "$INPUT" in
    *'"n1:'*) : ;;
    *)
        if [ -z "${N1_QUEUE_RUN_ID:-}" ] || [ "${N1_HEADLESS:-}" != "1" ]; then
            exit 0
        fi
        ;;
esac

CONFIG_FILE=$(n1_config_file)
PLUGIN_ROOT_DIR=$(n1_plugin_root)

# Find a WORKING interpreter — `command -v python3` can resolve to a broken
# pyenv-win shim that exists on PATH but fails to run.
PY=""
for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && [ "$(printf x | "$cand" -c "import sys; print(sys.stdin.read())" 2>/dev/null)" = "x" ]; then
        PY="$cand"
        break
    fi
done
if [ -z "$PY" ]; then
    # Warn once per session instead of silently skipping enforcement.
    SESSION_ID=$(printf '%s' "$INPUT" | n1_hook_field session_id)
    N1_ROOT_DIR=$(n1_home 2>/dev/null || true)
    MARKER="${N1_ROOT_DIR:-/tmp}/.enforce-warned-${SESSION_ID:-nosession}"
    if [ ! -f "$MARKER" ]; then
        mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
        : > "$MARKER" 2>/dev/null || true
        printf '{"systemMessage":"N1: agent model enforcement skipped (no Python interpreter)"}\n'
    fi
    exit 0
fi

set +e
printf '%s' "$INPUT" | "$PY" "${SCRIPT_DIR}/enforce-agent-policy.py" "${CONFIG_FILE:-}" "$PLUGIN_ROOT_DIR"
RC=$?
set -e
[ "$RC" -eq 2 ] && exit 2
exit 0

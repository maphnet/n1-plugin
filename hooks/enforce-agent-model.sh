#!/usr/bin/env bash
# PreToolUse hook (Task): deterministic config-model enforcement for n1 agent spawns.
# Delegates to enforce-agent-model.py; fail-open on any missing dependency.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"

INPUT=$(cat)

# Fast path: only n1 agent spawns are of interest (field name varies by version).
case "$INPUT" in
    *'"subagent_type"'*'n1:'* | *'"subagent_name"'*'n1:'*) : ;;
    *) exit 0 ;;
esac

CONFIG_FILE=$(n1_config_file)
[ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ] || exit 0

# Find a WORKING interpreter — `command -v python3` can resolve to a broken
# pyenv-win shim that exists on PATH but fails to run.
PY=""
for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 &&             [ "$(printf x | "$cand" -c "import sys; print(sys.stdin.read())" 2>/dev/null)" = "x" ]; then
        PY="$cand"
        break
    fi
done
[ -n "$PY" ] || exit 0

printf '%s' "$INPUT" | "$PY" "${SCRIPT_DIR}/enforce-agent-model.py" "$CONFIG_FILE" || exit 0

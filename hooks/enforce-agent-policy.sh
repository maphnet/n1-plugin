#!/usr/bin/env bash
# PreToolUse hook: N1 agent policy (persona tool restriction, config model override, queue merge gate) on both hosts.
# Delegates to enforce-agent-policy.py; fail-open unless the script denies (exit 2).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"

INPUT=$(cat)

# Fast path: persona payloads always go to Python; merge/push-shaped commands only inside
# queue children (Case 3, NP-212). Broad globs on purpose: Python does the exact token parse.
# The gh branch matches "erge" (not "merge") — case matters in a bash `case` glob, and
# GitHub's enablePullRequestAutoMerge mutation has a capital M.
# SEC-4: this glob is a raw substring match and can itself be evaded by quote-split
# obfuscation (`g''h pr m''erge 12`), which contains neither "gh" nor "git" as a substring.
# Queue children are the security-relevant path, so skip the cheap filter there entirely and
# always forward to Python; non-queue sessions keep the cheap filter unchanged.
case "$INPUT" in
    *'"n1:'* | *'"n1-'*) : ;;
    *)
        if [ -z "${N1_QUEUE_RUN_ID:-}" ]; then
            case "$INPUT" in
                *gh*erge* | *git*push* | *git*merge*) : ;;
                *) exit 0 ;;
            esac
        fi
        ;;
esac

CONFIG_FILE=$(n1_config_file)
PLUGIN_ROOT_DIR=$(n1_plugin_root)
HOST=$(n1_host)

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
printf '%s' "$INPUT" | "$PY" "${SCRIPT_DIR}/enforce-agent-policy.py" "${CONFIG_FILE:-}" "$PLUGIN_ROOT_DIR" "$HOST"
RC=$?
set -e
[ "$RC" -eq 2 ] && exit 2
exit 0

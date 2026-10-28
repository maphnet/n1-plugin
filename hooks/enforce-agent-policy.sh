#!/usr/bin/env bash
# PreToolUse hook: N1 agent policy (persona tool restriction, config model override, merge deny, pipe-mask deny).
# Delegates to enforce-agent-policy.py; fail-open unless the script denies (exit 2) or an n1:code-reviewer /
# n1:security-reviewer Write cannot be evaluated (no Python, script error, malformed payload): that Write is denied (N1-174).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"

INPUT=$(cat)

# Fast path: persona payloads and every Bash call go to Python (merge deny, Case 3; pipe-masked
# test status deny, Case 4, N1-159, applies even when merges are authorized). Key on the tool
# name, never the command text (SEC-4: a substring glob on the command is evaded by quote-split
# obfuscation).
QUEUE_CHILD=""
[ -n "${N1_QUEUE_RUN_ID:-}" ] && [ "${N1_HEADLESS:-}" = "1" ] && QUEUE_CHILD=1
case "$INPUT" in
    *'"n1:'*) : ;;
    *'"Bash"'*) : ;;
    *) exit 0 ;;
esac

# N1-174: deny a reviewer Write the policy script could not evaluate. Raw-text match, no JSON parse:
# Claude Code serializes agent_type and tool_name, the reviewer controls only tool_input string values,
# and a JSON string value cannot hold an unescaped quote, so the reviewer can neither forge nor hide
# these keys. Both keys are required: a spawn payload carries tool_input.agent_type with a spawn tool_name.
REVIEWER_KEY_RE='"agent_type"[[:space:]]*:[[:space:]]*"n1:(code|security)-reviewer"'
WRITE_KEY_RE='"tool_name"[[:space:]]*:[[:space:]]*"Write"'
deny_unevaluated_reviewer_write() {
    if [[ $INPUT =~ $REVIEWER_KEY_RE ]] && [[ $INPUT =~ $WRITE_KEY_RE ]]; then
        echo "N1: reviewer Write denied -- the agent policy hook could not evaluate it (no Python interpreter or hook error)" >&2
        exit 2
    fi
}

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
    # Fail closed for queue-child Bash (CR-11) and for a reviewer Write in any session (N1-174);
    # everything else fails open with the warning below (N1-146).
    case "$INPUT" in
        *'"Bash"'*) if [ -n "$QUEUE_CHILD" ] && [ "$(n1_merge_authorized)" != true ]; then
            echo "N1: Bash denied in queue run ${N1_QUEUE_RUN_ID} -- no Python interpreter for the merge-deny check" >&2
            exit 2
        fi ;;
    esac
    deny_unevaluated_reviewer_write  # before the marker: the deny does not consume the warn-once
    # Warn once per session instead of silently skipping enforcement.
    SESSION_ID=$(printf '%s' "$INPUT" | n1_hook_field session_id)
    N1_ROOT_DIR=$(n1_home 2>/dev/null || true)
    MARKER="${N1_ROOT_DIR:-/tmp}/.enforce-warned-${SESSION_ID:-nosession}"
    if [ ! -f "$MARKER" ]; then
        mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
        : > "$MARKER" 2>/dev/null || true
        printf '{"systemMessage":"N1: agent policy (model enforcement, merge deny and pipe-mask check) skipped -- no Python interpreter"}\n'
    fi
    exit 0
fi

set +e
printf '%s' "$INPUT" | "$PY" "${SCRIPT_DIR}/enforce-agent-policy.py" "${CONFIG_FILE:-}" "$PLUGIN_ROOT_DIR"
RC=$?
set -e
# 0 allow, 2 deny; any other code (3 unparseable payload, 1 crash, 126/127/137 exec failure or kill)
# means the script could not evaluate the call.
case "$RC" in
    0) exit 0 ;;
    2) exit 2 ;;
esac
deny_unevaluated_reviewer_write
exit 0

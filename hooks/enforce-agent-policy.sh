#!/usr/bin/env bash
# PreToolUse hook: N1 agent policy (persona tool restriction, config model override, merge deny, pipe-mask deny).
# Delegates to enforce-agent-policy.py and fails open, except where the call cannot be evaluated (no Python,
# script crash, malformed payload, or a shell error before Python runs): an n1:code-reviewer /
# n1:security-reviewer Write (N1-174) and a queue-child Bash (CR-11, N1-195) are then denied (exit 2).
# The EXIT trap below decides from env + raw stdin only. A hook timeout or SIGKILL still fails open
# (residual risk, references/architecture.md).
set -euo pipefail
trap '' PIPE  # a closed stderr must not turn the deny into SIGPIPE (SEC-1)

INPUT=""
INPUT_READ=0
QUEUE_CHILD=""
[ -n "${N1_QUEUE_RUN_ID:-}" ] && [ "${N1_HEADLESS:-}" = "1" ] && QUEUE_CHILD=1

# N1-174: deny a reviewer Write the policy script could not evaluate. Raw-text match, no JSON parse:
# Claude Code serializes agent_type and tool_name, the reviewer controls only tool_input string values,
# and a JSON string value cannot hold an unescaped quote, so the reviewer can neither forge nor hide
# these keys. Both keys are required: a spawn payload carries tool_input.agent_type with a spawn tool_name.
REVIEWER_KEY_RE='"agent_type"[[:space:]]*:[[:space:]]*"n1:(code|security)-reviewer"'
WRITE_KEY_RE='"tool_name"[[:space:]]*:[[:space:]]*"Write"'
# fail_closed_check [--allow-authorized]: exit 2 for a call that must not pass unevaluated, else return.
# A queue child whose stdin was never read is denied for any tool (the tool is unknown). --allow-authorized
# (only after config.sh loaded: no Python) keeps Bash for a merge-authorized queue child (CR-2); the trap
# and the Python-crash path never pass it (config.sh may be what failed; a crash must not drop the pipe-mask deny).
# Deny writes end in || true so a dead stderr can never replace exit 2 (SEC-1).
fail_closed_check() {
    if [[ $INPUT =~ $REVIEWER_KEY_RE ]] && [[ $INPUT =~ $WRITE_KEY_RE ]]; then
        echo "N1: reviewer Write denied -- the agent policy hook could not evaluate it (no Python interpreter or hook error)" >&2 || true
        exit 2
    fi
    [ -n "$QUEUE_CHILD" ] || return 0
    if [ "$INPUT_READ" = 1 ]; then
        case "$INPUT" in *'"Bash"'*) ;; *) return 0 ;; esac
    fi
    if [ "${1:-}" = --allow-authorized ] && declare -F n1_merge_authorized >/dev/null && [ "$(n1_merge_authorized)" = true ]; then
        return 0
    fi
    echo "N1: call denied in queue run ${N1_QUEUE_RUN_ID} -- the agent policy hook could not evaluate it (no Python interpreter or hook error)" >&2 || true
    exit 2
}
# N1-195: any exit other than the deliberate 0/2 (a set -e failure, unreadable stdin) is re-checked;
# otherwise the original code is kept, so ordinary calls still see a non-blocking error.
trap '_rc=$?; set +e; if [ "$_rc" -ne 0 ] && [ "$_rc" -ne 2 ]; then fail_closed_check; fi; exit "$_rc"' EXIT

INPUT=$(cat)
INPUT_READ=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"

# Fast path: persona payloads and every Bash call go to Python (merge deny, Case 3; pipe-masked
# test status deny, Case 4, N1-159, applies even when merges are authorized). Key on the tool
# name, never the command text (SEC-4: a substring glob on the command is evaded by quote-split
# obfuscation).
case "$INPUT" in
    *'"n1:'*) : ;;
    *'"Bash"'*) : ;;
    *) exit 0 ;;
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
    # Fail closed for queue-child Bash (CR-11; merge-authorized child exempt, CR-2) and for a reviewer
    # Write in any session (N1-174); everything else fails open with the warning below (N1-146).
    fail_closed_check --allow-authorized  # before the marker: the deny does not consume the warn-once
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
# means the script could not evaluate the call: deny a reviewer Write and queue-child Bash (N1-195).
case "$RC" in
    0) exit 0 ;;
    2) exit 2 ;;
esac
fail_closed_check
exit 0

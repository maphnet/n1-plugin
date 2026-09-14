#!/usr/bin/env bash
# N1 context-persistence helpers
#
# n1_write_context
#   Writes TIER, TYPE, DESC_QUALITY, LITE_MODE, and SIMPLE_PATH to
#   $N1_HOME/memory/$ID/ticket-context.sh so downstream bash
#   snippets can source it instead of re-deriving from frontmatter.
#   Requires: N1_HOME, ID, TIER, TYPE, DESC_QUALITY, LITE_MODE, SIMPLE_PATH set in env.
#
# n1_read_context
#   Sources $N1_HOME/memory/$ID/ticket-context.sh if present.
#   After this call, TIER, TYPE, DESC_QUALITY, LITE_MODE, and SIMPLE_PATH are set in env.
#   No-op (silent) if the file does not exist.

_N1_CONTEXT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

type n1_read_frontmatter >/dev/null 2>&1 || source "${_N1_CONTEXT_LIB_DIR}/frontmatter.sh"
type n1_read_signal      >/dev/null 2>&1 || source "${_N1_CONTEXT_LIB_DIR}/signals.sh"

n1_write_context() {
    local ctx_file="${N1_HOME}/memory/${ID}/ticket-context.sh"
    mkdir -p "$(dirname "$ctx_file")"
    cat > "$ctx_file" <<EOF
TIER="${TIER:-}"
TYPE="${TYPE:-}"
DESC_QUALITY="${DESC_QUALITY:-}"
LITE_MODE="${LITE_MODE:-false}"
SIMPLE_PATH="${SIMPLE_PATH:-false}"
EOF
}

n1_read_context() {
    local ctx_file="${N1_HOME}/memory/${ID}/ticket-context.sh"
    if [ -f "$ctx_file" ]; then
        # shellcheck source=/dev/null
        source "$ctx_file"
    fi
}

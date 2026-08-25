#!/usr/bin/env bash
# Standalone Codex preflight check.
# Outputs JSON: {"available":true,"model":"..."} or
#               {"available":false,"reason":"..."}
# Usage: bash "$CLAUDE_PLUGIN_ROOT/lib/codex-preflight.sh" <base_branch>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

BASE_BRANCH="${1:-}"

# Step 1: Check enabled
enabled=$(n1_codex_val 'enabled')
if [ "$enabled" != "true" ]; then
    printf '{"available":false,"reason":"codex.enabled is not true (got: %s)"}\n' "${enabled:-null}"
    exit 0
fi

# Step 2: Check codex CLI on PATH
if ! codex --version >/dev/null 2>&1; then
    printf '{"available":false,"reason":"codex CLI not available (codex --version failed)"}\n'
    exit 0
fi

# Step 3: Verify base branch (if provided)
if [ -n "$BASE_BRANCH" ]; then
    if ! git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
        printf '{"available":false,"reason":"base branch %s not resolvable"}\n' "$BASE_BRANCH"
        exit 0
    fi
fi

# Step 4: Read model config
CODEX_MODEL=$(n1_codex_val 'model')

# Success — output structured result
printf '{"available":true,"model":"%s"}\n' "${CODEX_MODEL:-}"

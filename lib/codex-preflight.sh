#!/usr/bin/env bash
# Standalone Codex preflight check.
# Outputs JSON: {"available":true,"codex_path":"...","model":"...","effort":"..."} or
#               {"available":false,"reason":"..."}
# Usage: bash "$CLAUDE_PLUGIN_ROOT/lib/codex-preflight.sh" <base_branch>
#
# Designed to be called as a single Bash command by the orchestrator model,
# eliminating the need to source config.sh and call functions.

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

# Step 2: Resolve companion path
CODEX=$(n1_codex_companion)
if [ -z "$CODEX" ]; then
    printf '{"available":false,"reason":"codex-companion.mjs not found in plugin cache"}\n'
    exit 0
fi

# Step 3: Check codex CLI
if ! codex --version >/dev/null 2>&1; then
    printf '{"available":false,"reason":"codex CLI not available (codex --version failed)"}\n'
    exit 0
fi

# Step 4: Verify base branch (if provided)
if [ -n "$BASE_BRANCH" ]; then
    if ! git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
        printf '{"available":false,"reason":"base branch %s not resolvable"}\n' "$BASE_BRANCH"
        exit 0
    fi
fi

# Step 5: Read model/effort config
CODEX_MODEL=$(n1_codex_val 'model')
CODEX_EFFORT=$(n1_codex_val 'effort')
: "${CODEX_EFFORT:=medium}"

# Success — output structured result
printf '{"available":true,"codex_path":"%s","model":"%s","effort":"%s"}\n' \
    "$CODEX" "${CODEX_MODEL:-}" "$CODEX_EFFORT"

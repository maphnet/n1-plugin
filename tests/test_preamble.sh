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

# Test 4: empty N1_ROOT triggers python3 host.json fallback (NP-180)
unset CLAUDE_PLUGIN_ROOT
unset PLUGIN_ROOT
HOST_JSON="$HOME/.n1/host.json"
if [ -f "$HOST_JSON" ]; then
    EXPECTED=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
    (
        source "$REPO_ROOT/lib/preamble.sh" 2>/dev/null
        [ -n "$N1_ROOT" ] || { echo "FAIL: empty-env N1_ROOT is empty"; exit 1; }
        [ "$N1_ROOT" = "$EXPECTED" ] || { echo "FAIL: empty-env N1_ROOT='$N1_ROOT' != '$EXPECTED'"; exit 1; }
        echo "PASS: empty-env fallback resolves via host.json"
    ) || FAIL=1
else
    echo "SKIP: empty-env fallback (no ~/.n1/host.json)"
fi

# Test 5 (NP-192 AC): a skill snippet run verbatim in a clean shell, with no python3
# available, sources the libs through the hook-generated ~/.n1/preamble.sh shim
# (temp HOME, never touches the real ~/.n1).
PROBE_HOME=$(mktemp -d)
NOPY_BIN="$PROBE_HOME/bin"; mkdir -p "$NOPY_BIN"
for c in bash cat mkdir mv rm printf dirname basename grep sed git jq head tr awk date; do
    p=$(command -v "$c") && ln -sf "$p" "$NOPY_BIN/$c"
done
echo '{"session_id":"s-probe","source":"startup"}' | env -i HOME="$PROBE_HOME" PATH="$NOPY_BIN" \
    N1_STATE_DIR="$PROBE_HOME/.n1" N1_HOME="$PROBE_HOME/proj" N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$REPO_ROOT/hooks/session-start.sh" >/dev/null 2>&1 || true
PROBE_OUT=$(cd "$PROBE_HOME" && env -i HOME="$PROBE_HOME" PATH="$NOPY_BIN" N1_HOME="$PROBE_HOME/proj" \
    bash -c 'source ~/.n1/preamble.sh && type n1_step_begin >/dev/null && echo "$N1_ROOT|$N1_HOME"' 2>&1) || true
if [ "$PROBE_OUT" = "$REPO_ROOT|$PROBE_HOME/proj" ]; then
    echo "PASS: clean-shell snippet resolves N1_ROOT and N1_HOME via ~/.n1/preamble.sh without python3"
else
    echo "FAIL: clean-shell probe got '$PROBE_OUT'"; FAIL=1
fi
rm -rf "$PROBE_HOME"

# Test 6 (NP-192): a preset valid N1_ROOT (as the shim sets it) wins over CLAUDE_PLUGIN_ROOT
OTHER_ROOT=$(mktemp -d); mkdir -p "$OTHER_ROOT/lib"; cp "$REPO_ROOT/lib"/*.sh "$OTHER_ROOT/lib/"
(
    export N1_ROOT="$OTHER_ROOT" CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    source "$REPO_ROOT/lib/preamble.sh" 2>/dev/null
    [ "$N1_ROOT" = "$OTHER_ROOT" ] || { echo "FAIL: preset N1_ROOT='$N1_ROOT' != '$OTHER_ROOT'"; exit 1; }
    echo "PASS: preset valid N1_ROOT wins over CLAUDE_PLUGIN_ROOT"
) || FAIL=1
rm -rf "$OTHER_ROOT"

# Test 7 (NP-192): a preset invalid N1_ROOT (no lib/) falls through to the chain
(
    export N1_ROOT="/nonexistent/path" CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    source "$REPO_ROOT/lib/preamble.sh" 2>/dev/null
    [ "$N1_ROOT" = "$REPO_ROOT" ] || { echo "FAIL: invalid preset N1_ROOT did not fall through, got '$N1_ROOT'"; exit 1; }
    echo "PASS: preset invalid N1_ROOT falls through to CLAUDE_PLUGIN_ROOT"
) || FAIL=1

echo ""
exit "$FAIL"

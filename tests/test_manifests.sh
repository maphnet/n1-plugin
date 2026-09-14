#!/usr/bin/env bash
# The four plugin manifests must be valid JSON and carry one identical version.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json plugin.json .agents/plugins/marketplace.json; do
    [ -f "$f" ] || { echo "FAIL: missing $f"; FAIL=1; continue; }
    jq -e . "$f" >/dev/null 2>&1 || { echo "FAIL: invalid JSON $f"; FAIL=1; }
done
V1=$(jq -r .version .claude-plugin/plugin.json)
V2=$(jq -r '.plugins[0].version' .claude-plugin/marketplace.json)
V3=$(jq -r .version plugin.json 2>/dev/null)
V4=$(jq -r '.plugins[0].version' .agents/plugins/marketplace.json 2>/dev/null)
if [ "$V1" = "$V2" ] && [ "$V1" = "$V3" ] && [ "$V1" = "$V4" ] && [ -n "$V1" ]; then
    echo "PASS: all manifests at $V1"
else
    echo "FAIL: versions differ: claude=$V1 claude-mkt=$V2 codex=$V3 codex-mkt=$V4"; FAIL=1
fi
[ "$(jq -r '.extensions["com.openai.hooks"]' plugin.json 2>/dev/null)" = "./hooks/codex-hooks.json" ] \
    && echo "PASS: codex manifest references codex-hooks.json" || { echo "FAIL: codex hooks reference"; FAIL=1; }
exit $FAIL

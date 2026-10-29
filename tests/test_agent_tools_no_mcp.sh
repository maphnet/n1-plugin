#!/usr/bin/env bash
# tests/test_agent_tools_no_mcp.sh -- N1-43: an explicit `tools:` allowlist in agents/*.md must never
# name an mcp__ tool (it would re-inject MCP tool definitions into that agent's prompt).
# Only the frontmatter `tools:` line is read; body text may mention mcp__.
# Run: bash tests/test_agent_tools_no_mcp.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

WITH_TOOLS=0
for f in agents/*.md; do
    # frontmatter only: lines between the first two '---'
    line=$(awk '/^---$/{n++; next} n==1 && /^tools:/{print; exit} n>=2{exit}' "$f")
    [ -z "$line" ] && continue
    WITH_TOOLS=$((WITH_TOOLS + 1))
    if [[ "$line" == *mcp__* ]]; then no "$f tools: list contains mcp__"; else ok "$f tools: list has no mcp__"; fi
done
if [ "$WITH_TOOLS" -gt 0 ]; then ok "at least one agent has a tools: line ($WITH_TOOLS)"; else no "no agent has a tools: line (guard would be vacuous)"; fi

echo "Passed: $PASS Failed: $FAIL"
[ "$FAIL" -eq 0 ]

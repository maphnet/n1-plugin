#!/usr/bin/env bash
# tests/test_agent_tools_no_mcp.sh -- N1-43: an explicit `tools:` allowlist in agents/*.md must never
# name an mcp__ tool (it would re-inject MCP tool definitions into that agent's prompt).
# Only the frontmatter `tools:` value (line + block-list continuation) is read; body text may mention mcp__.
# Run: bash tests/test_agent_tools_no_mcp.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Prints the frontmatter `tools:` line plus indented / "- " continuation lines (block lists); CRLF-tolerant.
tools_value() {
    awk '{sub(/\r$/, "")} /^---$/{n++; next} n>=2{exit}
        n==1 && /^tools:/{cap=1; print; next}
        n==1 && cap && /^([ \t]|-)/{print; next}
        n==1{cap=0}' "$1"
}

# self-check: block-list and CRLF files are caught
SELF=$(mktemp); trap 'rm -f "$SELF"' EXIT
printf -- '---\r\nname: x\r\ntools:\r\n  - Read\r\n  - mcp__a__b\r\nmodel: y\r\n---\r\n' > "$SELF"
if [[ "$(tools_value "$SELF")" == *mcp__* ]]; then ok "self-check: CRLF block list mcp__ caught"; else no "self-check: CRLF block list mcp__ missed"; fi
printf -- '---\nname: x\ntools: Read\ndescription: mcp__ok\n---\n' > "$SELF"
if [[ "$(tools_value "$SELF")" == *mcp__* ]]; then no "self-check: later key wrongly scanned"; else ok "self-check: later key not scanned"; fi

WITH_TOOLS=0
for f in agents/*.md; do
    line=$(tools_value "$f")
    [ -z "$line" ] && continue
    WITH_TOOLS=$((WITH_TOOLS + 1))
    if [[ "$line" == *mcp__* ]]; then no "$f tools: list contains mcp__"; else ok "$f tools: list has no mcp__"; fi
done
if [ "$WITH_TOOLS" -gt 0 ]; then ok "at least one agent has a tools: line ($WITH_TOOLS)"; else no "no agent has a tools: line (guard would be vacuous)"; fi

echo "Passed: $PASS Failed: $FAIL"
[ "$FAIL" -eq 0 ]

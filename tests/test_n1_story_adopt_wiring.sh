#!/usr/bin/env bash
# N1-107: n1-story adopts existing tickets as sub-tasks with one jcm_convertIssueType call.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
K=skills/n1-story/steps/01-collect.md
C=skills/n1-story/steps/02-compose.md

check() { # <label> <extended-regex> <file>
    if grep -qE "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

check "collect stores adopt keys as ADOPT_KEYS" 'ADOPT_KEYS' "$K"
check "collect drops cross-project keys" 'bulk move needs the same project' "$K"
check "collect warns adoption needs jc-mcp when VERSION_MCP is empty" 'Adopting existing tickets requires jc-mcp' "$K"
check "collect never turns an adopt key into a new ticket" 'never create new tickets for them' "$K"
check "dup-check hit on an adopt key is not a duplicate" 'drop it from `DUP_LINKS`' "$K"

exit $FAIL

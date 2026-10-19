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

# Step 9b section only: from its heading to Step 10.
S9B=$(awk '/^## Step 9b:/{f=1} /^## Step 10:/{f=0} f' "$C")
check9b() { # <label> <extended-regex>
    if grep -qE "$2" <<<"$S9B"; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

n9=$(grep -n '^## Step 9:' "$C" | cut -d: -f1)
n9b=$(grep -n '^## Step 9b:' "$C" | cut -d: -f1)
n10=$(grep -n '^## Step 10:' "$C" | cut -d: -f1)
if [ -n "$n9" ] && [ -n "$n9b" ] && [ -n "$n10" ] && [ "$n9" -lt "$n9b" ] && [ "$n9b" -lt "$n10" ]; then
    echo "PASS: Step 9b sits between Step 9 and Step 10"
else
    echo "FAIL: Step 9b sits between Step 9 and Step 10"; FAIL=1
fi

if [ "$(grep -cF 'mcp__<VERSION_MCP>__jcm_convertIssueType' "$C")" -eq 1 ]; then
    echo "PASS: exactly one jcm_convertIssueType call site"
else
    echo "FAIL: exactly one jcm_convertIssueType call site"; FAIL=1
fi

check9b "convert call routes through VERSION_MCP" 'mcp__<VERSION_MCP>__jcm_convertIssueType'
check9b "all adopt keys go in one issueKeys list" 'issueKeys: <ADOPT_KEYS>'
check9b "type name is a variable" 'issueTypeName: <SUBTASK_TYPE>'
check9b "parent is the new story" 'parentKey: <STORY_ID>'
check9b "unknown type retries with a name the error lists" 'names the error lists'
check9b "partial failures warned per key" '`failed`'
check9b "still-running move points to jcm_getIssue" 'RUNNING.*jcm_getIssue'
check9b "declined confirmation handled" 'declined'
check9b "thrown error names the jc-mcp minimum" '0\.9\.0'
check9b "adoption failure never creates a ticket" 'Never create a ticket for a key'
if grep -qE 'issueTypeName: "' <<<"$S9B"; then
    echo "FAIL: no hard-coded type literal in the convert call"; FAIL=1
else
    echo "PASS: no hard-coded type literal in the convert call"
fi

check "preview lists adopted tickets" '^### Adopt existing tickets' "$C"
check "scope guard counts adopted keys" 'Adopted keys \(`ADOPT_KEYS`\) count as children' "$C"
check "Step 10 reports adopted keys" '^\*\*Adopted:\*\*' "$C"
check "Step 10 reports not-adopted keys" '^\*\*Not adopted:\*\*' "$C"
check "n1-init states the jc-mcp minimum version" 'jc-mcp 0\.9\.0 or newer' skills/n1-init/steps/03-tracker.md

exit $FAIL

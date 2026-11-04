#!/usr/bin/env bash
# N1-18: n1-init prefers jc-mcp for Jira and still documents the Atlassian MCP path;
# README and architecture list jc-mcp as the default Jira MCP.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
check() { # <label> <extended-regex> <file>
    if grep -qE "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
refute() { # <label> <extended-regex> <file>
    if grep -qE "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}
before() { # <label> <first-ERE> <second-ERE> <file>: first match of $2 is on an earlier line than first match of $3
    local a b
    a=$(grep -nE "$2" "$4" 2>/dev/null | head -1 | cut -d: -f1)
    b=$(grep -nE "$3" "$4" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
D=skills/n1-init/steps/02-analyze-repo.md
T=skills/n1-init/steps/03-tracker.md

# Step 02: detection
check "02 detects jc-mcp by tool suffix" '__jcm_getIssue.*__jcm_createVersion' "$D"
check "02 still detects the Atlassian MCP" 'mcp__plugin_atlassian_atlassian__\*' "$D"
check "02 records the Jira flavor" 'Jira flavor \(jc-mcp / atlassian / both\)' "$D"
check "02 skips the project-list probe for jc-mcp" 'jc-mcp has no project-list operation' "$D"

# Step 03: jc-mcp is the default
check "03 both-present list recommends jc-mcp" '^  1 -- jc-mcp .*\(Recommended' "$T"
before "03 full menu lists jc-mcp before Atlassian" '^1 — Jira via jc-mcp \(Recommended' '^2 — Jira via Atlassian MCP' "$T"
refute "03 never recommends the Atlassian MCP" 'Atlassian MCP.*\(Recommended' "$T"
before "03 jc-mcp block precedes the Atlassian block" '^### If Jira via jc-mcp:$' '^### If Jira via Atlassian MCP:$' "$T"

# Step 03: jc-mcp flow and config
check "03 validates the key with jcm_listVersions" '__jcm_listVersions' "$T"
check "03 detects statuses via jcm_searchIssues" '__jcm_searchIssues' "$T"
check "03 detects transitions via jcm_getTransitions" '__jcm_getTransitions' "$T"
check "03 jc-mcp config sets mcp from the detected server" '"mcp": "<JCM_SERVER>"' "$T"
check "03 jc-mcp config sets versionMcp from the detected server" '"versionMcp": "<JCM_SERVER>"' "$T"
check "03 jc-mcp config reads comments via jcm_getIssue" '"getComments": "jcm_getIssue"' "$T"
GUARDS=$(grep -c 'Atlassian MCP only; skip when `JIRA_FLAVOR=jc-mcp`' "$T" 2>/dev/null)
if [ "${GUARDS:-0}" -ge 4 ]; then
    echo "PASS: 03 guards the Atlassian-only subsections"
else
    echo "FAIL: 03 guards the Atlassian-only subsections (found ${GUARDS:-0}, need 4)"; FAIL=1
fi

# Step 03: Atlassian path kept
check "03 jc-mcp block can fall back to Atlassian with the flavor reset" 'JIRA_FLAVOR=atlassian' "$T"
check "03 keeps the Atlassian project list" 'getVisibleJiraProjects' "$T"
check "03 keeps the Atlassian cloudId lookup" 'getAccessibleAtlassianResources' "$T"
check "03 keeps the Atlassian config" '"mcp": "plugin_atlassian_atlassian"' "$T"

# Docs: jc-mcp default, Atlassian alternative
R=README.md
A=references/architecture.md
check "README requirements name jc-mcp as the default" 'Jira \(jc-mcp, default, or the Atlassian MCP\)' "$R"
before "README tracker table lists jc-mcp first" '^\| Jira \| jc-mcp .*\| Supported \(default\) \|$' '^\| Jira \| `plugin_atlassian_atlassian` \| Supported \(alternative\) \|$' "$R"
check "README says existing Atlassian configs keep working" 'Existing Atlassian MCP configs keep working' "$R"
before "architecture presets list jc-mcp first" '^\| Jira \(jc-mcp, default\) \|' '^\| Jira \(Atlassian MCP, alternative\) \|' "$A"
refute "architecture drops the stale jira-velosity example" 'jira-velosity' "$A"

exit "$FAIL"

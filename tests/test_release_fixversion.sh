#!/usr/bin/env bash
# N1-316: n1-release 5b-2 sets fixVersions via the Jira `update` add op (not `fields`, which
# silently no-ops) and verifies with a chunked search read-back; the report separates
# verified / NOT verified / unchecked.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
R03=${R03:-skills/n1-release/steps/03-tracker-release.md}
R04=${R04:-skills/n1-release/steps/04-report.md}

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
lacks() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}

# Scope 03 checks to the 5b-2 section so text moved elsewhere cannot satisfy them.
S=$(mktemp); trap 'rm -f "$S"' EXIT
awk '/^## 5b-2/{f=1;next} /^## 5b-3/{f=0} f' "$R03" > "$S"

check "03 5b-2 sets fixVersions with the update add op" 'update: \{"fixVersions": \[\{"add": \{"name": VERSION_NAME\}\}\]\}' "$S"
lacks "03 5b-2 never passes fixVersions under fields" 'fields: \{"fixVersions"' "$S"
check "03 5b-2 read-back JQL" 'key in \(.*\) AND fixVersion = ' "$S"
check "03 5b-2 read-back search runs on tracker.mcp" 'mcp__<tracker\.mcp>__<operations\.search>' "$S"
lacks "03 5b-2 read-back never routes search to versionMcp" 'mcp__<(tracker\.)?versionMcp>__<operations\.search>' "$S"
check "03 5b-2 search-failure bullet puts IDs in the unchecked set" '^- .*(error|not configured).*unchecked' "$S"
check "03 5b-2 report names all three buckets" '^Report: .*verified on .*NOT verified on .*unchecked' "$S"
check "04 Fix version line has verified and NOT verified" 'Fix version: verified on .*NOT verified on' "$R04"
check "04 keeps the missing-server variant" 'Fix version: .*skipped \(tracker server <tracker\.mcp> not available\)' "$R04"

exit "$FAIL"

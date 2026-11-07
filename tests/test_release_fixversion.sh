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

check "03 sets fixVersions with the update add op" 'update: \{"fixVersions": \[\{"add": \{"name": VERSION_NAME\}\}\]\}' "$R03"
lacks "03 never passes fixVersions under fields" 'fields: \{"fixVersions"' "$R03"
check "03 read-back JQL" 'key in \(.*\) AND fixVersion = "<VERSION_NAME>"' "$R03"
check "03 read-back search runs on tracker.mcp" 'mcp__<tracker\.mcp>__<operations\.search>' "$R03"
lacks "03 read-back never routes search to versionMcp" 'mcp__<(tracker\.)?versionMcp>__<operations\.search>' "$R03"
check "03 states the 50-ID chunk cap" 'chunks of at most 50' "$R03"
check "03 warns per ticket when absent after read-back" 'absent after read-back' "$R03"
check "03 retries once for missing IDs" 'single retry' "$R03"
check "03 reports unchecked IDs when search fails" 'unchecked' "$R03"
check "04 Fix version line has verified and NOT verified" 'Fix version: verified on .*NOT verified on' "$R04"
check "04 keeps the missing-server variant" 'Fix version: .*skipped \(tracker server <tracker\.mcp> not available\)' "$R04"

exit "$FAIL"

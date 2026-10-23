#!/usr/bin/env bash
# N1-119: n1_story_convert_decision decision table. Pure function, no MCP.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_ROOT="$REPO_ROOT" N1_HOME="$T" ID=T-1
source "$REPO_ROOT/lib/preamble.sh"
source "$REPO_ROOT/lib/queue.sh"
d() { n1_story_convert_decision "$@"; }

# children=has -> keep Story regardless of tracker / convert availability
assert_eq "has + jira + jc -> story" "story" "$(d jira has jc)"
assert_eq "has + jira + no mcp -> story" "story" "$(d jira has '')"
assert_eq "has + youtrack -> story" "story" "$(d youtrack has '')"
# children=unknown (search failed or unparseable) -> never convert, keep Story
assert_eq "unknown + jira + jc -> story" "story" "$(d jira unknown jc)"
assert_eq "unknown + youtrack -> story" "story" "$(d youtrack unknown '')"
assert_eq "empty children -> story" "story" "$(d jira '' jc)"
# children=none
assert_eq "none + youtrack -> single:youtrack" "single:youtrack" "$(d youtrack none jc)"
assert_eq "none + jira + no mcp -> single:no-jc-mcp" "single:no-jc-mcp" "$(d jira none '')"
assert_eq "none + jira + jc -> convert" "convert" "$(d jira none jc)"
# tracker type is case-insensitive; unknown trackers never convert
assert_eq "none + JIRA -> convert" "convert" "$(d JIRA none jc)"
assert_eq "none + YouTrack -> single:youtrack" "single:youtrack" "$(d YouTrack none '')"
assert_eq "none + linear -> single:unsupported" "single:unsupported" "$(d linear none jc)"
assert_eq "none + empty tracker -> single:unsupported" "single:unsupported" "$(d '' none jc)"
d jira none jc >/dev/null; assert_eq "rc 0" "0" "$?"

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# N1-89: lib/ticket-watch.sh — gate, seed, comparator, delta, replan reset. jq fixtures, no MCP.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_ROOT="$REPO_ROOT" N1_HOME="$T" ID=T-1
source "$REPO_ROOT/lib/preamble.sh"
source "$REPO_ROOT/lib/ticket-watch.sh"
M="$N1_HOME/memory/$ID"; mkdir -p "$M"
cfg() { printf '%s' "$1" > "$N1_HOME/config.json"; }
CFG_ON='{"tracker":{"mcp":"jc","operations":{"getChangelog":"jcm_getIssueChangelog"},"statuses":{"done":"Done","blocked":"Blocked"}}}'
ON_JC=$(printf 'jc\tjcm_getIssueChangelog')
T0="2026-10-17T10:00:00.000+0000"; T1="2026-10-17T11:00:00.000+0000"; TC="2026-10-17T09:00:00.000+0000"

# ---- n1_watch_val / n1_tw_on ----
cfg '{}'
assert_eq "watch.enabled defaults true" "true" "$(n1_watch_val enabled)"
cfg "$CFG_ON"
assert_eq "on: unseeded -> nothing" "" "$(n1_tw_on "$ID")"
assert_eq "on: seed mode ignores missing cursor" "$ON_JC" "$(n1_tw_on "$ID" seed)"
cfg '{"tracker":{"mcp":"atl","versionMcp":"jc","operations":{"getChangelog":"jcm_getIssueChangelog"}}}'
assert_eq "on: versionMcp wins over tracker.mcp" "$ON_JC" "$(n1_tw_on "$ID" seed)"
cfg '{"tracker":{"mcp":"jc","operations":{}}}'
assert_eq "on: getChangelog unmapped -> off" "" "$(n1_tw_on "$ID" seed)"
cfg '{"watch":{"enabled":false},"tracker":{"mcp":"jc","operations":{"getChangelog":"jcm_getIssueChangelog"}}}'
assert_eq "on: watch.enabled=false -> off" "" "$(n1_tw_on "$ID" seed)"

# ---- n1_tw_seed ----
cfg "$CFG_ON"
printf '{"key":"T-1","updated":"%s","comments":[{"id":"100","authorAccountId":"me-1","author":"Me","body":"N1 enrichment","created":"%s","updated":"%s"}]}' "$T0" "$TC" "$TC" > "$T/issue0.json"
n1_tw_seed "$ID" "$T/issue0.json" me-1
assert_eq "seed: updated" "$T0" "$(jq -r .updated "$M/.ticket-watch")"
assert_eq "seed: changelog_since = updated" "$T0" "$(jq -r .changelog_since "$M/.ticket-watch")"
assert_eq "seed: me" "me-1" "$(jq -r .me "$M/.ticket-watch")"
assert_eq "seed: seen holds all comments" "[\"100@$TC\"]" "$(jq -c .seen "$M/.ticket-watch")"
assert_eq "on: seeded -> active" "$ON_JC" "$(n1_tw_on "$ID")"
cp "$M/.ticket-watch" "$T/cur0"
echo 'not json' > "$T/bad.json"
n1_tw_seed "$ID" "$T/bad.json" me-1; rc=$?
assert_eq "seed: bad input rc 1" "1" "$rc"
assert_eq "seed: bad input leaves cursor" "$(cat "$T/cur0")" "$(cat "$M/.ticket-watch")"
n1_tw_seed "$ID" "$T/issue0.json" ""
assert_eq "seed: empty me reuses cached me" "me-1" "$(jq -r .me "$M/.ticket-watch")"

# ---- n1_tw_cmp ----
printf '{"total":1,"issues":[{"key":"T-1","updated":"%s"}]}' "$T0" > "$T/p-same.json"
printf '{"total":1,"issues":[{"key":"T-1","updated":"%s"}]}' "$T1" > "$T/p-new.json"
printf '{"total":0,"issues":[]}' > "$T/p-empty.json"
assert_eq "cmp: unchanged -> silent" "" "$(n1_tw_cmp "$ID" "$T/p-same.json")"
assert_eq "cmp: changed -> CHANGED <since>" "CHANGED $T0" "$(n1_tw_cmp "$ID" "$T/p-new.json")"
assert_eq "cmp: no row -> silent" "" "$(n1_tw_cmp "$ID" "$T/p-empty.json")"
out=$(n1_tw_cmp "$ID" "$T/bad.json"); rc=$?
assert_eq "cmp: garbage rc 1" "1" "$rc"
assert_eq "cmp: garbage silent" "" "$out"

# @@DELTA@@  (Task 2 inserts delta tests here)
# @@REPLAN@@ (Task 3 inserts replan tests here)

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]

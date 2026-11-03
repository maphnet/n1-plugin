#!/usr/bin/env bash
# N1-314: hooks/ticket-watch-capture.sh saves jcm_* watch responses into the ticket-watch files; fail-open.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_SESSION_ID CLAUDE_CODE_SESSION_ID N1_RUN_ID
export N1_HOME="$T/home"
M="$N1_HOME/memory/T-1"; mkdir -p "$M"
H="$REPO_ROOT/hooks/ticket-watch-capture.sh"
GI=mcp__jc__jcm_getIssue; GL=mcp__jc__jcm_getIssueChangelog; GS=mcp__jc__jcm_searchIssues
K='{"issueKey":"T-1"}'
ISSUE='{"key":"T-1","updated":"2026-10-17T10:00:00.000+0000","comments":[]}'
PROBE='{"total":1,"issues":[{"key":"T-1","updated":"2026-10-17T10:00:00.000+0000"}]}'
BLOCKS=$(jq -nc --arg s "$ISSUE" '[{type:"text",text:$s}]')
hook() { # <tool_name> <tool_input-json> <tool_response-json>; prints "<rc>|<stdout>"
    local out rc
    out=$(jq -nc --arg t "$1" --argjson i "$2" --argjson r "$3" --arg cwd "$T" \
        '{session_id:"s1",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:$t,tool_input:$i,tool_response:$r}' | bash "$H"); rc=$?
    printf '%s|%s' "$rc" "$out"
}
norm() { jq -c . "$1" 2>/dev/null || echo "<none>"; }
has() { [ -e "$1" ] && echo yes || echo no; }
clean() { rm -f "$M"/.tw-*; }
count() { find "$N1_HOME" -name '.tw-*' | wc -l | tr -d ' '; }

# getIssue: every response shape lands in .tw-issue.json, silently, rc 0
clean; assert_eq "getIssue blocks: rc 0, no stdout" "0|" "$(hook "$GI" "$K" "$BLOCKS")"
assert_eq "getIssue content-block array: saved" "$ISSUE" "$(norm "$M/.tw-issue.json")"
clean; hook "$GI" "$K" "$(jq -nc --arg s "$ISSUE" '$s')" >/dev/null
assert_eq "getIssue plain string: saved" "$ISSUE" "$(norm "$M/.tw-issue.json")"
clean; hook "$GI" "$K" "$ISSUE" >/dev/null
assert_eq "getIssue object: saved" "$ISSUE" "$(norm "$M/.tw-issue.json")"
clean; hook "$GI" "$K" "{\"content\":$BLOCKS}" >/dev/null
assert_eq "getIssue result object with content blocks: saved" "$ISSUE" "$(norm "$M/.tw-issue.json")"
clean; hook "$GI" "$K" "$(jq -nc '[{type:"text",text:"Error: issue not found"}]')" >/dev/null
assert_eq "getIssue non-JSON text: nothing saved" "no" "$(has "$M/.tw-issue.json")"
clean; hook "$GI" "$K" 'null' >/dev/null
assert_eq "getIssue null response: nothing saved" "no" "$(has "$M/.tw-issue.json")"
assert_eq "failed captures leave no temp files" "0" "$(find "$M" -name '*.json.*' | wc -l | tr -d ' ')"

# Key validation before any path use; write only into an existing memory dir
for k in '../T-1' 't-1' 'T-1/x' 'T-' "$(printf 'T-1\n../x')"; do
    clean; hook "$GI" "$(jq -nc --arg k "$k" '{issueKey:$k}')" "$ISSUE" >/dev/null
    assert_eq "bad key [$k]: nothing saved" "0" "$(count)"
done
clean; assert_eq "no memory dir: rc 0, silent" "0|" "$(hook "$GI" '{"issueKey":"T-2"}' "$ISSUE")"
assert_eq "no memory dir: not created" "no" "$(has "$N1_HOME/memory/T-2")"

# Changelog: next free page 1..5, then no-op
clean
for n in 1 2 3; do hook "$GL" "$K" "$(jq -nc --argjson n "$n" '{entries:[],truncated:true,page:$n}')" >/dev/null; done
assert_eq "changelog: pages numbered 1..3" ".tw-log-1.json .tw-log-2.json .tw-log-3.json" "$(cd "$M" && ls -A | tr '\n' ' ' | sed 's/ $//')"
assert_eq "changelog: page 2 content" '{"entries":[],"truncated":true,"page":2}' "$(norm "$M/.tw-log-2.json")"
for n in 4 5 6; do hook "$GL" "$K" "$(jq -nc --argjson n "$n" '{entries:[],truncated:true,page:$n}')" >/dev/null; done
assert_eq "changelog: page 5 saved" '{"entries":[],"truncated":true,"page":5}' "$(norm "$M/.tw-log-5.json")"
assert_eq "changelog: no sixth page" "no" "$(has "$M/.tw-log-6.json")"

# searchIssues: only the exact single-key probe JQL
clean; hook "$GS" '{"jql":"key = T-1","maxResults":1}' "$PROBE" >/dev/null
assert_eq "search exact key jql: probe saved" "$PROBE" "$(norm "$M/.tw-probe.json")"
for q in 'key = T-1 OR key = T-2' 'project = T' 'key=T-1' 'key = T-1 ORDER BY updated' 'key = ../T-1'; do
    clean; hook "$GS" "$(jq -nc --arg q "$q" '{jql:$q}')" "$PROBE" >/dev/null
    assert_eq "search jql [$q]: nothing saved" "no" "$(has "$M/.tw-probe.json")"
done

# Other tools and garbage input: silent no-op, rc 0
clean; hook mcp__jc__jcm_getIssueLinks "$K" "$ISSUE" >/dev/null
assert_eq "other jcm tool: nothing saved" "0" "$(count)"
out=$(printf 'not json' | bash "$H"); rc=$?
assert_eq "garbage stdin: rc 0, silent" "0|" "$rc|$out"

# hooks.json registration: anchored matcher, synchronous
HJ="$REPO_ROOT/hooks/hooks.json"
MATCH=$(jq -r '[.hooks.PostToolUse[] | select(any(.hooks[]; .command | contains("ticket-watch-capture.sh")))][0].matcher // empty' "$HJ")
assert_eq "hooks.json: capture matcher" '^mcp__.+__jcm_(getIssue|getIssueChangelog|searchIssues)$' "$MATCH"
assert_eq "hooks.json: capture hook is synchronous" "false" "$(jq '[.hooks.PostToolUse[].hooks[] | select(.command | contains("ticket-watch-capture.sh")) | .async // false] | any' "$HJ")"
for t in mcp__jc__jcm_getIssue mcp__jc__jcm_getIssueChangelog mcp__plugin_x_jc__jcm_searchIssues; do
    assert_eq "matcher selects $t" "yes" "$([ -n "$MATCH" ] && [[ "$t" =~ $MATCH ]] && echo yes || echo no)"
done
for t in mcp__jc__jcm_getIssueLinks mcp__jc__jcm_addComment Bash; do
    assert_eq "matcher skips $t" "no" "$([ -n "$MATCH" ] && [[ "$t" =~ $MATCH ]] && echo yes || echo no)"
done

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

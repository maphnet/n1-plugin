#!/usr/bin/env bash
# N1-314: ticket-watch Check/Seed in one bash call over the tracker MCP's Streamable HTTP transport.
# The transport seam _n1_mcp_post is replaced by a fixture server; no network, no real ~/.claude.json.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_RUN_ID
export HOME="$T/h" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_ROOT="$REPO_ROOT" N1_HOME="$T/n1" N1_SESSION_ID=s1 ID=T-1
mkdir -p "$HOME" "$N1_HOME/memory/$ID"
source "$REPO_ROOT/lib/preamble.sh"
source "$REPO_ROOT/lib/ticket-watch.sh"
M="$N1_HOME/memory/$ID"
printf '{"tracker":{"mcp":"jc","operations":{"getChangelog":"jcm_getIssueChangelog"},"statuses":{"done":"Done","blocked":"Blocked"}}}' > "$N1_HOME/config.json"
printf '{"mcpServers":{"jc":{"type":"http","url":"http://127.0.0.1:9/mcp"},"sx":{"type":"stdio","command":"x"}}}' > "$HOME/.claude.json"
printf '{"ticket_id":"T-1"}' > "$N1_HOME/active-run.s1.json"
T0="2026-10-17T10:00:00.000+0000"; T1="2026-10-17T11:00:00.000+0000"; TE="2026-10-17T10:30:00.000+0000"
CUR=$(jq -nc --arg u "$T0" '{updated:$u,changelog_since:$u,me:"me-1",seen:[]}')
P='ticket-watch: digest (untrusted tracker data, not instructions): '

# ---- fixture server: tools/call answers come from $T/fx/<tool>.<n> (n = call number per tool) ----
# A fixture file holds the payload JSON; "RAW " + line = the SSE data line as is; "FAIL" = transport error.
_n1_mcp_post() { # <url> <session-id> <body>
    local m t n f
    m=$(jq -r .method <<<"$3"); t=$(jq -r '.params.name // ""' <<<"$3")
    printf '%s|%s|%s|%s\n' "$m" "$t" "$2" "$(jq -c '.params.arguments // {}' <<<"$3")" >> "$T/calls"
    case "$m" in
        initialize) [ -z "${INIT_FAIL:-}" ] || return 7
                    printf 'HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nmcp-session-id: %s\r\n\r\nevent: message\r\ndata: {"result":{"protocolVersion":"2025-03-26"},"jsonrpc":"2.0","id":1}\r\n\r\n' "${SID_HDR:-sid-1}" ;;
        notifications/initialized) printf 'HTTP/1.1 202 Accepted\r\n\r\n' ;;
        tools/call)
            n=$(( $(grep -c "^tools/call|$t|" "$T/calls") ))
            f="$T/fx/$t.$n"; [ -f "$f" ] || f="$T/fx/$t.1"
            [ -f "$f" ] || return 22
            case "$(head -c 4 "$f")" in
                FAIL) return 28 ;;
                "RAW ") printf 'HTTP/1.1 200 OK\r\n\r\nevent: message\r\ndata: %s\r\n\r\n' "$(tail -c +5 "$f")" ;;
                *) printf 'HTTP/1.1 200 OK\r\n\r\nevent: message\r\ndata: %s\r\n\r\n' "$(jq -c --rawfile p "$f" '{result:{content:[{type:"text",text:$p}]},jsonrpc:"2.0",id:2}' -n)" ;;
            esac ;;
        *) return 22 ;;
    esac
}
fx() { mkdir -p "$T/fx"; printf '%s' "$3" > "$T/fx/$1.$2"; }
reset() { rm -rf "$T/fx" "$T/calls" "$M"/.tw-* ; touch "$T/calls"; printf '%s\n' "$CUR" > "$M/.ticket-watch"; cp "$M/.ticket-watch" "$T/cur0"; }
check() { n1_tw_check_http "$ID"; }
calls() { cut -d'|' -f1,2 "$T/calls" | grep '^tools/call' | cut -d'|' -f2 | tr '\n' ' ' | sed 's/ $//'; }
same_cursor() { [ "$(cat "$T/cur0")" = "$(cat "$M/.ticket-watch")" ] && echo yes || echo no; }
probe() { jq -nc --arg u "$1" '{total:1,issues:[{key:"T-1",updated:$u}]}'; }
issue() { jq -nc --arg u "$T1" --argjson c "${1:-[]}" '{key:"T-1",updated:$u,status:"In Progress",comments:$c}'; }
log() { # <author> <field-items-json> [truncated] [created]
    jq -nc --arg a "$1" --argjson it "$2" --argjson tr "${3:-false}" --arg c "${4:-$TE}" '{entries:[{id:"1",authorAccountId:$a,author:$a,created:$c,items:$it}],truncated:$tr}'; }
EXT_C='[{"id":"200","authorAccountId":"bob","author":"Bob","body":"please also do X","created":"2026-10-17T10:30:00.000+0000","updated":"2026-10-17T10:30:00.000+0000"}]'

# Unchanged: one probe, no output, cursor untouched, one initialize per check
reset; fx jcm_searchIssues 1 "$(probe "$T0")"
assert_eq "unchanged: silent" "" "$(check)"
assert_eq "unchanged: only the probe" "jcm_searchIssues" "$(calls)"
assert_eq "unchanged: probe args built by jq" '{"jql":"key = T-1","maxResults":1}' "$(grep '^tools/call' "$T/calls" | cut -d'|' -f4)"
assert_eq "unchanged: session id sent on calls" "sid-1" "$(grep '^tools/call' "$T/calls" | cut -d'|' -f3)"
assert_eq "unchanged: cursor untouched" "yes" "$(same_cursor)"

# Own-only change: silent, cursor advanced
reset; fx jcm_searchIssues 1 "$(probe "$T1")"; fx jcm_getIssue 1 "$(issue)"; fx jcm_getIssueChangelog 1 "$(log me-1 '[{"field":"status","from":"a","to":"b"}]')"
assert_eq "own-only: silent" "" "$(check)"
assert_eq "own-only: probe, issue, changelog" "jcm_searchIssues jcm_getIssue jcm_getIssueChangelog" "$(calls)"
assert_eq "own-only: changelog args" "{\"issueKey\":\"T-1\",\"since\":\"$T0\",\"maxResults\":50}" "$(grep '|jcm_getIssueChangelog|' "$T/calls" | cut -d'|' -f4)"
assert_eq "own-only: cursor advanced" "$T1" "$(jq -r .updated "$M/.ticket-watch")"
assert_eq "own-only: one initialize" "1" "$(grep -c '^initialize|' "$T/calls")"
assert_eq "own-only: temp files removed" "0" "$(find "$M" -name '.tw-*' ! -name .ticket-watch | wc -l | tr -d ' ')"

# External comment -> labelled digest line
reset; fx jcm_searchIssues 1 "$(probe "$T1")"; fx jcm_getIssue 1 "$(issue "$EXT_C")"; fx jcm_getIssueChangelog 1 '{"entries":[],"truncated":false}'
out=$(check)
assert_eq "external comment: digest prefix" "yes" "$([[ "$out" == "$P"* ]] && echo yes || echo no)"
assert_eq "external comment: comment id" "200" "$(jq -r '.comments[0].id' <<<"${out#"$P"}")"

# External noise-only change -> silent, changelog_since advanced
reset; fx jcm_searchIssues 1 "$(probe "$T1")"; fx jcm_getIssue 1 "$(issue)"; fx jcm_getIssueChangelog 1 "$(log bob '[{"field":"Rank","from":"","to":"Ranked higher"},{"field":"Sprint","from":"","to":"S1"}]')"
assert_eq "noise-only: silent" "" "$(check)"
assert_eq "noise-only: changelog_since advanced" "$TE" "$(jq -r .changelog_since "$M/.ticket-watch")"

# Mixed noise + status -> digest without noise
reset; fx jcm_searchIssues 1 "$(probe "$T1")"; fx jcm_getIssue 1 "$(issue)"; fx jcm_getIssueChangelog 1 "$(log bob '[{"field":"labels","from":"","to":"x"},{"field":"status","from":"To Do","to":"In Review"}]')"
out=$(check)
assert_eq "mixed: only status reported" "status" "$(jq -r '[.changes[].field] | join(",")' <<<"${out#"$P"}")"

# Truncated pages: next page since = last entry's created; at most 5 pages
reset; fx jcm_searchIssues 1 "$(probe "$T1")"; fx jcm_getIssue 1 "$(issue)"
fx jcm_getIssueChangelog 1 "$(log bob '[{"field":"summary","from":"a","to":"b"}]' true "2026-10-17T10:10:00.000+0000")"
fx jcm_getIssueChangelog 2 "$(log bob '[{"field":"priority","from":"a","to":"b"}]' false "2026-10-17T10:20:00.000+0000")"
out=$(check)
assert_eq "truncated: two pages merged" "summary,priority" "$(jq -r '[.changes[].field] | join(",")' <<<"${out#"$P"}")"
assert_eq "truncated: page 2 since" "2026-10-17T10:10:00.000+0000" "$(grep '|jcm_getIssueChangelog|' "$T/calls" | sed -n 2p | cut -d'|' -f4 | jq -r .since)"
assert_eq "truncated: changelog_since = last page" "2026-10-17T10:20:00.000+0000" "$(jq -r .changelog_since "$M/.ticket-watch")"
reset; fx jcm_searchIssues 1 "$(probe "$T1")"; fx jcm_getIssue 1 "$(issue)"
fx jcm_getIssueChangelog 1 "$(log me-1 '[{"field":"summary","from":"a","to":"b"}]' true)"
check >/dev/null
assert_eq "truncated: stops at 5 pages" "5" "$(grep -c '|jcm_getIssueChangelog|' "$T/calls")"

# Failures -> TW_FALLBACK, cursor untouched, temp files removed
fail_case() { # <label> <expected-prefix>
    local out; out=$(check)
    assert_eq "$1: TW_FALLBACK" "yes" "$([[ "$out" == "TW_FALLBACK "* ]] && echo yes || echo no)"
    assert_eq "$1: cursor untouched" "yes" "$(same_cursor)"
    assert_eq "$1: temp files removed" "0" "$(find "$M" -name '.tw-*' ! -name .ticket-watch | wc -l | tr -d ' ')"
}
reset; fx jcm_searchIssues 1 FAIL; fail_case "probe transport error"
reset; INIT_FAIL=1 fail_case "initialize transport error"
reset; SID_HDR='a b' fail_case "unsafe session id"
reset; fx jcm_searchIssues 1 "$(probe "$T1")"; fx jcm_getIssue 1 FAIL; fail_case "getIssue transport error after CHANGED"
reset; fx jcm_searchIssues 1 "$(probe "$T1")"; fx jcm_getIssue 1 "$(issue)"; fx jcm_getIssueChangelog 1 "$(log bob '[{"field":"summary","from":"a","to":"b"}]' true)"; fx jcm_getIssueChangelog 2 FAIL
fail_case "page 2 transport error"
reset; fx jcm_searchIssues 1 'RAW {"result":{"content":[{"type":"text","text":"Jira API error 404"}],"isError":true},"jsonrpc":"2.0","id":2}'; fail_case "isError"
reset; fx jcm_searchIssues 1 'RAW {"error":{"code":-32602,"message":"bad"},"jsonrpc":"2.0","id":2}'; fail_case "JSON-RPC error"
reset; fx jcm_searchIssues 1 'not json'; fail_case "non-JSON payload"
reset; fx jcm_searchIssues 1 'RAW not json'; fail_case "non-JSON SSE data"
reset; fx jcm_searchIssues 1 '{"error":"x"}'; fail_case "probe without issues"

# Gates: watch off -> nothing; no http server / not the run owner -> fallback, no calls
reset; fx jcm_searchIssues 1 "$(probe "$T1")"
printf '{"tracker":{"mcp":"sx","operations":{"getChangelog":"jcm_getIssueChangelog"}}}' > "$N1_HOME/config.json"
assert_eq "stdio server: no-http-server" "TW_FALLBACK no-http-server" "$(check)"
printf '{"tracker":{"mcp":"nope","operations":{"getChangelog":"jcm_getIssueChangelog"}}}' > "$N1_HOME/config.json"
assert_eq "no entry: no-http-server" "TW_FALLBACK no-http-server" "$(check)"
printf '{"watch":{"enabled":false},"tracker":{"mcp":"jc","operations":{"getChangelog":"jcm_getIssueChangelog"}}}' > "$N1_HOME/config.json"
assert_eq "watch off: silent" "" "$(check)"
printf '{"tracker":{"mcp":"jc","operations":{"getChangelog":"jcm_getIssueChangelog"}}}' > "$N1_HOME/config.json"
assert_eq "other session's run: fallback" "TW_FALLBACK not-run-owner" "$(N1_SESSION_ID=s2 check)"
assert_eq "gates: no tracker calls" "" "$(calls)"
assert_eq "gates: cursor untouched" "yes" "$(same_cursor)"
rm -f "$M/.ticket-watch"; assert_eq "check unseeded: silent" "" "$(check)"
assert_eq "bad id: fallback" "TW_FALLBACK bad-id" "$(n1_tw_check_http '../T-1')"

# Seed over HTTP: getCurrentUser + getIssue -> cursor, silent
reset; rm -f "$M/.ticket-watch"; fx jcm_getCurrentUser 1 '{"accountId":"me-1","displayName":"Me"}'; fx jcm_getIssue 1 "$(issue "$EXT_C")"
assert_eq "seed: silent" "" "$(n1_tw_seed_http "$ID")"
assert_eq "seed: cursor me" "me-1" "$(jq -r .me "$M/.ticket-watch")"
assert_eq "seed: cursor seen" '["200@2026-10-17T10:30:00.000+0000"]' "$(jq -c .seen "$M/.ticket-watch")"
: > "$T/calls"; assert_eq "seed: already seeded -> silent" "" "$(n1_tw_seed_http "$ID")"
assert_eq "seed: already seeded -> no calls" "" "$(calls)"
reset; rm -f "$M/.ticket-watch"; fx jcm_getCurrentUser 1 FAIL
assert_eq "seed: transport error -> fallback" "yes" "$(o=$(n1_tw_seed_http "$ID"); [[ "$o" == "TW_FALLBACK "* ]] && echo yes || echo no)"
assert_eq "seed: transport error -> no cursor" "no" "$([ -e "$M/.ticket-watch" ] && echo yes || echo no)"
reset; rm -f "$M/.ticket-watch"; fx jcm_getCurrentUser 1 '{"displayName":"no id"}'; fx jcm_getIssue 1 "$(issue)"
assert_eq "seed: bad user -> fallback" "TW_FALLBACK seed-failed" "$(n1_tw_seed_http "$ID")"
assert_eq "seed: temp files removed" "0" "$(find "$M" -name '.tw-*' | wc -l | tr -d ' ')"

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# N1-634: n1_blocker_watch — one silent background shell: interval, cap, silence until exit,
# the three resolution rules, timeout record + comment, key validation, HTTP/PR-only mode.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_RUN_ID N1_BW_INTERVAL N1_BW_MAX_CHECKS N1_HEADLESS N1_QUEUE_RUN_ID
export HOME="$T/h" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_ROOT="$REPO_ROOT" N1_HOME="$T/n1" N1_SESSION_ID=s1
mkdir -p "$HOME" "$N1_HOME/memory/T-1" "$T/bin" "$T/gh"
source "$REPO_ROOT/lib/preamble.sh"
source "$REPO_ROOT/lib/memory.sh"
source "$REPO_ROOT/lib/ticket-watch.sh"
source "$REPO_ROOT/lib/poll.sh"
OV="$N1_HOME/memory/T-1/overview.md"
printf '{"mcpServers":{"jc":{"type":"http","url":"http://127.0.0.1:9/mcp"}}}' > "$HOME/.claude.json"
export SLEEP_LOG="$T/sleep" OUT_FILE="$T/out" GH_LOG="$T/ghlog" GH_FX="$T/gh"
export PATH="$T/bin:$PATH"

# sleep stub: logs its argument; flags any stdout written before exit
cat > "$T/bin/sleep" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SLEEP_LOG"
[ -s "$OUT_FILE" ] && echo early >> "$SLEEP_LOG.early"
exit 0
EOS
# gh stub: logs args; GH_FAIL=1 fails; else prints $GH_FX/<KEY> or []
cat > "$T/bin/gh" <<'EOG'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ -z "${GH_FAIL:-}" ] || exit 1
s=""; while [ $# -gt 0 ]; do [ "$1" = --search ] && s="$2"; shift; done
k=${s%% *}
if [ -f "$GH_FX/$k" ]; then cat "$GH_FX/$k"; else echo '[]'; fi
EOG
chmod +x "$T/bin/sleep" "$T/bin/gh"

# MCP transport fixture: jcm_getIssue answers from $T/fx/<issueKey>; jcm_searchIssues from $T/fx/S-<key in jql>
# (else {total:0,issues:[]}); jcm_addComment ok unless COMMENT_FAIL
_n1_mcp_post() { # <url> <session-id> <body>
    local m t a p j
    m=$(jq -r .method <<<"$3"); t=$(jq -r '.params.name // ""' <<<"$3"); a=$(jq -c '.params.arguments // {}' <<<"$3")
    case "$m" in
        initialize) printf 'HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nmcp-session-id: sid-1\r\n\r\nevent: message\r\ndata: {"result":{"protocolVersion":"2025-03-26"},"jsonrpc":"2.0","id":1}\r\n\r\n' ;;
        notifications/initialized) printf 'HTTP/1.1 202 Accepted\r\n\r\n' ;;
        tools/call)
            printf '%s|%s\n' "$t" "$a" >> "$T/calls"
            case "$t" in
                jcm_getIssue) p=$(cat "$T/fx/$(jq -r .issueKey <<<"$a")" 2>/dev/null) || return 22 ;;
                jcm_searchIssues) j=$(jq -r .jql <<<"$a"); j=${j#key = }; p=$(cat "$T/fx/S-${j%% *}" 2>/dev/null) || p='{"total":0,"issues":[]}' ;;
                jcm_addComment) [ -z "${COMMENT_FAIL:-}" ] || return 28; p='{"id":"c1"}'; [ -z "${COMMENT_DECLINE:-}" ] || p='{"ok":false,"message":"Comment not added"}' ;;
                *) return 22 ;;
            esac
            printf 'HTTP/1.1 200 OK\r\n\r\nevent: message\r\ndata: %s\r\n\r\n' "$(jq -nc --arg p "$p" '{result:{content:[{type:"text",text:$p}]},jsonrpc:"2.0",id:2}')" ;;
        *) return 22 ;;
    esac
}
cfg() { jq -nc --arg t "$1" --arg d "${2:-}" '{tracker:{type:$t,mcp:"jc",statuses:{deployed:$d}}}' > "$N1_HOME/config.json"; }
iss() { mkdir -p "$T/fx"; jq -nc --arg s "$2" '{key:"x",status:$s}' > "$T/fx/$1"; }   # jc-mcp getIssue: status is a bare name
srch() { mkdir -p "$T/fx"; jq -nc --arg k "$1" --argjson n "$2" '{total:$n,issues:[range($n)|{key:$k,status:"Closed"}]}' > "$T/fx/S-$1"; }   # jc-mcp searchIssues
iss_rest() { mkdir -p "$T/fx"; jq -nc --arg s "$2" --arg c "$3" '{key:"x",fields:{status:{name:$s,statusCategory:{key:$c}}}}' > "$T/fx/$1"; }   # Jira REST shape
pr() { printf '[{"number":5,"title":"%s","headRefName":"b","state":"%s"}]' "$2" "$3" > "$GH_FX/$1"; }
reset() { rm -rf "$T/fx" "$GH_FX"/* "$T/calls" "$GH_LOG" "$SLEEP_LOG" "$SLEEP_LOG.early"; touch "$T/calls" "$GH_LOG" "$SLEEP_LOG"
          printf -- '---\nticket: T-1\n---\n# T-1\n\n## Escalations\n' > "$OV"; unset GH_FAIL COMMENT_FAIL; export N1_BW_INTERVAL=7 N1_BW_MAX_CHECKS=2; }
run() { : > "$OUT_FILE"; n1_blocker_watch "$@" > "$OUT_FILE" 2> "$T/err"; echo $? > "$T/rc"; }
out() { cat "$OUT_FILE"; }

# Defaults: 6 x sleep 1800, silent until exit, one line, nothing on stderr
reset; cfg youtrack; unset N1_BW_INTERVAL N1_BW_MAX_CHECKS
run T-1 A-1
eq "defaults: six sleeps of 1800" "1800 1800 1800 1800 1800 1800" "$(tr '\n' ' ' < "$SLEEP_LOG" | sed 's/ $//')"
eq "defaults: no output before exit" "no" "$([ -f "$SLEEP_LOG.early" ] && echo yes || echo no)"
eq "defaults: exactly one stdout line" "1" "$(wc -l < "$OUT_FILE" | tr -d ' ')"
eq "defaults: stderr empty" "" "$(cat "$T/err")"
eq "defaults: rc 0" "0" "$(cat "$T/rc")"
eq "defaults: timeout line (pr-only -> comment pending)" "TIMEOUT T-1 comment:pending blocked (watch timed out after 3h): A-1" "$(out)"
eq "defaults: one gh lookup per check" "6" "$(wc -l < "$GH_LOG" | tr -d ' ')"

# Resolution 1: status category Done (jc-mcp searchIssues statusCategory = Done; Jira REST getIssue shape)
reset; cfg jira; iss A-1 Closed; srch A-1 1; run T-1 A-1
eq "done category: resolved" "RESOLVED T-1: blockers resolved (A-1). Next: invoke skill n1-start with T-1." "$(out)"
eq "done category: resolved on the first check" "1" "$(wc -l < "$SLEEP_LOG" | tr -d ' ')"
eq "done category: getIssue args built by jq" 'jcm_getIssue|{"issueKey":"A-1"}' "$(head -1 "$T/calls")"
eq "done category: searchIssues args built by jq" 'jcm_searchIssues|{"jql":"key = A-1 AND statusCategory = Done","maxResults":1}' "$(sed -n 2p "$T/calls")"
reset; cfg jira; iss A-1 Closed; srch A-1 0; run T-1 A-1
eq "done category: empty searchIssues issues stays open" "TIMEOUT" "$(out | cut -d' ' -f1)"
reset; cfg jira; iss_rest A-1 Closed done; run T-1 A-1
eq "done category (REST shape): resolved" "RESOLVED" "$(out | cut -d' ' -f1)"

# Resolution 2: status equals tracker.statuses.deployed, case-insensitive; empty deployed never matches
reset; cfg jira QA; iss A-1 qa; run T-1 A-1
eq "deployed status (case-insensitive): resolved" "RESOLVED" "$(out | cut -d' ' -f1)"
reset; cfg jira ""; iss A-1 QA; run T-1 A-1
eq "deployed status empty: stays open" "TIMEOUT" "$(out | cut -d' ' -f1)"

# Resolution 3: merged PR (searched with --state all)
reset; cfg youtrack; pr A-1 "[A-1] fix" MERGED; run T-1 A-1
eq "merged PR: resolved" "RESOLVED" "$(out | cut -d' ' -f1)"
eq "merged PR: gh searches --state all" "yes" "$(grep -q -- '--state all' "$GH_LOG" && echo yes || echo no)"

# Negatives: CLOSED PR, no whole-token match, gh failure -> unresolved
reset; cfg youtrack; pr A-1 "[A-1] fix" CLOSED; run T-1 A-1
eq "closed PR: stays open" "TIMEOUT" "$(out | cut -d' ' -f1)"
reset; cfg youtrack; pr A-1 "[A-12] other" MERGED; run T-1 A-1
eq "A-12 PR does not resolve A-1" "TIMEOUT" "$(out | cut -d' ' -f1)"
reset; cfg youtrack; pr A-1 "[A-1] fix" MERGED; export GH_FAIL=1; run T-1 A-1
eq "gh failure: stays open" "TIMEOUT" "$(out | cut -d' ' -f1)"
reset; cfg jira; pr A-1 "[A-1] fix" OPEN; run T-1 A-1
eq "HTTP read failure + open PR: stays open" "TIMEOUT" "$(out | cut -d' ' -f1)"

# Multiple blockers: all must resolve; timeout lists only the open ones
reset; cfg youtrack; pr A-1 "[A-1] x" MERGED; run T-1 A-1 A-2
eq "one of two resolved: timeout names the open one" "TIMEOUT T-1 comment:pending blocked (watch timed out after 3h): A-2" "$(out)"
reset; cfg youtrack; pr A-1 "[A-1] x" MERGED; pr A-2 "[A-2] y" MERGED; run T-1 A-1 A-2
eq "both resolved" "RESOLVED T-1: blockers resolved (A-1, A-2). Next: invoke skill n1-start with T-1." "$(out)"

# Timeout in HTTP mode: escalation line + one jcm_addComment with the marker; comment failure -> pending
reset; cfg jira; iss A-1 "To Do"; run T-1 A-1
eq "timeout http: comment posted" "TIMEOUT T-1 comment:posted blocked (watch timed out after 3h): A-1" "$(out)"
eq "timeout: escalation line in overview.md" "1" "$(grep -cxF -- '- [watch] ticket: blocked (watch timed out after 3h): A-1' "$OV")"
eq "timeout http: one addComment call" "1" "$(grep -c '^jcm_addComment|' "$T/calls")"
eq "timeout http: comment carries the n1-esc marker" "yes" "$(grep '^jcm_addComment|' "$T/calls" | cut -d'|' -f2- | jq -r '.issueKey + " " + (.body | test("n1-esc:T-1:ticket") | tostring)' | grep -qx 'T-1 true' && echo yes || echo no)"
reset; cfg jira; iss A-1 "To Do"; export COMMENT_FAIL=1; run T-1 A-1
eq "timeout http: comment failure -> pending" "TIMEOUT T-1 comment:pending blocked (watch timed out after 3h): A-1" "$(out)"

reset; cfg jira; iss A-1 "To Do"; export COMMENT_DECLINE=1; run T-1 A-1
eq "timeout http: declined write (ok:false) -> pending" "TIMEOUT T-1 comment:pending blocked (watch timed out after 3h): A-1" "$(out)"
unset COMMENT_DECLINE

# Validation: bad key or ID -> rc 2 before any sleep or gh call
for bad in 'a;rm' 'X-1;x' '$(id)'; do
    reset; cfg youtrack; run T-1 "$bad"
    eq "bad key [$bad]: rc 2" "2" "$(cat "$T/rc")"
    eq "bad key [$bad]: ERROR line" "ERROR bad-key" "$(out)"
    eq "bad key [$bad]: no gh call, no sleep" "0 0" "$(wc -l < "$GH_LOG" | tr -d ' ') $(wc -l < "$SLEEP_LOG" | tr -d ' ')"
done
reset; cfg youtrack; run 'T-1;x' A-1
eq "bad ID: rc 2" "2" "$(cat "$T/rc")"
reset; cfg youtrack; run T-1
eq "no keys: rc 2" "2" "$(cat "$T/rc")"

# One watcher per ticket: a newer launch takes the token, the older watcher exits silently
reset; cfg youtrack
( _n1_bw_resolved() { echo newer > "$N1_HOME/memory/T-1/blocker-watch.token"; return 1; }; run T-1 A-1 )
eq "superseded watcher: no output, rc 0" "|0" "$(out)|$(cat "$T/rc")"
reset; cfg youtrack; run T-1 A-1
eq "latest watcher keeps running to timeout" "TIMEOUT" "$(out | cut -d' ' -f1)"

# Mode
cfg youtrack; eq "mode: non-Jira -> pr-only" "pr-only" "$(n1_blocker_watch_mode)"
cfg jira; eq "mode: Jira + loopback HTTP server -> http" "http http://127.0.0.1:9/mcp" "$(n1_blocker_watch_mode)"
printf '{}' > "$HOME/.claude.json"
cfg jira; eq "mode: Jira without HTTP server -> pr-only" "pr-only" "$(n1_blocker_watch_mode)"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]

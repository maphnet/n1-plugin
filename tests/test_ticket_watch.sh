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
printf '{"accountId":"me-1","displayName":"Me"}' > "$T/me.json"
n1_tw_seed "$ID" "$T/issue0.json" "$T/me.json"
assert_eq "seed: updated" "$T0" "$(jq -r .updated "$M/.ticket-watch")"
assert_eq "seed: changelog_since = updated" "$T0" "$(jq -r .changelog_since "$M/.ticket-watch")"
assert_eq "seed: me" "me-1" "$(jq -r .me "$M/.ticket-watch")"
assert_eq "seed: seen holds all comments" "[\"100@$TC\"]" "$(jq -c .seen "$M/.ticket-watch")"
assert_eq "on: seeded -> active" "$ON_JC" "$(n1_tw_on "$ID")"
cp "$M/.ticket-watch" "$T/cur0"
echo 'not json' > "$T/bad.json"
n1_tw_seed "$ID" "$T/bad.json" "$T/me.json"; rc=$?
assert_eq "seed: bad input rc 1" "1" "$rc"
assert_eq "seed: bad input leaves cursor" "$(cat "$T/cur0")" "$(cat "$M/.ticket-watch")"
n1_tw_seed "$ID" "$T/issue0.json" "$T/bad.json"; rc=$?
assert_eq "seed: unreadable me rc 1" "1" "$rc"
assert_eq "seed: unreadable me leaves cursor" "$(cat "$T/cur0")" "$(cat "$M/.ticket-watch")"

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

# ---- n1_tw_delta ----
reset() { cp "$T/cur0" "$M/.ticket-watch"; }
c_own=$(printf '{"id":"100","authorAccountId":"me-1","author":"Me","body":"N1 enrichment","created":"%s","updated":"%s"}' "$TC" "$TC")
printf '{"updated":"%s","comments":[%s,{"id":"101","authorAccountId":"me-1","author":"Me","body":"N1 PR link","created":"%s","updated":"%s"}]}' "$T1" "$c_own" "$T1" "$T1" > "$T/issue-own.json"
printf '{"entries":[{"id":"1","authorAccountId":"me-1","author":"Me","created":"2026-10-17T10:30:00.000+0000","items":[{"field":"status","from":"To Do","to":"In Progress"}]}],"truncated":false}' > "$T/log-own.json"
printf '{"entries":[],"truncated":false}' > "$T/log-empty.json"
printf '{"updated":"%s","comments":[%s,{"id":"200","authorAccountId":"al-2","author":"Alice","body":"Please also export CSV x\\u001b[2Jy","created":"%s","updated":"%s"}]}' "$T1" "$c_own" "$T1" "$T1" > "$T/issue-ext.json"
printf '{"updated":"2026-10-17T12:00:00.000+0000","comments":[%s,{"id":"200","authorAccountId":"al-2","author":"Alice","body":"Edited ask","created":"%s","updated":"2026-10-17T12:00:00.000+0000"}]}' "$c_own" "$T1" > "$T/issue-edit.json"
ext_log() { printf '{"entries":[{"id":"%s","authorAccountId":"al-2","author":"Alice","created":"%s","items":[{"field":"%s","from":"a","to":"%s"}]}],"truncated":%s}' "$1" "$2" "$3" "$4" "$5"; }
ext_log 7 "2026-10-17T10:40:00.000+0000" status Done false > "$T/log-done.json"
ext_log 8 "2026-10-17T10:40:00.000+0000" status Blocked false > "$T/log-blocked.json"
ext_log 9 "2026-10-17T10:40:00.000+0000" status "In Review" false > "$T/log-review.json"
ext_log 10 "2026-10-17T10:40:00.000+0000" description "New AC: CSV" false > "$T/log-desc.json"
ext_log 11 "2026-10-17T10:10:00.000+0000" labels x true > "$T/log-p1.json"
ext_log 13 "2026-10-17T10:45:00.000+0000" description "$(printf 'z%.0s' $(seq 600))" false > "$T/log-long.json"
ext_log 12 "2026-10-17T10:20:00.000+0000" description y false > "$T/log-p2.json"

reset; out=$(n1_tw_delta "$ID" "$T/issue-own.json" "$T/log-own.json")
assert_eq "delta: own-only -> silent" "" "$out"
assert_eq "delta: own-only advances updated" "$T1" "$(jq -r .updated "$M/.ticket-watch")"
assert_eq "delta: own-only advances changelog_since" "2026-10-17T10:30:00.000+0000" "$(jq -r .changelog_since "$M/.ticket-watch")"
assert_eq "delta: own comment recorded as seen" "2" "$(jq '.seen | length' "$M/.ticket-watch")"

reset; out=$(n1_tw_delta "$ID" "$T/issue-ext.json" "$T/log-empty.json")
assert_eq "delta: external comment surfaced" "200" "$(jq -r '.comments[0].id' <<<"$out")"
assert_eq "delta: own comment excluded" "1" "$(jq '.comments | length' <<<"$out")"
assert_eq "delta: new comment not edited" "false" "$(jq -r '.comments[0].edited' <<<"$out")"
assert_eq "delta: control chars stripped" "Please also export CSV x [2Jy" "$(jq -r '.comments[0].body' <<<"$out")"
assert_eq "delta: idempotent second call" "" "$(n1_tw_delta "$ID" "$T/issue-ext.json" "$T/log-empty.json")"
out=$(n1_tw_delta "$ID" "$T/issue-edit.json" "$T/log-empty.json")
assert_eq "delta: edited comment flagged" "true" "$(jq -r '.comments[0].edited' <<<"$out")"

reset; out=$(n1_tw_delta "$ID" "$T/issue-own.json" "$T/log-done.json")
assert_eq "delta: external Done -> status_stop" "Done" "$(jq -r .status_stop <<<"$out")"
reset; out=$(n1_tw_delta "$ID" "$T/issue-own.json" "$T/log-blocked.json")
assert_eq "delta: external Blocked -> status_stop" "Blocked" "$(jq -r .status_stop <<<"$out")"
printf '{"entries":[{"id":"20","authorAccountId":"al-2","author":"Alice","created":"2026-10-17T10:40:00.000+0000","items":[{"field":"status","from":"In Progress","to":"Blocked"}]},{"id":"21","authorAccountId":"al-2","author":"Alice","created":"2026-10-17T10:50:00.000+0000","items":[{"field":"status","from":"Blocked","to":"In Progress"}]}],"truncated":false}' > "$T/log-flip.json"
reset; out=$(n1_tw_delta "$ID" "$T/issue-own.json" "$T/log-flip.json")
assert_eq "delta: flip and revert -> no status_stop" "null" "$(jq -r .status_stop <<<"$out")"
reset; out=$(n1_tw_delta "$ID" "$T/issue-own.json" "$T/log-review.json")
assert_eq "delta: other status -> no status_stop" "null" "$(jq -r .status_stop <<<"$out")"
reset; out=$(n1_tw_delta "$ID" "$T/issue-own.json" "$T/log-desc.json")
assert_eq "delta: external description -> description_edited" "true" "$(jq -r .description_edited <<<"$out")"

reset; out=$(n1_tw_delta "$ID" "$T/issue-own.json" "$T/log-p1.json" "$T/log-p2.json")
assert_eq "delta: two pages merged" "2" "$(jq '.changes | length' <<<"$out")"
assert_eq "delta: since = last page's last created" "2026-10-17T10:20:00.000+0000" "$(jq -r .changelog_since "$M/.ticket-watch")"
reset; n1_tw_delta "$ID" "$T/issue-own.json" "$T/log-p1.json" >/dev/null
assert_eq "delta: truncated last page keeps old updated" "$T0" "$(jq -r .updated "$M/.ticket-watch")"
assert_eq "delta: truncated last page still advances since" "2026-10-17T10:10:00.000+0000" "$(jq -r .changelog_since "$M/.ticket-watch")"

jq -n --arg u "$T1" '{updated:$u, comments:[range(12) | {id:"\(300+.)", authorAccountId:"al-2", author:"Alice", body:("b" * 2000), created:$u, updated:$u}]}' > "$T/issue-many.json"
reset; out=$(n1_tw_delta "$ID" "$T/issue-many.json" "$T/log-empty.json")
assert_eq "delta: comments capped at 10" "10" "$(jq '.comments | length' <<<"$out")"
assert_eq "delta: dropped count" "2" "$(jq .dropped <<<"$out")"
assert_eq "delta: body capped at 1500" "1500" "$(jq '.comments[0].body | length' <<<"$out")"

reset; out=$(n1_tw_delta "$ID" "$T/issue-own.json" "$T/log-long.json")
assert_eq "delta: changelog from/to capped at 500" "500" "$(jq '.changes[0].to | length' <<<"$out")"
printf '{"entries":[{"id":"30","authorAccountId":"al-2","author":"Alice","created":"2026-10-17T10:45:00.000+0000","items":[{"field":"labels","from":"a\u200bb\u00adc","to":"x"}]}],"truncated":false}' > "$T/log-inv.json"
reset; out=$(n1_tw_delta "$ID" "$T/issue-own.json" "$T/log-inv.json")
assert_eq "delta: zero-width chars stripped" "a b c" "$(jq -r '.changes[0].from' <<<"$out")"
reset; out=$(n1_tw_delta "$ID" "$T/bad.json" "$T/log-empty.json"); rc=$?
assert_eq "delta: bad issue rc 1" "1" "$rc"
assert_eq "delta: bad issue silent" "" "$out"
assert_eq "delta: bad issue leaves cursor byte-identical" "$(cat "$T/cur0")" "$(cat "$M/.ticket-watch")"
reset; n1_tw_delta "$ID" "$T/issue-own.json" "$T/bad.json" >/dev/null; rc=$?
assert_eq "delta: bad changelog page rc 1" "1" "$rc"
assert_eq "delta: bad page leaves cursor" "$(cat "$T/cur0")" "$(cat "$M/.ticket-watch")"
# ---- N1-89 follow-up 1: caps keep the remainder pending ----
reset; out=$(n1_tw_delta "$ID" "$T/issue-many.json" "$T/log-empty.json")
assert_eq "cap: withheld comments not seen" "0" "$(jq '[.seen[] | select(startswith("310@") or startswith("311@"))] | length' "$M/.ticket-watch")"
assert_eq "cap: delivered comments seen" "1" "$(jq '[.seen[] | select(startswith("300@"))] | length' "$M/.ticket-watch")"
assert_eq "cap: withheld keeps old updated" "$T0" "$(jq -r .updated "$M/.ticket-watch")"
assert_eq "cap: pending flag" "true" "$(jq .pending <<<"$out")"
out=$(n1_tw_delta "$ID" "$T/issue-many.json" "$T/log-empty.json")
assert_eq "cap: remainder delivered next check" "2" "$(jq '.comments | length' <<<"$out")"
assert_eq "cap: remainder first id" "310" "$(jq -r '.comments[0].id' <<<"$out")"
assert_eq "cap: drained advances updated" "$T1" "$(jq -r .updated "$M/.ticket-watch")"
jq -nc '{entries:[range(12) | {id:"\(40+.)", authorAccountId:"al-2", author:"Alice", created:"2026-10-17T11:\(10+.):00.000+0000", items:[{field:"labels",from:"a",to:"b"}]}], truncated:false}' > "$T/log-12.json"
reset; out=$(n1_tw_delta "$ID" "$T/issue-own.json" "$T/log-12.json")
assert_eq "cap: changes capped at 10" "10" "$(jq '.changes | length' <<<"$out")"
assert_eq "cap: changelog_since stops at last delivered" "2026-10-17T11:19:00.000+0000" "$(jq -r .changelog_since "$M/.ticket-watch")"
assert_eq "cap: changelog withheld keeps updated" "$T0" "$(jq -r .updated "$M/.ticket-watch")"
assert_eq "cap: changelog dropped count" "2" "$(jq .dropped <<<"$out")"
# truncated last page: current status decides
jq '.status="Blocked"' "$T/issue-own.json" > "$T/issue-blk.json"
reset; out=$(n1_tw_delta "$ID" "$T/issue-blk.json" "$T/log-p1.json")
assert_eq "trunc: current Blocked -> status_stop" "Blocked" "$(jq -r .status_stop <<<"$out")"
reset; out=$(n1_tw_delta "$ID" "$T/issue-own.json" "$T/log-p1.json")
assert_eq "trunc: current non-stop -> none" "null" "$(jq -r .status_stop <<<"$out")"
# later own-account transition cancels an external stop
printf '{"entries":[{"id":"50","authorAccountId":"al-2","author":"Alice","created":"2026-10-17T10:40:00.000+0000","items":[{"field":"status","from":"In Progress","to":"Blocked"}]},{"id":"51","authorAccountId":"me-1","author":"Me","created":"2026-10-17T10:50:00.000+0000","items":[{"field":"status","from":"Blocked","to":"In Progress"}]}],"truncated":false}' > "$T/log-ownflip.json"
reset; out=$(n1_tw_delta "$ID" "$T/issue-own.json" "$T/log-ownflip.json")
assert_eq "status: own later transition -> no stop" "null" "$(jq -r .status_stop <<<"$out")"
# ---- n1_tw_replan_reset ----
A=$(_n1_step_display_name analysis); Q=$(_n1_step_display_name qa)
printf -- '---\nstep: review\nqa_fix_cycle: 2\nreview_fix_cycle: 1\n---\n\n- [x] %s\n- [x] %s\n- [x] Unrelated checklist item\n' "$A" "$Q" > "$M/overview.md"
assert_eq "replan: first reset prints 1" "1" "$(n1_tw_replan_reset "$ID")"
assert_eq "replan: step back to ticket" "ticket" "$(n1_read_frontmatter "$M/overview.md" step)"
assert_eq "replan: qa_fix_cycle zeroed" "0" "$(n1_read_frontmatter "$M/overview.md" qa_fix_cycle)"
assert_eq "replan: review_fix_cycle zeroed" "0" "$(n1_read_frontmatter "$M/overview.md" review_fix_cycle)"
assert_eq "replan: analysis box unticked" "1" "$(grep -c -- "- \[ \] $A" "$M/overview.md")"
assert_eq "replan: qa box unticked" "1" "$(grep -c -- "- \[ \] $Q" "$M/overview.md")"
assert_eq "replan: unrelated box kept" "1" "$(grep -c -- '- \[x\] Unrelated checklist item' "$M/overview.md")"
assert_eq "replan: second reset prints 2" "2" "$(n1_tw_replan_reset "$ID")"
n1_tw_replan_reset "$ID" >/dev/null; rc=$?
assert_eq "replan: cap of 2 -> rc 1" "1" "$rc"
assert_eq "replan: cap leaves count at 2" "2" "$(n1_read_frontmatter "$M/overview.md" replan_count)"

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]

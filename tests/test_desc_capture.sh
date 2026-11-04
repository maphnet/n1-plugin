#!/usr/bin/env bash
# N1-326: hooks/desc-capture.sh writes a fetched ticket's title/description (.title/.txt) from the jcm_getIssue
# result into the file named by the calling session's one-shot n1_desc_mark marker; anything else writes nothing.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_SESSION_ID CLAUDE_CODE_SESSION_ID N1_RUN_ID N1_QUEUE_RUN_ID N1_QUEUE_DIR
export N1_HOME="$T/home" CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
M="$N1_HOME/memory/T-1"; Q="$N1_HOME/queue/q1"; MK="$N1_HOME/.desc-marker"
mkdir -p "$M" "$Q" "$T/h" "$T/elsewhere"
H="$REPO_ROOT/hooks/desc-capture.sh"
GI=mcp__jc__jcm_getIssue
qlib() { # <sid> <cmd...>: run a lib/queue.sh function the way a skill bash block does
    local sid="$1"; shift
    ( export HOME="$T/h" N1_ROOT="$REPO_ROOT" N1_SESSION_ID="$sid"
      source "$REPO_ROOT/lib/preamble.sh" >/dev/null 2>&1; source "$REPO_ROOT/lib/queue.sh"; "$@" )
}
mark() { qlib "$1" n1_desc_mark "${@:2}" >/dev/null 2>&1; echo $?; }      # prints rc
unmark() { qlib "$1" n1_desc_unmark "$2" >/dev/null 2>&1; echo $?; }
hookr() { # <tool_input-json> <tool_response-json> [agent_id]; env SID (default s1), TOOL (default GI); prints "<rc>|<stdout>"
    local out rc
    out=$(jq -nc --arg t "${TOOL:-$GI}" --argjson i "$1" --argjson r "$2" --arg cwd "$T" --arg sid "${SID:-s1}" --arg a "${3:-}" \
        '{session_id:$sid,cwd:$cwd,hook_event_name:"PostToolUse",tool_name:$t,tool_input:$i,tool_response:$r}
         | if $a != "" then .agent_id = $a else . end' | bash "$H"); rc=$?
    printf '%s|%s' "$rc" "$out"
}
hook() { hookr "$1" "$(jq -c '[{type:"text",text:tojson}]' <<<"$2")" "${3:-}"; }   # payload object as one text block
same() { cmp -s "$1" "$2" && echo same || echo differs; }
has() { [ -e "$1" ] || [ -L "$1" ] && echo yes || echo no; }
out_count() { find "$N1_HOME/memory" "$N1_HOME/queue" "$T/elsewhere" -type f 2>/dev/null | wc -l | tr -d ' '; }
clean() { rm -rf "$MK" "$N1_HOME"/memory/*/.desc-* "$N1_HOME"/memory/*/.guard-live* "$Q/desc"; }

K='{"issueKey":"T-1"}'
TITLE=$(printf 'Fix caf\xc3\xa9  $(touch %s/pwned) `id`' "$T")
DESC=$(printf 'line1\n\n  line2 \\/ x\n.'); DESC=${DESC%.}   # keeps the trailing newline
printf '%s' "$TITLE" > "$T/exp.title"; printf '%s' "$DESC" > "$T/exp.txt"
ISSUE=$(jq -nc --arg s "$TITLE" --arg d "$DESC" '{key:"T-1",summary:$s,description:$d,status:"To Do"}')

# [AC1] each kind writes <dest>.title/.txt byte-equal to the result's summary/description, silently
for kv in pre:.desc-pre post:.desc-post guard:.guard-live; do
    kind=${kv%%:*}; f=${kv#*:}
    clean; mark s1 "$kind" T-1 >/dev/null
    assert_eq "$kind: rc 0, no stdout" "0|" "$(hook "$K" "$ISSUE")"
    assert_eq "$kind: title byte-exact" same "$(same "$T/exp.title" "$M/$f.title")"
    assert_eq "$kind: description byte-exact (trailing newline kept)" same "$(same "$T/exp.txt" "$M/$f.txt")"
    assert_eq "$kind: marker consumed" no "$(has "$MK/s1/T-1")"
done
assert_eq "tracker text is never executed (SEC-1)" no "$(has "$T/pwned")"
clean; mark s1 queue T-1 q1 >/dev/null; hook "$K" "$ISSUE" >/dev/null
assert_eq "queue: desc/ created, title byte-exact" same "$(same "$T/exp.title" "$Q/desc/T-1.title")"
assert_eq "queue: description byte-exact" same "$(same "$T/exp.txt" "$Q/desc/T-1.txt")"
for shape in string result; do
    case $shape in
        string) r=$(jq -nc --arg s "$ISSUE" '$s') ;;
        result) r=$(jq -nc --arg s "$ISSUE" '{content:[{type:"text",text:$s[:9]},{type:"text",text:$s[9:]}]}') ;;
    esac
    clean; mark s1 pre T-1 >/dev/null; hookr "$K" "$r" >/dev/null
    assert_eq "response shape $shape: captured" same "$(same "$T/exp.txt" "$M/.desc-pre.txt")"
done

# [AC3] the marker is one-shot: a second getIssue on the same key leaves .desc-pre untouched
clean; mark s1 pre T-1 >/dev/null; hook "$K" "$ISSUE" >/dev/null
hook "$K" "$(jq -c '.summary = "changed" | .description = "changed"' <<<"$ISSUE")" >/dev/null
assert_eq "second getIssue: .desc-pre.title unchanged" same "$(same "$T/exp.title" "$M/.desc-pre.title")"
assert_eq "second getIssue: .desc-pre.txt unchanged" same "$(same "$T/exp.txt" "$M/.desc-pre.txt")"
clean; mark s1 pre T-1 >/dev/null; mark s1 post T-1 >/dev/null; hook "$K" "$ISSUE" >/dev/null
assert_eq "re-mark: the latest kind wins" "no|yes" "$(has "$M/.desc-pre.title")|$(has "$M/.desc-post.title")"

# [AC2] no valid marker, mismatched key or invalid destination: nothing written, rc 0, silent
clean; assert_eq "no marker: rc 0, silent" "0|" "$(hook "$K" "$ISSUE")"
assert_eq "no marker: nothing written" 0 "$(out_count)"
clean; mark s2 pre T-1 >/dev/null; hook "$K" "$ISSUE" >/dev/null
assert_eq "another session's marker: nothing written" 0 "$(out_count)"
assert_eq "another session's marker: left in place" yes "$(has "$MK/s2/T-1")"
mkdir -p "$N1_HOME/memory/T-2"
clean; mark s1 pre T-1 >/dev/null; hook '{"issueKey":"T-2"}' "$(jq -c '.key = "T-2"' <<<"$ISSUE")" >/dev/null
assert_eq "key mismatch: nothing written" 0 "$(out_count)"
assert_eq "key mismatch: the T-1 marker is kept" yes "$(has "$MK/s1/T-1")"
clean; mark s1 pre T-1 >/dev/null; hook "$K" "$(jq -c '.key = "T-9"' <<<"$ISSUE")" >/dev/null
assert_eq "result for another issue: nothing written" 0 "$(out_count)"
clean; mark s1 pre T-1 >/dev/null; TOOL=mcp__jc__jcm_getIssueChangelog hook "$K" "$ISSUE" >/dev/null
assert_eq "other tool: nothing written, marker kept" "0|yes" "$(out_count)|$(has "$MK/s1/T-1")"
for c in 'evil' 'pre extra' 'queue' 'queue ../x' 'queue q1/../../memory' "$(printf 'queue q1\nqueue q2')"; do
    clean; mkdir -p "$MK/s1"; printf '%s\n' "$c" > "$MK/s1/T-1"
    hook "$K" "$ISSUE" >/dev/null
    assert_eq "bad marker content [$c]: nothing written, consumed" "0|no" "$(out_count)|$(has "$MK/s1/T-1")"
done
clean; mkdir -p "$MK/s1"; printf 'pre\n' > "$T/m"; ln -s "$T/m" "$MK/s1/T-1"; hook "$K" "$ISSUE" >/dev/null
assert_eq "symlinked marker: nothing written" 0 "$(out_count)"
ln -s "$T/elsewhere" "$N1_HOME/queue/qlink"
clean; mark s1 queue T-1 qlink >/dev/null; hook "$K" "$ISSUE" >/dev/null
assert_eq "symlinked queue dir: nothing written" 0 "$(out_count)"
clean; mark s1 queue T-1 nosuch >/dev/null; hook "$K" "$ISSUE" >/dev/null
assert_eq "missing queue dir: nothing written, not created" "0|no" "$(out_count)|$(has "$N1_HOME/queue/nosuch")"
clean; ln -s "$T/elsewhere" "$Q/desc"; mark s1 queue T-1 q1 >/dev/null; hook "$K" "$ISSUE" >/dev/null
assert_eq "symlinked desc/ dir: nothing written" 0 "$(out_count)"; rm -f "$Q/desc"
ln -s "$T/elsewhere" "$N1_HOME/memory/T-3"
clean; mark s1 pre T-3 >/dev/null; hook '{"issueKey":"T-3"}' "$(jq -c '.key = "T-3"' <<<"$ISSUE")" >/dev/null
assert_eq "symlinked memory dir: nothing written" 0 "$(out_count)"
clean; mark s1 pre T-4 >/dev/null; hook '{"issueKey":"T-4"}' "$(jq -c '.key = "T-4"' <<<"$ISSUE")" >/dev/null
assert_eq "missing memory dir: nothing written, not created" "0|no" "$(out_count)|$(has "$N1_HOME/memory/T-4")"

# [AC4] null description -> empty .txt; unparseable or wrong-shape payload -> nothing written, marker gone
clean; mark s1 pre T-1 >/dev/null; hook "$K" "$(jq -c '.description = null' <<<"$ISSUE")" >/dev/null
assert_eq "null description: zero-byte .txt" "yes|0" "$(has "$M/.desc-pre.txt")|$(wc -c < "$M/.desc-pre.txt" 2>/dev/null | tr -d ' ')"
assert_eq "null description: title still written" same "$(same "$T/exp.title" "$M/.desc-pre.title")"
clean; mark s1 pre T-1 >/dev/null; hook "$K" "$(jq -c 'del(.description)' <<<"$ISSUE")" >/dev/null
assert_eq "absent description: zero-byte .txt" "yes|0" "$(has "$M/.desc-pre.txt")|$(wc -c < "$M/.desc-pre.txt" 2>/dev/null | tr -d ' ')"
BAD=(
    "$(jq -nc '[{type:"text",text:"Error: issue not found"}]')"
    "$(jq -nc '[{type:"text",text:"[1,2]"}]')"
    "$(jq -nc '[{type:"text",text:"{\"summary\":5,\"description\":\"x\"}"}]')"
    "$(jq -nc '[{type:"text",text:"{\"summary\":\"s\",\"description\":7}"}]')"
    "$(jq -nc --arg s "$ISSUE" '[{type:"text",text:($s + $s)}]')"
    "$ISSUE"
    'null'
)
for r in "${BAD[@]}"; do
    clean; mark s1 pre T-1 >/dev/null; hookr "$K" "$r" >/dev/null
    assert_eq "bad payload [${r:0:40}]: nothing written, marker gone" "0|no" "$(out_count)|$(has "$MK/s1/T-1")"
done
assert_eq "no temp or claim files left" 0 "$(find "$N1_HOME" -type f \( -name '*.claim.*' -o -name '.desc-pre.??????' \) | wc -l | tr -d ' ')"

# [D7] a subagent call (agent_id present) with a live marker captures
clean; mark s1 guard T-1 >/dev/null; hook "$K" "$ISSUE" agent-123 >/dev/null
assert_eq "subagent call with marker captures (D7)" same "$(same "$T/exp.txt" "$M/.guard-live.txt")"

# n1_desc_mark validation, unmark, stale sweep
clean
for args in "x T-1" "pre t-1" "pre ../T-1" "queue T-1" "queue T-1 ../x" "queue T-1 .q" "pre T-1 q1"; do
    # shellcheck disable=SC2086
    assert_eq "n1_desc_mark rejects [$args]" "1|0" "$(mark s1 $args)|$(find "$MK" -type f 2>/dev/null | wc -l | tr -d ' ')"
done
assert_eq "n1_desc_mark rejects a bad session id" "1|0" "$(mark 'a/b' pre T-1)|$(find "$MK" -type f 2>/dev/null | wc -l | tr -d ' ')"
mark s1 queue T-1 q1 >/dev/null
assert_eq "n1_desc_mark writes only the validated tokens" "queue q1" "$(cat "$MK/s1/T-1")"
clean; mark s1 pre T-1 >/dev/null
assert_eq "n1_desc_unmark removes the marker" "0|no" "$(unmark s1 T-1)|$(has "$MK/s1/T-1")"
mark s1 pre T-1 >/dev/null; touch -d '2 hours ago' "$MK/s1/T-1"; mark s1 guard T-2 >/dev/null
assert_eq "stale marker (>60 min) swept by the next mark" no "$(has "$MK/s1/T-1")"

# Hash parity with the readers
clean; mark s1 pre T-1 >/dev/null; hook "$K" "$ISSUE" >/dev/null
assert_eq "hash parity with n1_queue_content_hash" \
    "$(qlib s1 n1_queue_content_hash "$T/exp.title" "$T/exp.txt")" \
    "$(qlib s1 n1_queue_content_hash "$M/.desc-pre.title" "$M/.desc-pre.txt")"

# hooks.json registration: own entry, anchored matcher, synchronous (the skill hashes right after the fetch)
HJ="$REPO_ROOT/hooks/hooks.json"
assert_eq "hooks.json: desc-capture matcher" '^mcp__.+__jcm_getIssue$' \
    "$(jq -r '[.hooks.PostToolUse[] | select(any(.hooks[]; .command | contains("desc-capture.sh")))][0].matcher // empty' "$HJ")"
assert_eq "hooks.json: desc-capture is synchronous" false \
    "$(jq '[.hooks.PostToolUse[].hooks[] | select(.command | contains("desc-capture.sh")) | .async // false] | any' "$HJ")"

# Real Claude Code PostToolUse payload (sanitized fixture), rebound to this test's session (runs last: leaves files)
FX="$REPO_ROOT/tests/fixtures/hooks/claude/posttooluse-jcm-getIssue.json"
FK=$(jq -r '.tool_input.issueKey' "$FX"); mkdir -p "$N1_HOME/memory/$FK"
jq -j '.tool_response | if type == "string" then .
    elif type == "array" then [.[] | select(type == "object" and .type == "text") | .text] | join("")
    else [.content[] | select(type == "object" and .type == "text") | .text] | join("") end' "$FX" > "$T/fx.json"
jq -j '.summary' "$T/fx.json" > "$T/fx.title"; jq -j '.description // ""' "$T/fx.json" > "$T/fx.txt"
clean; mark s1 pre "$FK" >/dev/null
jq -c --arg cwd "$T" '.session_id = "s1" | .cwd = $cwd | del(.agent_id) | .tool_name |= sub("^mcp__.+__"; "mcp__jc__")' "$FX" | bash "$H" >/dev/null
assert_eq "real payload: title byte-exact" same "$(same "$T/fx.title" "$N1_HOME/memory/$FK/.desc-pre.title")"
assert_eq "real payload: description byte-exact" same "$(same "$T/fx.txt" "$N1_HOME/memory/$FK/.desc-pre.txt")"

echo "test_desc_capture: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

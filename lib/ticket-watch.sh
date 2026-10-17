#!/usr/bin/env bash
# N1-89 ticket watch: deterministic, LLM-free change detection for the run's own ticket.
# Pure functions; no MCP calls. The orchestrator relays raw MCP JSON through files
# (procedures/ticket-watch.md). Requires lib/preamble.sh (config.sh, host.sh, step.sh) first.
# State: $N1_HOME/memory/<ID>/.ticket-watch = {updated, changelog_since, me, seen:["<id>@<updated>"]}

n1_watch_val() {
    # Usage: n1_watch_val <key> — .watch.<key> from config, else defaults/watch.json.
    local key="$1" val
    val=$(n1_config_val ".watch.${key}")
    [ -n "$val" ] || val=$(n1_config_val ".${key}" "$(n1_plugin_root)/defaults/watch.json")
    printf '%s' "$val"
}

n1_tw_on() {
    # Usage: n1_tw_on <ID> [seed] — prints "<watch_mcp>\t<changelog_op>" when the watch is active,
    # else nothing. Active = watch.enabled AND tracker.operations.getChangelog mapped (jc-mcp only)
    # AND cursor seeded ("seed" skips the cursor check). watch_mcp = versionMcp, else tracker.mcp.
    local id="$1" mode="${2:-}" op mcp
    [ "$(n1_watch_val enabled)" = "true" ] || return 0
    op=$(n1_config_val '.tracker.operations.getChangelog'); [ -n "$op" ] || return 0
    [ "$mode" = seed ] || [ -f "$N1_HOME/memory/$id/.ticket-watch" ] || return 0
    mcp=$(n1_config_val '.tracker.versionMcp'); [ -n "$mcp" ] || mcp=$(n1_config_val '.tracker.mcp')
    [ -n "$mcp" ] && printf '%s\t%s\n' "$mcp" "$op"
    return 0
}

n1_tw_seed() {
    # Usage: n1_tw_seed <ID> <issue.json> <me.json> — writes the cursor from raw getIssue and
    # getCurrentUser responses. Bad input -> rc 1, cursor untouched.
    local f="$N1_HOME/memory/$1/.ticket-watch" issue="$2" me tmp
    me=$(jq -r '.accountId // empty' "$3" 2>/dev/null)
    [ -n "$me" ] || return 1
    mkdir -p "${f%/*}" && tmp=$(mktemp "$f.XXXXXX") || return 1
    if jq -e --arg me "$me" '
        select((.updated | type) == "string" and .updated != "")
        | {updated, changelog_since: .updated, me: $me,
           seen: [(.comments // [])[] | "\(.id)@\(.updated)"]}' "$issue" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"; return 1
    fi
}

n1_tw_cmp() {
    # Usage: n1_tw_cmp <ID> <probe.json> — compares a raw searchIssues result with the cursor.
    # Silent rc 0 when unchanged or no row; "CHANGED <changelog_since>" when raw updated moved;
    # rc 1 and no output on bad input. Keys on raw updated: the minute-floored JQL always re-matches.
    local f="$N1_HOME/memory/$1/.ticket-watch" old since out
    old=$(jq -r '.updated // empty' "$f" 2>/dev/null); [ -n "$old" ] || return 1
    since=$(jq -r '.changelog_since // empty' "$f" 2>/dev/null)
    out=$(jq -r --arg old "$old" --arg since "$since" '
        if (.issues | type) != "array" then error("bad probe")
        elif (.issues | length) == 0 then empty
        else (.issues[0].updated // "") as $u
             | if $u == "" or $u == $old then empty else "CHANGED \($since)" end end' "$2" 2>/dev/null) || return 1
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
}

n1_tw_delta() {
    # Usage: n1_tw_delta <ID> <issue.json> [changelog-page.json...]
    # External delta = comments with an unseen (id, updated) key and changelog items, both by
    # authors != me. Persists the advanced cursor BEFORE printing, so one change never fires twice
    # (pause/resume, re-plan). Prints one compact JSON digest, or nothing when every change is our
    # own. rc 1 and cursor untouched on bad input. A truncated last page or any item past the cap (10
    # comments, ~10 changelog items by whole entries) stays pending: old updated kept, withheld comments
    # not marked seen, changelog_since stops at the last delivered entry. A truncated last page also
    # checks the current getIssue status for Done/Blocked.
    local f="$N1_HOME/memory/$1/.ticket-watch" issue="$2" res tmp
    shift 2
    [ -f "$f" ] || return 1
    res=$(jq -nc --slurpfile cur "$f" --slurpfile iss "$issue" \
        --arg done "$(n1_config_val '.tracker.statuses.done')" \
        --arg blocked "$(n1_config_val '.tracker.statuses.blocked')" '
        def s: tostring | .[:1500] | gsub("[\u0000-\u001f\u007f-\u009f\u00ad\u061c\u200b-\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069\ufeff]"; " ");
        def t: s | .[:500];
        $cur[0] as $c | $iss[0] as $i | [inputs] as $pages
        | if ($c.me | type) != "string" or ($i.updated | type) != "string"
             or ($pages | all(.entries | type == "array") | not) then error("bad input") else . end
        | ($c.seen // []) as $seen
        | [($i.comments // [])[] | select(.authorAccountId != $c.me)
           | select("\(.id)@\(.updated)" as $k | any($seen[]; . == $k) | not)] as $new
        | ([$pages[].entries[] | select(.authorAccountId != $c.me)]
           | reduce .[] as $e ({inc: [], n: 0, full: false};
               ([$e.items[]] | length) as $k
               | if .full or (.inc | length) > 0 and .n + $k > 10 then .full = true
                 else {inc: (.inc + [$e]), n: (.n + $k), full: false} end)) as $sel
        | ([$pages[].entries[] | select(.authorAccountId != $c.me)] | map([.items[]] | length) | add // 0) as $total
        | [$sel.inc[] | (.author // "" | s) as $a | (.created | s) as $t
           | .items[] | {author: $a, created: $t, field: (.field // "" | t), from: (.from // "" | t), to: (.to // "" | t)}] as $items
        | ([$pages[].entries[] | . as $e | $e.items[] | select(.field == "status")
            | {by: $e.authorAccountId, to: (.to // "" | t)}] | last) as $ls
        | (($pages | last // {}) | .truncated == true) as $trunc
        | (if $trunc then ($i.status // "" | t)
           elif $ls != null and $ls.by != $c.me then $ls.to else "" end) as $st
        | (if ($st == $done and $done != "") or ($st == $blocked and $blocked != "") then $st else null end) as $stop
        | ($total - ($items | length)) as $cwith
        | ($new[:10] | map("\(.id)@\(.updated)")) as $inc
        | ([$new[10:][] | .id | tostring]) as $wid
        | (($new | length) > 10 or $cwith > 0) as $held
        | {cursor: ($c + {
              updated: (if $trunc or $held then $c.updated else $i.updated end),
              changelog_since: (if $cwith > 0 then $sel.inc[-1].created else ([$pages[].entries[].created] | last) // $c.changelog_since end),
              seen: ([($i.comments // [])[] | "\(.id)@\(.updated)" as $k
                      | select(.authorAccountId == $c.me or any($seen[]; . == $k) or any($inc[]; . == $k)) | $k]
                     + [$seen[] | select(. as $k | any($wid[]; . as $w | $k | startswith($w + "@")))])}),
           digest: (if ($new | length) == 0 and ($items | length) == 0 and $stop == null then null else
              {comments: [$new[:10][] | (.id | tostring) as $id
                  | {id: ($id | s), author: (.author // "" | s), created: (.created | s), updated: (.updated | s),
                     edited: any($seen[]; startswith("\($id)@")), body: (.body // "" | s)}],
               dropped: (([($new | length) - 10, 0] | max) + $cwith),
               pending: $held,
               changes: $items,
               status_stop: $stop,
               description_edited: any($items[]; .field == "description")} end)}
        ' "$@" </dev/null 2>/dev/null) || return 1
    [ -n "$res" ] || return 1
    tmp=$(mktemp "$f.XXXXXX") || return 1
    if jq -c '.cursor' <<<"$res" > "$tmp"; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
    jq -c '.digest // empty' <<<"$res"
}

n1_tw_replan_reset() {
    # Usage: n1_tw_replan_reset <ID> — prepares overview.md for an autonomous re-plan from Step 1.
    # Prints the new replan_count; rc 1 with no change once the per-run cap (2) is used.
    local o="$N1_HOME/memory/$1/overview.md" n k s name tmp
    [ -f "$o" ] || return 1
    n=$(n1_read_frontmatter "$o" replan_count); case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -ge 2 ] && return 1
    for k in qa_fix_cycle tq_fix_cycle review_fix_cycle clean_passes local_test_fix_cycle ci_fix_cycle; do
        [ -n "$(n1_read_frontmatter "$o" "$k")" ] && n1_write_frontmatter "$o" "$k" 0
    done
    n1_write_frontmatter "$o" step ticket
    n1_write_frontmatter "$o" replan_count "$((n + 1))"
    for s in ticket analysis brainstorm plan plan-review estimation implementation qa review fix local-testing pr ci finish; do
        name=$(_n1_step_display_name "$s"); [ -n "$name" ] || continue
        tmp=$(mktemp "$o.XXXXXX") || return 1
        sed "s/- \[x\] ${name}/- [ ] ${name}/" "$o" > "$tmp" && mv "$tmp" "$o" || rm -f "$tmp"
    done
    printf '%s\n' "$((n + 1))"
}

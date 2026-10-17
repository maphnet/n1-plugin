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
    # Usage: n1_tw_seed <ID> <issue.json> [me] — writes the cursor from a raw getIssue response.
    # Empty me -> reuse the cursor's cached me. Bad input -> rc 1, cursor untouched.
    local f="$N1_HOME/memory/$1/.ticket-watch" issue="$2" me="${3:-}" tmp
    [ -n "$me" ] || me=$(jq -r '.me // empty' "$f" 2>/dev/null)
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

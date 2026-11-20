#!/usr/bin/env bash
# Bounded internal polling for gh state — one tool call instead of one call per poll.
# Each invocation runs at most POLL_CHUNK_SECONDS; callers re-invoke until terminal.

POLL_CHUNK_SECONDS=480   # 8 min — safely under the 10-min Bash tool ceiling

n1_wait_ci_checks() {
    # Usage: n1_wait_ci_checks <pr-number> <max-minutes>
    # Prints: "green" | "red" | "pending"
    local pr="$1" max_minutes="${2:-30}"
    local deadline=$(( $(date +%s) + max_minutes * 60 ))
    local chunk_end=$(( $(date +%s) + POLL_CHUNK_SECONDS ))
    [ "$deadline" -lt "$chunk_end" ] && chunk_end=$deadline
    while :; do
        local counts
        counts=$(gh pr checks "$pr" --json bucket --jq \
            '[([.[] | select(.bucket == "fail" or .bucket == "cancel")] | length),
              ([.[] | select(.bucket == "pending")] | length), length] | @tsv' 2>/dev/null) || counts=""
        if [ -n "$counts" ]; then
            local failed pending total
            failed=$(printf '%s' "$counts" | cut -f1)
            pending=$(printf '%s' "$counts" | cut -f2)
            total=$(printf '%s' "$counts" | cut -f3)
            [ "$failed" -gt 0 ] 2>/dev/null && { printf 'red\n'; return 0; }
            [ "$total" -gt 0 ] 2>/dev/null && [ "$pending" -eq 0 ] 2>/dev/null && { printf 'green\n'; return 0; }
        fi
        [ "$(date +%s)" -ge "$chunk_end" ] && { printf 'pending\n'; return 0; }
        sleep 30
    done
}

# <json> -> "total<TAB>bad<TAB>running", empty when gh/jq gave no array
_n1_release_counts() {
    jq -r 'select(type == "array") | [length,
        ([.[] | select(.status == "completed" and .conclusion != "success"
            and .conclusion != "neutral" and .conclusion != "skipped")] | length),
        ([.[] | select(.status != "completed")] | length)] | @tsv' <<<"$1" 2>/dev/null
}

n1_wait_release_runs() {
    # Usage: n1_wait_release_runs <sha> <grace-minutes> <max-minutes> [workflow-name] [event]
    # Watches <event>-event workflow runs on <sha>; event defaults to "release" (push/workflow_run
    # runs on the same commit are then ignored), "any" watches every event (n1-finish merge commit).
    # A failed or unparseable gh call (TLS timeout) is "no information": it is
    # retried, never read as "no runs" or as a deploy failure.
    # Grace starts at the first successful gh answer, so outages do not consume it.
    # "none" = an empty answer at/after grace end; "skipped" = every run skipped (nothing deployed);
    # "unknown" = absence not confirmed (gh errors, or the chunk ended inside grace).
    # Prints: "none" | "unknown" | "pending" | "success" | "failed" | "skipped";
    # after pending/success/failed/skipped, one "<conclusion-or-status> <url>" line per run.
    local sha="$1" grace_minutes="${2:-0}" max_minutes="${3:-30}" workflow="${4:-}" event="${5:-release}"
    [ "$event" = any ] && event=""
    local start; start=$(date +%s)
    local grace_end=""
    local deadline=$(( start + max_minutes * 60 ))
    local chunk_end=$(( start + POLL_CHUNK_SECONDS ))
    [ "$deadline" -lt "$chunk_end" ] && chunk_end=$deadline
    local fmt='.[] | "\(if (.conclusion // "") == "" then .status else .conclusion end) \(.url)"'
    local runs="" json counts total bad running total2 bad2 running2
    while :; do
        json=$(gh run list ${event:+--event "$event"} --commit "$sha" ${workflow:+--workflow "$workflow"} \
            --json status,conclusion,url 2>/dev/null) || json=""
        counts=$(_n1_release_counts "$json") || counts=""
        if [ -n "$counts" ]; then
            [ -z "$grace_end" ] && grace_end=$(( $(date +%s) + grace_minutes * 60 ))
            IFS=$'\t' read -r total bad running <<<"$counts"
            if [ "$total" -gt 0 ]; then
                runs=$json
                [ "$bad" -gt 0 ] && { printf 'failed\n'; jq -r "$fmt" <<<"$runs"; return 0; }
                if [ "$running" -eq 0 ] && [ $(( $(date +%s) + 30 )) -lt "$chunk_end" ]; then
                    # First all-complete sighting: a later workflow may not have registered yet. Confirm once
                    # (skipped when the chunk ends first: the chunk-end check then reports pending).
                    sleep 30
                    json=$(gh run list ${event:+--event "$event"} --commit "$sha" ${workflow:+--workflow "$workflow"} \
                        --json status,conclusion,url 2>/dev/null) || json=""
                    counts=$(_n1_release_counts "$json") || counts=""
                    if [ -n "$counts" ]; then
                        IFS=$'\t' read -r total2 bad2 running2 <<<"$counts"
                        if [ "$total2" -ge "$total" ]; then
                            runs=$json
                            [ "$bad2" -gt 0 ] && { printf 'failed\n'; jq -r "$fmt" <<<"$runs"; return 0; }
                            if [ "$running2" -eq 0 ]; then
                                if jq -e 'all(.[]; .conclusion == "skipped")' <<<"$runs" >/dev/null; then
                                    # all skipped: terminal only once grace is over, else keep looping
                                    [ "$(date +%s)" -ge "$grace_end" ] && { printf 'skipped\n'; jq -r "$fmt" <<<"$runs"; return 0; }
                                else
                                    printf 'success\n'; jq -r "$fmt" <<<"$runs"; return 0
                                fi
                            fi
                        fi
                    fi
                fi
            elif [ -z "$runs" ] && [ "$(date +%s)" -ge "$grace_end" ]; then
                printf 'none\n'; return 0
            fi
        fi
        if [ "$(date +%s)" -ge "$chunk_end" ]; then
            if [ -n "$runs" ]; then printf 'pending\n'; jq -r "$fmt" <<<"$runs"
            else printf 'unknown\n'; fi
            return 0
        fi
        sleep 30
    done
}

# N1-301: (poll:)/(monitor:) steps in n1-release custom procedures. Names keep the n1_wait_ prefix.

_n1_wait_secs() { # <N><s|m|h> (already grammar-checked) -> seconds; rc 1 when zero
    local n=$((10#${1%[smh]}))
    [ "$n" -gt 0 ] || return 1
    case "${1: -1}" in s) echo "$n" ;; m) echo $((n * 60)) ;; h) echo $((n * 3600)) ;; esac
}

n1_wait_parse_marker() {
    # Usage: n1_wait_parse_marker <autorun true|false> <step text>
    # Prints one line: "poll<TAB><s><TAB><interval-s>" | "monitor<TAB><s><TAB><interval-s>" | "none" | "reject".
    # Grammar: (poll: <N><s|m|h>[, every <N><s|m|h>]) or (monitor: ...), lowercase, anywhere in the text;
    # default interval 15s. "reject": more than one (poll:/(monitor: opener (any case), or an opener that does
    # not match the grammar; the walk then handles the step as manual. With no opener, the phrase
    # "Retry until it passes" (any case) is a 10m poll only when autorun is true.
    local autorun="$1" text="$2" n kind dur every=15
    local re='\((poll|monitor):[[:space:]]*([0-9]+[smh])[[:space:]]*(,[[:space:]]*every[[:space:]]+([0-9]+[smh])[[:space:]]*)?\)'
    n=$(( $(grep -oiE '\((poll|monitor):' <<<"$text" | wc -l) ))
    if [ "$n" -eq 0 ]; then
        if [ "$autorun" = true ] && grep -qi 'retry until it passes' <<<"$text"; then printf 'poll\t600\t15\n'; else printf 'none\n'; fi
        return 0
    fi
    if [ "$n" -ne 1 ] || ! [[ "$text" =~ $re ]]; then printf 'reject\n'; return 0; fi
    kind=${BASH_REMATCH[1]}
    dur=$(_n1_wait_secs "${BASH_REMATCH[2]}") || { printf 'reject\n'; return 0; }
    if [ -n "${BASH_REMATCH[4]}" ]; then
        every=$(_n1_wait_secs "${BASH_REMATCH[4]}") || { printf 'reject\n'; return 0; }
    fi
    printf '%s\t%s\t%s\n' "$kind" "$dur" "$every"
}

n1_wait_step() {
    # Usage: n1_wait_step <poll|monitor> <remaining-s> <interval-s> <command>
    # Runs <command> via `bash -c` every <interval-s> for at most one chunk (POLL_CHUNK_SECONDS). Each check is
    # cut at N1_WAIT_CHECK_TIMEOUT (default 60, capped at 100) seconds, so a chunk ends within POLL_CHUNK_SECONDS + 100 + 5; a cut check
    # counts as failed. First output line: poll -> "passed" | "pending <remaining-s>" | "timeout";
    # monitor -> "failed" (first non-zero check, at once) | "pending <remaining-s>" | "ok". Then the last
    # check's output (last 40 lines). rc 0 on passed/ok/pending, 1 on timeout/failed and on bad arguments
    # ("failed" + usage). Callers re-invoke with the <remaining-s> from "pending"; no state file.
    local mode="$1" remaining="$2" interval="$3" cmd="${4:-}"
    if ! { [ "$mode" = poll ] || [ "$mode" = monitor ]; } || ! [[ "$remaining" =~ ^[1-9][0-9]*$ ]] \
        || ! [[ "$interval" =~ ^[1-9][0-9]*$ ]] || [ -z "$cmd" ]; then
        printf 'failed\nusage: n1_wait_step <poll|monitor> <remaining-s> <interval-s> <command>\n'; return 1
    fi
    local start now end t out rc rem nap
    start=$(date +%s)
    end=$(( start + (remaining < POLL_CHUNK_SECONDS ? remaining : POLL_CHUNK_SECONDS) ))
    while :; do
        t=${N1_WAIT_CHECK_TIMEOUT:-60}; [[ "$t" =~ ^[1-9][0-9]*$ ]] || t=60; [ "$t" -gt 100 ] && t=100
        out=$(timeout -k 5 "$t" bash -c "$cmd" 2>&1 | tail -n 40; exit "${PIPESTATUS[0]}"); rc=$?
        { [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; } && out="check timed out after ${t}s"
        if [ "$mode" = poll ] && [ "$rc" -eq 0 ]; then printf 'passed\n%s\n' "$out"; return 0; fi
        if [ "$mode" = monitor ] && [ "$rc" -ne 0 ]; then printf 'failed\n%s\n' "$out"; return 1; fi
        now=$(date +%s); rem=$(( remaining - (now - start) ))
        if [ "$rem" -le 0 ]; then
            if [ "$mode" = poll ]; then printf 'timeout\n%s\n' "$out"; return 1; fi
            printf 'ok\n%s\n' "$out"; return 0
        fi
        if [ "$now" -ge "$end" ]; then printf 'pending %s\n%s\n' "$rem" "$out"; return 0; fi
        nap=$interval; [ $(( end - now )) -lt "$nap" ] && nap=$(( end - now ))
        sleep "$nap"
    done
}

# --- N1-634: blind blocker watch. Run as ONE background shell; zero model turns while silent. ---
# Caller sources lib/memory.sh and lib/ticket-watch.sh after the preamble (n1_append_escalation, n1_mcp_http_call).
N1_BW_KEY_RE='^[A-Z][A-Z0-9_]*-[0-9]+$'

n1_blocker_watch_mode() {
    # Prints "http <url>" (Jira + curl + loopback Streamable HTTP url of versionMcp else mcp) or "pr-only".
    local mcp url
    mcp=$(n1_config_val '.tracker.versionMcp'); [ -n "$mcp" ] || mcp=$(n1_config_val '.tracker.mcp')
    if [ "$(n1_config_val '.tracker.type')" = jira ] && [ -n "$mcp" ] && command -v curl >/dev/null 2>&1 \
        && url=$(n1_mcp_http_url "$mcp"); then
        printf 'http %s\n' "$url"
    else
        echo pr-only
    fi
}

_n1_bw_resolved() {
    # Usage: _n1_bw_resolved <KEY> <mode> <url> <deployed> — rc 0 when the blocker's status category is Done,
    # its status name equals <deployed> (case-insensitive, skipped when empty), or its PR is merged.
    # The merged-PR rule must match references/blocker-check.md § 4 (CALLER=start): first matching PR, state MERGED.
    # Any read failure or unknown status counts as unresolved. Tracker text is compared, never echoed.
    # jc-mcp getIssue returns status as a bare name (no category), so the Done category comes from
    # jcm_searchIssues "key = <KEY> AND statusCategory = Done" returning a non-empty issues array.
    local k="$1" mode="$2" url="$3" dep="$4" f st=""
    if [ "$mode" = http ] && f=$(mktemp); then
        _N1_MCP_URL=""                      # fresh MCP session per check: 30 min outlives server sessions
        _N1_MCP_DEADLINE=$((SECONDS + 60))
        if n1_mcp_http_call "$url" jcm_getIssue "$(jq -nc --arg k "$k" '{issueKey:$k}')" > "$f"; then
            st=$(jq -r --arg d "$dep" '
                (.fields.status // .status) as $s
                | (if ($s | type) == "object" then ($s.name // "") else ($s // "") end) as $name
                | (if ($s | type) == "object" then ($s.statusCategory.key // "")
                   else (.statusCategory | if type == "object" then (.key // "") else (. // "") end) end) as $cat
                | if ($cat | ascii_downcase) == "done"
                     or ($d != "" and $name != "" and ($name | ascii_downcase) == ($d | ascii_downcase))
                  then "done" else "open" end' "$f" 2>/dev/null)
        fi
        if [ "$st" != done ] && n1_mcp_http_call "$url" jcm_searchIssues \
            "$(jq -nc --arg k "$k" '{jql:("key = " + $k + " AND statusCategory = Done"),maxResults:1}')" > "$f" \
            && jq -e '(.issues | type) == "array" and (.issues | length) > 0' "$f" >/dev/null 2>&1; then
            st=done
        fi
        _N1_MCP_DEADLINE=""; rm -f "$f"
        [ "$st" = done ] && return 0
    fi
    gh pr list --state all --search "$k in:title" --json number,title,headRefName,state --limit 5 2>/dev/null \
        | jq -e --arg k "$k" '
            ("(^|[^A-Za-z0-9_-])" + $k + "($|[^A-Za-z0-9_-])") as $re
            | [.[] | select(((.title // "") | test($re)) or ((.headRefName // "") | test($re)))][0].state == "MERGED"' \
            >/dev/null 2>&1
}

n1_blocker_watch() {
    # Usage: n1_blocker_watch <ID> <KEY>... — keys as argv only. Silent until exit, then ONE stdout line, rc 0:
    #   RESOLVED <ID>: blockers resolved (<KEYS>). Next: invoke skill n1-start with <ID>.
    #   TIMEOUT <ID> comment:posted|pending blocked (watch timed out after 3h): <OPEN KEYS>
    # Invalid ID/key or no keys: "ERROR bad-key", rc 2, before any sleep. Seams: N1_BW_INTERVAL, N1_BW_MAX_CHECKS.
    local id="${1:-}" k mode url dep i c=pending line all
    local -a keys open still
    [ $# -ge 2 ] || { echo "ERROR bad-key"; return 2; }
    shift
    for k in "$id" "$@"; do [[ "$k" =~ $N1_BW_KEY_RE ]] || { echo "ERROR bad-key"; return 2; }; done
    keys=("$@"); open=("$@")
    read -r mode url <<<"$(n1_blocker_watch_mode 2>/dev/null)"
    dep=$(n1_config_val '.tracker.statuses.deployed' 2>/dev/null)
    for ((i = 0; i < ${N1_BW_MAX_CHECKS:-6}; i++)); do
        sleep "${N1_BW_INTERVAL:-1800}" 2>/dev/null
        still=()
        for k in "${open[@]}"; do _n1_bw_resolved "$k" "$mode" "$url" "$dep" 2>/dev/null || still+=("$k"); done
        open=("${still[@]}")
        if [ ${#open[@]} -eq 0 ]; then
            all=$(printf '%s, ' "${keys[@]}"); all=${all%, }
            printf 'RESOLVED %s: blockers resolved (%s). Next: invoke skill n1-start with %s.\n' "$id" "$all" "$id"
            return 0
        fi
    done
    line=$(printf '%s, ' "${open[@]}"); line="blocked (watch timed out after 3h): ${line%, }"
    n1_append_escalation "$N1_HOME/memory/$id/overview.md" "- [watch] ticket: $line" >/dev/null 2>&1
    if [ "$mode" = http ]; then
        _N1_MCP_URL=""; _N1_MCP_DEADLINE=$((SECONDS + 60))
        # jc-mcp answers a declined write as a normal {ok:false} payload, so rc 0 alone is not "posted".
        if f=$(mktemp) && n1_mcp_http_call "$url" jcm_addComment "$(jq -nc --arg k "$id" \
            --arg b "N1 [blocker-watch] $id $line. Run /n1:n1-start $id to re-check."$'\n\n'"n1-esc:$id:ticket" \
            '{issueKey:$k,body:$b}')" > "$f" 2>/dev/null && jq -e '.ok != false' "$f" >/dev/null 2>&1; then
            c=posted
        fi
        rm -f "$f"
        _N1_MCP_DEADLINE=""
    fi
    printf 'TIMEOUT %s comment:%s %s\n' "$id" "$c" "$line"
}

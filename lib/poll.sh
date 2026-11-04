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

# N1-301: (poll:)/(monitor:) steps in n1-release custom procedures. Names keep the n1_wait_ prefix so the
# stuck-detector never records these calls (references/architecture.md, stuck detection).

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
    # cut at N1_WAIT_CHECK_TIMEOUT (default 60) seconds, clamped to the time left in the chunk; a cut check
    # counts as failed. First output line: poll -> "passed" | "pending <remaining-s>" | "timeout";
    # monitor -> "failed" (first non-zero check, at once) | "pending <remaining-s>" | "ok". Then the last
    # check's output (last 40 lines). rc 0 on passed/ok/pending, 1 on timeout/failed and on bad arguments
    # ("failed" + usage). Callers re-invoke with the <remaining-s> from "pending"; no state file.
    local mode="$1" remaining="$2" interval="$3" cmd="${4:-}"
    if ! { [ "$mode" = poll ] || [ "$mode" = monitor ]; } || ! [[ "$remaining" =~ ^[1-9][0-9]*$ ]] \
        || ! [[ "$interval" =~ ^[1-9][0-9]*$ ]] || [ -z "$cmd" ]; then
        printf 'failed\nusage: n1_wait_step <poll|monitor> <remaining-s> <interval-s> <command>\n'; return 1
    fi
    local start now end left t out rc rem nap
    start=$(date +%s)
    end=$(( start + (remaining < POLL_CHUNK_SECONDS ? remaining : POLL_CHUNK_SECONDS) ))
    while :; do
        now=$(date +%s); left=$(( end - now )); [ "$left" -lt 1 ] && left=1
        t=${N1_WAIT_CHECK_TIMEOUT:-60}; [[ "$t" =~ ^[1-9][0-9]*$ ]] || t=60; [ "$t" -gt "$left" ] && t=$left
        out=$(timeout -k 5 "$t" bash -c "$cmd" 2>&1); rc=$?
        { [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; } && out="check timed out after ${t}s"
        out=$(tail -n 40 <<<"$out")
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

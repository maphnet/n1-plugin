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
              ([.[] | select(.bucket == "pending")] | length)] | @tsv' 2>/dev/null) || counts=""
        if [ -n "$counts" ]; then
            local failed pending
            failed=$(printf '%s' "$counts" | cut -f1)
            pending=$(printf '%s' "$counts" | cut -f2)
            [ "$failed" -gt 0 ] 2>/dev/null && { printf 'red\n'; return 0; }
            [ "$pending" -eq 0 ] 2>/dev/null && { printf 'green\n'; return 0; }
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

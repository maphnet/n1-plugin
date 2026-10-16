#!/usr/bin/env bash
# Durable review receipts are independent of the optional telemetry lock.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/telemetry.sh"

n1_review_receipt() {
    local url="$1" sid
    sid=$(n1_session_id)
    [[ "$sid" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    [[ "$url" =~ ^https://github\.com/([a-zA-Z0-9_.-]+)/([a-zA-Z0-9_.-]+)/pull/([0-9]+)$ ]] || return 1
    printf '%s/review-receipts/%s/%s_%s_%s.json' "$(n1_home)" "$sid" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

n1_review_record() {
    local url="$1" outcome="$2" reason="${3:-}" processed="${4:-true}" comment="${5:-none}"
    local file tmp ID=""
    file=$(n1_review_receipt "$url") || return 1
    mkdir -p "$(dirname "$file")"
    tmp=$(mktemp "${file}.XXXXXX")
    jq -n --arg url "$url" --arg outcome "$outcome" --arg reason "$reason" \
        --argjson processed "$processed" --arg comment "$comment" \
        '{id:"codex-review",pr_url:$url,outcome:$outcome,reason:$reason,processed:$processed,comment:$comment}' > "$tmp"
    mv "$tmp" "$file"
    # Hooks identify a run only through its session-owned lock; no shared pointer.
    if n1_read_lock "${N1_HOME}/memory"; then
        ID="$N1_LOCK_TICKET_ID"
        n1_record_decision codex-review "$([ "$outcome" = ran ] && echo true || echo false)" \
            '{"config":"crossHostReview.enabled"}' "pr_url=$url" "outcome=$outcome" "reason=$reason" "comment=$comment"
    fi
}

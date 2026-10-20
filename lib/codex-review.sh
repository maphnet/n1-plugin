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

# N1-115: deterministic backstop for a PR created outside n1-pr (PostToolUse missed it).
# Prints each PR on the active run's branch lacking a processed receipt in any session, and
# records this session's skipped/step-not-run receipt so the Stop loop blocks once.
# Fail open: no pointer, empty/default branch, no gh, offline -> prints nothing, returns 0.
n1_review_check_run() {
    local run branch wt url receipt tmo=""
    run=$(n1_active_run_file) && [ -f "$run" ] || return 0
    # Only this session's keyed pointer; the unkeyed fallback may belong to a crashed run.
    case "$run" in */active-run.json) return 0 ;; esac
    branch=$(jq -r '.branch // empty' "$run" 2>/dev/null) || return 0
    case "$branch" in ""|main|master|HEAD) return 0 ;; esac
    command -v gh >/dev/null 2>&1 || return 0
    if command -v timeout >/dev/null 2>&1; then tmo="timeout 10"; fi   # macOS without coreutils: unbounded but stdin-closed
    wt=$(jq -r '.worktreePath // empty' "$run" 2>/dev/null) || wt=""
    while IFS= read -r url; do
        receipt=$(n1_review_receipt "$url") || continue
        # Receipts are per session; a resumed run counts any session's processed receipt.
        jq -se 'any(.[]; .processed == true)' "$(n1_home)"/review-receipts/*/"${receipt##*/}" >/dev/null 2>&1 && continue
        [ -f "$receipt" ] || n1_review_record "$url" skipped step-not-run false
        printf '%s\n' "$url"
    done < <(cd "${wt:-.}" 2>/dev/null && $tmo gh pr list --head "$branch" --json url -q '.[].url' </dev/null 2>/dev/null)
    return 0
}

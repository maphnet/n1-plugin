#!/usr/bin/env bash
# Durable review receipts are independent of the optional telemetry lock.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/telemetry.sh"

# Fixed, cwd-independent root: hooks, runner and finish may run from different repos.
n1_review_root() { printf '%s/review-receipts' "${N1_STATE_DIR:-$HOME/.n1}"; }

# N1-405: Codex runs before the PR exists, so receipts are keyed on the branch (KEY = branch, / -> _).
n1_review_receipt() {
    local key="${1//\//_}" sid
    sid=$(n1_session_id)
    [[ "$sid" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    [[ "$key" =~ ^[A-Za-z0-9._-]+$ && "$key" != .* ]] || return 1
    printf '%s/%s/%s.json' "$(n1_review_root)" "$sid" "$key"
}

# Outcome of a processed receipt for BRANCH in any session (legacy per-project root included); "ran" wins. Empty if none.
n1_review_outcome() {
    local receipt
    receipt=$(n1_review_receipt "$1") || return 0
    { cat "$(n1_review_root)"/*/"${receipt##*/}" "$(n1_home)"/review-receipts/*/"${receipt##*/}" 2>/dev/null || :; } \
        | jq -rs '[.[] | select(.processed == true) | (.outcome // "unknown")] | if index("ran") then "ran" else (last // empty) end' 2>/dev/null
}

n1_review_record() {
    n1_bind_run_to_ticket   # caller's ID, before the local ID below shadows it (N1-193)
    local branch="$1" outcome="$2" reason="${3:-}" processed="${4:-true}" comment="${5:-none}"
    local file tmp ID=""
    file=$(n1_review_receipt "$branch") || return 1
    mkdir -p "$(dirname "$file")"
    tmp=$(mktemp "${file}.XXXXXX")
    jq -n --arg branch "$branch" --arg outcome "$outcome" --arg reason "$reason" \
        --argjson processed "$processed" --arg comment "$comment" \
        '{id:"codex-review",branch:$branch,outcome:$outcome,reason:$reason,processed:$processed,comment:$comment}' > "$tmp"
    mv "$tmp" "$file"
    # Hooks identify a run only through its session-owned lock; no shared pointer.
    if n1_read_lock "${N1_HOME}/memory"; then
        ID="$N1_LOCK_TICKET_ID"
        n1_record_decision codex-review "$([ "$outcome" = ran ] && echo true || echo false)" \
            '{"config":"crossHostReview.enabled"}' "branch=$branch" "outcome=$outcome" "reason=$reason" "comment=$comment"
    fi
}

# Deterministic backstop for a PR whose pre-push Codex step never ran (PostToolUse missed it).
# When the active run's branch has a PR but no processed receipt in any session, prints the PR URLs and
# records this session's skipped/step-not-run receipt so the Stop loop blocks once.
# Fail open: no pointer, empty/default branch, no PR, no gh, offline -> prints nothing, returns 0.
n1_review_check_run() {
    local run branch wt urls receipt
    run=$(n1_active_run_file) && [ -f "$run" ] || return 0
    # Only this session's keyed pointer; the unkeyed fallback may belong to a crashed run.
    case "$run" in */active-run.json) return 0 ;; esac
    branch=$(jq -r '.branch // empty' "$run" 2>/dev/null) || return 0
    case "$branch" in ""|main|master|HEAD) return 0 ;; esac
    wt=$(jq -r '.worktreePath // empty' "$run" 2>/dev/null) || wt=""
    # No PR can exist before the first push; skip the network call (git error: fail open).
    [ -n "$(git -C "${wt:-.}" for-each-ref --count=1 --format=x "refs/remotes/*/$branch" 2>/dev/null)" ] || return 0
    command -v gh >/dev/null 2>&1 || return 0
    command -v timeout >/dev/null 2>&1 || return 0   # cannot bound the network call (macOS without coreutils): skip
    urls=$(cd "${wt:-.}" 2>/dev/null && timeout 10 gh pr list --head "$branch" --json url -q '.[].url' </dev/null 2>/dev/null) || return 0
    [ -n "$urls" ] || return 0
    [ -z "$(n1_review_outcome "$branch")" ] || return 0
    receipt=$(n1_review_receipt "$branch") || return 0
    [ -f "$receipt" ] || n1_review_record "$branch" skipped step-not-run false
    printf '%s\n' "$urls"
    return 0
}

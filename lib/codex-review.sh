#!/usr/bin/env bash
# Durable review receipts are independent of the optional telemetry lock.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/telemetry.sh"

# Fixed, cwd-independent root: hooks, runner and finish may run from different repos.
n1_review_root() { printf '%s/review-receipts' "${N1_STATE_DIR:-$HOME/.n1}"; }

# N1-405: Codex runs before the PR exists, so receipts are keyed on repo and branch (KEY = branch, / -> _).
# Repo slug: stable across worktrees of one clone. N1_REVIEW_DIR (default .) is the checkout used for git lookups.
n1_review_repo() {
    local gc base
    gc=$(git -C "${N1_REVIEW_DIR:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    base=$(printf '%s' "${gc%/*}" | sed 's|.*/||' | tr -c 'A-Za-z0-9._-' '_')
    printf '%s-%s' "${base#.}" "$(printf '%s' "$gc" | cksum | cut -d' ' -f1)"
}

# File name of BRANCH's receipt in this repo (no session dir): the one place the naming rule lives.
n1_review_name() {
    local key="${1//\//_}" repo h
    [[ "$key" =~ ^[A-Za-z0-9._-]+$ && "$key" != .* ]] || return 1
    repo=$(n1_review_repo) || return 1
    h=$(printf '%s' "$1" | cksum | cut -d' ' -f1)   # "/" -> "_" collides (a_b vs a/b): the hash keeps branches apart
    printf '%s__%s.%s.json' "$repo" "$key" "$h"
}

n1_review_receipt() {
    local sid name
    sid=$(n1_session_id)
    [[ "$sid" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    name=$(n1_review_name "$1") || return 1
    printf '%s/%s/%s' "$(n1_review_root)" "$sid" "$name"
}

# Outcome of a processed receipt for BRANCH of this repo in any session (legacy per-project root included); "ran" wins. Empty if none.
# A "ran" receipt counts only when its head is an ancestor of TIP (default HEAD); otherwise it is stale and ignored.
n1_review_outcome() {
    local receipt name f o h last="" tip="${2:-HEAD}"
    receipt=$(n1_review_receipt "$1") || return 0
    name=${receipt##*/}
    for f in "$(n1_review_root)"/*/"$name" "$(n1_home)"/review-receipts/*/"$name"; do
        [ -f "$f" ] || continue
        o=$(jq -r 'select(.processed == true) | (.outcome // "unknown")' "$f" 2>/dev/null) || continue
        [ -n "$o" ] || continue
        if [ "$o" = ran ]; then
            h=$(jq -r '.head // empty' "$f" 2>/dev/null)
            [[ "$h" =~ ^[0-9a-f]{40,64}$ ]] && git -C "${N1_REVIEW_DIR:-.}" merge-base --is-ancestor "$h" "$tip" 2>/dev/null || continue
            printf 'ran'; return 0
        fi
        last=$o
    done
    printf '%s' "$last"
}

# After a clean rebase (PRE = pre-rebase tip, new tip = HEAD): move a "ran" receipt head that was an ancestor of PRE to HEAD.
n1_review_reanchor() {
    local pre="$1" name f h new tmp
    [[ "$pre" =~ ^[0-9a-f]{40,64}$ ]] || return 0
    name=$(n1_review_receipt "$(git -C "${N1_REVIEW_DIR:-.}" branch --show-current 2>/dev/null)") || return 0
    name=${name##*/}
    new=$(git -C "${N1_REVIEW_DIR:-.}" rev-parse HEAD 2>/dev/null) || return 0
    for f in "$(n1_review_root)"/*/"$name" "$(n1_home)"/review-receipts/*/"$name"; do
        [ -f "$f" ] || continue
        h=$(jq -r 'select(.outcome == "ran") | .head // empty' "$f" 2>/dev/null)
        [[ "$h" =~ ^[0-9a-f]{40,64}$ ]] && git -C "${N1_REVIEW_DIR:-.}" merge-base --is-ancestor "$h" "$pre" 2>/dev/null || continue
        tmp=$(mktemp "$f.XXXXXX") || continue
        jq --arg h "$new" '.head = $h' "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f" || rm -f "$tmp"
    done
    return 0
}

# N1-405 SEC-3: a failed scope-gate cleanup leaves unvetted commits (or edits) on the branch. The marker holds the run-start SHA;
# every push path calls n1_codex_gate_check and refuses while HEAD differs. It is removed only when HEAD equals that SHA.
n1_codex_gate_block() {   # ID VALUE
    [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ && -n "${N1_HOME:-}" ]] || return 0
    mkdir -p "$N1_HOME/memory/$1" && printf '%s\n' "${2:-unknown}" > "$N1_HOME/memory/$1/codex-gate-blocked"
}
n1_codex_gate_check() {   # ID
    local m s
    [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ && -n "${N1_HOME:-}" ]] || return 0
    m="$N1_HOME/memory/$1/codex-gate-blocked"
    [ -e "$m" ] || return 0
    s=$(cat "$m" 2>/dev/null)
    if [ -n "$s" ] && [ "$s" = "$(git rev-parse HEAD 2>/dev/null)" ]; then rm -f "$m"; return 0; fi
    echo "push:blocked-by-codex-gate"; return 1
}
# CR-1: uncommitted tracked edits left by the Codex developer are saved (mode 600) and removed from the tree. Prints tree:* lines.
# A failure blocks the push like kept= (marker value never equals HEAD, so it is cleared by hand).
n1_codex_tree_restore() {   # ID
    local patch="$N1_HOME/memory/$1/codex-uncommitted.patch"
    [ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] && return 0
    echo "tree:dirty"
    if mkdir -p "$N1_HOME/memory/$1" && { (umask 077; rm -f "$patch"; git diff --binary --no-color --no-ext-diff --no-textconv HEAD > "$patch") 2>/dev/null; } \
        && [ -s "$patch" ] && git restore --staged --worktree -- . 2>/dev/null \
        && [ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        echo "tree:restored patch=$patch"
    else
        echo "tree:restore-failed"
        n1_codex_gate_block "$1" "dirty-tree"
        return 1
    fi
}

n1_review_record() {
    n1_bind_run_to_ticket   # caller's ID, before the local ID below shadows it (N1-193)
    local branch="$1" outcome="$2" reason="${3:-}" processed="${4:-true}" comment="${5:-none}"
    local file tmp repo head ID=""
    file=$(n1_review_receipt "$branch") || return 1
    repo=$(n1_review_repo) || return 1
    head=$(git -C "${N1_REVIEW_DIR:-.}" rev-parse HEAD 2>/dev/null) || head=""
    mkdir -p "$(dirname "$file")"
    tmp=$(mktemp "${file}.XXXXXX")
    jq -n --arg branch "$branch" --arg repo "$repo" --arg head "$head" --arg outcome "$outcome" --arg reason "$reason" \
        --argjson processed "$processed" --arg comment "$comment" \
        '{id:"codex-review",branch:$branch,repo:$repo,head:$head,outcome:$outcome,reason:$reason,processed:$processed,comment:$comment}' > "$tmp"
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
    local -x N1_REVIEW_DIR="${wt:-.}"   # receipts are repo-scoped: look them up from the run's checkout
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

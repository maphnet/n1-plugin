#!/usr/bin/env bash
# N1 queue chain (N1-447): rebases a queue branch that was cut from a predecessor queue branch once the predecessor's
# final PR merged. Usage: n1-queue-chain.sh <queue.md>... | --all   (--all: every $N1_HOME/queue/*/queue.md)
# Callers: the runner's final_prs (its own queue.md, every --run) and n1-finish steps/07-queue-chain.md (--all).
# Per "## Predecessor" row with status waiting, in an integration: queue queue with no open Plan row (no child PR is in
# flight against the branch), the predecessor final PR is re-derived through gh (queue.md is child-writable):
#   OPEN or unreadable: nothing; a later trigger retries. CLOSED, or MERGED from another branch or into another base:
#   stopped. MERGED with a headRefOid other than the row's Head (gained commits after the cut): stopped.
#   Else: rebase --onto origin/<default> <Base> in a detached worktree under the queue dir (the user's checkout is never
#   touched), then a push with a lease on the fetched tip. Conflict: stopped. Push refused: stays waiting. Success:
#   rebased, queues waiting on this branch get the new tip as Head, and an open final PR gets its body refreshed (and
#   is marked ready when every child landed).
# Every stop is recorded (row status, Final PRs Note when the repo has a row, queue_chain_* event) and sent as a
# needs-you notice. Exit 0; 2 on a usage error.
set -uo pipefail

N1_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export N1_ROOT
: "${CLAUDE_PLUGIN_ROOT:=$N1_ROOT}"; export CLAUDE_PLUGIN_ROOT
source "$N1_ROOT/lib/config.sh"
source "$N1_ROOT/lib/frontmatter.sh"
source "$N1_ROOT/lib/queue.sh"
source "$N1_ROOT/lib/orca-queue.sh"
[ -n "${N1_HOME:-}" ] || N1_HOME=$(n1_home)
export N1_HOME

case "${1:-}" in
    --all) set -- "$N1_HOME"/queue/*/queue.md ;;
    ''|-*) echo "usage: n1-queue-chain.sh <queue.md>... | --all" >&2; exit 2 ;;
esac

# record <status> <event> <reason> <hint> — the row outcome: status, Final PRs Note, event, needs-you notice. No git.
record() {
    local fu fd fm
    n1_queue_pred_set "$Q" "$REPO" "$PQ" "$PB" "$PU" "$BASE" "$HEAD" "$1" || echo "queue chain: $REPO row not recorded in queue.md"
    # n1_queue_final_prs prints "repo\tpr\tdraft\tmergeable\tnote": skip the repo cell, keep pr, draft and mergeable.
    IFS=$'\t' read -r _ fu fd fm _ <<< "$(n1_queue_final_prs "$Q" | awk -F'\t' -v r="$REPO" '$1 == r')"
    [ -z "$fu" ] || n1_queue_final_pr_set "$Q" "$REPO" "$fu" "$fd" "$fm" "chain: $3" || true
    n1_queue_event "$(dirname "$Q")/events.jsonl" "$QID" "$RID" "$2" pr="$PU" reason="$3"
    # </dev/null: the caller loops over a here-string and a notifier must not consume the remaining rows.
    n1_notify needs-you "Queue $QID: $3 for ${OWN:-its queue branch} in $REPO (predecessor $PB, $PU); $4" </dev/null
    echo "queue chain: $REPO $3"
}

sync_row() {
    local N1H def nwo st pbase phead pref old new wt body counts nr fu fisd fm f r q b u bs s
    OWN=$(n1_queue_story_branch_get "$Q" "$REPO")
    { [[ "$OWN" == queue/* ]] && _n1_queue_valid_branch "$OWN"; } \
        || { OWN=""; record stopped queue_chain_stopped "own queue branch unreadable" "fix ## Story Branches in queue.md"; return; }
    N1H=$(n1_queue_pending_rows "$Q" '.*' | awk -F'\t' -v r="$REPO" '$3 == r { print $4; exit }')
    def=$(N1_HOME="${N1H:-$N1_HOME}" n1_config_val '.git.defaultBranch' 2>/dev/null); def="${def:-main}"
    _n1_queue_valid_branch "$def" || { record stopped queue_chain_stopped "invalid default branch" "fix git.defaultBranch"; return; }
    nwo=$(cd "$REPO" 2>/dev/null && timeout -k 30 30 gh repo view --json nameWithOwner -q .nameWithOwner </dev/null 2>/dev/null)
    [ -n "$nwo" ] || { echo "queue chain: $REPO repo unreadable; a later trigger retries"; return; }
    [[ "$PU" =~ ^https://github\.com/"$nwo"/pull/[0-9]+$ ]] \
        || { record stopped queue_chain_stopped "predecessor PR outside $nwo" "fix ## Predecessor in queue.md"; return; }
    IFS=$'\t' read -r st pbase phead <<< "$(n1_queue_pr_view "$PU")"
    case "$st" in
        OPEN) echo "queue chain: $REPO $PB not merged yet"; return ;;
        CLOSED) record stopped queue_chain_stopped "predecessor closed unmerged" "rebase or re-cut $OWN by hand"; return ;;
        MERGED) ;;
        *) echo "queue chain: $REPO predecessor PR state unreadable; a later trigger retries"; return ;;
    esac
    pref=$(timeout -k 30 30 gh pr view --json headRefName -q .headRefName -- "$PU" </dev/null 2>/dev/null)
    { [ "$pbase" = "$def" ] && [ "$pref" = "$PB" ]; } \
        || { record stopped queue_chain_stopped "predecessor merged from another branch or into another base" "rebase $OWN by hand"; return; }
    # A squash merge leaves the predecessor tip outside the default branch history, so the PR head is compared instead.
    [ "$phead" = "$HEAD" ] || { record stopped queue_chain_stopped "predecessor gained commits after cut" "rebase $OWN onto $def by hand"; return; }
    git -C "$REPO" fetch -q origin "+refs/heads/$def:refs/remotes/origin/$def" "+refs/heads/$OWN:refs/remotes/origin/$OWN" </dev/null >/dev/null 2>&1 \
        || { echo "queue chain: $REPO fetch failed; a later trigger retries"; return; }
    old=$(git -C "$REPO" rev-parse -q --verify "refs/remotes/origin/$OWN^{commit}" 2>/dev/null)
    git -C "$REPO" merge-base --is-ancestor "$BASE" "$old" 2>/dev/null \
        || { record stopped queue_chain_stopped "base not in $OWN history" "rebase $OWN by hand"; return; }
    wt="$(dirname "$Q")/chain-$$"
    git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true
    git -C "$REPO" worktree add -q --detach "$wt" "$old" </dev/null >/dev/null 2>&1 \
        || { echo "queue chain: $REPO worktree failed; a later trigger retries"; return; }
    if ! git -C "$wt" rebase -q --onto "refs/remotes/origin/$def" "$BASE" </dev/null >/dev/null 2>&1; then
        git -C "$wt" rebase --abort >/dev/null 2>&1
        git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true
        record stopped queue_chain_stopped "rebase conflict" "rebase $OWN onto $def by hand"; return
    fi
    new=$(git -C "$wt" rev-parse HEAD)
    # The lease pins the fetched tip: anything pushed to $OWN after the fetch makes this push fail instead of being lost.
    if ! git -C "$wt" push -q "--force-with-lease=refs/heads/$OWN:$old" origin "HEAD:refs/heads/$OWN" </dev/null >/dev/null 2>&1; then
        git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true
        record waiting queue_chain_push_failed "chain-push-failed" "a later /n1:n1-queue --run $QID or n1-finish retries"; return
    fi
    git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true
    n1_queue_pred_set "$Q" "$REPO" "$PQ" "$PB" "$PU" "$BASE" "$HEAD" rebased || echo "queue chain: $REPO row not recorded in queue.md"
    n1_queue_event "$(dirname "$Q")/events.jsonl" "$QID" "$RID" queue_chain_rebased pr="$PU" reason="$OWN $old -> $new"
    echo "queue chain: $REPO $OWN rebased onto $def ($new)"
    # Chain of 3: queues waiting on this branch now expect its new tip at their predecessor's merge; Base stays.
    for f in "$N1_HOME"/queue/*/queue.md; do
        { [ -f "$f" ] && ! [ "$f" -ef "$Q" ]; } || continue
        while IFS=$'\t' read -r r q b u bs _ s; do
            { [ "$q" = "${OWN#queue/}" ] && [ "$s" = waiting ]; } || continue
            n1_queue_pred_set "$f" "$r" "$q" "$b" "$u" "$bs" "$new" waiting && echo "queue chain: $f now expects $OWN at $new"
        done <<< "$(n1_queue_preds "$f")"
    done
    # An open final PR gets the body without the predecessor line; it is marked ready only when every child landed.
    body="$(dirname "$Q")/chain-body.md"
    counts=$(n1_queue_final_body "$Q" "$REPO" "${OWN#queue/}" "$body" queue) || return
    read -r _ nr <<< "$counts"
    IFS=$'\t' read -r fu fisd <<< "$(n1_queue_final_pr_find "$nwo" "$OWN" "$def")"
    [ -n "$fu" ] || return
    timeout -k 30 30 gh pr edit --body-file "$body" -- "$fu" </dev/null >/dev/null 2>&1 || echo "queue chain: $REPO final PR body not refreshed"
    if [ "$nr" = 0 ] && [ "$fisd" = true ] && timeout -k 30 30 gh pr ready -- "$fu" </dev/null >/dev/null 2>&1; then
        IFS=$'\t' read -r _ _ _ fm _ <<< "$(n1_queue_final_prs "$Q" | awk -F'\t' -v r="$REPO" '$1 == r')"
        n1_queue_final_pr_set "$Q" "$REPO" "$fu" ready "${fm:--}" "rebased onto $def" || true
        echo "queue chain: $REPO final PR $fu marked ready"
    fi
}

for Q in "$@"; do
    { [ -f "$Q" ] && [ "$(n1_read_frontmatter "$Q" integration)" = queue ]; } || continue
    QID=$(n1_read_frontmatter "$Q" queue_id); RID=$(n1_read_frontmatter "$Q" run_id)
    ROWS=$(n1_queue_preds "$Q" | awk -F'\t' '$7 == "waiting"')
    [ -n "$ROWS" ] || continue
    if [ -n "$(n1_queue_pending_rows "$Q" 'pending|held|in-progress|awaiting-human')" ]; then
        echo "queue chain: $QID skipped (rows still open)"; continue
    fi
    while IFS=$'\t' read -r REPO PQ PB PU BASE HEAD _; do OWN=""; sync_row; done <<< "$ROWS"
done
exit 0

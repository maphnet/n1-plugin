#!/usr/bin/env bash
# N1 queue chain (N1-447): rebases a queue branch that was cut from a predecessor queue branch once the predecessor's
# final PR merged. Usage: n1-queue-chain.sh <queue.md>... | --all   (--all: every $N1_HOME/queue/*/queue.md)
# Options before the files: --own <queue/id> (the caller's queue branch; else it must be queue/<queue dir name>-<UTC stamp>),
# --pred <PR url> (only rows waiting on that PR). Callers: the runner's final_prs (its own queue.md, --own, every --run) and
# n1-finish steps/07-queue-chain.md (--all --pred <merged final PR>).
# Per "## Predecessor" row with status waiting, in an integration: queue queue with no open Plan row and no child PR still
# open against the branch, the predecessor final PR is re-derived through gh (queue.md is child-writable). Row cells that
# name a git target are bound: the repo path must be its own toplevel, the queue branch must belong to this queue, Base must
# be an ancestor of the predecessor PR head fetched from origin, and git runs with hooks disabled:
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

OWN_ARG=""; PRED_ARG=""
while :; do
    case "${1:-}" in
        --own) OWN_ARG="${2:-}"; shift $(($# > 1 ? 2 : 1)) ;;
        --pred) PRED_ARG="${2:-}"; shift $(($# > 1 ? 2 : 1)) ;;
        *) break ;;
    esac
done
G() { git -c core.hooksPath=/dev/null "$@"; }
case "${1:-}" in
    --all) set -- "$N1_HOME"/queue/*/queue.md ;;
    ''|-*) echo "usage: n1-queue-chain.sh [--own <queue/id>] [--pred <pr-url>] <queue.md>... | --all" >&2; exit 2 ;;
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

# mk <repo> — the per-repo marker of a pushed-but-not-fully-recorded rebase: "<old tip> <new tip>" (queue dir, child-writable
# like queue.md, but it only ever selects a tip that must still equal origin's branch tip).
mk() { echo "$(dirname "$Q")/.chain-push-$(cksum <<< "$1" | cut -d' ' -f1)"; }

# after_push <old> <new> <def> <nwo> — records a pushed rebase and updates the queues waiting on this branch. The marker is
# removed last, so an interruption anywhere in here is replayed by the next trigger.
after_push() {
    local old="$1" new="$2" def="$3" nwo="$4" f r q b u bs s mf
    n1_queue_pred_set "$Q" "$REPO" "$PQ" "$PB" "$PU" "$BASE" "$HEAD" rebased || { echo "queue chain: $REPO row not recorded in queue.md; a later trigger retries"; return 1; }
    n1_queue_event "$(dirname "$Q")/events.jsonl" "$QID" "$RID" queue_chain_rebased pr="$PU" reason="$OWN $old -> $new"
    echo "queue chain: $REPO $OWN rebased onto $def ($new)"
    # Chain of 3: queues waiting on this branch now expect its new tip at their predecessor's merge. Base stays (the cut
    # point in their history); the marker records that the rewritten head replaced the tip Base was cut from.
    for f in "$N1_HOME"/queue/*/queue.md; do
        { [ -f "$f" ] && ! [ "$f" -ef "$Q" ]; } || continue
        while IFS=$'\t' read -r r q b u bs _ s; do
            { [ "$r" = "$REPO" ] && [ "$q" = "${OWN#queue/}" ] && [ "$s" = waiting ]; } || continue
            [ "$bs" = "$old" ] || continue
            mf="$(dirname "$f")/.chain-rebased-$(cksum <<< "$r $q" | cut -d' ' -f1)"
            echo "$bs $new" > "$mf" || continue
            n1_queue_pred_set "$f" "$r" "$q" "$b" "$u" "$bs" "$new" waiting && echo "queue chain: $f now expects $OWN at $new"
        done <<< "$(n1_queue_preds "$f")"
    done
    rm -f "$(mk "$REPO")"
}

sync_row() {
    local N1H def nwo st pbase phead pref old new wt body counts nr fu fisd fm b pn top cn cr cu cs mo mn rb ok
    OWN=$(n1_queue_story_branch_get "$Q" "$REPO")
    # The branch is force-pushed, so it must belong to this queue: the caller's own, else queue/<queue dir name>-<UTC stamp>
    # (the reduction n1-queue-run.sh applies to the queue id).
    b=$(basename "$(dirname "$Q")" | tr -c 'A-Za-z0-9\n' '-' | sed 's/^-*//')
    { [[ "$OWN" == queue/* ]] && _n1_queue_valid_branch "$OWN" \
        && if [ -n "$OWN_ARG" ]; then [ "$OWN" = "$OWN_ARG" ]; else [[ "$OWN" =~ ^queue/${b}-[0-9]{8}T[0-9]{6}Z$ ]]; fi; } \
        || { OWN=""; record stopped queue_chain_stopped "own queue branch unreadable or not this queue's" "fix ## Story Branches in queue.md"; return; }
    top=$(G -C "$REPO" rev-parse --show-toplevel 2>/dev/null)
    { [ -n "$top" ] && [ "$top" -ef "$REPO" ]; } \
        || { record stopped queue_chain_stopped "repo path is not a git toplevel" "fix the Repo cell in queue.md"; return; }
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
    # A not-landed child whose PR is still open is based on $OWN; rewriting the branch would reintroduce the predecessor commits.
    while IFS=$'\t' read -r _ cn cr _; do
        [ "$cr" = "$REPO" ] && [ "$(_n1_queue_run_outcome "$Q" "$cn")" != merged ] || continue
        cu=$(awk -F'|' -v tk="$cn" '/^## Runs/ { f = 1; next } /^## / { f = 0 }
            f && index($0, "| " tk " |") == 1 { p = $6 } END { gsub(/^[[:space:]]+|[[:space:]]+$/, "", p); print p }' "$Q")
        [[ "$cu" =~ ^https://github\.com/"$nwo"/pull/[0-9]+$ ]] || continue
        IFS=$'\t' read -r cs _ <<< "$(n1_queue_pr_view "$cu")"
        [ "$cs" = OPEN ] && { echo "queue chain: $REPO child PR $cu still open against $OWN; a later trigger retries"; return; }
    done < <(n1_queue_pending_rows "$Q" '.*')
    pn=${PU##*/}
    G -C "$REPO" fetch -q origin "+refs/heads/$def:refs/remotes/origin/$def" "+refs/heads/$OWN:refs/remotes/origin/$OWN" \
        "+refs/pull/$pn/head:refs/remotes/origin/n1-pred-$pn" </dev/null >/dev/null 2>&1 \
        || { echo "queue chain: $REPO fetch failed; a later trigger retries"; return; }
    old=$(G -C "$REPO" rev-parse -q --verify "refs/remotes/origin/$OWN^{commit}" 2>/dev/null)
    # A push that went through but was not fully recorded (marker: old, new tip) is resumed, not re-validated: the branch
    # was rewritten, so Base is no longer in its history.
    read -r mo mn < "$(mk "$REPO")" 2>/dev/null || true
    if [ -n "${mn:-}" ] && [ "$old" = "$mn" ]; then
        new="$mn"
        after_push "$mo" "$new" "$def" "$nwo" || return
    else
        # Base is the cut point and the rebase drops everything up to it: it must lie inside the merged predecessor PR's
        # history. When the predecessor was itself rebased, its rewritten head no longer holds Base; the marker written by
        # that rebase (Base, new head) stands in for it, still bound to the row's Head by the check above.
        ok=0
        [ "$(G -C "$REPO" rev-parse -q --verify "refs/remotes/origin/n1-pred-$pn^{commit}" 2>/dev/null)" = "$phead" ] && ok=1
        if [ "$ok" = 1 ]; then
            rb=$(cat "$(dirname "$Q")/.chain-rebased-$(cksum <<< "$REPO $PQ" | cut -d' ' -f1)" 2>/dev/null)
            [ "$rb" = "$BASE $phead" ] || G -C "$REPO" merge-base --is-ancestor "$BASE" "$phead" 2>/dev/null || ok=0
        fi
        { [ "$ok" = 1 ] && G -C "$REPO" merge-base --is-ancestor "$BASE" "$old" 2>/dev/null; } \
            || { record stopped queue_chain_stopped "base not in the predecessor PR and $OWN history" "rebase $OWN by hand"; return; }
        wt="$(dirname "$Q")/chain-$$"
        G -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true
        G -C "$REPO" worktree add -q --detach "$wt" "$old" </dev/null >/dev/null 2>&1 \
            || { echo "queue chain: $REPO worktree failed; a later trigger retries"; return; }
        if ! G -C "$wt" rebase -q --onto "refs/remotes/origin/$def" "$BASE" </dev/null >/dev/null 2>&1; then
            G -C "$wt" rebase --abort >/dev/null 2>&1
            G -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true
            record stopped queue_chain_stopped "rebase conflict" "rebase $OWN onto $def by hand"; return
        fi
        new=$(G -C "$wt" rev-parse HEAD)
        echo "$old $new" > "$(mk "$REPO")" || { G -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true; echo "queue chain: $REPO marker not written; a later trigger retries"; return; }
        # The lease pins the fetched tip: anything pushed to $OWN after the fetch makes this push fail instead of being lost.
        if ! G -C "$wt" push -q "--force-with-lease=refs/heads/$OWN:$old" origin "HEAD:refs/heads/$OWN" </dev/null >/dev/null 2>&1; then
            rm -f "$(mk "$REPO")"
            G -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true
            record waiting queue_chain_push_failed "chain-push-failed" "a later /n1:n1-queue --run $QID or n1-finish retries"; return
        fi
        G -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true
        after_push "$old" "$new" "$def" "$nwo" || return
    fi
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
    # A rebased row with a marker is a pushed rebase whose bookkeeping was interrupted: it is resumed too.
    ROWS=""
    while IFS=$'\t' read -r REPO PQ PB PU BASE HEAD st; do
        { [ "$st" = waiting ] || { [ "$st" = rebased ] && [ -f "$(mk "$REPO")" ]; }; } \
            && { [ -z "$PRED_ARG" ] || [ "$PU" = "$PRED_ARG" ]; } \
            && ROWS+="$REPO"$'\t'"$PQ"$'\t'"$PB"$'\t'"$PU"$'\t'"$BASE"$'\t'"$HEAD"$'\t'"$st"$'\n'
    done <<< "$(n1_queue_preds "$Q")"
    ROWS=${ROWS%$'\n'}
    [ -n "$ROWS" ] || continue
    if [ -n "$(n1_queue_pending_rows "$Q" 'pending|held|in-progress|awaiting-human')" ]; then
        echo "queue chain: $QID skipped (rows still open)"; continue
    fi
    while IFS=$'\t' read -r REPO PQ PB PU BASE HEAD _; do OWN=""; sync_row; done <<< "$ROWS"
done
exit 0

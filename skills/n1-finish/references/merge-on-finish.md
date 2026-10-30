# Step 2 § 3.1 and § 3.4: Merge on Finish

Read from `steps/02-merge.md` § 3.1 only when the entry printed `merge-on-finish:yes` and the PR is `OPEN`; it is not read at entry. The escalation and Queue-runs rules at the top of `02-merge.md` apply to every **STOP** here. § 3.2 (deployment actions) stays in `02-merge.md` and runs between § 3.1 and § 3.4.

## 3.1 Pre-merge checks

One Bash call:
```bash
source ~/.n1/preamble.sh
N="<n>"; case "$N" in ""|*[!0-9]*) echo pr:invalid; exit 1;; esac
V=$(gh pr view "$N" --json headRefOid,isDraft,mergeStateStatus -q '"head:"+.headRefOid+" draft:"+(.isDraft|tostring)+" state:"+.mergeStateStatus' 2>/dev/null) || V="head: draft:false state:"
echo "$V"
echo "pin:$(n1_review_pin get "$N")"
C=$(gh pr checks "$N" --json bucket --jq '"checks:fail="+([.[]|select(.bucket=="fail" or .bucket=="cancel")]|length|tostring)+" pending="+([.[]|select(.bucket=="pending")]|length|tostring)' 2>&1)
case "$C" in checks:*) echo "$C";; *"no checks reported"*) if grep -qsE 'pull_request' "$(git rev-parse --show-toplevel)/.github/workflows/"*.y*ml; then echo checks:expected; else echo checks:none; fi;; *) echo "checks:error ${C:0:200}";; esac
R=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
echo "codex:$(cat "${N1_STATE_DIR:-$HOME/.n1}"/review-receipts/*/"${R//\//_}_$N.json" "$N1_HOME"/review-receipts/*/"${R//\//_}_$N.json" 2>/dev/null | jq -rs 'if length==0 then "none" elif any(.[]; .outcome=="ran") then "ran" else "not-ran" end' 2>/dev/null)"
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){totalCount nodes{isResolved}}}}}' -f o="${R%/*}" -f r="${R#*/}" -F n="$N" --jq '.data.repository.pullRequest.reviewThreads|if .totalCount>(.nodes|length) then "threads:truncated" else "threads:"+([.nodes[]|select(.isResolved|not)]|length|tostring) end' 2>/dev/null || echo threads:error
```
- `pr:invalid` → **STOP.**
- `checks:error <msg>` → "Could not read the CI checks of PR #<n> (<msg>). Re-run `/n1:n1-finish`, or merge it yourself." **STOP.**
- `checks:fail=<k>` with `<k>` > 0 → "CI is failing on PR #<n> (<k> failed or cancelled checks). Fix CI, then re-run `/n1:n1-finish`." **STOP.**
- `pending=<k>` with `<k>` > 0 → "CI is still running on PR #<n>. Re-run `/n1:n1-finish` when it finishes." **STOP.**
- `checks:expected` (no checks yet, but the repo has a `pull_request` workflow) → "CI has not started on PR #<n>; re-run when it reports, or merge it yourself, then re-run `/n1:n1-finish`." **STOP.**
- `checks:none` (no CI in this repo) or `checks:fail=0 pending=0` → continue.
- `head:` empty → "Could not read the head commit of PR #<n>. Re-run `/n1:n1-finish`." **STOP.**
- `pin:` empty (no reviewed-head pin: the PR was not created by n1-pr, or predates N1-141) → with `headless:yes` or `queue-run:yes`: "No reviewed-head pin recorded for PR #<n>; N1 does not pin unattended." **STOP.** Otherwise follow `<N1_ROOT>/skills/n1-finish/references/resolve-dirty.md` § Re-pin (read it now; it is not read at entry): after the user confirms, it pins the current head and this list continues with `<head>` as the pin. Never pin without that confirmation.
- `pin:unavailable` (the pin lookup failed) → "Could not read the reviewed-head pin for PR #<n>. Re-run `/n1:n1-finish`, or merge it yourself." **STOP.**
- `pin:<sha>` not equal to `head:<sha>` → "PR #<n> head <first 7 of head> differs from the reviewed head <first 7 of pin>: commits were pushed after review. Review them (`/n1:n1-review`), then merge it yourself and re-run `/n1:n1-finish`." **STOP**, unless the **Re-pin** line below applies. Otherwise keep the pin as `<head>` for 3.4.
- **Re-pin** (`pin:<sha>` not equal to `head:<sha>` only; an empty pin uses § Re-pin above, and `pin:unavailable` always stops): with `headless:yes` or `queue-run:yes` → "PR #<n> has no valid reviewed-head pin; N1 does not re-review and re-pin unattended." **STOP.** A differing pin after a re-pin attempt in this run → the STOP message above. Otherwise (first in this run), once every other line of this list has passed (threads answered; a `state:DIRTY` or `state:BEHIND` waits, since resolve-dirty needs a valid pin), follow `<N1_ROOT>/skills/n1-finish/references/repin.md` (read it now; it is not read at entry) with the STOP message above as `<message>`. It asks the user, re-reviews the checked-out PR branch (`/n1:n1-review --full`), pushes its fixes, re-pins the new head, waits for CI and re-runs this list. Each of its STOPs ends the run.
- `draft:true` → "PR #<n> is a draft. Mark it ready (`gh pr ready <n>`), then re-run `/n1:n1-finish`." **STOP.** `state:BLOCKED`, or `state:DIRTY` / `BEHIND` after a resolve attempt in this run (from this list or from 3.4) → "PR #<n> cannot merge yet (conflicts / required review or checks missing / branch behind base). Fix that, then re-run `/n1:n1-finish`." **STOP.** Other states continue.
- `state:DIRTY` or `state:BEHIND` (first in this run) → once every other line of this list has passed (threads answered), follow `<N1_ROOT>/skills/n1-finish/references/resolve-dirty.md` (read it now unless already read in this run; it is not read at entry). It rebases the PR branch onto its base, re-bumps conflicting version manifests, hands other conflicts to the developer persona, pushes, advances the pin, waits for CI and re-runs this list. Queue and headless runs follow it too (`merge-on-finish:yes` there already requires `autonomy.fullAuto`). Each of its STOPs ends the run; in a headless or queue run it is also recorded as an escalation with a `N1 [headless]` tracker comment.
- `codex:not-ran` or `codex:none` (no Codex review of this PR ran; the pin only means "the head N1 pushed after local review") → print one informational line, "Note: no completed Codex review is recorded for PR #<n>; merging the head N1 pushed after local review." Do not stop.
- `threads:0` → Step 6 `Comments:` is `no unresolved comments`.
- `threads:error` / `threads:truncated` (API error, or more than 100 threads) / `threads:<k>` with `<k>` > 0 → with `headless:yes` or `queue-run:yes`, do not ask: "PR #<n> has unresolved or unverifiable review threads; N1 did not merge it." **STOP.** Otherwise ask the user:
  ```
  PR #<n> has unresolved or unverifiable review threads (<k>, or "unknown" on error or truncation). Proceed with merge?
  No recommendation. The options are equivalent given the available evidence; select based on team preference.
  1 — Yes, merge anyway
  2 — No, stop (resolve the threads, then re-run /n1:n1-finish)
  ```
  **1** → `Comments:` is `<k> unresolved, user approved merge` (`unverified, user approved merge` when unknown). **2** → "Merge stopped: PR #<n> has unresolved review threads." **STOP.**

## 3.4 Merge

Merge directly: no auto-merge, no remote-branch deletion (Step 6 leaves that to the repo settings), no retry except the single resolve-then-retry below. The key is the user's consent; do not ask again. One Bash call; `<head>` is the reviewed-head pin from 3.1 (the block re-checks it against the pin, and `--match-head-commit` makes GitHub refuse if the PR head moved since), `<mergeMethod>` is the entry's `finishWork.mergeMethod` (empty means squash):
```bash
source ~/.n1/preamble.sh
[ "$(n1_merge_authorized)" = true ] || { echo merge:denied; exit 1; }
N="<n>"; H="<head>"; MM="<mergeMethod>"
case "$N" in ""|*[!0-9]*) echo pr:invalid; exit 1;; esac
[[ "$H" =~ ^[0-9a-f]{40}$ ]] || { echo head:invalid; exit 1; }
case "${MM:-squash}" in squash|merge|rebase) MM=${MM:-squash};; *) echo method:invalid; exit 1;; esac
[ "$(n1_review_pin get "$N")" = "$H" ] || { echo pin:mismatch; exit 1; }
echo "mergeOnFinish=true: merging PR #$N ($MM)"
gh pr merge "$N" "--$MM" --match-head-commit "$H" 2>&1; E=$?; echo "merge-exit:$E"
gh pr view "$N" --json state,mergeCommit -q '"state:"+.state+" sha:"+(.mergeCommit.oid // "")'
if [ "$E" != 0 ]; then
  P=${MERGE_REREAD_POLLS:-5}; MS=
  for i in $(seq "$P"); do
    MS=$(gh pr view "$N" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null)
    { [ "$MS" = UNKNOWN ] || [ "$MS" = CLEAN ]; } && [ "$i" -lt "$P" ] || break
    sleep "${MERGE_REREAD_SLEEP:-3}"
  done
  echo "mss:$MS"
fi
```
- `merge:denied` → "Merge is not authorized in this run." **STOP.**
- `pr:invalid` / `head:invalid` / `method:invalid` → report it ("`finishWork.mergeMethod` must be squash, merge or rebase" for the last). **STOP.**
- `pin:mismatch` → "PR #<n> is not at the reviewed head, so N1 did not merge it. Re-run `/n1:n1-finish`." **STOP.**
- `state:MERGED sha:<oid>` → capture `<oid>` as the merge commit SHA. Step 6 uses `by n1-finish (mergeOnFinish)`. Go to Step 3.
- `merge-exit:0` with `state:OPEN` (merge queue) → "PR #<n> was queued for merge; re-run `/n1:n1-finish` once it merges." **STOP.** Not a failure.
- `mss:DIRTY` or `mss:BEHIND` and no resolve attempt yet in this run (from 3.1 or here): the merge was refused for conflicts or a stale base. GitHub computes the merge state lazily, so 3.1 can read a stale `CLEAN`. Report the `gh pr merge` output, then follow `<N1_ROOT>/skills/n1-finish/references/resolve-dirty.md` (read it now unless already read in this run). Its § Re-check re-runs 3.1, then 3.2 (ticked actions are not repeated), then this step with `<head>` = the new pin. That is the single retry; never re-run this block with the old `<head>`.
- `mss:DIRTY` or `mss:BEHIND` after a resolve attempt in this run → "PR #<n> has conflicts again after conflict resolution; another PR landed first. Re-run `/n1:n1-finish`." **STOP.**
- Any other `state:` or `mss:` (branch protection, required reviews, a push since 3.1, `UNKNOWN` or `CLEAN` after polling (a refused merge reading `CLEAN` is presumed stale), or an empty re-read) → report the `gh pr merge` output and "PR #<n> was not merged. Merge it yourself, then re-run `/n1:n1-finish`." **STOP.** Never retry and never fall back to auto-merge.

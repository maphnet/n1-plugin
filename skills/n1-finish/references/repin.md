# Re-pin a PR without a valid reviewed-head pin (mergeOnFinish)

Reached from Step 2 § 3.1 when the reviewed-head pin is missing (`pin:` empty) or differs from the PR head, in an interactive n1-finish run with `merge-on-finish:yes`. Asks the user, re-reviews the checked-out PR branch with `/n1:n1-review --full --base <base>`, pushes its fix commits with a lease pinned to the PR head, pins the new head with `n1_review_pin set`, waits for CI when it pushed, then re-runs 3.1. One attempt per run. Queue and headless runs never reach this file, and every writing block re-checks that.

`<n>` is the PR number, `<head>` the `head:` SHA from 3.1, and `<message>` the 3.1 STOP message of the case that routed here. Each **STOP** below ends the run with the quoted message. The pin is written only after a review that ended `Verdict: PASS` on exactly the head being pinned; every other path leaves the pin as it was, so the merge stays blocked.

## § Offer

Ask the user:

```
PR #<n> has no valid reviewed-head pin (head <first 7 of head>, pin <first 7 of pin, or "none">). Re-review the PR branch and re-pin it?
No recommendation. The options are equivalent given the available evidence; select based on team preference.
1 — Re-review the PR branch, then re-pin and continue the merge
2 — No, stop (merge it yourself, then re-run /n1:n1-finish)
```

**2**, or no answer → `<message>` **STOP.** Nothing was changed. **1** → § Preflight.

## § Preflight

One shell call in the current checkout.

```bash
source ~/.n1/preamble.sh
[ "$(n1_merge_authorized)" = true ] && [ -z "${N1_QUEUE_RUN_ID:-}" ] && [ "${N1_HEADLESS:-}" != 1 ] || { echo repin:denied; exit 1; }
N="<n>"; H="<head>"
case "$N" in ""|*[!0-9]*) echo pr:invalid; exit 1;; esac
[[ "$H" =~ ^[0-9a-f]{40}$ ]] || { echo head:invalid; exit 1; }
skip() { echo "repin:skip $1"; exit 1; }
read -r BR BASE XR < <(gh pr view "$N" --json headRefName,baseRefName,isCrossRepository -q '[.headRefName,.baseRefName,(.isCrossRepository|tostring)]|join(" ")' 2>/dev/null)
[ -n "$BR" ] && [ -n "$BASE" ] || skip pr-view
[ "$XR" = false ] && [ "$BR" != "$BASE" ] || skip fork
[ "$(git symbolic-ref -q --short HEAD)" = "$BR" ] || skip branch
git merge-base --is-ancestor "$H" HEAD || skip local-tip
[ -z "$(git status --porcelain --untracked-files=no)" ] || skip dirty
echo "repin:ok head:$H branch:$BR base:$BASE"
```

- `repin:denied` → "Merge is not authorized in this run." **STOP.**
- `pr:invalid` / `head:invalid` → report it. **STOP.**
- `repin:skip <reason>` (`pr-view`: PR lookup failed; `fork`: fork PR or head branch equal to base; `branch`: the current checkout is not the PR branch; `local-tip`: the local branch does not contain the PR head, e.g. commits were pushed from elsewhere (local commits on top of the PR head are fine); `dirty`: uncommitted changes) → "PR #<n> cannot be re-pinned from this checkout (<reason>). Check out the PR branch with the PR head in its history and a clean tree (pull it), then re-run `/n1:n1-finish`; or merge it yourself." **STOP.** Nothing was changed.
- `repin:ok head:<sha> branch:<br> base:<base>` → § Review with `<base>`.

## § Review

Invoke skill `/n1:n1-review --full --base <base>` in the current checkout (`--base` binds the review to the merge-base with the PR's base branch; `--full` forces the FULL tier with security-reviewer, so a docs/config-only or low-risk diff is never skipped or narrowed). That is its Review Loop: it reviews the branch against its base, fixes confirmed findings through the developer persona and commits them locally; it does not push.

- Its final report ends `Verdict: PASS` → run `git rev-parse HEAD` in the checkout and keep it as `<reviewed>` (the head the review ended on), then § Push and pin.
- `Verdict: FAIL`, a STOP inside the review, or no final report → "The re-review of PR #<n> did not pass, so N1 did not re-pin it. Any fix commits are local and unpushed. Fix the remaining findings, then re-run `/n1:n1-finish`; or merge it yourself." **STOP.**

## § Push and pin

One shell call (`<reviewed>` is the SHA kept in § Review). After a push it waits up to 20 s for GitHub to report the new head before pinning. The lease is pinned to the PR head from 3.1, so the push fails if anyone moved the remote branch since then; the review only adds commits, so the push is a fast-forward.

```bash
source ~/.n1/preamble.sh
[ "$(n1_merge_authorized)" = true ] && [ -z "${N1_QUEUE_RUN_ID:-}" ] && [ "${N1_HEADLESS:-}" != 1 ] || { echo repin:denied; exit 1; }
N="<n>"; H="<head>"; REV="<reviewed>"
case "$N" in ""|*[!0-9]*) echo pr:invalid; exit 1;; esac
[[ "$H" =~ ^[0-9a-f]{40}$ ]] && [[ "$REV" =~ ^[0-9a-f]{40}$ ]] || { echo head:invalid; exit 1; }
read -r BR BASE XR < <(gh pr view "$N" --json headRefName,baseRefName,isCrossRepository -q '[.headRefName,.baseRefName,(.isCrossRepository|tostring)]|join(" ")' 2>/dev/null)
NEW=$(git rev-parse HEAD)
[ "$NEW" = "$REV" ] && [ -n "$BR" ] && [ "$XR" = false ] && [ "$BR" != "$BASE" ] && [ "$(git symbolic-ref -q --short HEAD)" = "$BR" ] && [ -z "$(git status --porcelain --untracked-files=no)" ] && git merge-base --is-ancestor "$H" "$NEW" || { echo push:skip; exit 1; }
if [ "$NEW" != "$H" ]; then
  git push -q --force-with-lease="$BR:$H" origin "$BR" 2>&1 || { echo push:rejected; exit 1; }
  echo "pushed:${NEW:0:7}"
  for _ in $(seq 10); do [ "$(gh pr view "$N" --json headRefOid -q .headRefOid 2>/dev/null)" = "$NEW" ] && break; sleep "${REPIN_WAIT_SLEEP:-2}"; done
fi
n1_review_pin set "$N"
[ "$(n1_review_pin get "$N")" = "$NEW" ] && echo "repin:done $NEW" || echo repin:failed
```

- `repin:denied` → "Merge is not authorized in this run." **STOP.** `pr:invalid` / `head:invalid` → report it. **STOP.**
- `push:skip` (the checkout changed, HEAD is not `<reviewed>`, the tree is dirty, or the review rewrote history so the local tip no longer descends from the PR head) → "PR #<n> was re-reviewed but not pushed: the checkout changed. Re-run `/n1:n1-finish`." **STOP.**
- `push:rejected` → "The push of the review fixes for PR #<n> was rejected: the remote branch moved since the check. Nothing was pinned; the local branch holds the fix commits. Pull, then re-run `/n1:n1-finish`." **STOP.**
- `repin:failed` → "Could not record the reviewed-head pin for PR #<n> (the PR head is not the local tip, or the pin write failed), so N1 will not merge it. Re-run `/n1:n1-finish`, or merge it yourself." **STOP.**
- `repin:done <new>` after a `pushed:` line → § CI wait. `repin:done <new>` without one → § Re-check.

## § CI wait

One shell call; run it with the maximum (10-minute) tool timeout: it polls for up to 8 minutes. The same block as `resolve-dirty.md` § CI wait.

```bash
source ~/.n1/preamble.sh
N="<n>"; case "$N" in ""|*[!0-9]*) echo pr:invalid; exit 1;; esac
WF=0; grep -qsE 'pull_request' "$(git rev-parse --show-toplevel)/.github/workflows/"*.y*ml && WF=1
R=timeout; S=; CP=0; NC=0
for _ in $(seq "${RESOLVE_CI_POLLS:-24}"); do
  sleep "${RESOLVE_CI_SLEEP:-20}"; CP=0
  C=$(gh pr checks "$N" --json bucket --jq '"fail="+([.[]|select(.bucket=="fail" or .bucket=="cancel")]|length|tostring)+" pending="+([.[]|select(.bucket=="pending")]|length|tostring)' 2>&1)
  case "$C" in
    "fail=0 pending=0") NC=0; CP=1 ;;
    *"no checks reported"*) NC=$((NC+1)); [ "$WF" = 1 ] || [ "$NC" -lt 3 ] || CP=1 ;;
    "fail=0 "*) NC=0 ;;
    fail=[1-9]*) R=fail; break ;;
    *) NC=0 ;;
  esac
  [ "$CP" = 1 ] || continue
  S=$(gh pr view "$N" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null)
  case "$S" in ""|UNKNOWN) ;; *) R=pass; break ;; esac
done
[ "$R" = timeout ] && [ "$CP" = 1 ] && R=pass
echo "ci:$R"; echo "state:$S"
```

No checks yet with a `pull_request` workflow, and API errors, count as pending. Without one, "no checks reported" passes only after 3 consecutive no-check polls (about 60 s), so push-triggered or external CI (commit status or checks API) can register first; any other poll (checks or API error) resets the count. Green checks with `mergeStateStatus` still `UNKNOWN` at the end count as `ci:pass` (3.1 treats `UNKNOWN` as continue; `--match-head-commit` in 3.4 is the backstop).

- `ci:fail` → "CI is failing on PR #<n> after the review-fix push. Fix CI, then re-run `/n1:n1-finish`." **STOP.**
- `ci:timeout` → "CI still running after the review-fix push; re-run `/n1:n1-finish`." **STOP.**
- `ci:pass` → § Re-check.

## § Re-check

Run the 3.1 pre-merge block again and apply every line, with this run's re-pin attempt counted: a missing or different pin is now a **STOP** with its 3.1 message. The pin now equals the PR head, so `<head>` for 3.2 and 3.4 is `<new>`. A threads answer already given in this run carries over when the count is unchanged. A `state:DIRTY` now follows `resolve-dirty.md` as usual (the pin is valid).

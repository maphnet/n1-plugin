# Step 2: Merge State Machine

N1 merges an open PR only when the entry printed `merge-on-finish:yes` (`finishWork.mergeOnFinish` is `true`; a queue or headless run also needs `autonomy.fullAuto` `true`). Otherwise the human merges, then re-runs n1-finish.

With `headless:yes` or `queue-run:yes`, every **STOP** in 3.1 and 3.4 (and in resolve-dirty.md) is also added under `## Escalations` and posted as a `N1 [headless]` tracker comment.

**Queue runs.** When the entry printed `queue-run:yes` without `merge-on-finish:yes`, report "Queue run: N1 merges only when `autonomy.fullAuto` and `finishWork.mergeOnFinish` are both true. The ticket stops after PR + CI." **STOP.** This covers both the PR path and Step 2b.

Evaluate the PR state:

1. **`MERGED`** → capture the merge commit SHA (`.mergeCommit.oid`). Go to Step 3.
2. **`CLOSED`** (not merged) → report "PR #<n> was closed without merging — nothing to finish. The ticket stays open." **STOP.**
3. **`OPEN`:**
   1. **Pre-merge checks** (only with `merge-on-finish:yes`; otherwise skip to 3.2). One Bash call:
      ```bash
      source ~/.n1/preamble.sh
      N="<n>"; case "$N" in ""|*[!0-9]*) echo pr:invalid; exit 1;; esac
      V=$(gh pr view "$N" --json headRefOid,isDraft,mergeStateStatus -q '"head:"+.headRefOid+" draft:"+(.isDraft|tostring)+" state:"+.mergeStateStatus' 2>/dev/null) || V="head: draft:false state:"
      echo "$V"
      echo "pin:$(n1_review_pin get "$N")"
      C=$(gh pr checks "$N" --json bucket --jq '"checks:fail="+([.[]|select(.bucket=="fail" or .bucket=="cancel")]|length|tostring)+" pending="+([.[]|select(.bucket=="pending")]|length|tostring)' 2>&1)
      case "$C" in checks:*) echo "$C";; *"no checks reported"*) if grep -qsE 'pull_request' "$(git rev-parse --show-toplevel)/.github/workflows/"*.y*ml; then echo checks:expected; else echo checks:none; fi;; *) echo "checks:error ${C:0:200}";; esac
      R=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
      echo "codex:$(cat "$N1_HOME"/review-receipts/*/"${R//\//_}_$N.json" 2>/dev/null | jq -rs 'if length==0 then "none" elif any(.[]; .outcome=="ran") then "ran" else "not-ran" end' 2>/dev/null)"
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
   2. **Deployment actions:** follow `<N1_ROOT>/references/deployment-actions.md` § Parse (already read at entry; do not re-read) with `PRS=<n>` and `OUT=$N1_HOME/scratch/deploy-actions-<n>.tsv`.
      - `fetch-failed:#<n>` → "Could not read the PR #<n> body, so its deployment actions are unknown. Re-run `/n1:n1-finish`." **STOP.**
      - `unticked:0` → nothing to do.
      - `mode:runbook` (headless run) with any unticked row → § Runbook with `ID=<ID>` and an empty `SHA`. Report "Deployment actions pending for <ID>. Resume with `n1-finish <ID>` (runbook in N1 memory)." **STOP.**
      - `mode:walk` with `before` rows → § Walk with `PHASE=before`. `WALK=aborted` → "Merge blocked: before-deploy actions are not complete. Re-run `/n1:n1-finish` when ready; ticked actions are not repeated." **STOP.**
      - `after` rows wait for Step 4.
   3. **Without `merge-on-finish:yes`:** report "PR #<n> is open. Merge it, then re-run /n1:n1-finish." **STOP.**
   4. **With `merge-on-finish:yes`:** merge directly: no auto-merge, no remote-branch deletion (Step 6 leaves that to the repo settings), no retry except the single resolve-then-retry below. The key is the user's consent; do not ask again. One Bash call; `<head>` is the reviewed-head pin from 3.1 (the block re-checks it against the pin, and `--match-head-commit` makes GitHub refuse if the PR head moved since), `<mergeMethod>` is the entry's `finishWork.mergeMethod` (empty means squash):
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

## Step 2b: Local Merge (no-PR path, `prMode == "skip"` only)

**Chained runs:** when the entry printed `chained:yes` without `merge-on-finish:yes`, report "Branch <b> is not merged. Run /n1:n1-finish <ID> to merge locally." **STOP.** A manual run merges locally as below.

1. **Worktree context:** if the current toplevel (`git rev-parse --show-toplevel`) contains `/$(n1_worktree_root)/`, resolve the main checkout (`MAIN_CHECKOUT=$(dirname "$(git rev-parse --git-common-dir)")`) and run the default-branch git commands below from `$MAIN_CHECKOUT` — the default branch is checked out there, and `git checkout <defaultBranch>` inside the worktree fails with "already checked out". The clean-tree precondition then applies to the main checkout. Plain checkout: run everything from the current directory.
2. **Preconditions:** `git status --porcelain` must be empty (dirty tree → "Commit or stash changes first." **STOP.**); the feature branch and `git.defaultBranch` must both exist locally.
3. **Test-suite precondition** (run in the feature-branch directory — the worktree, or the plain checkout on `<branch>`): discover the full-suite test command the same way the qa-engineer does (project root: `package.json` `scripts.test`, `pytest.ini`, `pyproject.toml`, `setup.cfg`, `phpunit.xml`, `go.mod` → `go test ./...`, Makefile `test` target — first match wins).
   - **No test configuration found:** note "no test suite detected — skipping test precondition" in the report and proceed.
   - **Test configuration found:**
     ```bash
     <discovered-test-command> 2>&1; SUITE_EXIT=$?
     ```
     Non-zero `SUITE_EXIT` → report the failure output and "Refusing to merge: test suite is failing (exit code <SUITE_EXIT>). Fix failing tests and re-run `/n1:n1-finish`." **STOP.**
4. **Merge** by `mergeMethod`:
   - `squash`: on `<defaultBranch>` (`git checkout <defaultBranch>`; in `$MAIN_CHECKOUT` when in a worktree): `git merge --squash <branch> && git commit -m "<ID>: <ticket title>"`
   - `merge`: on `<defaultBranch>`: `git merge --no-ff <branch> -m "Merge branch '<branch>'"`
   - `rebase`: in the feature-branch directory: `git rebase <defaultBranch>`; then on `<defaultBranch>`: `git merge --ff-only <branch>`
5. **Merge conflict** → `git merge --abort` (or `git rebase --abort` in the feature-branch directory), report the conflicting files, and in a plain checkout switch back to the feature branch. **STOP.**
6. Capture the merge SHA: `git rev-parse HEAD` on `<defaultBranch>`. **No push.** Report: "Merged `<branch>` into `<defaultBranch>` locally. Push it yourself (for example `!git push origin <defaultBranch>`): N1's merge-deny hook blocks agent pushes to the default branch unless `finishWork.mergeOnFinish` is true."
7. Skip Step 3 (`03-deploy.md`) — nothing is on the remote. Deploy status `skipped (local merge)`, smoke `n/a`. Go to Step 4; the tracker comment is the local-merge variant.

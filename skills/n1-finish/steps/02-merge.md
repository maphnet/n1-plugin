# Step 2: Merge State Machine

N1 merges an open PR only when the entry printed `merge-on-finish:yes` (`finishWork.mergeOnFinish` is `true`, interactive run, not a queue or headless run). Otherwise the human merges, then re-runs n1-finish.

**Queue runs.** When the entry printed `queue-run:yes`, report "Queue run: N1 never merges. The ticket stops after PR + CI." **STOP.** This covers both the PR path and Step 2b.

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
      C=$(gh pr checks "$N" --json bucket --jq '"checks:fail="+([.[]|select(.bucket=="fail" or .bucket=="cancel")]|length|tostring)+" pending="+([.[]|select(.bucket=="pending")]|length|tostring)' 2>&1)
      case "$C" in checks:*) echo "$C";; *"no checks reported"*) if grep -qsE 'pull_request|push' "$(git rev-parse --show-toplevel)/.github/workflows/"*.y*ml; then echo checks:expected; else echo checks:none; fi;; *) echo "checks:error ${C:0:200}";; esac
      R=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
      gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){totalCount nodes{isResolved}}}}}' -f o="${R%/*}" -f r="${R#*/}" -F n="$N" --jq '.data.repository.pullRequest.reviewThreads|if .totalCount>(.nodes|length) then "threads:truncated" else "threads:"+([.nodes[]|select(.isResolved|not)]|length|tostring) end' 2>/dev/null || echo threads:error
      ```
      - `pr:invalid` → **STOP.**
      - `checks:error <msg>` → "Could not read the CI checks of PR #<n> (<msg>). Re-run `/n1:n1-finish`, or merge it yourself." **STOP.**
      - `checks:fail=<k>` with `<k>` > 0 → "CI is failing on PR #<n> (<k> failed or cancelled checks). Fix CI, then re-run `/n1:n1-finish`." **STOP.**
      - `pending=<k>` with `<k>` > 0 → "CI is still running on PR #<n>. Re-run `/n1:n1-finish` when it finishes." **STOP.**
      - `checks:expected` (no checks yet, but the repo has a `pull_request` or `push` workflow) → "CI has not started on PR #<n>; re-run when it reports, or merge it yourself, then re-run `/n1:n1-finish`." **STOP.**
      - `checks:none` (no CI in this repo) or `checks:fail=0 pending=0` → continue.
      - `head:` empty → "Could not read the head commit of PR #<n>. Re-run `/n1:n1-finish`." **STOP.** Otherwise keep it as `<head>` for 3.4.
      - `draft:true` → "PR #<n> is a draft. Mark it ready (`gh pr ready <n>`), then re-run `/n1:n1-finish`." **STOP.** `state:DIRTY` / `BLOCKED` / `BEHIND` → "PR #<n> cannot merge yet (conflicts / required review or checks missing / branch behind base). Fix that, then re-run `/n1:n1-finish`." **STOP.** Other states continue.
      - `threads:0` → Step 6 `Comments:` is `no unresolved comments`.
      - `threads:error` / `threads:truncated` (API error, or more than 100 threads) / `threads:<k>` with `<k>` > 0 → ask the user:
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
   4. **With `merge-on-finish:yes`:** merge directly: no auto-merge, no remote-branch deletion (Step 6 leaves that to the repo settings), no retry. The key is the user's consent; do not ask again. One Bash call; `<head>` from 3.1, `<mergeMethod>` is the entry's `finishWork.mergeMethod` (empty means squash):
      ```bash
      source ~/.n1/preamble.sh
      [ "$(n1_finish_merge_enabled)" = true ] && [ -z "${N1_QUEUE_RUN_ID:-}" ] && [ "${N1_HEADLESS:-}" != 1 ] || { echo merge:denied; exit 1; }
      N="<n>"; H="<head>"; MM="<mergeMethod>"
      case "$N" in ""|*[!0-9]*) echo pr:invalid; exit 1;; esac
      [[ "$H" =~ ^[0-9a-f]{40}$ ]] || { echo head:invalid; exit 1; }
      case "${MM:-squash}" in squash|merge|rebase) MM=${MM:-squash};; *) echo method:invalid; exit 1;; esac
      echo "mergeOnFinish=true: merging PR #$N ($MM)"
      gh pr merge "$N" "--$MM" --match-head-commit "$H" 2>&1; echo "merge-exit:$?"
      gh pr view "$N" --json state,mergeCommit -q '"state:"+.state+" sha:"+(.mergeCommit.oid // "")'
      ```
      - `merge:denied` → "Merge is not authorized in this run." **STOP.**
      - `pr:invalid` / `head:invalid` / `method:invalid` → report it ("`finishWork.mergeMethod` must be squash, merge or rebase" for the last). **STOP.**
      - `state:MERGED sha:<oid>` → capture `<oid>` as the merge commit SHA. Step 6 uses `by n1-finish (mergeOnFinish)`. Go to Step 3.
      - Any other `state:` → report the `gh pr merge` output (branch protection, required reviews, conflicts, or a push since 3.1) and "PR #<n> was not merged. Merge it yourself, then re-run `/n1:n1-finish`." **STOP.** Never retry and never fall back to auto-merge.

## Step 2b: Local Merge (no-PR path, `prMode == "skip"` only)

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
6. Capture the merge SHA: `git rev-parse HEAD` on `<defaultBranch>`. **No push.** Report: "Merged `<branch>` into `<defaultBranch>` locally. Push manually when ready: `git push origin <defaultBranch>`."
7. Skip Step 3 (`03-deploy.md`) — nothing is on the remote. Deploy status `skipped (local merge)`, smoke `n/a`. Go to Step 4; the tracker comment is the local-merge variant.

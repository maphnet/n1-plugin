# Step 2: Merge State Machine

N1 never merges a PR: the human merges, then re-runs n1-finish.

**Queue runs.** When the entry printed `queue-run:yes`, report "Queue run: N1 never merges. The ticket stops after PR + CI." **STOP.** This covers both the PR path and Step 2b.

Evaluate the PR state:

1. **`MERGED`** → capture the merge commit SHA (`.mergeCommit.oid`). Go to Step 3.
2. **`CLOSED`** (not merged) → report "PR #<n> was closed without merging — nothing to finish. The ticket stays open." **STOP.**
3. **`OPEN`:** **Deployment actions:** follow `<N1_ROOT>/references/deployment-actions.md` § Parse (already read at entry; do not re-read) with `PRS=<n>` and `OUT=$N1_HOME/scratch/deploy-actions-<n>.tsv`.
   - `fetch-failed:#<n>` → "Could not read the PR #<n> body, so its deployment actions are unknown. Re-run `/n1:n1-finish`." **STOP.**
   - `unticked:0` → nothing to do.
   - `mode:runbook` (headless run) with any unticked row → § Runbook with `ID=<ID>` and an empty `SHA`. Report "Deployment actions pending for <ID>. Resume with `n1-finish <ID>` (runbook in N1 memory)." **STOP.**
   - `mode:walk` with `before` rows → § Walk with `PHASE=before`. `WALK=aborted` → "Merge blocked: before-deploy actions are not complete. Re-run `/n1:n1-finish` when ready; ticked actions are not repeated." **STOP.**
   - `after` rows wait for Step 4.

   Then report "PR #<n> is open. Merge it, then re-run /n1:n1-finish." **STOP.**

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
